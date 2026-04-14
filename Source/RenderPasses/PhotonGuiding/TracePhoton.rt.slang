#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.RaytracingInline;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;
import Utils.Color.ColorHelpers;
import Rendering.Lights.LightHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import StructsAndHelpers;

#ifndef USE_SEPERATE_DIR_SG
#define USE_SEPERATE_DIR_SG 0
#endif

#ifndef LIGHT_GUIDING_MAP_MIPLEVEL
#define LIGHT_GUIDING_MAP_MIPLEVEL 1
#endif

#ifndef DIRECTION_GUIDING_MAP_MIPLEVEL
#define DIRECTION_GUIDING_MAP_MIPLEVEL 1
#endif

cbuffer CB
{
    PackedPathLength gPackedPathLength;   //Packed path length
    uint gFrameCount;   // Frame count since scene was loaded.
    float2 gPhotonRadius;//Global/Caustic radius

    float gGlobalRejectionProb; //Rejection Probability for global photons
    uint gGuidingTextureResolution; // Resolution of all guiding textures. xy is the same
    uint gGuidingTextureMaxMip; // Highest Mip of the guiding texture
    uint gGuidingAtlasResolution; //Resolution of the guiding atlas

    float gNormalizedPixelDiagonal; // Pixel length at distance 1
    uint gLightIndexGuidingMaxMip;  // Max Mip of "gGuidingLightIndex" or of the combined guiding atlas if kUseFixedPhotonGuiding == true
    uint2 gScreenDimensions; // Screen dimensions for backprojection

    uint gLightIndexGuidingResolution; // Resolution of "gGuidingLightIndex"
    float2 gAdaptivePhotonRadius;      // Pixel scale for global/ caustic photons.
    float gJacobianDistanceThreshold;   //Distance threshold for jacobian used in Path ReSTIR

    uint gLightIndexGuidingMaxMip2;
    uint gMapTextureResolution; 
}

RWStructuredBuffer<AABB> gPhotonAABB[2];
RWStructuredBuffer<PhotonData> gPhotonData[2];
RWStructuredBuffer<uint> gPhotonDirSG[2]; 
RWStructuredBuffer<uint> gPhotonCounter;

RWTexture2D<int> gLightTraceHeadCounter;
RWStructuredBuffer<int> gLightTraceLinkedList; // next pointer
RWStructuredBuffer<PackedHitInfo> gCausticPhotonHitInfo;

Texture2D<float> gGuidingTexture;
Texture2D<float> gGuidingLightIndex;
Texture2D<uint> gMapLightIndexToGuidingDirection;

static const uint kFixed1DIndexBlockSize = 16;
static const bool kAlphaTest = true;
static const uint2 kPhotonBufferSize = uint2(PHOTON_BUFFER_SIZE_GLOBAL,PHOTON_BUFFER_SIZE_CAUSTIC);
static const float kRoughnessThreshold = ROUGHNESS_THRESHOLD;
static const bool kRussianRoulette = RUSSIAN_ROULETTE;
static const bool kUseAdaptivePhotonRadius = USE_ADAPTIVE_PHOTON_RADIUS;
static const bool kEnableLightTraceSplatting = ENABLE_LIGHT_TRACE_SPATTING;
static const bool kUseFixedPhotonGuiding = USE_FIXED_PHOTON_GUIDING; // Photons are distributed before the pass
static const uint kFixedPhotonGuidingMinPhotons = FIXED_GUIDING_MIN_PHOTONS; // Min photons for light guiding
static const uint kTotalLightCount = TOTAL_LIGHT_COUNT;
static const uint kRNGNumPasses = RNG_NUM_PASSES;
static const bool kUseJacobianToMarkCaustic = USE_JACOBIAN_DISTANCE_THRESHOLD_TO_MARK_AS_CAUSTIC; // Used for path ReSTIR to get samples is regions where the jacobian distance threshold applies
static const bool kStoreOnlyIndirectPhotons = STORE_ONLY_INDIRECT_PHOTONS; // Store only photons with path length >= 1
static const bool kUseOptimizedAtlas = USE_OPTIMIZED_ATLAS;
static const bool kDisableGuiding = DISABLE_GUIDING;    //If guiding is disabled

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

    return true;
}

