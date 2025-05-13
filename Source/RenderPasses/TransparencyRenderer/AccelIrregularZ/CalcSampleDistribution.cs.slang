#pragma once
#include "../SharedShadowDefines.slang"

#ifndef COUNT_LIGHTS
#define COUNT_LIGHTS 1
#endif

#ifndef USE_ONE_BUFFER_FOR_ALL_LIGHTS
#define USE_ONE_BUFFER_FOR_ALL_LIGHTS 0
#endif

Texture2D<uint> gImpt[COUNT_LIGHTS];
Texture2D<uint> gImptMip[COUNT_LIGHTS]; 
RWTexture2D<float> gSmp[COUNT_LIGHTS];   //Distributed Sample (Rays) texture
Texture2D<float> gSmpMip[COUNT_LIGHTS];

Buffer<uint> gElementCount; // Last frames aabb count
RWBuffer<uint> gLastFrameSampleCount; //Max number of distributed samples

static const uint kMaxAtomicWeight = IMPORTANCE_MAX_ATOMIC_WEIGHT; // Should be the same as in AccelIrregularZ.slang (where the atomic counter is increased)
static const uint kMinSamples = 4096;    // Min 64x64 samples
static const uint kMaxSamples = MAX_SAMPLES; //Cannot distribute more than this per shadow map
static const bool kUseOneBufferForAllLights = USE_ONE_BUFFER_FOR_ALL_LIGHTS;

cbuffer CB {
    uint2 gDstSize;
    int gMaxNumAABBs;
    float gChangePercentageIncrease;    //(0,1] how much can the ray dispatch can increase
    float gChangePercentageDecrease;    //(0,1] how much can the ray dispatch can decrease
    bool gCalcTotalDispatchCount; // Should only be true on the max mip level
    float gMaxSampleOverestimate;
    bool gReduceTest;  
}

[numthreads(16, 16, 1)]
void main(uint3 thdID: SV_DispatchThreadID)
{
    const uint2 pixel = thdID.xy;
    if (any(pixel > gDstSize))
        return;

    //Calc dynamic amount of rays
    if (gCalcTotalDispatchCount) {
        if (thdID.z > 0 || thdID.x > 0 || thdID.y > 0) //Only one thread is calculating the following
            return;

        // Get importance and ray count from each light
        uint rayCounts[COUNT_LIGHTS];
        float importances[COUNT_LIGHTS];
        float totalRayCount = 0;
        float totalImportance = 0.0;
        int elementCount = kUseOneBufferForAllLights ? gElementCount[0] : 0;
        for (uint i = 0; i < COUNT_LIGHTS; i++) {
            rayCounts[i] = gLastFrameSampleCount[i];
            // Fallback
            if(rayCounts[i] == 0) 
                rayCounts[i] = gSmp[i][pixel];
            totalRayCount += rayCounts[i];
            importances[i] = gImpt[i][pixel] / float(kMaxAtomicWeight);
            totalImportance += importances[i];
            if(!kUseOneBufferForAllLights)
                elementCount += gElementCount[i];
        }

        // adjust ray count based on the fullness of the buffer
        int countDiff = gMaxNumAABBs - elementCount;
        float diffPercentage = float(countDiff) / gMaxNumAABBs;
        float rayCountChange = 0.0;
        if (diffPercentage > 0)
            rayCountChange = totalRayCount * diffPercentage * gChangePercentageIncrease;
        else
            rayCountChange = totalRayCount * diffPercentage * gChangePercentageDecrease;

        totalRayCount += rayCountChange;
        totalRayCount = max(totalRayCount, kMinSamples);

        // Write new ray counts to textures
        for (uint i = 0; i < COUNT_LIGHTS; i++) {
            float w = importances[i] / totalImportance;
            float newCount = min(floor(w * totalRayCount), kMaxSamples * gMaxSampleOverestimate);
            gSmp[i][pixel] = newCount;
            gLastFrameSampleCount[i] = uint(newCount);
        }
    }
    else if (gReduceTest) {
        uint2 pixelMip = uint2(0);
        uint fullImportance = gImptMip[thdID.z][pixelMip];
        float totalSampleCount = gSmpMip[thdID.z][pixelMip];
        uint sampleImportance = gImpt[thdID.z][pixel];
        float weight = float(sampleImportance) / (fullImportance + 1e-10);
        float samples = 0.0;
        if (weight > 1e-7)
            samples = totalSampleCount * weight;

        gSmp[thdID.z][pixel] = samples;
    }
    //Pull ray count to lower levels
    else {       
        uint2 pixelMip = pixel / 2;
        uint fullImportance = gImptMip[thdID.z][pixelMip];
        uint sampleImportance = gImpt[thdID.z][pixel];    //TODO Gather instead of fetching full importance mip
        float sampleCount = gSmpMip[thdID.z][pixelMip];
        //if (gDstSize.x == 2)
            //sampleCount = min(sampleCount, uint(ceil(float(fullImportance) / kMaxAtomicWeight)));

        float weight = float(sampleImportance) / (fullImportance + 1e-10);

        // TODO error diffusion ?
        float samples = 0.0;
        if (weight > 1e-7)
            samples = sampleCount * weight;

        gSmp[thdID.z][pixel] = samples;
    }
}
