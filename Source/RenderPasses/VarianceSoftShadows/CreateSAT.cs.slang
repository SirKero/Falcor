
#ifndef NUM_SM
#define NUM_SM 1
#endif

cbuffer CB {
    uint gShadowMapRes;   //Shadow Map resolution
}

Texture2D<float> gShadowMap[NUM_SM];
RWTexture2D<uint2> gSAT[NUM_SM];

static const float kMantissaMax = MAX_MANTISSA;

[numthreads(16, 1, 1)]
void main(uint2 thID: SV_DispatchThreadID)
{
    if (thID.x > gShadowMapRes || thID.y > NUM_SM)
        return;

    uint texID = thID.y;
    uint2 satSum = uint2(0);

#if HORIZONTAL == 1
    uint y = thID.x;
    for (uint x = 0; x < gShadowMapRes; x++) {
        uint2 pixel = uint2(x, y);
        float2 varianceSM = float2(0);
        varianceSM.x = gShadowMap[texID][pixel];
        varianceSM.y = varianceSM.x * varianceSM.x;
        uint2 convertedVarianceSM = varianceSM * kMantissaMax;
        satSum += convertedVarianceSM;
        gSAT[texID][pixel] = satSum;
    }
#else // VERTICAL
    uint x = thID.x;
    for (uint y = 0; y < gShadowMapRes; y++) {
        uint2 pixel = uint2(x, y);
        satSum += gSAT[texID][pixel];
        gSAT[texID][pixel] = satSum;
    }
#endif
}