bool sampleLightIndex(float randomVal, out uint selectedIdx , out float selectPdf)
{
    selectedIdx = 0;
    selectPdf = 0.0;

    float tw = randomVal; // traverse weight
    uint2 mipIdx = uint2(0);     // Working index for mip chain traversal. Starts top left (0)
    int startMip = int(gLightIndexGuidingMaxMip) - 1; // start from secound highest level
    float weightNormFactor = gGuidingLightIndex.Load(uint3(0, 0, gLightIndexGuidingMaxMip)); //Sum of all weights, used for normalization

    // Start traversal from the second highest miplevel to level 0
    for (int m = startMip; m >= 0; m--)
    {
        // Update mip index from last iteration (does not matter for first iteration)
        mipIdx *= 2;
        // Fetch samples in 2x2 grid
        float4 mipSamples;
        mipSamples[0] = gGuidingLightIndex.Load(uint3(mipIdx.x, mipIdx.y, m));
        mipSamples[1] = gGuidingLightIndex.Load(uint3(mipIdx.x + 1, mipIdx.y, m));
        mipSamples[2] = gGuidingLightIndex.Load(uint3(mipIdx.x, mipIdx.y + 1, m));
        mipSamples[3] = gGuidingLightIndex.Load(uint3(mipIdx.x + 1, mipIdx.y + 1, m));
        mipSamples /= weightNormFactor;

        // Select a sample using the current traverse weight
        float totalWeight = mipSamples[0] + mipSamples[1] + mipSamples[2] + mipSamples[3];
        float currWeight = 0;      // Total for select in loop
        uint selectedSubpixel = 0; // Selected subpixel id
        float selWeight = 0;       // Selected weight
        for (uint x = 0; x < 4 && totalWeight > 0; x++) {
            selWeight = mipSamples[x];
            currWeight += selWeight;
            selectedSubpixel = x;
            if (tw < currWeight)
                break;
        }

        // Update traversal weight
        float nonSelectedWeight = currWeight - selWeight;
        tw -= nonSelectedWeight;

        // Update the index used to fetch the next mip level
        if (selectedSubpixel == 1 || selectedSubpixel == 3)
            mipIdx.x += 1;
        if (selectedSubpixel > 1) // 2 or 3
            mipIdx.y += 1;

        if (m == 0)
            selectPdf = mipSamples[selectedSubpixel];
    }

    // Linearize the selected mip idx
    selectedIdx = mipIdx.x + mipIdx.y * gLightIndexGuidingResolution;
    if (selectedIdx >= kTotalLightCount)
        return false;

    return true;
}

