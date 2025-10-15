#ifndef IS_HORIZONTAL
#define IS_HORIZONTAL 1
#endif

#ifndef IS_VERTICAL
#define IS_VERTICAL 0
#endif

#ifndef BLUR_WIDTH
#define BLUR_WIDTH 3
#endif

#ifndef COUNT_LIGHTS
#define COUNT_LIGHTS 1
#endif

cbuffer CB {
    uint gGuidingSize;
    uint gAtlasSize;
}

Texture2D<float> gSrc;
RWTexture2D<float> gDst;

StructuredBuffer<float> gBlurWeights;

float blur(int2 pixel) {
    #if IS_HORIZONTAL
        const int2 dir = int2(1, 0);
    #elif IS_VERTICAL
        const int2 dir = int2(0,1);
    #endif

        const int2 offset = -(BLUR_WIDTH / 2) * dir;
    // Get guiding texture borders
    int2 clampMin = pixel - (pixel % gGuidingSize); 
    int2 clampMax = clampMin + (gGuidingSize - 1);
    float color = 0.0;
    [unroll]
    for (uint i = 0; i < BLUR_WIDTH; i++) {
        int2 idx = pixel + offset + i * dir;
        idx = clamp(idx, clampMin, clampMax);
        color += gSrc[idx] * gBlurWeights[i];
    }

    return color;
}

[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    if (any(pixel >= gAtlasSize))
        return;

    // Return early if light is not set
    const uint lightsPerRow = gAtlasSize / gGuidingSize;
    uint2 lightPixel = pixel / gGuidingSize;
    uint lightIdx = lightPixel.x + lightPixel.y * lightsPerRow;
    if (lightIdx >= COUNT_LIGHTS)
        return;

    float outColor = blur(pixel);
    gDst[pixel] = outColor;
}
