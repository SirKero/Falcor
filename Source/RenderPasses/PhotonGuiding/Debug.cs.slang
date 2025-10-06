#ifndef COUNT_TEXTURES
#define COUNT_TEXTURES 1
#endif

Texture2D<float> gGuidingTexture;
Texture2D<float> gLightIndexGuidingTexture;
RWTexture2D<float4> gDebug;

SamplerState gLinearSampler;
SamplerState gPointSampler;


cbuffer CB {
    uint2 gDispatchSize; // Dispatch Dimensions
    uint gTextureSize;   // Guiding Texture size
    float gColorScaleFactor;
    float gSizeScaleFactor;
    bool gShowLightIndexGuiding;
    uint gLightIndexGuidingSize;
    float gLightIndexGuidingScale;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchID: SV_DispatchThreadID, uint3 localInvocationID: SV_GroupThreadID, uint3 workGroupID: SV_GroupID)
{
    const uint2 pixel = dispatchID.xy;
    if (any(pixel > gDispatchSize))
        return;

    // TODO add other scaling settings
    uint textureSize = gShowLightIndexGuiding ? gLightIndexGuidingSize : gTextureSize;
    float divident = min(min(textureSize * gSizeScaleFactor, float(gDispatchSize.x)), float(gDispatchSize.y));
    float4 output = float4(0, 0, 0, 1);
    float2 uv = (float2(pixel) + 0.5) / divident;

    if (all(uv <= 1))
    {
        if (gShowLightIndexGuiding)
            output.x = gLightIndexGuidingTexture.SampleLevel(gPointSampler, uv, 0) * gLightIndexGuidingScale;
        else
            output.x = gGuidingTexture.SampleLevel(gLinearSampler, uv, 0) * gColorScaleFactor;
    }
    gDebug[pixel] = output; 
}
