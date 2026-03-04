#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Sampling.SampleGenerator;
import Utils.Math.MathHelpers;
import RenderPasses.PhotonGuiding.StructsAndHelpers;

cbuffer CB {
    uint2 gFrameDim;
}

StructuredBuffer<ReservoirCaustic> gPrevReservoir;

RWStructuredBuffer<int> gCellCounter;
RWStructuredBuffer<int> gSplattingLinkedList;
RWStructuredBuffer<uint> gGlobalCounter;
RWStructuredBuffer<uint4> gSplatSortData;

static const bool kSplattingUseLinkedList = SPLATTING_USE_LINKED_LIST;

[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    const uint reservoirIndex = index2Dto1D(pixel, gFrameDim.x);
    // Load the reservoir from the last frame
    ReservoirCaustic r = gPrevReservoir[reservoirIndex];

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
    uint newReservoirIndex = index2Dto1D(newPixel, gFrameDim.x);
    if (kSplattingUseLinkedList)
    {
        int nodeNext = -1;
        InterlockedExchange(gCellCounter[newReservoirIndex], reservoirIndex, /*out*/ nodeNext);
        gSplattingLinkedList[reservoirIndex] = nodeNext;
    }
    else
    {
        uint index = 0;
        InterlockedAdd(gGlobalCounter[kSplattingGlobalCounterElement], 1, index);

        int cellIndex = 0;
        InterlockedAdd(gCellCounter[newReservoirIndex], 1, cellIndex);

        gSplatSortData[index] = uint4(newReservoirIndex, cellIndex, pixel);
    }

}
