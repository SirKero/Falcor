#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Math.MathHelpers;
import Utils.Color.ColorHelpers;
import RenderPasses.PhotonGuiding.StructsAndHelpers;

#ifndef USE_LIGHT_PATH_RETRACE
#define USE_LIGHT_PATH_RETRACE 0
#endif

cbuffer CB {
    uint2 gFrameDim;
    uint gGuidingTextureResolution; // Resolution of one guiding texture
}

RWStructuredBuffer<ReservoirCaustic> gPrevReservoir;

RWStructuredBuffer<int> gCellCounter; //Is head buffer if linked list is used
RWStructuredBuffer<int> gSplattingLinkedList;
RWStructuredBuffer<uint> gGlobalCounter;
RWStructuredBuffer<uint4> gSplatSortData;

static const bool kAlphaTest = true;
static const float kRoughnessThreshold = ROUGHNESS_THRESHOLD;
static const bool kPhotonRussianRoulette = PHOTON_RUSSIAN_ROULETTE;
static const bool kSplattingUseLinkedList = SPLATTING_USE_LINKED_LIST;

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

bool randomReplayPhotonPath(ReservoirCaustic reservoir, out HitInfo photonHit, out float3 photonView, out float3 photonFlux) {
    photonFlux = float3(0);
    photonHit = {}; // Init
    photonView = float3(0);
    // Recreate Light Dir Sample generator
    SampleGenerator sg = SampleGenerator(reservoir.photonRetraceData.startPixel, reservoir.photonRetraceData.startSeed);

    // Create pls to get start position for the path
    PhotonLightSample pls = PhotonLightSample();
    pls.lightIdx = reservoir.lightIndex;
    pls.guidingPixels = reservoir.guidingPixels;
    pls.useRandomLightDirection = reservoir.photonRetraceData.usedRandomDirection;
    photonRetraceRecreateDirectionsRandomValues(pls, sampleNext2D(sg), gGuidingTextureResolution);

    RayDesc ray = {};
    if (!photonSampleLight(pls, ray, sg))
        return false;

    photonFlux = pls.flux;
    float3 thp = float3(1.0);
    RayPayload rayPayload = RayPayload();
    const uint targetPathLength = reservoir.photonRetraceData.pathLength;
    bool validPhoton = false;
    bool lastHitSpecular = false;

    for (uint i = 0; i <= targetPathLength; i++) {
        TraceRay(gScene.rtAccel, 0 /*Flags*/, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayPayload);

        HitInfo hit = HitInfo(rayPayload.packedHitInfo);
        if (!hit.isValid())
            break;

        // Get shading infos
        let lod = ExplicitLodTextureSampler(0);
        // Get Material properties
        ShadingData sd = loadShadingData(hit, ray.Direction, lod);

        // If target lenght is reached, store position and end path
        if (i == targetPathLength) {
            photonHit = hit;
            photonView = ray.Direction;
            photonFlux *= thp;
            validPhoton = lastHitSpecular;
            break;
        }

        // Photon Bounce for next iteration
        uint hints = (uint)MaterialInstanceHints::AdjustShadingNormal;
        let mi = gScene.materials.getMaterialInstance(sd, lod, hints);
        let bsdfProperties = mi.getProperties(sd);
        BSDFSample bsdfSample;
        bool validSample = mi.sample(sd, sg, bsdfSample, true /*ImportanceSampling*/);
        if (!validSample || any(bsdfProperties.emission > 0))
            break;
        bool transmission = bsdfSample.isLobe(LobeType::Transmission);
        ray.Origin = sd.computeNewRayOrigin(!transmission); // false is for transmissions
        ray.Direction = bsdfSample.wo;
        lastHitSpecular = bsdfProperties.roughness < kRoughnessThreshold;

        thp *= bsdfSample.weight;
        // Russian roulette
        if (kPhotonRussianRoulette) {
            float rrRand = sampleNext1D(sg);
            const float rrVal = luminance(thp);
            if ((rrRand > rrVal))
            {
                break; // Photon is absorbed
            }
            thp /= rrVal;
        }

    }

    return validPhoton; 
}

[shader("miss")]
void miss(inout RayPayload rayData: SV_RayPayload)
{
    HitInfo hitInfo = {};
    rayData.packedHitInfo = hitInfo.getData(); // Invalid hit
}

// For alpha test
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
    const uint reservoirIndex = index2Dto1D(pixel, gFrameDim.x);
    // Load the reservoir from the last frame
    ReservoirCaustic r = gPrevReservoir[reservoirIndex];

    // Return for non-splattable reservoirs
    if (r.pathLength > 0 || !r.isValid())
        return;

    // Get shading data for the current reservoir (TODO could be optimized, as shading data is only used to calculate the offset ray)
    let lod = ExplicitLodTextureSampler(0.f);
    HitInfo hit = {};
    float3 photonView;
    float3 photonFlux;
    if (!randomReplayPhotonPath(r, hit, photonView, photonFlux))
        return;

    r.sampleSurfaceView = photonView;
    r.sampleSurface = hit.getData();
    r.photonRadiance = photonFlux / r.photonGuidingPdf;

    ShadingData sd = loadShadingData(hit, r.sampleSurfaceView, lod);

    // Reproject postion in current camera view
    float4 screenPos = mul(gScene.camera.data.viewProjMatNoJitter, float4(sd.posW, 1));
    screenPos /= screenPos.w;
    screenPos.y *= -1;
    screenPos.xy = screenPos.xy * 0.5 + 0.5; // UV from [-1,1] to [0,1]
    if (any(screenPos.xy < 0) || any(screenPos.xy >= 1) || screenPos.z < 0 || screenPos.z > 1)
        return;

    //Visibility test (from point to camera)
    float3 directionToCamera = gScene.camera.getPosition() - sd.posW;
    float distanceToCamera = length(directionToCamera);
    directionToCamera /= distanceToCamera;
    distanceToCamera -= gScene.camera.data.nearZ; // Remove near
    SceneRayQuery<1> rayQuery;
    const Ray ray = Ray(sd.computeNewRayOrigin(), directionToCamera, 0.f, distanceToCamera);
    if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
        return;

    uint2 newPixel = uint2(floor(screenPos.xy * gFrameDim));
    int newReservoirIndex = index2Dto1D(newPixel, gFrameDim.x);
    if (kSplattingUseLinkedList)
    {
        int nodeNext = -1;
        InterlockedExchange(gCellCounter[newReservoirIndex], int(reservoirIndex), /*out*/ nodeNext);
        gSplattingLinkedList[int(reservoirIndex)] = nodeNext;
    }
    else
    {
        uint index = 0;
        InterlockedAdd(gGlobalCounter[kSplattingGlobalCounterElement], 1, index);

        int cellIndex = 0;
        InterlockedAdd(gCellCounter[newReservoirIndex], 1, cellIndex);

        gSplatSortData[index] = uint4(newReservoirIndex, cellIndex, pixel);
    }

    gPrevReservoir[reservoirIndex] = r;
}
