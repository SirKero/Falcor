#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.RaytracingInline;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import StructsAndHelpers;

cbuffer CB
{
    uint gFrameCount;                     // Frame count since scene was loaded.
    float2 gPhotonRadius;                 // Global/Caustic radius
    PackedPathLength gPackedPathLength;   // Packed Path Length

    float gGlobalRejectionProb; // Rejection Probability for global photons
    uint gDispatchDimension;    // Dispatch dims (x,y identical) 
    uint2 gScreenDimensions;    //Camera screen dimensions in pixels for backprojection

    float gMixedLightsAnalyticProbability;  //Probablity that a analytic light is choosen when mixed lights are utilized
    float gNormalizedPixelDiagonal;         //Approximated pixel diagonal at distance 1
}

RWStructuredBuffer<AABB> gPhotonAABB[2];       //(Global/Caustic) AABBs for the Acceleration Structure
RWStructuredBuffer<PhotonData> gPhotonData[2]; //(Global/Caustic) Photon Data
RWStructuredBuffer<PackedHitInfo> gPhotonHitInfo;   //Caustic Photon Hit Info for backprojection
RWStructuredBuffer<uint> gPhotonCounter;            //Counter

RWTexture2D<int> gLightTraceHeadCounter;        //Head index for the linked list
RWStructuredBuffer<int> gLightTraceLinkedList; //next pointer

static const bool kAlphaTest = ENABLE_ALPHA_TEST;
static const uint kRNGNumPasses = RNG_NUM_PASSES;
static const uint2 kPhotonBufferSize = uint2(PHOTON_BUFFER_SIZE_GLOBAL, PHOTON_BUFFER_SIZE_CAUSTIC);
static const float kRoughnessThreshold = ROUGHNESS_THRESHOLD;
static const bool kUseEmissive = USE_EMISSIVE_LIGHTS;
static const bool kUseAnalytic = USE_ANALYTIC_LIGHTS;
static const bool kUseAdaptivePhotonRadius = USE_ADAPTIVE_PHOTON_RADIUS;

struct RayPayload
{
    PackedHitInfo packedHitInfo; //< Hit Info

    __init()
    {
        this.packedHitInfo = {};
    }
}

//Helper struct to generate a photon form the lightSources
struct PhotonLightSample {
    float3 posW;
    float normalX;
    float3 dirW;
    float normalY;
    float3 flux;
    float normalZ;

    property float3 normal {
        get { return float3(normalX, normalY, normalZ); }
        set {
            normalX = newValue.x;
            normalY = newValue.y;
            normalZ = newValue.z;
        }
    }
};

float getPhotonRadius(const uint photonTypeIdx, const float3 hitPos)
{
    float adaptiveRadius = 1.0;
    if (kUseAdaptivePhotonRadius)
    {
        float distToCamera = distance(hitPos, gScene.camera.getPosition());
        adaptiveRadius = (gNormalizedPixelDiagonal * distToCamera) / 2.0;
    }
    return adaptiveRadius * gPhotonRadius[photonTypeIdx];
}

