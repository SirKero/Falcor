#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.RaytracingInline;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Rendering.Lights.LightHelpers;
import Rendering.PhotonGuiding.PhotonGuiding;
import StructsAndHelpers;

cbuffer CB
{
    uint gFrameCount;                     // Frame count since scene was loaded.
    float2 gPhotonRadius;                 // Global/Caustic radius
    PackedPathLength gPackedPathLength;   // Packed Path Length

    float gGlobalRejectionProb; // Rejection Probability for global photons
    uint2 gDispatchDimension;   // Dispatch dims (x,y identical)
    float gNormalizedPixelDiagonal; // Approximated pixel diagonal at distance 1

    uint2 gScreenDimensions; // Camera screen dimensions in pixels for backprojection
    float gMixedLightsAnalyticProbability; // Probablity that a analytic light is choosen when mixed lights are utilized
    uint _pad;
}

#if IS_SHIFT
    #if IS_SHIFT_PATH
        RWStructuredBuffer<PathReservoir> gPathReservoir;
    #elif IS_SHIFT_CAUSTIC
        RWStructuredBuffer<CausticReservoir> gCausticReservoir;
        Texture2D<uint2> gCausticReservoirGuidingData;
    #endif
#else
    RWStructuredBuffer<AABB> gPhotonAABB[2];       //(Global/Caustic) AABBs for the Acceleration Structure
    RWStructuredBuffer<PhotonData> gPhotonData[2]; //(Global/Caustic) Photon Data
    RWStructuredBuffer<PhotonGuidingData> gPhotonGuidingData[2]; //(Global/Caustic) Photon Guiding Data (can be nullptr)
    RWStructuredBuffer<PackedHitInfo> gPhotonHitInfo;   //Caustic Photon Hit Info for backprojection
    RWStructuredBuffer<uint> gPhotonCounter;            //Counter
#endif
RWTexture2D<int> gLightTraceHeadCounter;        //Head index for the linked list
RWStructuredBuffer<int> gLightTraceLinkedList; //next pointer

static const bool kAlphaTest = ENABLE_ALPHA_TEST;
static const uint kRNGNumPasses = RNG_NUM_PASSES;
static const uint2 kPhotonBufferSize = uint2(PHOTON_BUFFER_SIZE_GLOBAL, PHOTON_BUFFER_SIZE_CAUSTIC);
static const float kRoughnessThreshold = ROUGHNESS_THRESHOLD;
static const bool kUseEmissive = USE_EMISSIVE_LIGHTS;
static const bool kUseAnalytic = USE_ANALYTIC_LIGHTS;
static const bool kUseAdaptivePhotonRadius = USE_ADAPTIVE_PHOTON_RADIUS;
static const bool kDiffClassUseLobes = DIFF_CLASS_USE_LOBES;

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

