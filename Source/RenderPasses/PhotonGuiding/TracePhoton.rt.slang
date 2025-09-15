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

#ifndef NUM_GUIDING_TEXTURES
#define NUM_GUIDING_TEXTURES 1
#endif

cbuffer CB
{
    uint gMaxBounces;   // Max number of bounces allowed
    uint gFrameCount;   // Frame count since scene was loaded.
    float2 gPhotonRadius;//Global/Caustic radius

    uint gDispatchDimension;    //Dispatch dims (x,y identical) 
    float gGlobalRejectionProb; //Rejection Probability for global photons
    uint2 gScreenRes;   //For back projection

    uint gGuidingTextureResolution; // Resolution of all guiding textures. xy is the same
    uint gGuidingTextureMaxMip;     // Highest Mip of the guiding texture
}

RWStructuredBuffer<AABB> gPhotonAABB[2];
RWStructuredBuffer<PhotonData> gPhotonData[2];
RWBuffer<uint> gPhotonCounter;

Texture2D<float> gGuidingTexture[NUM_GUIDING_TEXTURES];

static const bool kAlphaTest = true;
static const uint2 kPhotonBufferSize = uint2(PHOTON_BUFFER_SIZE_GLOBAL,PHOTON_BUFFER_SIZE_CAUSTIC);
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
    float rndX;
    float3 normal;
    float rndY;
    float3 flux;
    uint lightIdx;
    uint2 guidingPixels;
    uint2 _pad;
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

bool createGuidingLightSample(inout SampleGenerator sg, out PhotonLightSample pls)
{
    pls = {};
    if (gScene.lightCollection.isEmpty())
        return false;

    // Randomly pick a triangle out of the global list with uniform probability
    const uint triangleCount = gScene.lightCollection.triangleCount;
    // Safety precaution as the result of the multiplication may be rounded to triangleCount even if uLight < 1.0 when triangleCount is large.
    uint triIdx = min((uint)(sampleNext1D(sg) * triangleCount), triangleCount - 1);
    float triangleSelectionPdf = 1.0 / triangleCount;

    // Traverse the mipmap
    float tw = sampleNext1D(sg); // traverse weight
    uint2 mipIdx = uint2(0);       // Working index for mip chain traversal. Starts top left (0)
    int startMip = int(gGuidingTextureMaxMip) - 1;
    float endWeight = 0;

    // Start traversal from the second highest miplevel to level 0
    for (int m = startMip; m >= 0; m--) {
        //Update mip index from last iteration (does not matter for first iteration)
        mipIdx *= 2;
        // Fetch samples in 2x2 grid
        float4 mipSamples;
        mipSamples[0] = gGuidingTexture[triIdx].Load(uint3(mipIdx.x, mipIdx.y, m));
        mipSamples[1] = gGuidingTexture[triIdx].Load(uint3(mipIdx.x + 1, mipIdx.y, m));
        mipSamples[2] = gGuidingTexture[triIdx].Load(uint3(mipIdx.x, mipIdx.y + 1, m));
        mipSamples[3] = gGuidingTexture[triIdx].Load(uint3(mipIdx.x + 1, mipIdx.y + 1, m));

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
    pls.guidingPixels = mipIdx;
    float2 relMinWeight = float2(pls.guidingPixels) / gGuidingTextureResolution;
    float2 relMaxWeight = float2(pls.guidingPixels + 1) / gGuidingTextureResolution;
    relMinWeight += (relMaxWeight - relMinWeight) * sampleNext2D(sg);
    pls.rndX = relMinWeight.x;
    pls.rndY = relMinWeight.y;
    float guidingPDF = endWeight * (gGuidingTextureResolution * gGuidingTextureResolution);

    // Get emissive triangle data
    const EmissiveTriangle tri = gScene.lightCollection.getTriangle(triIdx);
    const float3 barycentrics = sample_triangle(sampleNext2D(sg));
    pls.posW = tri.getPosition(barycentrics);
    pls.normal = tri.normal;
    pls.lightIdx = triIdx;

    // Get Flux
    float2 uv = tri.getTexCoord(barycentrics);
    pls.flux = gScene.materials.evalEmissive(tri.materialID, uv) * tri.area;

    pls.posW = computeRayOrigin(pls.posW, pls.normal); // Offset as this light is real geometry
    pls.flux /= triangleSelectionPdf * guidingPDF;
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

    // Create a photon by sampling from emissive lights or analytic light sources
    if (!createGuidingLightSample(sg, pls))
        return;

    float lightDirPDF = 1.0;
    float2 randomValues = float2(pls.rndX, pls.rndY);
    //float2 randomValues = sampleNext2D(sg);

    float3 woLocal = sample_cosine_hemisphere_concentric(randomValues, lightDirPDF);

    if (lightDirPDF <= 0.)
        return;

    ray.Direction = fromLocalToWorld(pls.normal, woLocal);
    pls.flux *= M_PI; // Lambert Emitter
    
    const uint lightCount = dispatchDims.x * dispatchDims.y;

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
    photon.lightIndex = pls.lightIdx;
    photon.guidingPixel = pls.guidingPixels;
    photon.guidingRandomVal = float2(pls.rndX, pls.rndY);

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
                uint photonInsertIndex = 0;
                InterlockedAdd(gPhotonCounter[photonTypeIdx], 1u, photonInsertIndex);
                if (photonInsertIndex <= kPhotonBufferSize[photonTypeIdx])
                {
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

        const float rrVal = luminance(thp);

        // RussianRoulette
        if ((sampleNext1D(sg) > rrVal) || isEmissive)
        {
            return; // Photon is absorbed
        }

        thp /= rrVal;

        // Update Photon
        storeAsCaustic = !reflectedDiffuse;
        photon.dir = -ray.Direction;
        photon.flux = photonStartFlux * thp;
        photon.pathLenght++;
    }
}
