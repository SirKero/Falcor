
#ifndef COUNT_LIGHTS
#define COUNT_LIGHTS 1
#endif

Texture2D<uint> gImpt[COUNT_LIGHTS];
Texture2D<uint> gImptMip[COUNT_LIGHTS]; 
RWTexture2D<float> gSmp[COUNT_LIGHTS];   //Distributed Sample (Rays) texture
Texture2D<float> gSmpMip[COUNT_LIGHTS];

Buffer<uint> gAABBCount;    //Last frames aabb count

static const uint kMaxAtomicWeight = 64; // Should be the same as in AccelIrregularZ.slang (where the atomic counter is increased)
static const uint kMinSamples = 4096;    // Min 64x64 samples
static const uint kMaxSamples = 512 * 512; //Cannot distribute more than this per shadow map

cbuffer CB {
    uint2 gDstSize;
    int gMaxNumAABBs;
    float gChangePercentage;    //(0,1] how much can the ray dispatch change
    bool gCalcTotalDispatchCount; //Should only be true on the max mip level
}

[numthreads(16, 16, 1)]
void main(uint3 thdID: SV_DispatchThreadID)
{
    const uint2 pixel = thdID.xy;
    if (any(pixel > gDstSize))
        return;

    //Calc dynamic amount of rays
    if (gCalcTotalDispatchCount) {
        if (thdID.z > 0) //Only one thread is calculating the following
            return;

        // Get importance and ray count from each light
        uint rayCounts[COUNT_LIGHTS];
        float importances[COUNT_LIGHTS];
        float totalRayCount = 0;
        float totalImportance = 0.0;
        int aabbCount = gAABBCount[0];
        for (uint i = 0; i < COUNT_LIGHTS; i++) {
            rayCounts[i] = gSmp[i][pixel];
            totalRayCount += rayCounts[i];
            importances[i] = gImpt[i][pixel] / float(kMaxAtomicWeight);
            totalImportance += importances[i];
        }

        // adjust ray count based on the fullness of the buffer
        int countDiff = gMaxNumAABBs - aabbCount;
        float diffPercentage = float(countDiff) / gMaxNumAABBs;
        totalRayCount += totalRayCount * diffPercentage * gChangePercentage;
        
        totalRayCount = max(totalRayCount, kMinSamples);

        // Write new ray counts to textures
        for (uint i = 0; i < COUNT_LIGHTS; i++) {
            float w = importances[i] / totalImportance;
            gSmp[i][pixel] = min(floor(w * totalRayCount), kMaxSamples);
        }
    }
    //Pull ray count to lower levels
    else {       
        uint2 pixelMip = pixel / 2;
        uint fullImportance = gImptMip[thdID.z][pixelMip];
        uint sampleImportance = gImpt[thdID.z][pixel];
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