bool generateLightSample(inout SampleGenerator sg, out PhotonLightSample ls)
{
    ls = {};

    float3 woLocal = float3(0);
    bool isEmissive = kUseEmissive;
    if (kUseAnalytic && kUseEmissive)
    {
        isEmissive = sampleNext1D(sg) > gMixedLightsAnalyticProbability;
    }

    if (isEmissive)
    {
        const uint lightCount = gScene.lightCollection.triangleCount;
        const uint selectedLight = min(uint(floor(lightCount * sampleNext1D(sg))), lightCount - 1);
        // Get emissive triangle data
        const EmissiveTriangle tri = gScene.lightCollection.getTriangle(selectedLight);
        const float3 barycentrics = sample_triangle(sampleNext2D(sg)); // Sample random triangle position
        ls.posW = tri.getPosition(barycentrics);
        ls.normal = tri.normal;

        // Sample emissive material of the triangle
        float2 uv = tri.getTexCoord(barycentrics);
        ls.flux = gScene.materials.evalEmissive(tri.materialID, uv) * tri.area;

        ls.posW = computeRayOrigin(ls.posW, ls.normal); // Offset as this light is real geometry

        // Sample random direction in a cosine lobe
        float lightDirPDF = 1.0;
        woLocal = sample_cosine_hemisphere_concentric(sampleNext2D(sg), lightDirPDF);
        if (lightDirPDF <= 0.) // Invalid direction
            return false;
        ls.flux *= M_PI;               // Lambert Emitter (or reduced cos/pdf)
        ls.flux *= lightCount;         // Inv light select pdf
        if (kUseAnalytic && kUseEmissive)
            ls.flux /= 1.0 - gMixedLightsAnalyticProbability; // Probability to select an emissive light
    } else
    {
        const uint lightCount = gScene.getLightCount();
        const uint selectedLight = min(uint(floor(lightCount * sampleNext1D(sg))), lightCount - 1);
        LightData lightData = gScene.getLight(selectedLight);
        // Only Point (and Spot) lights are supported
        if (lightData.type != uint(LightType::Point))
            return false;

        float spotAngle = lightData.cosOpeningAngle;
        float2 rndDir = sampleNext2D(sg); // Random direction variable
        // Depending on the opening angle, the light is a spot or point light
        if (lightData.openingAngle < M_2PI) // Spot Light
        {
            woLocal = sample_cone(rndDir, spotAngle);
        } else // Point Light
        {
            spotAngle = 0; // Just to be sure
            woLocal = sample_sphere(rndDir);
        }
        float invLightPdf = M_2PI * (1.0 - spotAngle);
        ls.normal = lightData.dirW;
        ls.posW = lightData.posW;
        ls.flux = lightData.intensity * invLightPdf;
        ls.flux *= lightCount; // Inv light select pdf
        if (kUseAnalytic && kUseEmissive)
            ls.flux /= gMixedLightsAnalyticProbability; // Probability to select an emissive light
    }

    // Local to world direction
    // Convert direction local -> world
    float3 bitangent = perp_stark(ls.normal);
    float3 tangent = cross(bitangent, ls.normal);
    ls.dirW = woLocal.x * tangent + woLocal.y * bitangent + woLocal.z * ls.normal;

    //Divide by the number of light paths
    ls.flux /= gDispatchDimension * gDispatchDimension;
    return true;
}

//Backprojects the caustic photon and stores it in an linked list to collect all pixels caustic photons with RIS
bool causticPhotonBackprojection(uint photonBufferIndex, ShadingData sd)
{
    // Check if position is in camera view
    float4 screenPos = mul(gScene.camera.getViewProj(), float4(sd.posW, 1));
    screenPos /= screenPos.w;
    screenPos.y *= -1;
    screenPos.xy = screenPos.xy * 0.5 + 0.5; // UV from [-1,1] to [0,1]
    if (any(screenPos.xy < 0) || any(screenPos.xy >= 1) || screenPos.z < 0 || screenPos.z > 1)
        return false;

    // If the photon is in screen it is assumed that it will contribute something
    // Check visibility with ray query
    float3 directionToCamera = gScene.camera.getPosition() - sd.posW;
    float distanceToCamera = length(directionToCamera);
    directionToCamera /= distanceToCamera;

    SceneRayQuery<1> rayQuery;
    const Ray ray = Ray(sd.computeNewRayOrigin(), directionToCamera, 0.f, distanceToCamera);
    if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
        return false;

    // Caustic photon is a valid sample, add to the linked list for the RIS pass later
    uint2 currentPixel = uint2(floor(screenPos.xy * gScreenDimensions));
    int nodeNext = -1;
    InterlockedExchange(gLightTraceHeadCounter[currentPixel], photonBufferIndex, /*out*/ nodeNext);
    gLightTraceLinkedList[photonBufferIndex] = nodeNext;
    return true;
}

[shader("miss")]
void miss(inout RayPayload rayData: SV_RayPayload)
{
    HitInfo hitInfo = {};
    rayData.packedHitInfo = hitInfo.getData(); // Invalid hit
}

//For alpha test
[shader("anyhit")]
void anyHit(inout RayPayload rayData: SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs: SV_IntersectionAttributes)
{
    if (kAlphaTest)
    {
        // Alpha test for non-opaque geometry.
        GeometryInstanceID instanceID = getGeometryInstanceID();
        VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
        uint materialID = gScene.getMaterialID(instanceID);
        if (gScene.materials.alphaTest(v, materialID, 0.f))
            IgnoreHit();
    }
}

[shader("closesthit")]
void closestHit(inout RayPayload rayData: SV_RayPayload, BuiltInTriangleIntersectionAttributes attribs: SV_IntersectionAttributes) {
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;

    rayData.packedHitInfo = HitInfo(triangleHit).getData();
}

