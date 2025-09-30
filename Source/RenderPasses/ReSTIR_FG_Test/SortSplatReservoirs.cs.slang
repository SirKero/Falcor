#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Math.MathHelpers;
import StructsAndHelpers;

cbuffer CB
{
    uint2 gFrameDim;
}

RWStructuredBuffer<uint32_t> gGlobalCounter;
StructuredBuffer<uint32_t> gCellCounter;

StructuredBuffer<uint4> gSortingData;

RWStructuredBuffer<uint> gCellOffsets;
RWStructuredBuffer<uint2> gSortedReservoirs;

/**
    * Prefix sum to compute where a given cell (pixel) should start its indexing.
    * @param[in] pixel Pixel corresponding to a given cell.
    */
void computeCellOffsetsFunc(const uint2 pixel)
{
    if (any(pixel >= gFrameDim))
        return;

    uint index = index2Dto1D(pixel, gFrameDim.x);

    uint cellCounter = gCellCounter[index];

    uint offset;
    InterlockedAdd(gGlobalCounter[1], cellCounter, offset);

    gCellOffsets[index] = offset;
}

/**
    * Use the cell offsets and the cell index to place an item into a sorted linear buffer.
    * @param[in] index Index of an item.
    */
void sortCellDataFunc(const uint index)
{
    //Check if index is smaller than total number of cells
    if (index >= gGlobalCounter[0])
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
