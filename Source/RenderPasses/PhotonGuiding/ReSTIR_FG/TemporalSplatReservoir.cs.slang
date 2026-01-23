#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Math.MathHelpers;
import RenderPasses.PhotonGuiding.StructsAndHelpers;

#ifndef USE_LIGHT_PATH_RETRACE
#define USE_LIGHT_PATH_RETRACE 0
#endif

cbuffer CB {
    uint2 gFrameDim;
    uint gGuidingTextureResolution;
}

StructuredBuffer<ReservoirCaustic> gPrevReservoir;
RWStructuredBuffer<uint> gCellCounter;
RWStructuredBuffer<uint> gGlobalCounter;
RWStructuredBuffer<uint4> gSplatSortData;

static const float kRoughnessThreshold = ROUGHNESS_THRESHOLD;

// Photon retracing
bool randomReplayPhotonPath(ReservoirCaustic reservoir, out float3 photonHitPosition)
{
    photonHitPosition = float3(0);
    // Recreate Light Dir Sample generator
    SampleGenerator sg = SampleGenerator(reservoir.photonRetraceData.startPixel, reservoir.photonRetraceData.startSeed);

    // Create pls to get start position for the path
    PhotonLightSample pls = PhotonLightSample();
    pls.lightIdx = reservoir.lightIndex;
    pls.guidingPixels = reservoir.guidingPixels;
    pls.useRandomLightDirection = reservoir.photonRetraceData.usedRandomDirection;
    photonRetraceRecreateDirectionsRandomValues(pls, sampleNext2D(sg), gGuidingTextureResolution);

    RayDesc tmpRay = {};
    if (!photonSampleLight(pls, tmpRay, sg))
        return false;

    Ray ray = Ray(tmpRay.Origin, tmpRay.Direction, tmpRay.TMin, tmpRay.TMax); // Ray query uses this ray struct
    const uint targetPathLength = reservoir.photonRetraceData.pathLength;
    bool validPhoton = false;
    bool lastHitSpecular = false;

    for (uint i = 0; i <= targetPathLength; i++) {
        SceneRayQuery<1> rayQuery;
        HitInfo hit = {};
        float hitT = -1.0;
        if (!rayQuery.traceRay(ray, hit, hitT, 0, 0xFF))
            break;

        // Get shading infos
        let lod = ExplicitLodTextureSampler(0);
        // Get Material properties
        ShadingData sd = loadShadingData(hit, ray.dir, lod);

        //If target lenght is reached, store position and end path
        if (i == targetPathLength) {
            photonHitPosition = sd.posW;
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
        ray.origin = sd.computeNewRayOrigin(!transmission); // false is for transmissions
        ray.dir = bsdfSample.wo;
        lastHitSpecular = bsdfProperties.roughness < kRoughnessThreshold;
    }

    return validPhoton;
}


[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    // Load the reservoir from the last frame
    ReservoirCaustic r = gPrevReservoir[index2Dto1D(pixel, gFrameDim.x)];

    // Return for non-splattable reservoirs
    if (r.pathLength > 0 || !r.isValid())
        return;

    // Get shading data for the current reservoir (TODO could be optimized, as shading data is only used to calculate the offset ray)
    let lod = ExplicitLodTextureSampler(0.f);
    HitInfo hit = HitInfo(r.sampleSurface);
    if (!hit.isValid())
        return;

    ShadingData sd = loadShadingData(hit, r.sampleSurfaceView, lod);

    // Reproject postion in current camera view
    float4 screenPos = mul(gScene.camera.data.viewProjMatNoJitter, float4(sd.posW, 1));
    screenPos /= screenPos.w;
    screenPos.y *= -1;
    screenPos.xy = screenPos.xy * 0.5 + 0.5; // UV from [-1,1] to [0,1]
    if (any(screenPos.xy < 0) || any(screenPos.xy >= 1) || screenPos.z < 0 || screenPos.z > 1)
        return;

    uint2 newPixel = uint2(floor(screenPos.xy * gFrameDim));
    #if USE_LIGHT_PATH_RETRACE
    float3 retracedPhotonPos;
    bool validRetrace = randomReplayPhotonPath(r, retracedPhotonPos);
    if (validRetrace) {
        float4 retracedScreenPos = mul(gScene.camera.data.viewProjMatNoJitter, float4(retracedPhotonPos, 1));
        retracedScreenPos /= retracedScreenPos.w;
        retracedScreenPos.y *= -1;
        retracedScreenPos.xy = retracedScreenPos.xy * 0.5 + 0.5; // UV from [-1,1] to [0,1]
        int2 retracedPixel = int2(floor(retracedScreenPos.xy * gFrameDim));
        validRetrace &= all(retracedPixel == newPixel);
    }
    if (!validRetrace)
        return;
    #endif

    //Visibility test (from point to camera)
    float3 directionToCamera = gScene.camera.getPosition() - sd.posW;
    float distanceToCamera = length(directionToCamera);
    directionToCamera /= distanceToCamera;
    SceneRayQuery<1> rayQuery;
    const Ray ray = Ray(sd.computeNewRayOrigin(), directionToCamera, 0.f, distanceToCamera);
    if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
        return;

    uint linPixel = index2Dto1D(newPixel, gFrameDim.x);

    uint index = 0;
    InterlockedAdd(gGlobalCounter[kSplattingGlobalCounterElement], 1, index);

    uint cellIndex = 0;
    InterlockedAdd(gCellCounter[linPixel], 1, cellIndex);

    gSplatSortData[index] = uint4(linPixel, cellIndex, pixel); 
}
