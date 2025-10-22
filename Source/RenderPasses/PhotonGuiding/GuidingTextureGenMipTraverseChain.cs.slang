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

RWTexture2D<COUNTER_FORMAT> gSrcCounter;    // RW for clearing; only used when gCopyFromCounter = true
Texture2D<COUNTER_FORMAT> gSrcCounterTotal; // Only used when gCopyFromCounter = true
RWTexture2D<float> gWeightLastFrame; // Only used when gCopyFromCounter = true
Texture2D<float> gSrc;
RWTexture2D<float> gDst;
Texture2D<float> gFixedGuidingLightIdxPhotons; //Only used on a certain mip level

cbuffer CB {
    uint gRes;
    bool gCopyFromCounter;
    uint gIterationCount;
    float gClearValue;

    uint gDispatchSize;
    bool gFixedGuidingCheckPhotonCount;  
}

/* Reduce using a Mip-Chain. Calculates the Total Importance for the Importance Map.
   gSrc is the lower Mip, gDst is one Mip higher.
   The dispatch dimensions are derived from gDst. 
*/

[numthreads(16, 16, 1)]
void main(uint3 thdID: SV_DispatchThreadID)
{
    const uint2 pixel = thdID.xy;
    if (any(pixel > gDispatchSize))
        return;

    //Check if there is a light at the pixel
#if !IS_LIGHT_INDEX_TEXTURE
    if (gRes > 0) //Res can be 0 in case fixed photon distribution is used
    { 
        uint lightsPerRow = gDispatchSize / gRes;
        uint2 lightPixel = pixel / gRes;
        uint lightIdx = lightPixel.x + lightPixel.y * lightsPerRow;
        if (lightIdx >= COUNT_LIGHTS)
            return;
    }
#endif
    
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
            uint2 totalCounterIndex = uint2(0);
            #if !IS_LIGHT_INDEX_TEXTURE
                totalCounterIndex = pixel / gRes;
            #endif
            float total = float(gSrcCounterTotal[totalCounterIndex]);
            float pixelCounterVal = float(gSrcCounter[pixel]);
            weight = total > 0 ? pixelCounterVal / total : 0.0;
            float oldWeight = 0.0;
            #if USE_TEMPORAL_WEIGHT_TEXTURE
                oldWeight = gWeightLastFrame[pixel];
            #else
                oldWeight = gSrc[pixel];
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
        gDst[pixel] = weight;
        gSrcCounter[pixel] = clearValue;
        #if USE_TEMPORAL_WEIGHT_TEXTURE
            gWeightLastFrame[pixel] = weight;
        #endif
    }
    else
    {
        uint2 srcIdx = pixel * 2;
        //Sum of the 4 corresponding pixels of one mip below
        float sum = 0;
        sum += gSrc[uint2(srcIdx.x, srcIdx.y)];
        sum += gSrc[uint2(srcIdx.x + 1, srcIdx.y)];
        sum += gSrc[uint2(srcIdx.x, srcIdx.y + 1)];
        sum += gSrc[uint2(srcIdx.x + 1, srcIdx.y + 1)];

        if (gFixedGuidingCheckPhotonCount) {
            //Check if photons where distributed on the lower levels
            if (sum <= 0) {
                // Sample the light texture and use the number of photons
                sum += gFixedGuidingLightIdxPhotons[pixel];
            }

        }

        gDst[pixel] = sum;
    }
}
