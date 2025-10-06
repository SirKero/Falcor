#ifndef COUNT_TEXTURES
#define COUNT_TEXTURES 1
#endif

#ifndef COUNTER_FORMAT
#define COUNTER_FORMAT uint
#endif

#ifndef USE_TEMPORAL_WEIGHT_TEXTURE
#define USE_TEMPORAL_WEIGHT_TEXTURE 1
#endif

#ifndef COUNT_LIGHTS
#define COUNT_LIGHTS 1
#endif

#ifndef IS_LIGHT_INDEX_TEXTURE
#define IS_LIGHT_INDEX_TEXTURE 0
#endif

RWTexture2D<COUNTER_FORMAT> gSrcCounter[COUNT_TEXTURES];    // RW for clearing; only used when gCopyFromCounter = true
Texture2D<COUNTER_FORMAT> gSrcCounterTotal[COUNT_TEXTURES]; // Only used when gCopyFromCounter = true
RWTexture2D<float> gWeightLastFrame[COUNT_TEXTURES]; // Only used when gCopyFromCounter = true
Texture2D<float> gSrc[COUNT_TEXTURES];
RWTexture2D<float> gDst[COUNT_TEXTURES];

cbuffer CB {
    uint gRes;
    bool gCopyFromCounter;
    uint gIterationCount;
    float gClearValue;
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
        // Get Start weight
        float weight = 0.0;
        #if IS_LIGHT_INDEX_TEXTURE
            uint index1D = pixel.x + pixel.y * gRes;
            weight = COUNT_LIGHTS > index1D ? 1.0 / (COUNT_LIGHTS) : 0.0;
        #else
            weight = 1.0 / (gRes * gRes); // Uniform
        #endif
        if (gIterationCount > 0) {
            float total = float(gSrcCounterTotal[texIdx][uint2(0)]);
            float pixelCounterVal = float(gSrcCounter[texIdx][pixel]);
            weight = pixelCounterVal / total;
            float oldWeight = 0.0;
            #if USE_TEMPORAL_WEIGHT_TEXTURE
                oldWeight = gWeightLastFrame[texIdx][pixel];
            #else
                oldWeight = gDst[texIdx][pixel];
            #endif

            oldWeight *= gIterationCount;
            weight = (weight + oldWeight) / (gIterationCount + 1);
        }

        COUNTER_FORMAT clearValue = 0;
        #if IS_LIGHT_INDEX_TEXTURE
            clearValue = COUNT_LIGHTS > index1D ? (COUNTER_FORMAT)gClearValue : 0.0;
        #else
            clearValue = (COUNTER_FORMAT)gClearValue; // Clear
        #endif

        // Write
        gDst[texIdx][pixel] = weight;
        gSrcCounter[texIdx][pixel] = clearValue;
        #if USE_TEMPORAL_WEIGHT_TEXTURE
            gWeightLastFrame[texIdx][pixel] = weight;
        #endif
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
