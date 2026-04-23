#define WK_SIZE 16
#define WK_TOTAL WK_SIZE * WK_SIZE

Texture2D<uint> gSrc;
RWTexture2D<uint> gDst;

cbuffer CB {
    uint2 gDstSize;     //Size of the destination
    bool gUseMip;       //If true, MipMap (sum of 4 samples) is used instad of reduce (usually for the last levels)
}

groupshared uint sdata[WK_TOTAL];

/*
    Parallel Reduction. Calculates the sum of the contribution.
    Each Workgroup calculates the sum of the whole group.
    gDst is the Mip-Level corresponding to the sum Region. (+5 Mip Levels)
*/
[numthreads(WK_SIZE, WK_SIZE, 1)]
void main(uint3 dispatchID: SV_DispatchThreadID, uint3 localInvocationID: SV_GroupThreadID, uint3 workGroupID: SV_GroupID)
{
    const uint2 pixel = dispatchID.xy;
    if (any(pixel > gDstSize))
        return;

    // Get Sum of 2x2 field
    uint2 startIdx = pixel * 2u;
    uint startSum = 0;
    startSum += gSrc[startIdx];
    startSum += gSrc[startIdx + uint2(1, 0)];
    startSum += gSrc[startIdx + uint2(0, 1)];
    startSum += gSrc[startIdx + uint2(1, 1)];

    // When MIPs should be used or dispatch is started from second highest MIP.
    // Sum is written to destination and shader is finished.
    if (gDstSize.x == 1 || gUseMip) {
        gDst[pixel] = startSum;
        return;
    }

    // Get 1D index
    int tid = localInvocationID.x + localInvocationID.y  * WK_SIZE;
    sdata[tid] = startSum;
    GroupMemoryBarrierWithGroupSync();

    // Reduce with Sequential Addressing.
    //TODO can be optimized further with WaveOP (https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/hlsl-shader-model-6-0-features-for-direct3d-12#wave-reduction)
    const uint maxLoop = min(WK_TOTAL, gDstSize.x * gDstSize.y); // Dispatch can theoretically be smaller than Workgroup size
    for (uint s = maxLoop / 2; s > 0; s >>= 1) {
        if (tid < s) {
            sdata[tid] += sdata[tid + s];
        }
        GroupMemoryBarrierWithGroupSync();
    }

    // First thread writes. WorkGroupID is identical to the MIP bound to gDst
    if (tid == 0)
        gDst[workGroupID.xy] = sdata[0];
}