[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 dispatchDims = DispatchRaysDimensions().xy;

    SampleGenerator sg = SampleGenerator(pixel, gFrameCount * kRNGNumPasses);
    RayDesc ray;
    PhotonLightSample pls;

    if (!generateLightSample(sg, pls))
        return;
    
    //Prepare Ray and Payload
    ray.Origin = pls.posW;
    ray.Direction = pls.dirW;
    ray.TMin = 0.0;
    ray.TMax = FLT_MAX;
    RayPayload rayPayload = RayPayload();

    //Loop Variables
    bool storeAsCaustic = false;
    bool reflectedDiffuse = false;
    PackedPathLength pathLengthInfo = PackedPathLength();
    PhotonData photon = PhotonData();
    photon.flux = pls.flux;
    photon.dir = -ray.Direction;
    photon.normalW = pls.normal;
    
    // Main Loop
    for (uint i = 0; i < gPackedPathLength.pathLength; i++) {
        //Trace Ray
        TraceRay(gScene.rtAccel, 0 /*Flags*/, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayPayload);

        //Handle Hit
        HitInfo hit = HitInfo(rayPayload.packedHitInfo);
        if (!hit.isValid())
            return;

        // Get Material and Properties
        let lod = ExplicitLodTextureSampler(0);
        uint hints = (uint)MaterialInstanceHints::AdjustShadingNormal;
        ShadingData sd = loadShadingData(hit, -ray.Direction, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
        let bsdfProperties = mi.getProperties(sd);

        // Store Photon
        photon.normalW = sd.getOrientedFaceNormal();
        reflectedDiffuse = bsdfProperties.roughness > kRoughnessThreshold;
        float3 tmpPhotonFlux = photon.flux; //Rejection probability can cahnge the flux, therefore we temporally store the flux here 
        if (reflectedDiffuse) {
            PhotonType photonType = storeAsCaustic ? PhotonType::Caustic : PhotonType::Global;
            bool storePhoton = true;
            if (photonType == PhotonType::Global) {
                storePhoton = sampleNext1D(sg) <= gGlobalRejectionProb;
                photon.flux /= gGlobalRejectionProb;
            }
            if (storePhoton) {
                uint photonTypeIdx = (uint)photonType;
                uint photonInsertIndex = 0;
                InterlockedAdd(gPhotonCounter[photonTypeIdx], 1u, photonInsertIndex);
                if (photonInsertIndex < kPhotonBufferSize[photonTypeIdx])
                {
                    float photonRadius = getPhotonRadius(photonTypeIdx, sd.posW);
                    AABB photonAABB = AABB(sd.posW - photonRadius, sd.posW + photonRadius);
                    gPhotonAABB[photonTypeIdx][photonInsertIndex] = photonAABB;
                    gPhotonData[photonTypeIdx][photonInsertIndex] = photon;
                    if (photonType == PhotonType::Caustic) {
                        if (causticPhotonBackprojection(photonInsertIndex, sd))
                            gPhotonHitInfo[photonInsertIndex] = hit.getData();
                    }
                }
            }
        }
        // Restore flux
        photon.flux = tmpPhotonFlux;

        //Photon Bounce for next iteration
        BSDFSample bsdfSample;
        bool validSample = mi.sample(sd, sg, bsdfSample, true /*ImportanceSampling*/);

        // Path Length
        if (bsdfSample.isLobe(LobeType::Delta))
            pathLengthInfo.deltaBounces = pathLengthInfo.deltaBounces + 1;
        else if (bsdfSample.isLobe(LobeType::Diffuse))
            pathLengthInfo.diffuseBounces = pathLengthInfo.diffuseBounces + 1;
        else if (bsdfSample.isLobe(LobeType::Specular))
            pathLengthInfo.specularBounces = pathLengthInfo.specularBounces + 1;
        validSample &= pathLengthInfo.comparePathLengts(gPackedPathLength);

        if (!validSample)
            return;

        //Prepare next ray and update photon
        bool transmission = bsdfSample.isLobe(LobeType::Transmission);
        ray.Origin = sd.computeNewRayOrigin(!transmission); // false is for transmissions
        ray.Direction = bsdfSample.wo;
        photon.flux *= bsdfSample.weight;

        // Update Photon
        storeAsCaustic = !reflectedDiffuse;
        photon.dir = -ray.Direction;
        photon.pathLenght++;
    }
}
