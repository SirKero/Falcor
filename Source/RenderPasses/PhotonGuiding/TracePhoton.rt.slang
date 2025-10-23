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

cbuffer CB
{
    uint gMaxBounces;   // Max number of bounces allowed
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
}

RWStructuredBuffer<AABB> gPhotonAABB[2];
RWStructuredBuffer<PhotonData> gPhotonData[2];
RWStructuredBuffer<uint> gPhotonCounter;

RWTexture2D<int> gLightTraceHeadCounter;
RWStructuredBuffer<int> gLightTraceLinkedList; // next pointer
RWStructuredBuffer<PackedHitInfo> gCausticPhotonHitInfo;

Texture2D<float> gGuidingTexture;
Texture2D<float> gGuidingLightIndex;

static const uint kFixed1DIndexBlockSize = 16;
static const bool kAlphaTest = true;
static const uint2 kPhotonBufferSize = uint2(PHOTON_BUFFER_SIZE_GLOBAL,PHOTON_BUFFER_SIZE_CAUSTIC);
static const float kRoughnessThreshold = ROUGHNESS_THRESHOLD;
static const bool kRussianRoulette = RUSSIAN_ROULETTE;
static const bool kUseAdaptivePhotonRadius = USE_ADAPTIVE_PHOTON_RADIUS;
static const bool kEnableLightTraceSplatting = ENABLE_LIGHT_TRACE_SPATTING;
static const bool kUseFixedPhotonGuiding = USE_FIXED_PHOTON_GUIDING; // Photons are distributed before the pass
static const uint kFixedPhotonGuidingMinPhotons = FIXED_GUIDING_MIN_PHOTONS; // Min photons for light guiding
static const uint kAnalyticLightIdxOffset = ANALYTIC_START_INDEX;
static const uint kTotalLightCount = TOTAL_LIGHT_COUNT;

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
    float rndX;
    float3 normal;
    float rndY;
    float3 flux;
    uint lightIdx;
    uint2 guidingPixels;
    float guidingPdf;
    uint _pad;
};

