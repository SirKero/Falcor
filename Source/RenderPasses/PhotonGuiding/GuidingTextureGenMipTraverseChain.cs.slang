#ifndef COUNT_TEXTURES
#define COUNT_TEXTURES 1
#endif

RWTexture2D<uint> gSrcCounter[COUNT_TEXTURES];    // RW for clearing; only used when gCopyFromCounter = true
Texture2D<uint> gSrcCounterTotal[COUNT_TEXTURES]; // Only used when gCopyFromCounter = true
Texture2D<float> gSrc[COUNT_TEXTURES];
RWTexture2D<float> gDst[COUNT_TEXTURES];

cbuffer CB {
    uint gRes;
    bool gCopyFromCounter;
    uint gIterationCount;
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

    const uint texIdx = thdID.z;

    if (gCopyFromCounter)
    {
        // Get Weight
        float weight = 1.0 / (gRes * gRes); // Uniform
        if (gIterationCount > 0) {
            float total = float(gSrcCounterTotal[texIdx][uint2(0)]);
            float pixelCounterVal = float(gSrcCounter[texIdx][pixel]);
            weight = pixelCounterVal / total;
            float oldWeight = gDst[texIdx][pixel];
            oldWeight *= gIterationCount;
            weight = (weight + oldWeight) / (gIterationCount + 1);
        }
       
        // Write
        gDst[texIdx][pixel] = weight;
        gSrcCounter[texIdx][pixel] = 1; //Clear
    }
    else
    {
        uint2 srcIdx = pixel * 2;
        //Sum of the 4 corresponding pixels of one mip below
        float sum = 0;
        sum += gSrc[texIdx][uint2(srcIdx.x, srcIdx.y)];
        sum += gSrc[texIdx][uint2(srcIdx.x + 1, srcIdx.y)];
        sum += gSrc[texIdx][uint2(srcIdx.x, srcIdx.y + 1)];
        sum += gSrc[texIdx][uint2(srcIdx.x + 1, srcIdx.y + 1)];

        gDst[texIdx][pixel] = sum;
    }
}