bool generateLightSample(inout SampleGenerator sg, out PhotonLightSample ls, out float invPhotonScaleFactor)
{
    ls = {};
    invPhotonScaleFactor = 1.0;

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
        ls.flux *= M_PI;                    // Lambert Emitter (or reduced cos/pdf)
        invPhotonScaleFactor /= lightCount;         // Inv light select pdf
        if (kUseAnalytic && kUseEmissive)
            invPhotonScaleFactor *= 1.0 - gMixedLightsAnalyticProbability; // Probability to select an emissive light
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
        invPhotonScaleFactor /= lightCount; // Inv light select pdf
        if (kUseAnalytic && kUseEmissive)
            invPhotonScaleFactor *= gMixedLightsAnalyticProbability; // Probability to select an emissive light
    }

    // Local to world direction
    // Convert direction local -> world
    float3 bitangent = perp_stark(ls.normal);
    float3 tangent = cross(bitangent, ls.normal);
    ls.dirW = woLocal.x * tangent + woLocal.y * bitangent + woLocal.z * ls.normal;

    // Add number of photon paths to probability
    invPhotonScaleFactor *= gDispatchDimension.x * gDispatchDimension.y;
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

    // Get the sample generator. For shift, the reservoir needs to be loaded
    // For initial photon tracing, the sample generator is initialized normaly
    SampleGenerator sg;
    #if IS_SHIFT
        #if IS_SHIFT_PATH
            PathReservoir pathReservoir = gPathReservoir[index2Dto1D(pixel, dispatchDims.x)];
            // Return early if reservoir is not valid or not a photon path
            bool isValidPhotonPath = pathReservoir.isValid() && (pathReservoir.flags.isRadianceEstimate || pathReservoir.flags.isFinalGather);
            if (!isValidPhotonPath)
                return;
            sg = createPhotonSGFromPacked(pathReservoir.packedPhotonRetraceData);
        #elif IS_SHIFT_CAUSTIC
            CausticReservoir causticReservoir = gCausticReservoir[index2Dto1D(pixel, dispatchDims.x)];
            if (!causticReservoir.isValid())
                return;
            sg = createPhotonSGFromPacked(causticReservoir.packedPhotonRetraceData);
        #endif //IS_SHIFT_PATH/_CAUSTIC
    #else //IS_SHIFT. Initial Photon Tracing
        sg = SampleGenerator(pixel, gFrameCount * kRNGNumPasses);
    #endif

    RayDesc ray;
    PhotonLightSample pls;
    float invPhotonScaleFactor = 1.0; // Light selection probabilty and number of light paths

    //Create a photon sample
    #if USE_PHOTON_GUIDING
        PhotonGuidingSample pgs = {};

        float2 randomVals = sampleNext2D(sg);
        //!IS_SHIFT: Traverse the guiding textures
        // IS_SHIFT: Load guiding light and direction from reservoir. Re-apply subpixel jitter. Light sampling can proceed as normal
        #if IS_SHIFT
            //Load guiding data
            #if IS_SHIFT_PATH
                PhotonGuidingData pgd = PhotonGuidingData(pathReservoir.packedGuidingData);
                pgs.photonFluxDivFactor = pathReservoir.invPhotonScaleFactor;
            #elif IS_SHIFT_CAUSTIC
                PhotonGuidingData pgd = PhotonGuidingData(gCausticReservoirGuidingData[pixel]);
                pgs.photonFluxDivFactor = causticReservoir.invPhotonScaleFactor;
            #endif //IS_SHIFT_PATH/_CAUSTIC
            //Fill PGS manually
            pgs.lightIndex = pgd.lightIndex;
            if (pgd.isLightGuiding)
                pgs.directionUV = randomVals;
            else
                pgs.directionUV = gPhotonGuiding.getUVWithSubpixelJitter(pgd.guidingPixels, randomVals);

        #else //IS_SHIFT
            if (!gPhotonGuiding.sampleGuidedLightAndDirection(pixel, dispatchDims.x, randomVals, pgs))
                return;
        #endif
        PhotonGuidingPhotonLightSample pgpls = {};
        if (!gPhotonGuiding.createPhotonSample(pgs, sg, pgpls))
            return;

        //Copy data 
        pls.posW = pgpls.posW;
        pls.normal = pgpls.normal;
        pls.flux = pgpls.flux;
        pls.dirW = pgpls.dirW;
        invPhotonScaleFactor = pgs.photonFluxDivFactor; //Store div factor

        // Store guiding data for the Photon. Unused for shifts
        #if !IS_SHIFT
        PhotonGuidingData pgd = PhotonGuidingData();
        pgd.lightIndex = pgs.lightIndex;
        pgd.guidingPixels = gPhotonGuiding.guidingMapUVToPixel(pgs.directionUV);
        pgd.isLightGuiding = pgs.isLightGuiding;
        #endif
    #else // USE_PHOTON_GUIDING

        if (!generateLightSample(sg, pls, invPhotonScaleFactor))
                return;

        //For shift, reuse the scale factor stored in the reservoir
        #if IS_SHIFT
            #if IS_SHIFT_PATH
                pls.flux /= pathReservoir.invPhotonScaleFactor;
            #elif IS_SHIFT_CAUSTIC
                pls.flux /= causticReservoir.invPhotonScaleFactor;
            #endif
        #else
            pls.flux /= invPhotonScaleFactor;
        #endif
    #endif
    //Prepare Ray and Payload
    ray.Origin = pls.posW;
    ray.Direction = pls.dirW;
    ray.TMin = 0.0;
    ray.TMax = FLT_MAX;
    RayPayload rayPayload = RayPayload();

    //Loop Variables
    bool storeAsCaustic = false;
    PackedPathLength pathLengthInfo = PackedPathLength();
    PhotonData photon = PhotonData();
    photon.flux = pls.flux;
    photon.dir = -ray.Direction;
    photon.faceN = pls.normal;
    //Store sample generator data
    photon.sgStartPixel = pixel;
    photon.sgSeed = gFrameCount * kRNGNumPasses;
    photon.invPhotonScaleFactor = invPhotonScaleFactor;

    uint maxPathLength = gPackedPathLength.pathLength; 
    #if IS_SHIFT
        bool shiftIsValid = false;
        #if IS_SHIFT_PATH
            maxPathLength = getPhotonPathLengthFromPacked(pathReservoir.packedPhotonRetraceData);
        #elif IS_SHIFT_CAUSTIC
            maxPathLength = getPhotonPathLengthFromPacked(causticReservoir.packedPhotonRetraceData);
        #endif//IS_SHIFT_PATH/CAUSTIC
        
    #endif //IS_SHIFT

    // Main Loop
    for (uint i = 0; i <= maxPathLength; i++) {
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
        photon.faceN = sd.getOrientedFaceNormal();
        bool storePhotons = false;
        if (kDiffClassUseLobes)
            storePhotons = (mi.getLobeTypes(sd) & (uint)LobeType::Diffuse) > 0; //If surface has diffuse lobes
        else
            storePhotons = bsdfProperties.roughness > kRoughnessThreshold; //Use roughness

        
        float3 tmpPhotonFlux = photon.flux; // Rejection probability can change the flux, therefore we temporally store the flux here
        if (storePhotons) {
            PhotonType photonType = storeAsCaustic ? PhotonType::Caustic : PhotonType::Global;
            bool storePhoton = true;
            if (photonType == PhotonType::Global) {
                storePhoton = sampleNext1D(sg) <= gGlobalRejectionProb;
                photon.flux /= gGlobalRejectionProb;
            }
            // Store photon and backproject in initial samples
            #if !IS_SHIFT
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
                        if (causticPhotonBackprojection(sd, gScreenDimensions, photonInsertIndex, gLightTraceHeadCounter, gLightTraceLinkedList))
                            gPhotonHitInfo[photonInsertIndex] = hit.getData();
                    }
                    #if USE_PHOTON_GUIDING
                        gPhotonGuidingData[photonTypeIdx][photonInsertIndex] = pgd;
                    #endif
                }
            }
            #endif // !IS_SHIFT

            //TODO Update photon radiance for the path case
            //Shift for path samples (Radiance Estimate)
            #if IS_SHIFT && IS_SHIFT_PATH
            if (i == maxPathLength)
            {
                //For final gather, it is check if the photon is still within the radius
                if (pathReservoir.flags.isFinalGather)
                {
                    shiftIsValid = distance(pathReservoir.samplePosW, sd.posW) <= pathReservoir.sampleRadius;
                }

                if (pathReservoir.flags.isRadianceEstimate)
                {
                    shiftIsValid = true; // Photon is potentially rejected in path shift
                    pathReservoir.samplePosW = sd.posW;
                    pathReservoir.sampleRadius = getPhotonRadius((uint)photonType, sd.posW);
                }
                // Check if photon type differs
                shiftIsValid &= pathReservoir.flags.isCaustic == storeAsCaustic;
                break;
            }
            #endif // IS_SHIFT && IS_SHIFT_PATH

            //Shift for caustic reservoirs (Backprojection)
            #if IS_SHIFT && IS_SHIFT_CAUSTIC
            if(i == maxPathLength)
            {
                if (storeAsCaustic)
                {
                    const int bufferIndex = index2Dto1D(pixel, dispatchDims.x);
                    if (causticPhotonBackprojection(sd, gScreenDimensions, bufferIndex, gLightTraceHeadCounter, gLightTraceLinkedList))
                    {
                        causticReservoir.sampleSurface = hit.getData();
                        causticReservoir.sampleSurfaceView = photon.dir;
                        causticReservoir.photonRadiance = photon.flux;
                        shiftIsValid = true;
                    }
                }
                break;
            }
            #endif // IS_SHIFT && IS_SHIFT_PATH
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
            break;

        //Prepare next ray and update photon
        bool transmission = bsdfSample.isLobe(LobeType::Transmission);
        ray.Origin = sd.computeNewRayOrigin(!transmission); // false is for transmissions
        ray.Direction = bsdfSample.wo;
        photon.flux *= bsdfSample.weight;

        // Update Photon
        if (kDiffClassUseLobes)
            storeAsCaustic = bsdfSample.isLobe(LobeType::Specular) || bsdfSample.isLobe(LobeType::Delta);
        else
            storeAsCaustic = !storePhotons; //Surfaces below threshold are specular
        photon.dir = -ray.Direction;
        photon.pathLenght++;
    }

    //Update path reservoir
    #if IS_SHIFT && IS_SHIFT_PATH
        //Set weight to zero if shift is invalid
        if(!shiftIsValid)
            pathReservoir.weight = 0;

        gPathReservoir[index2Dto1D(pixel, dispatchDims.x)] = pathReservoir;
    #endif

    //Update Caustic Reservoir
    #if IS_SHIFT && IS_SHIFT_CAUSTIC
        if(shiftIsValid)
            gCausticReservoir[index2Dto1D(pixel, dispatchDims.x)] = causticReservoir;
    #endif
}
