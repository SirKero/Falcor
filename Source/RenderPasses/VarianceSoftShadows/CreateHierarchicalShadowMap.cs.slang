#include "Utils/Math/MathConstants.slangh"

#ifndef NUM_SM
#define NUM_SM 1
#endif

cbuffer CB
{
    uint gDispatchSize;    //Size of the dispatch
    bool gFirstPass; //Should shadow map values be copied
}

Texture2D<float> gShadowMap[NUM_SM];
Texture2D<float2> gSrc[NUM_SM];
RWTexture2D<float2> gDst[NUM_SM];

SamplerState gSMSampler;

[numthreads(16, 16, 1)]
void main(uint3 thID: SV_DispatchThreadID)
{
    uint2 pixel = thID.xy;
    if (any(pixel >= gDispatchSize))
        return;

    float2 centerUV = (float2(pixel) + 0.5) / float2(gDispatchSize);

    float minDepth = FLT_MAX;
    float maxDepth = 0;

    if (gFirstPass) {
        float4 depths = gShadowMap[thID.z].Gather(gSMSampler, centerUV);

        [unroll]
        for (uint i = 0; i < 4; i++) {
            minDepth = min(minDepth, depths[i]);
            maxDepth = max(maxDepth, depths[i]);
        } 
    } else {
        float4 minDepths = gSrc[thID.z].GatherRed(gSMSampler, centerUV);
        float4 maxDepths = gSrc[thID.z].GatherGreen(gSMSampler, centerUV);

        [unroll]
        for (uint i = 0; i < 4; i++) {
            minDepth = min(minDepth, minDepths[i]);
            maxDepth = max(maxDepth, maxDepths[i]);
        }
    }

    gDst[thID.z][pixel] = float2(minDepth, maxDepth);
}
