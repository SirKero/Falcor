#include "Utils/Math/MathConstants.slangh"

#ifndef COUNT_LIGHTS
#define COUNT_LIGHTS 1
#endif

RWTexture2D<float> gSampleDistribution0[COUNT_LIGHTS];
RWTexture2D<float> gSampleDistribution1[COUNT_LIGHTS];

cbuffer CB {
    uint2 gDispatchSize;
    uint gMipLevel; //Mip level 1 lower than dispatch size
    uint gLightCount;
}

static const uint kMaxSamplesPerPixel = MAX_SAMPLES; //Max sample count on the lowest level                         

[numthreads(16, 16, 1)]
void main(uint3 thdID: SV_DispatchThreadID)
{
    const uint2 pixel = thdID.xy;
    const uint lightID = thdID.z;
    
    // Load the 4 pixels from the mip before
    const uint2 pixelLower = pixel * 2;
    float4 values = float4(0);
    values[0] = gSampleDistribution0[lightID][pixelLower];
    values[1] = gSampleDistribution0[lightID][uint2(pixelLower.x + 1, pixelLower.y)];
    values[2] = gSampleDistribution0[lightID][uint2(pixelLower.x, pixelLower.y + 1)];
    values[3] = gSampleDistribution0[lightID][uint2(pixelLower.x + 1, pixelLower.y + 1)];
  
    float totalSampleWeight = values.x + values.y + values.z + values.w; //Total weight before redistribution.

    // check properties
    uint numValidSamples = 0;
    for (uint i = 0; i < 4; i++) {
        if (values[i] > 0) {
            numValidSamples++;
        }
    }

    bool redistribute = true;
    // Check if reweighting is possible
    if (totalSampleWeight < numValidSamples) //
        redistribute = false;

    if (redistribute) {
        // Increase all weight smaller than 0 to 1
        float remainingWeight = totalSampleWeight;
        float totalWeightOverOne = 0.0;
        for (uint i = 0; i < 4; i++) {
            if (values[i] > 0 && values[i] < 1.0) {
                remainingWeight -= 1.0;
                values[i] = 1.0;
            } else if (values[i] > 0) {
                remainingWeight -= 1.0;
                totalWeightOverOne += values[i] - 1.0;
            }
        }
        //Reweight the remaining weights
        totalSampleWeight = 0;
        for (uint i = 0; i < 4 && totalWeightOverOne > 0; i++) {
            if (values[i] > 1.0) {
                float portion = 1.0 + max(((values[i] - 1.0) / totalWeightOverOne) * remainingWeight, 0.0);
                if (gMipLevel == 0)
                {
                    portion = floor(sqrt(portion));
                    portion *= portion;
                    portion = min(portion, kMaxSamplesPerPixel);
                }
                values[i] = portion;
            }
            totalSampleWeight += values[i];
        }            
    } else {
        [unroll]
        for (uint i = 0; i < 4; i++) {
            values[i] = 0;
        }
    }

    // Write to tex
    {
        gSampleDistribution0[lightID][pixelLower] = values[0];
        gSampleDistribution0[lightID][uint2(pixelLower.x + 1, pixelLower.y)] = values[1];
        gSampleDistribution0[lightID][uint2(pixelLower.x, pixelLower.y + 1)] = values[2];
        gSampleDistribution0[lightID][uint2(pixelLower.x + 1, pixelLower.y + 1)] = values[3];
    }

    gSampleDistribution1[lightID][pixel] = totalSampleWeight;

}
