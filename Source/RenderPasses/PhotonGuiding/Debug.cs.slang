#ifndef COUNT_TEXTURES
#define COUNT_TEXTURES 1
#endif

Texture2D<float> gGuidingTexture;
RWTexture2D<float4> gDebug;

SamplerState gSampler;


cbuffer CB {
    uint2 gDispatchSize; // Dispatch Dimensions
    uint gTextureSize;   // Guiding Texture size
    float gColorScaleFactor;
    float gSizeScaleFactor;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchID: SV_DispatchThreadID, uint3 localInvocationID: SV_GroupThreadID, uint3 workGroupID: SV_GroupID)
{
    const uint2 pixel = dispatchID.xy;
    if (any(pixel > gDispatchSize))
        return;

    // TODO add other scaling settings
    float divident = min(min(gTextureSize * gSizeScaleFactor, float(gDispatchSize.x)), float(gDispatchSize.y));
    float4 output = float4(0, 0, 0, 1);
    float2 uv = (float2(pixel) + 0.5) / divident;

    if (all(uv <= 1))
    {
        output.x = gGuidingTexture.SampleLevel(gSampler, uv, 0) * gColorScaleFactor;
    }
    gDebug[pixel] = output; 
}
