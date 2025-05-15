#include "../SharedShadowDefines.slang"

#ifndef COUNT_LIGHTS
#define COUNT_LIGHTS 1
#endif

#define WK_SIZE 16
#define WK_SIZE_SQ WK_SIZE * WK_SIZE

Texture2D<uint> gSrc[COUNT_LIGHTS];
RWTexture2D<uint> gDst[COUNT_LIGHTS];

cbuffer CB {
    uint2 gDstSize;
    bool gCapLowestLevel;
}

groupshared uint sdata[WK_SIZE * WK_SIZE];

// "Explodes" an integer, i.e. inserts a 0 between each bit.  Takes inputs up to 16 bit wide.
//      For example, 0b11111111 -> 0b1010101010101010
uint integerExplode(uint x)
{
    x = (x | (x << 8)) & 0x00FF00FF;
    x = (x | (x << 4)) & 0x0F0F0F0F;
    x = (x | (x << 2)) & 0x33333333;
    x = (x | (x << 1)) & 0x55555555;
    return x;
}

// Reverse of integerExplode, i.e. takes every other bit in the integer and compresses
// those bits into a dense bit field. Takes 32-bit inputs, produces 16-bit outputs.
//    For example, 0b'abcdefgh' -> 0b'0000bdfh'
uint integerCompact(uint x)
{
    x = (x & 0x11111111) | ((x & 0x44444444) >> 1);
    x = (x & 0x03030303) | ((x & 0x30303030) >> 2);
    x = (x & 0x000F000F) | ((x & 0x0F000F00) >> 4);
    x = (x & 0x000000FF) | ((x & 0x00FF0000) >> 8);
    return x;
}

// Converts a 2D position to a linear index following a Z-curve pattern.
uint zCurveToLinearIndex(uint2 xy)
{
    return integerExplode(xy[0]) | (integerExplode(xy[1]) << 1);
}

// Converts a linear to a 2D position following a Z-curve pattern.
uint2 linearIndexToZCurve(uint index)
{
    return uint2(
        integerCompact(index),
        integerCompact(index >> 1));
}

void warpReduce(inout uint[WK_SIZE_SQ] data, int tid) {
    data[tid] += data[tid + 32];
    data[tid] += data[tid + 16];
    data[tid] += data[tid + 8];
    data[tid] += data[tid + 4];
    data[tid] += data[tid + 2];
    data[tid] += data[tid + 1];
}

// Inspired by https://developer.download.nvidia.com/compute/cuda/1.1-Beta/x86_website/projects/reduction/doc/reduction.pdf
[numthreads(WK_SIZE, WK_SIZE, 1)]
void main(uint3 thdID: SV_DispatchThreadID, uint3 localInvocationID: SV_GroupThreadID, uint3 workGroupID: SV_GroupID)
{
    const uint2 pixel = thdID.xy;
    if (any(pixel > gDstSize))
        return;

    uint linTid = zCurveToLinearIndex(localInvocationID.xy);
    uint linIdx = zCurveToLinearIndex(thdID.xy);

    sdata[linTid] = gSrc[thdID.z][thdID.xy];

    GroupMemoryBarrierWithGroupSync();

    const uint maxLoop = min(WK_SIZE_SQ, gDstSize.x * gDstSize.y);
    
    for (uint s = maxLoop / 2; s > 0; s >>= 1) {
        if (linTid < s) {
            sdata[linTid] += sdata[linTid + s];
        }
        GroupMemoryBarrierWithGroupSync();
    }

    //TODO Try https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/hlsl-shader-model-6-0-features-for-direct3d-12#wave-reduction
    
    //if (linTid < 32)
    //    warpReduce(sdata, linTid);

    if (linTid == 0)
        gDst[thdID.z][workGroupID.xy] = sdata[0];
}
