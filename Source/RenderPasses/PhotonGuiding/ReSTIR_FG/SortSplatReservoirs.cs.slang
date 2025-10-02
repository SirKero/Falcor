#include "../StructsAndHelpers.slang"
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Math.MathHelpers;

cbuffer CB
{
    uint2 gFrameDim;
}

RWStructuredBuffer<uint32_t> gGlobalCounter;
StructuredBuffer<uint32_t> gCellCounter;

StructuredBuffer<uint4> gSortingData;

RWStructuredBuffer<uint> gCellOffsets;
RWStructuredBuffer<uint2> gSortedReservoirs;

/* Prefix Sum to compute offsets
*/
void computeCellOffsetsFunc(const uint2 pixel)
{
    if (any(pixel >= gFrameDim))
        return;

    uint index = index2Dto1D(pixel, gFrameDim.x);

    uint cellCounter = gCellCounter[index];

    uint offset;
    InterlockedAdd(gGlobalCounter[kSplattingGlobalCounterPrefixSum], cellCounter, offset);

    gCellOffsets[index] = offset;
}

/* Uses the offset to place reservoir position in the linearized buffer
*/
void sortCellDataFunc(const uint index)
{
    //Check if index is smaller than total number of cells
    if (index >= gGlobalCounter[kSplattingGlobalCounterElement])
        return;

    // The index queries where the scattered reservoir from prevPixel was at.
    uint4 sortData = gSortingData[index];

    uint2 prevPixel = sortData.zw;
    const uint linearizedIndex = sortData.x;
    const uint cellIndex = sortData.y;

    gSortedReservoirs[gCellOffsets[linearizedIndex] + cellIndex] = prevPixel;
}

[numthreads(16, 16, 1)]
void computeCellOffsets(uint2 pixel: SV_DispatchThreadID)
{
    computeCellOffsetsFunc(pixel);
}

[numthreads(256, 1, 1)]
void sortCellData(uint index: SV_DispatchThreadID)
{
    sortCellDataFunc(index);
}
