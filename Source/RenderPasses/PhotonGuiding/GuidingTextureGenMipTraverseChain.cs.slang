import SharedEnums;

#ifndef COUNT_TEXTURES
#define COUNT_TEXTURES 1
#endif

#ifndef COUNTER_FORMAT
#define COUNTER_FORMAT uint
#endif

#ifndef COUNT_LIGHTS
#define COUNT_LIGHTS 1
#endif

#ifndef IS_LIGHT_INDEX_TEXTURE
#define IS_LIGHT_INDEX_TEXTURE 0
#endif

#ifndef HISTORAM_ACCUM_MODE
#define HISTORAM_ACCUM_MODE 0
#endif

#ifndef USE_ATLAS_OPTIMIZATION
#define USE_ATLAS_OPTIMIZATION 0
#endif

Texture2D<COUNTER_FORMAT> gSrcCounter;    // RW for clearing; only used when gCopyFromCounter = true
Texture2D<COUNTER_FORMAT> gSrcCounterTotal; // Only used when gCopyFromCounter = true
RWTexture2D<float> gWeightLastFrame;        // Only used when gCopyFromCounter = true
Texture2D<float> gWeightLastFramePingPongRead; //Only used with the atlas optimization
Texture2D<float> gSrc;
RWTexture2D<float> gDst;
Texture2D<float> gFixedGuidingLightIdxPhotons; //Only used on a certain mip level

Texture2D<uint> gMapGuidingDirectionToLightIndex; //Used when Atlas Optimization is active
Texture2D<uint> gMapLightIdxToDirGMPrev;          // Used when Atlas Optimization is active

//Histogram accumulate modes
static const uint kAccumMode_Offline = (uint)(GuidingHistogramAccumulateMode::ResetOnMove);
static const uint kAccumMode_FrameAvrg = (uint)(GuidingHistogramAccumulateMode::AverageFrames);
static const uint kAccumMode_PercentageAvrg = (uint)(GuidingHistogramAccumulateMode::AveragePercentage);
static const uint kAccumMode_LastFrame = (uint)(GuidingHistogramAccumulateMode::UseLastFrame);

static const uint kAccumMode = HISTORAM_ACCUM_MODE;
static const bool kUseAtlasOptimization = USE_ATLAS_OPTIMIZATION; //Is always disabled for light passes
static const uint kAtlasOptimizationMaxMapIndex = 0xFFFF;

cbuffer CB {
    uint gRes;
    bool gCopyFromCounter;
    uint gIterationCount;
    uint gDispatchSize;

    bool gFixedGuidingCheckPhotonCount;
    float gAccumValue; // Used in some accumulate modes
    uint gLightGMResolution;
    uint gGMResolution;

    uint gMapResolution;
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
        float defaultWeight = 0.0;
        #if IS_LIGHT_INDEX_TEXTURE
            uint index1D = pixel.x + pixel.y * gRes;
            defaultWeight = COUNT_LIGHTS > index1D ? 1.0 / (COUNT_LIGHTS) : 0.0;
        #else
            defaultWeight = 1.0 / (gRes * gRes); // Uniform
        #endif
        float weight = defaultWeight;
        if (gIterationCount > 0) {
            uint2 totalCounterIndex = uint2(0);
            #if !IS_LIGHT_INDEX_TEXTURE
                totalCounterIndex = pixel / gRes;
            #endif
            
            float oldWeight = 0.0;
            bool oldWeightValid = true;
            if (kAccumMode != kAccumMode_LastFrame) {
                if (kUseAtlasOptimization) //Can only be true on directional guiding resources
                {
                    uint2 prevPixel = pixel;
                    oldWeightValid = false;
                    //Get the recorded counter values and weight from last frame
                    uint lightIndex = gMapGuidingDirectionToLightIndex[pixel / gGMResolution];
                    if (lightIndex < COUNT_LIGHTS)
                    {
                        uint2 lightPixel = uint2(lightIndex % gLightGMResolution, lightIndex / gLightGMResolution);
                        uint prevMapIdx = gMapLightIdxToDirGMPrev[lightPixel];
                        if (prevMapIdx < kAtlasOptimizationMaxMapIndex) {
                            prevPixel = prevPixel % gGMResolution;
                            prevPixel += uint2(prevMapIdx % gMapResolution, prevMapIdx / gMapResolution) * gGMResolution;
                            oldWeightValid = true;
                            oldWeight = gWeightLastFramePingPongRead[prevPixel];
                            totalCounterIndex = prevPixel / gRes;
                            float total = float(gSrcCounterTotal[totalCounterIndex]);
                            float pixelCounterVal = float(gSrcCounter[prevPixel]);
                            weight = total > 0 ? pixelCounterVal / total : 0.0;
                        }
                    }
                }
                else {
                    oldWeight = gWeightLastFrame[pixel];
                    float total = float(gSrcCounterTotal[totalCounterIndex]);
                    float pixelCounterVal = float(gSrcCounter[pixel]);
                    weight = total > 0 ? pixelCounterVal / total : 0.0;
                } 
            }
                        
            if (oldWeightValid)
            {
                if (kAccumMode == kAccumMode_Offline || kAccumMode == kAccumMode_FrameAvrg)
                    weight = (weight + oldWeight * gIterationCount) / (gIterationCount + 1);
                else if (kAccumMode == kAccumMode_PercentageAvrg)
                    weight = (weight * gAccumValue) + (oldWeight * (1.0 - gAccumValue));
            } else
                weight = defaultWeight;
        }

        // Write
        gDst[pixel] = weight;
        if(kAccumMode != kAccumMode_LastFrame)
            gWeightLastFrame[pixel] = weight;
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
