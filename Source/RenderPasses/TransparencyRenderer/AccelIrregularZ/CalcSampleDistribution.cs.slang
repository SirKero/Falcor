
#ifndef COUNT_LIGHTS
#define COUNT_LIGHTS 1
#endif

Texture2D<uint> gImpt[COUNT_LIGHTS];
Texture2D<uint> gImptMip[COUNT_LIGHTS];
RWTexture2D<uint> gSmp[COUNT_LIGHTS];
Texture2D<uint> gSmpMip[COUNT_LIGHTS];

static const uint kMaxAtomicWeight = 64; //Should be the same as in AccelIrregularZ.slang (where the atomic counter is increased)

cbuffer CB {
    uint2 gDstSize;
}

[numthreads(16, 16, 1)]
void main(uint3 thdID: SV_DispatchThreadID)
{
    const uint2 pixel = thdID.xy;
    if (any(pixel > gDstSize))
        return;

    uint2 pixelMip = pixel / 2;
    uint fullImportance = gImptMip[thdID.z][pixelMip];
    uint sampleImportance = gImpt[thdID.z][pixel];
    uint sampleCount = gSmpMip[thdID.z][pixelMip];
    if (gDstSize.x == 2)
        sampleCount = min(sampleCount, uint(ceil(float(fullImportance) / kMaxAtomicWeight)));

    float weight = float(sampleImportance) / fullImportance;

    //TODO error diffusion ?
    uint samples = 0;
    if (weight > 0)
        samples = uint(round(sampleCount * weight));

    gSmp[thdID.z][pixel] = samples;
}