// transforms direction from local to world space
float3 fromLocalToWorld(const in float3 normal, float3 w)
{
    // transform from local space -> random dir vector in world space
    float3 bitangent = perp_stark(normal);
    float3 tangent = cross(bitangent, normal);

    return w.x * tangent + w.y * bitangent + w.z * normal;
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

bool sampleLightIndex(inout SampleGenerator sg, out uint selectedIdx , out float selectPdf)
{
    selectedIdx = 0;
    selectPdf = 0.0;

    float tw = sampleNext1D(sg); // traverse weight
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

bool createGuidingLightSample(inout SampleGenerator sg, out PhotonLightSample pls)
{
    pls = {};
    if (gScene.lightCollection.isEmpty())
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
    if (!sampleLightIndex(sg, triIdx, triangleSelectionPdf))
        return false;
    
    // Traverse the mipmap
    float tw = sampleNext1D(sg); // traverse weight
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
    relMinWeight += (relMaxWeight - relMinWeight) * sampleNext2D(sg);
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

bool createGuidingSampleFixed(uint2 pixel, uint dispatchDimX, inout SampleGenerator sg, out PhotonLightSample pls)
{
    pls = {};
    if (gScene.lightCollection.isEmpty())
        return false;

    //Get start id and compaire against the total number of photons

    // Get a 1D index, divided into blocks
    const uint blockSize = kFixed1DIndexBlockSize;
    uint2 blockPixel = pixel % blockSize;
    uint2 blockID = pixel / blockSize;
    uint block1D = blockPixel.x + blockPixel.y * blockSize;
    uint blockOffset = blockID.x * (blockSize * blockSize) + blockID.y * dispatchDimX * blockSize;
    float tw = block1D + blockOffset;

    // float tw = pixel.x + pixel.y * dispatchDimX; //Old simple linearized version
    float maxPhotons = gGuidingTexture.Load(uint3(0, 0, gLightIndexGuidingMaxMip)); // Sum of all photons

    if (tw >= maxPhotons)
        return false;

    //Traverse the mipmap chain
    uint2 mipIdx = uint2(0); // Working index for mip chain traversal. Starts top left (0)
    const uint mipLevelCheckLightCount = gGuidingTextureMaxMip; 
    int startMip = int(gLightIndexGuidingMaxMip) - 1; // start from second highest level
    float endWeight = 0;
    uint lightIndex = 0;
    const uint atlasLightsPerRow = gGuidingAtlasResolution / gGuidingTextureResolution;
    bool endedLoopEarly = false;
    for (int m = startMip; m >= 0; m--) {
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

        if (m == mipLevelCheckLightCount)
        {
            lightIndex = mipIdx.x + mipIdx.y * atlasLightsPerRow;
            if (mipSamples[selectedSubpixel] < kFixedPhotonGuidingMinPhotons)
            {
                endWeight = mipSamples[selectedSubpixel];
                endedLoopEarly = true;
                break;
            }
        }

        if (m == 0)
            endWeight = mipSamples[selectedSubpixel];
    }
    // Recreate selected random number range from the choosen index
    float2 randomVal = sampleNext2D(sg);
    float guidingPDF = endWeight / maxPhotons;

    //Fill out random values depending if the loop ended at the light or direction
    if (endedLoopEarly) {
        pls.rndX = randomVal.x;
        pls.rndY = randomVal.y;
        uint2 offsetLightIdx = uint2(lightIndex % atlasLightsPerRow, lightIndex / atlasLightsPerRow) * gGuidingTextureResolution;
        pls.guidingPixels = offsetLightIdx + uint2(floor(randomVal * gGuidingTextureResolution));
    } else {
        pls.guidingPixels = mipIdx;
        uint2 relIdx = mipIdx % gGuidingTextureResolution;
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

//Samples the light
bool sampleLight(inout PhotonLightSample pls, inout RayDesc ray, inout SampleGenerator sg)
{
    // Check if the light is emissive or analytic
    bool isAnalytic = pls.lightIdx >= kAnalyticLightIdxOffset;
    float2 randomValues = float2(pls.rndX, pls.rndY);
    // float2 randomValues = sampleNext2D(sg);

    float3 woLocal = float3 (0);

    // Sample Light depending on type
    if (isAnalytic)
    {
        const uint analyticLightIndex = pls.lightIdx - kAnalyticLightIdxOffset;
        LightData lightData = gScene.getLight(analyticLightIndex);
        //For now only point (and spot) lights are supported
        if (lightData.type != uint(LightType::Point))
            return false;

        float spotAngle = lightData.cosOpeningAngle;
       
        if (lightData.openingAngle < M_2PI) // If the opening angle is smaller than 2PI it is a spotlight
        {
            // TODO support penumbra
            woLocal = sample_cone(randomValues.xy, spotAngle);
        } else // Pointlight
        {
            spotAngle = 0;
            woLocal = sample_sphere(randomValues.xy);
        }
        float invLightPdf = M_2PI * (1.0 - spotAngle);

        if (invLightPdf <= 0.f)
            return false;

        pls.posW = lightData.posW;
        pls.normal = lightData.dirW;
        pls.flux = lightData.intensity * invLightPdf;

    } else //Emissive
    {
        // Get light data
        const EmissiveTriangle tri = gScene.lightCollection.getTriangle(pls.lightIdx);
        const float3 barycentrics = sample_triangle(sampleNext2D(sg));
        pls.posW = tri.getPosition(barycentrics);
        pls.normal = tri.normal;

        // Get Flux
        float2 uv = tri.getTexCoord(barycentrics);
        pls.flux = gScene.materials.evalEmissive(tri.materialID, uv) * tri.area;

        pls.posW = computeRayOrigin(pls.posW, pls.normal); // Offset as this light is real geometry

        //Light direction
        float lightDirPDF = 1.0;
        
        woLocal = sample_cosine_hemisphere_concentric(randomValues, lightDirPDF);

        if (lightDirPDF <= 0.)
            return false;

        pls.flux *= M_PI; // Lambert Emitter
    }

    ray.Origin = pls.posW;
    ray.Direction = fromLocalToWorld(pls.normal, woLocal);
    ray.TMin = 0.0f;
    ray.TMax = FLT_MAX;
    
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
    float4 screenPos = mul(gScene.camera.getViewProj(), float4(sd.posW, 1));
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

    SampleGenerator sg = SampleGenerator(pixel, gFrameCount * 2);
    RayDesc ray = {};
    PhotonLightSample pls = {};

    // Create a photon by sampling from emissive lights or analytic light sources
    if (kUseFixedPhotonGuiding) {
        if (!createGuidingSampleFixed(pixel, dispatchDims.x, sg, pls))
            return;
    } else {
        if (!createGuidingLightSample(sg, pls))
            return;
    }

    //Sample emissive or analytic light
    if (!sampleLight(pls, ray, sg))
        return;
    
    const uint lightCount = dispatchDims.x * dispatchDims.y;

    //Prepare photon data
    RayPayload rayPayload = RayPayload();
    
    bool storeAsCaustic = false;
    bool reflectedDiffuse = false;
    float3 photonStartFlux = pls.flux;
    float3 thp = float3(1.0); //Throughput

    PhotonData photon = PhotonData();
    photon.flux = photonStartFlux;
    photon.dir = -ray.Direction;
    photon.normalW = pls.normal;
    photon.lightIndex = pls.lightIdx;
    photon.guidingPixel = pls.guidingPixels;
    photon.guidingRandomVal = float2(pls.rndX, pls.rndY);
    photon.guidingPdf = pls.guidingPdf;

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

        if (any(bsdfProperties.emission > 0))
            break;
                   
        photon.normalW = sd.getOrientedFaceNormal();
        reflectedDiffuse = bsdfProperties.roughness > kRoughnessThreshold;

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
        if (kRussianRoulette)
        {
            const float rrVal = luminance(thp);
            if ((sampleNext1D(sg) > rrVal) || isEmissive)
            {
                return; // Photon is absorbed
            }
            thp /= rrVal;
        }
       
        // Update Photon
        storeAsCaustic = !reflectedDiffuse;
        photon.dir = -ray.Direction;
        photon.flux = photonStartFlux * thp;
        photon.pathLenght++;
    }
}
