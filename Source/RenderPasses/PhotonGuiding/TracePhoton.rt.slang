#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.RaytracingInline;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import StructsAndHelpers;

cbuffer CB
{
    uint gMaxBounces;   // Max number of bounces allowed
    uint gFrameCount;   // Frame count since scene was loaded.
    float2 gPhotonRadius;//Global/Caustic radius

    uint gDispatchDimension;    //Dispatch dims (x,y identical) 
    float gGlobalRejectionProb; //Rejection Probability for global photons
    uint2 gScreenRes;   //For back projection

    float gImagePlaneDist;
    float gNormalizedPixelArea;
}

#if USE_EMISSIVE_LIGHT // Buffer is only valid if emissive light is enabled
cbuffer Light {
    EmissiveLightSampler gEmissiveSampler;
}
#endif

RWStructuredBuffer<AABB> gPhotonAABB[2];
RWStructuredBuffer<PhotonData> gPhotonData[2];
RWBuffer<uint> gPhotonCounter;
RWTexture2D<uint> gLightTraceColor[3]; //Uint spinlock color texture for every channel 

static const bool kAlphaTest = true;
static const uint2 kPhotonBufferSize = uint2(PHOTON_BUFFER_SIZE_GLOBAL, PHOTON_BUFFER_SIZE_CAUSTIC);
static const float kRoughnessThreshold = ROUGHNESS_THRESHOLD;
static const bool kRussianRoulette = true;  //TODO as option

struct RayPayload
{
    PackedHitInfo packedHitInfo; //< Hit Info

    /** Create ray payload with default parameters.
     */
    __init()
    {
        this.packedHitInfo = {};
    }
}

//Helper struct to generate a photon form the lightSources
struct PhotonLightSample {
    float3 posW;
    float emissionPDF;
    float3 normal;
    float directPDF;
    float3 flux;
    float cosTheta;
};

// transforms direction from local to world space
float3 fromLocalToWorld(const in float3 normal, float3 w)
{
    // transform from local space -> random dir vector in world space
    float3 bitangent = perp_stark(normal);
    float3 tangent = cross(bitangent, normal);

    return w.x * tangent + w.y * bitangent + w.z * normal;
}

#if USE_EMISSIVE_LIGHT // Function is only valid if the emissive sampler is set
bool createLightSample(inout SampleGenerator sg, out PhotonLightSample pls) {
    pls = {};
    if (gScene.lightCollection.isEmpty())
        return false;

    // Randomly pick a triangle out of the global list with uniform probability
    const uint triangleCount = gScene.lightCollection.triangleCount;
    // Safety precaution as the result of the multiplication may be rounded to triangleCount even if uLight < 1.0 when triangleCount is large.
    uint triangleIndex = min((uint)(sampleNext1D(sg) * triangleCount), triangleCount - 1);

    float triangleSelectionPdf = 1.0 / triangleCount;

    const EmissiveTriangle tri = gScene.lightCollection.getTriangle(triangleIndex);
    const float3 barycentrics = sample_triangle(sampleNext2D(sg));
    pls.posW = tri.getPosition(barycentrics);
    pls.normal = tri.normal;

    // Get Flux
    float2 uv = tri.getTexCoord(barycentrics);
    pls.flux = gScene.materials.evalEmissive(tri.materialID, uv) * tri.area;

    pls.posW = computeRayOrigin(pls.posW, pls.normal); //Offset as this light is real geometry
    pls.flux /= triangleSelectionPdf;

    pls.emissionPDF = 1.0 / (tri.area * triangleCount);
    pls.directPDF = pls.emissionPDF;

    return true;
}
#endif

bool createLightSampleAnalytic(inout SampleGenerator sg, out PhotonLightSample pls, out float3 sampledDir)
{
    pls = {};
    sampledDir = float3(0);
    const uint lightCount = gScene.getLightCount();
    if (lightCount == 0)
        return false;
    // Uniformly sample one of the analytic lights
    float rndLightIdx = float(lightCount) * sampleNext1D(sg);
    uint lightIdx = min(uint(floor(rndLightIdx)), lightCount - 1);
    LightData lightData = gScene.getLight(lightIdx);

    // Only Point(+ Spot) lights are supported (due to RTXDI)
    if (lightData.type != uint(LightType::Point))
        return false;
    float invLightPdf;
    float3 woLocal;
    float3 rnd = sampleNext3D(sg);
    rnd.z = 0;
    float spotAngle = lightData.cosOpeningAngle;
    if (lightData.openingAngle < M_2PI) // If the opening angle is smaller than 2PI it is a spotlight
    {
        spotAngle = cos(lightData.openingAngle - lightData.penumbraAngle * rnd.z);
        woLocal = sample_cone(rnd.xy, spotAngle);
    }
    else // Pointlight
    {
        woLocal = sample_sphere(rnd.xy);
    }
    invLightPdf = M_2PI * (1.f - spotAngle);

    if (invLightPdf <= 0.f)
        return false;

    invLightPdf *= lightCount; // Take the select pdf into account

    // Fill the photon light struct
    pls.posW = lightData.posW;
    pls.normal = lightData.dirW;
    pls.flux = lightData.intensity * invLightPdf;

    sampledDir = fromLocalToWorld(pls.normal, woLocal);
    return true;
}