bool createGuidingLightSample(float4 randomVal, out PhotonLightSample pls)
{
    pls = {};
    if (kTotalLightCount == 0)
        return false;

    //Uniform sample code
    /*
    // Randomly pick a triangle out of the global list with uniform probability
    const uint triangleCount = gScene.lightCollection.triangleCount;
    // Safety precaution as the result of the multiplication may be rounded to triangleCount even if uLight < 1.0 when triangleCount is large.
    uint triIdx = min((uint)(sampleNext1D(sg) * triangleCount), triangleCount - 1);
    float triangleSelectionPdf = 1.0 / triangleCount;
    */

    //Select triangle index with guiding texture
    float triangleSelectionPdf;
    uint triIdx;
    if (!sampleLightIndex(randomVal.x, triIdx, triangleSelectionPdf))
        return false;
    
    // Traverse the mipmap
    float tw = randomVal.y; // traverse weight
    uint2 mipIdx = uint2(0);       // Working index for mip chain traversal. Starts top left (0)
    int startMip = int(gGuidingTextureMaxMip) - 1; //start from second highest level
    float endWeight = 0;
    //uint lightIdx1D = triIdx * gGuidingTextureResolution;
    // uint2 atlasOffset = uint2(lightIdx1D % gGuidingAtlasResolution, (lightIdx1D / gGuidingAtlasResolution) * gGuidingTextureResolution); // Offset in the atlas for the current light
    uint atlasLightsPerRow = gGuidingAtlasResolution / gGuidingTextureResolution;
    uint2 atlasOffset = uint2(triIdx % atlasLightsPerRow, triIdx / atlasLightsPerRow); // Offset in the atlas for the current light
    float weightNormFactor = gGuidingTexture.Load(uint3(atlasOffset.x, atlasOffset.y, gGuidingTextureMaxMip)); //Sum of all weights, used for normalization
    // Start traversal from the second highest miplevel to level 0
    for (int m = startMip; m >= 0; m--) {
        // Update mip index and offset from last iteration
        mipIdx *= 2;
        atlasOffset *= 2;
        
        // Fetch samples in 2x2 grid
        uint2 fetchIdx = atlasOffset + mipIdx;
        float4 mipSamples;
        mipSamples[0] = gGuidingTexture.Load(uint3(fetchIdx.x, fetchIdx.y, m));
        mipSamples[1] = gGuidingTexture.Load(uint3(fetchIdx.x + 1, fetchIdx.y, m));
        mipSamples[2] = gGuidingTexture.Load(uint3(fetchIdx.x, fetchIdx.y + 1, m));
        mipSamples[3] = gGuidingTexture.Load(uint3(fetchIdx.x + 1, fetchIdx.y + 1, m));
        mipSamples /= weightNormFactor;

        // Select a sample using the current traverse weight
        float totalWeight = mipSamples[0] + mipSamples[1] + mipSamples[2] + mipSamples[3];
        float currWeight = 0;      // Total for select in loop
        uint selectedSubpixel = 0; // Selected subpixel id
        float selWeight = 0;       //Selected weight
        for (uint x = 0; x < 4 && totalWeight > 0; x++) {
            selWeight = mipSamples[x];
            currWeight += selWeight;
            selectedSubpixel = x;
            if (tw < currWeight)
                break;
        }

        // Update traversal weight
        float nonSelectedWeight = currWeight - selWeight;
        tw -= nonSelectedWeight;

        // Update the index used to fetch the next mip level
        if (selectedSubpixel == 1 || selectedSubpixel == 3)
            mipIdx.x += 1;
        if (selectedSubpixel > 1) // 2 or 3
            mipIdx.y += 1;

        if (m == 0)
            endWeight = mipSamples[selectedSubpixel];
    }
    // Recreate selected random number range from the choosen index
    pls.guidingPixels = atlasOffset + mipIdx;
    float2 relMinWeight = float2(mipIdx) / gGuidingTextureResolution;
    float2 relMaxWeight = float2(mipIdx + 1) / gGuidingTextureResolution;
    relMinWeight += (relMaxWeight - relMinWeight) * randomVal.zw;
    pls.rndX = relMinWeight.x;
    pls.rndY = relMinWeight.y;
    float guidingPDF = endWeight * (gGuidingTextureResolution * gGuidingTextureResolution);

    pls.lightIdx = triIdx;
    pls.guidingPdf = triangleSelectionPdf * guidingPDF;

    return true;
    // Get emissive triangle data
    /*
    const EmissiveTriangle tri = gScene.lightCollection.getTriangle(triIdx);
    const float3 barycentrics = sample_triangle(sampleNext2D(sg));
    pls.posW = tri.getPosition(barycentrics);
    pls.normal = tri.normal;
    pls.lightIdx = triIdx;

    // Get Flux
    float2 uv = tri.getTexCoord(barycentrics);
    pls.flux = gScene.materials.evalEmissive(tri.materialID, uv) * tri.area;

    pls.posW = computeRayOrigin(pls.posW, pls.normal); // Offset as this light is real geometry
    pls.guidingPdf = triangleSelectionPdf * guidingPDF;
    //pls.flux /= pls.guidingPdf;
    return true;
    */
}

