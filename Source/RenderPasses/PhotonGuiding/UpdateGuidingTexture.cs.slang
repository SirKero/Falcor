#ifndef COUNT_TEXTURES
#define COUNT_TEXTURES 1
#endif

Texture2D<float> gSrc[COUNT_TEXTURES];
RWTexture2D<float> gDst[COUNT_TEXTURES];

cbuffer CB {
    uint gRes;
}

/* Reduce using a Mip-Chain. Calculates the Total Importance for the Importance Map.
   gSrc is the lower Mip, gDst is one Mip higher.
   The dispatch dimensions are derived from gDst. 
*/

[numthreads(16, 16, 1)]
void main(uint3 thdID: SV_DispatchThreadID)
{
    const uint2 pixel = thdID.xy;
    if (any(pixel > gRes))
        return;

    uint2 srcIdx = pixel * 2;

    float sum = 0;
    sum += gSrc[thdID.z][uint2(srcIdx.x, srcIdx.y)];
    sum += gSrc[thdID.z][uint2(srcIdx.x + 1, srcIdx.y)];
    sum += gSrc[thdID.z][uint2(srcIdx.x, srcIdx.y + 1)];
    sum += gSrc[thdID.z][uint2(srcIdx.x + 1, srcIdx.y + 1)];

    gDst[thdID.z][pixel] = sum;
}