void spinlockToImage(RWTexture2D<uint> colorTex, uint2 pixel, float value)
{
    uint currentColor = 0;
    uint originalValue;
    [allow_uav_condition]
    do {
        InterlockedAdd(colorTex[pixel], 0u, currentColor);
        float color = asfloat(currentColor);
        uint updatedColor = asuint(color + value);
        InterlockedCompareExchange(colorTex[pixel], currentColor, updatedColor, originalValue);
    } while (originalValue != currentColor);
}

bool backprojectPhotonToCamera(ShadingData sd, IMaterialInstance mi, PhotonData photon, uint lightCount, inout SampleGenerator sg)
{
    float4 screenPos = mul(gScene.camera.getViewProj(), float4(sd.posW, 1));
    screenPos /= screenPos.w;
    screenPos.y *= -1;
    screenPos.xy = screenPos.xy * 0.5 + 0.5; // UV from [-1,1] to [0,1]
    if (any(screenPos.xy < 0) || any(screenPos.xy >= 1) || screenPos.z < 0 || screenPos.z > 1)
        return false;

    float3 directionToCamera = gScene.camera.getPosition() - sd.posW;
    float distanceToCamera = length(directionToCamera);
    directionToCamera /= distanceToCamera;
    
    // Bsdf and pdf to camera
    float3 bsdf = mi.eval(sd, directionToCamera, sg);
    float reversePDF = mi.evalPdf(sd, directionToCamera, sd.V);

    if (all(bsdf <= 0))
        return false;

    // Pdf conversion factor from image plane
    const float3 camForward = normalize(gScene.camera.data.cameraW);
    const float cosAtCamera = dot(-directionToCamera, camForward);
    const float cameraPdf = distanceToCamera * distanceToCamera * gNormalizedPixelArea * pow(cosAtCamera, 3); //Surface to image factor

    const float pathPDF = photon.pdf  * cameraPdf;
    const float reversePathPDF = photon.reversePdf * reversePDF; // Path tracing probability
    float misWeight = pathPDF / (pathPDF + reversePathPDF);

    // Contribution on image (no MIS needed, as this is the only technique that can contribute)
    float3 contribution = (misWeight * photon.flux * bsdf) / (lightCount * cameraPdf);
    
    if(any(contribution > 0))
    {
        //Visibility
        SceneRayQuery<1> rayQuery;
        const Ray ray = Ray(sd.computeNewRayOrigin(), directionToCamera , 0.f, distanceToCamera);
        if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
            return false;

        // If backprojection is valid, spinlock the value to the screen buffer
        const uint2 pixel = uint2(floor((screenPos.xy * gScreenRes) + 0.5));
        spinlockToImage(gLightTraceColor[0], pixel, contribution.x);
        spinlockToImage(gLightTraceColor[1], pixel, contribution.y);
        spinlockToImage(gLightTraceColor[2], pixel, contribution.z);
    }

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

    const float invRejection = 1.f / gGlobalRejectionProb;

    SampleGenerator sg = SampleGenerator(pixel, gFrameCount * 2);
    RayDesc ray;
    PhotonLightSample pls;

    //Create a photon by sampling from emissive lights or analytic light sources
#if USE_EMISSIVE_LIGHT
    if (false)
#endif
    { // Analytic light sample
        float3 sampleDir;
        if (!createLightSampleAnalytic(sg, pls, sampleDir))
            return;

        ray.Direction = sampleDir;
    }
#if USE_EMISSIVE_LIGHT
    else { // Emissive light sample
        if (!createLightSample(sg, pls))
            return;

        float lightDirPDF = 1.0;
        float3 woLocal = sample_cosine_hemisphere_concentric(sampleNext2D(sg), lightDirPDF);

        if (lightDirPDF <= 0.f)
            return;

        ray.Direction = fromLocalToWorld(pls.normal, woLocal);
        pls.flux *= M_PI; // Lambert Emitter
        pls.cosTheta = woLocal.z;
        pls.emissionPDF *= lightDirPDF;
    }
#endif
    const uint lightCount = dispatchDims.x * dispatchDims.y;
    //pls.flux /= float3(lightCount); // Division through all dipatched photons

    // MIS constants
    //const float etaVCM = (M_PI * gPhotonRadius.x * gPhotonRadius.x) * lightCount;
    //float mMisVmWeightFactor = etaVCM;
    //float mMisVcWeightFactor = (1.0 / etaVCM); //Maybe this needs to be 0 if no light tracing is used

    //Prepare the rest of the ray
    ray.Origin = pls.posW;
    ray.TMin = 0.0f;
    ray.TMax = FLT_MAX;
    RayPayload rayPayload = RayPayload();
    
    bool storeAsCaustic = false;
    bool reflectedDiffuse = false;
    float3 photonStartFlux = pls.flux;
    float3 thp = float3(1.0); //Throughput

    PhotonData photon = PhotonData();
    photon.flux = photonStartFlux;
    photon.dir = -ray.Direction;
    photon.normalW = pls.normal;
    photon.pdf = pls.emissionPDF;
    //photon.dVCM = pls.directPDF / pls.emissionPDF;
    //photon.dVC = pls.cosTheta / pls.emissionPDF;
    //photon.dVM = photon.dVC * mMisVcWeightFactor;

    // Main Loop
    for (uint i = 0; i < gMaxBounces; i++) {
        TraceRay(gScene.rtAccel, 0 /*Flags*/, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayPayload);

        HitInfo hit = HitInfo(rayPayload.packedHitInfo);
        if (!hit.isValid())
            return;

        // Get shading infos
        let lod = ExplicitLodTextureSampler(0);

        // Get Material properties
        uint hints = (uint)MaterialInstanceHints::AdjustShadingNormal;
        ShadingData sd = loadShadingData(hit, ray.Direction, lod);
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
        let bsdfProperties = mi.getProperties(sd);

        // Update MIS helpers
        /*
        if (i > 0) {
            float dist = distance(sd.posW, ray.Origin);
            photon.dVCM *= dist * dist;
        }
        float cosTheta = abs(dot(sd.faceN, sd.V));
        photon.dVCM /= cosTheta;
        photon.dVM /= cosTheta;
        photon.dVC /= cosTheta;
        photon.continationProb = getContinuationProbablity(bsdfProperties);
        */

        photon.normalW = sd.getOrientedFaceNormal();
        reflectedDiffuse = bsdfProperties.roughness > kRoughnessThreshold;
        float continuationProb = getContinuationProbablity(bsdfProperties);
        photon.reversePdf *= continuationProb;

        // Backprojection to camera
        if (reflectedDiffuse && i>0)
        {
            backprojectPhotonToCamera(sd, mi, photon, lightCount, sg);
        }

        // Store Photon
        if (reflectedDiffuse) {
            PhotonType photonType = storeAsCaustic ? PhotonType::Caustic : PhotonType::Global;
            bool storePhoton = true;
            if (photonType == PhotonType::Global) {
                storePhoton = sampleNext1D(sg) <= gGlobalRejectionProb;
                photon.flux *= invRejection;
            }
            if (storePhoton) {
                uint photonTypeIdx = (uint)photonType;
                uint photonInsertIndex = 0;
                InterlockedAdd(gPhotonCounter[photonTypeIdx], 1u, photonInsertIndex);
                if (photonInsertIndex <= kPhotonBufferSize[photonTypeIdx])
                {
                    // photon.flux = float3(1, 0, 0);
                    AABB photonAABB = AABB(sd.posW - gPhotonRadius[photonTypeIdx], sd.posW + gPhotonRadius[photonTypeIdx]);
                    gPhotonAABB[photonTypeIdx][photonInsertIndex] = photonAABB;
                    gPhotonData[photonTypeIdx][photonInsertIndex] = photon;
                }
            }
        }
             
        //Photon Bounce for next iteration
        BSDFSample bsdfSample;
        bool validSample = mi.sample(sd, sg, bsdfSample, true /*ImportanceSampling*/);
        if (!validSample)
            return;
        bool transmission = bsdfSample.isLobe(LobeType::Transmission);
        ray.Origin = sd.computeNewRayOrigin(!transmission); // false is for transmissions
        ray.Direction = bsdfSample.wo;
        thp *= bsdfSample.weight;
        bool isEmissive = any(bsdfProperties.emission > 0);

        // RussianRoulette
        if (sampleNext1D(sg) > continuationProb || isEmissive)
        {
            return; // Photon is absorbed
        }

        thp /= continuationProb;

        // Update Photon
        storeAsCaustic = !reflectedDiffuse;
        photon.dir = -ray.Direction;
        photon.flux = photonStartFlux * thp;
        photon.pathLenght++;

        // Update MIS weight
        if (reflectedDiffuse)
        {
            photon.pdf *= bsdfSample.pdf * continuationProb;
            photon.reversePdf *= mi.evalPdf(sd, ray.Direction, sd.V); // Continuation prob was handled above
        } else {
            photon.pdf *= 1;
            photon.reversePdf *= mi.evalPdf(sd, ray.Direction, sd.V);
        }

        // Partially update MIS weights
        /*
        float cosThetaOut = abs(dot(sd.faceN, ray.Direction));
        float bsdfPdf = bsdfSample.pdf * photon.continationProb;
        float bsdfReversePDF = mi.evalPdf(sd, ray.Direction, sd.V) * photon.continationProb; 

        if (reflectedDiffuse)
        {
            photon.dVC = (cosThetaOut / bsdfPdf) * (photon.dVC * bsdfReversePDF) + (photon.dVCM + mMisVmWeightFactor);
            photon.dVM = (cosThetaOut / bsdfPdf) * (photon.dVM * bsdfReversePDF) + (photon.dVCM * mMisVcWeightFactor + 1.0);
            photon.dVCM = 1.0 / bsdfPdf;
        } else // Specular
        {
            photon.dVCM = 0;
            photon.dVM *= cosThetaOut;
            photon.dVC *= cosThetaOut;
        }
        */
    }
}