// TODO fix the guiding probablity
bool createGuidingSampleFixed(uint2 pixel, uint dispatchDimX, float2 randomVal, out PhotonLightSample pls)
{
    pls = {};
    if (kTotalLightCount == 0)
        return false;

    
    //Get start id and compaire against the total number of photons
    const uint blockSize = kFixed1DIndexBlockSize;
    uint2 blockPixel = pixel % blockSize;
    uint2 blockID = pixel / blockSize;
    uint block1D = blockPixel.x + blockPixel.y * blockSize;
    uint blockOffset = blockID.x * (blockSize * blockSize) + blockID.y * dispatchDimX * blockSize;
    float tw = block1D + blockOffset;

    float maxPhotons = gGuidingLightIndex.Load(uint3(0, 0, gLightIndexGuidingMaxMip2)); // Sum of all photons

    if (tw >= maxPhotons)
        return false;

    // Traverse light index guiding map
    uint2 mipIdx = uint2(0);                           // Working index for mip chain traversal. Starts top left (0)
    float endWeight = 0;
    uint lightIndex = 0;

    [unroll]
    for (int m = LIGHT_GUIDING_MAP_MIPLEVEL - 1; m >= 0; m--) {
        // Update mip index and offset from last iteration
        mipIdx *= 2;

        // Fetch samples in 2x2 grid
        uint2 fetchIdx = mipIdx;
        float4 mipSamples;
        mipSamples[0] = gGuidingLightIndex.Load(uint3(mipIdx.x, mipIdx.y, m));
        mipSamples[1] = gGuidingLightIndex.Load(uint3(mipIdx.x + 1, mipIdx.y, m));
        mipSamples[2] = gGuidingLightIndex.Load(uint3(mipIdx.x, mipIdx.y + 1, m));
        mipSamples[3] = gGuidingLightIndex.Load(uint3(mipIdx.x + 1, mipIdx.y + 1, m));

        // Select a sample using the current traverse weight
        float totalWeight = mipSamples[0] + mipSamples[1] + mipSamples[2] + mipSamples[3];
        float currWeight = 0;      // Total for select in loop
        uint selectedSubpixel = 0; // Selected subpixel id
        float selWeight = 0;       // Selected weight
        for (uint x = 0; x < 4 && totalWeight > 0; x++) {
            selWeight = mipSamples[x];
            currWeight += selWeight;
            selectedSubpixel = x;
            if (tw < currWeight)
                break;
        }

        // Update traversal weight
        float nonSelectedWeight = currWeight - selWeight;
        tw -= nonSelectedWeight;

        // Update the index used to fetch the next mip level
        if (selectedSubpixel == 1 || selectedSubpixel == 3)
            mipIdx.x += 1;
        if (selectedSubpixel > 1) // 2 or 3
            mipIdx.y += 1;

        if (m == 0) {
            lightIndex = mipIdx.x + mipIdx.y * gLightIndexGuidingResolution;
            endWeight = mipSamples[selectedSubpixel];
        }
    }

    // Check if the light fulfills the min photon condition for directional guiding
    bool useDirectionalGuiding = endWeight >= kFixedPhotonGuidingMinPhotons;
    if(kDisableGuiding)
        useDirectionalGuiding = false;

    // Get mapped starting index in the atlas
    if (kUseOptimizedAtlas)
    {
        uint2 lightPixel = uint2(lightIndex % gLightIndexGuidingResolution, lightIndex / gLightIndexGuidingResolution);
        uint mapIndex = gMapLightIndexToGuidingDirection[lightPixel];
        if(mapIndex < kAtlasOptimizationMaxMapIndex){
            mipIdx = uint2(mapIndex % gMapTextureResolution, mapIndex / gMapTextureResolution);
        }else
            useDirectionalGuiding = false;
    }

    //Check if the current photon is a directionally guided photon
    if (useDirectionalGuiding) {
        float directionalPhotons = gGuidingTexture.Load(uint3(mipIdx, gGuidingTextureMaxMip));
        useDirectionalGuiding = (tw - directionalPhotons) <= 0 && directionalPhotons >= kFixedPhotonGuidingMinPhotons;    //All photon greater 0 are left over photons from flooring the directional importance
    }

    pls.useRandomLightDirection = !useDirectionalGuiding;

    //Perform traversal of the directional guiding map
    if (useDirectionalGuiding)
    {
        endWeight = 0;
        [unroll]
        for (int m = DIRECTION_GUIDING_MAP_MIPLEVEL - 1; m >= 0; m--) {
            // Update mip index and offset from last iteration
            mipIdx *= 2;

            // Fetch samples in 2x2 grid
            uint2 fetchIdx = mipIdx;
            float4 mipSamples;
            mipSamples[0] = gGuidingTexture.Load(uint3(mipIdx.x, mipIdx.y, m));
            mipSamples[1] = gGuidingTexture.Load(uint3(mipIdx.x + 1, mipIdx.y, m));
            mipSamples[2] = gGuidingTexture.Load(uint3(mipIdx.x, mipIdx.y + 1, m));
            mipSamples[3] = gGuidingTexture.Load(uint3(mipIdx.x + 1, mipIdx.y + 1, m));

            // Select a sample using the current traverse weight
            float totalWeight = mipSamples[0] + mipSamples[1] + mipSamples[2] + mipSamples[3];
            float currWeight = 0;      // Total for select in loop
            uint selectedSubpixel = 0; // Selected subpixel id
            float selWeight = 0;       // Selected weight
            for (uint x = 0; x < 4 && totalWeight > 0; x++) {
                selWeight = mipSamples[x];
                currWeight += selWeight;
                selectedSubpixel = x;
                if (tw < currWeight)
                    break;
            }

            // Update traversal weight
            float nonSelectedWeight = currWeight - selWeight;
            tw -= nonSelectedWeight;

            // Update the index used to fetch the next mip level
            if (selectedSubpixel == 1 || selectedSubpixel == 3)
                mipIdx.x += 1;
            if (selectedSubpixel > 1) // 2 or 3
                mipIdx.y += 1;

            if (m == 0) {
                endWeight = mipSamples[selectedSubpixel];
            }
        }
    }

    // Recreate selected random number range from the choosen index
    float guidingPDF = endWeight / maxPhotons;

    // Fill out random values depending if the loop ended at the light or direction
    if (pls.useRandomLightDirection) {
        pls.rndX = randomVal.x;
        pls.rndY = randomVal.y;
        if(kUseOptimizedAtlas)
            pls.guidingPixels = uint2(floor(randomVal * gGuidingTextureResolution)); //Store as local for the optimized atlas
        else{
            uint2 offsetLightIdx = uint2(lightIndex % gLightIndexGuidingResolution, lightIndex / gLightIndexGuidingResolution) * gGuidingTextureResolution;
            pls.guidingPixels = offsetLightIdx + uint2(floor(randomVal * gGuidingTextureResolution)); 
        }
    } else {
        uint2 relIdx = mipIdx % gGuidingTextureResolution;
        pls.guidingPixels = kUseOptimizedAtlas ? relIdx : mipIdx;
        float2 relMinWeight = float2(relIdx) / gGuidingTextureResolution;
        float2 relMaxWeight = float2(relIdx + 1) / gGuidingTextureResolution;
        relMinWeight += (relMaxWeight - relMinWeight) * randomVal;
        pls.rndX = relMinWeight.x;
        pls.rndY = relMinWeight.y;
        guidingPDF *= (gGuidingTextureResolution * gGuidingTextureResolution);
    }

    if (lightIndex >= kTotalLightCount)
        return false;

    pls.guidingPdf = guidingPDF;
    pls.lightIdx = lightIndex;

    return true;
}

float getPhotonRadius(const uint photonTypeIdx, const float3 hitPos)
{
    if (kUseAdaptivePhotonRadius) {

        float distToCamera = distance(hitPos, gScene.camera.getPosition());
        return adaptiveRadius(distToCamera, gNormalizedPixelDiagonal, gAdaptivePhotonRadius[photonTypeIdx]);
    }
    else {
        return gPhotonRadius[photonTypeIdx];
    }
}

// Backprojects the caustic photon and stores it in an linked list to collect all pixels caustic photons with RIS
void causticPhotonBackprojection(uint photonBufferIndex, ShadingData sd)
{
    // Check if position is in camera view
    float4 screenPos = mul(gScene.camera.data.viewProjMatNoJitter, float4(sd.posW, 1));
    screenPos /= screenPos.w;
    screenPos.y *= -1;
    screenPos.xy = screenPos.xy * 0.5 + 0.5; // UV from [-1,1] to [0,1]
    if (any(screenPos.xy < 0) || any(screenPos.xy >= 1) || screenPos.z < 0 || screenPos.z > 1)
        return;

    // If the photon is in screen it is assumed that it will contribute something
    // Check visibility with ray query
    float3 directionToCamera = gScene.camera.getPosition() - sd.posW;
    float distanceToCamera = length(directionToCamera);
    directionToCamera /= distanceToCamera;

    distanceToCamera -= gScene.camera.data.nearZ; //Remove near
    SceneRayQuery<1> rayQuery;
    const Ray ray = Ray(sd.computeNewRayOrigin(), directionToCamera, 0.f, distanceToCamera);
    if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
        return;

    // Caustic photon is a valid sample, add to the linked list for the RIS pass later
    uint2 currentPixel = uint2(floor(screenPos.xy * gScreenDimensions));
    int nodeNext = -1;
    InterlockedExchange(gLightTraceHeadCounter[currentPixel], photonBufferIndex, /*out*/ nodeNext);
    gLightTraceLinkedList[photonBufferIndex] = nodeNext;
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

    SampleGenerator sg = SampleGenerator(pixel, gFrameCount * kRNGNumPasses);
    #if USE_SEPERATE_DIR_SG
        SampleGenerator sgPhotonDir = SampleGenerator(pixel, getStartSeedPhotonDirSG(gFrameCount, kRNGNumPasses)); //TODO test if this works properly
    #endif
    RayDesc ray = {};
    PhotonLightSample pls = PhotonLightSample();

    // Create a photon by sampling from emissive lights or analytic light sources
#if USE_SEPERATE_DIR_SG
    float2 randomValForLightDirection = sampleNext2D(sgPhotonDir);
#else
    float2 randomValForLightDirection = sampleNext2D(sg);
#endif
    if (kUseFixedPhotonGuiding) {
        if (!createGuidingSampleFixed(pixel, dispatchDims.x, randomValForLightDirection, pls))
            return;
    } else {
        float4 randomVal = float4(sampleNext2D(sg), randomValForLightDirection);
        if (!createGuidingLightSample(randomVal, pls))
            return;
    }

    //Sample emissive or analytic light
    bool validLightSample = false;
#if USE_SEPERATE_DIR_SG
    bool usedRandomDirection = pls.useRandomLightDirection;
    validLightSample = photonSampleLight(pls, ray, sgPhotonDir);
#else
    validLightSample = photonSampleLight(pls, ray, sg);
#endif
    if(!validLightSample)
        return;  
    
    const uint lightCount = dispatchDims.x * dispatchDims.y;

    //Prepare photon data
    RayPayload rayPayload = RayPayload();
    
    bool storeAsCaustic = false;
    bool reflectedDiffuse = false;
    float3 photonStartFlux = pls.flux / pls.guidingPdf;
    float3 thp = float3(1.0); //Throughput

    PhotonData photon = PhotonData();
    photon.flux = photonStartFlux;
    photon.dir = -ray.Direction;
    photon.normalW = pls.normal;
    photon.lightIndex = pls.lightIdx;
    photon.guidingPixel = pls.guidingPixels;
    photon.guidingPdf = pls.guidingPdf;

    const PackedPathLength maxPathLengths = gPackedPathLength;
    PackedPathLength currentPathLength = PackedPathLength();
    // Main Loop
    for (uint i = 0; i < maxPathLengths.pathLength; i++) {
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

        if (any(bsdfProperties.emission > 0))
            break;
                   
        photon.normalW = sd.getOrientedFaceNormal();
        reflectedDiffuse = bsdfProperties.roughness > kRoughnessThreshold;
        if (kUseJacobianToMarkCaustic) {
            float rayDistance = distance(ray.Origin, sd.posW);
            if(rayDistance < gJacobianDistanceThreshold) {
                storeAsCaustic = true;
            }
        }

        // Store Photon
        bool storePhoton = reflectedDiffuse;
        if (kStoreOnlyIndirectPhotons)
            storePhoton &= i > 0;
        if (storePhoton) {
            PhotonType photonType = storeAsCaustic ? PhotonType::Caustic : PhotonType::Global;
            if (photonType == PhotonType::Global) {
                storePhoton = sampleNext1D(sg) <= gGlobalRejectionProb;
                photon.flux *= invRejection;
            }
            if (storePhoton) {
                uint photonTypeIdx = (uint)photonType;
                float radius = getPhotonRadius(photonTypeIdx, sd.posW);
                uint photonInsertIndex = 0;
                InterlockedAdd(gPhotonCounter[photonTypeIdx], 1u, photonInsertIndex);
                if (photonInsertIndex <= kPhotonBufferSize[photonTypeIdx])
                {
                    AABB photonAABB = AABB(sd.posW - radius, sd.posW + radius);
                    gPhotonAABB[photonTypeIdx][photonInsertIndex] = photonAABB;
                    gPhotonData[photonTypeIdx][photonInsertIndex] = photon;
                    if (kEnableLightTraceSplatting) {
                        if (photonType == PhotonType::Caustic) {
                            causticPhotonBackprojection(photonInsertIndex, sd);
                            gCausticPhotonHitInfo[photonInsertIndex] = hit.getData();
                        }  
                    }
                    #if USE_SEPERATE_DIR_SG
                        gPhotonDirSG[photonTypeIdx][photonInsertIndex] = packPhotonRetraceData(pixel, i, usedRandomDirection);
                    #endif
                }
            }
        }

        // Photon Bounce for next iteration
        bool isEmissive = any(bsdfProperties.emission > 0);
        BSDFSample bsdfSample;
#if USE_SEPERATE_DIR_SG
        bool validSample = mi.sample(sd, sgPhotonDir, bsdfSample, true /*ImportanceSampling*/);
#else
        bool validSample = mi.sample(sd, sg, bsdfSample, true /*ImportanceSampling*/);
#endif
        if (!validSample || isEmissive)
            return;
        bool transmission = bsdfSample.isLobe(LobeType::Transmission);
        ray.Origin = sd.computeNewRayOrigin(!transmission); // false is for transmissions
        ray.Direction = bsdfSample.wo;
        thp *= bsdfSample.weight;
       
        // RussianRoulette
        if (kRussianRoulette)
        {
        #if USE_SEPERATE_DIR_SG
            float rrRand = sampleNext1D(sgPhotonDir);
        #else
            float rrRand = sampleNext1D(sg);
        #endif
            const float rrVal = luminance(thp);
            if (rrRand > rrVal)
            {
                return; // Photon is absorbed
            }
            thp /= rrVal;
        }
       
        // Update Photon
        storeAsCaustic = !reflectedDiffuse;
        photon.dir = -ray.Direction;
        photon.flux = photonStartFlux * thp;
        photon.pathLength = i + 1;

        // Update path lenght
        if (bsdfSample.isLobe(LobeType::Delta))
            currentPathLength.deltaBounces = currentPathLength.deltaBounces + 1;
        else if (bsdfSample.isLobe(LobeType::Diffuse))
            currentPathLength.diffuseBounces = currentPathLength.diffuseBounces + 1;
        else // Specular
            currentPathLength.specularBounces = currentPathLength.specularBounces + 1;

        //Abort path if max bounces for a type was reached
        if (!currentPathLength.comparePathLengts(maxPathLengths))
            return;
    }
}
