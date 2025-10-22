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
    uint gGuidingAtlasSize;   // Guiding Texture size
    float gColorScaleFactor;

    float gSizeScaleFactor;
    int gLightIndex;
    uint gGuidingTextureSize;
    bool gShowLightIndexGuiding;
    uint gLightIndexGuidingSize;

    float gLightIndexGuidingScale;
    bool gIsFixedGuidingMode; 
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchID: SV_DispatchThreadID, uint3 localInvocationID: SV_GroupThreadID, uint3 workGroupID: SV_GroupID)
{
    const uint2 pixel = dispatchID.xy;
    if (any(pixel > gDispatchSize))
        return;

    // TODO add other scaling settings
    uint textureSize = gShowLightIndexGuiding ? gLightIndexGuidingSize : gGuidingAtlasSize;
    float divident = min(min(textureSize * gSizeScaleFactor, float(gDispatchSize.x)), float(gDispatchSize.y));
    float4 output = float4(0, 0, 0, 1);
    float2 uv = (float2(pixel) + 0.5) / divident;

    // Scale UV to light area
    if (gLightIndex >= 0 && all(uv <= 1)) {
        uint atlasLightsPerRow = gGuidingAtlasSize / gGuidingTextureSize;
        uint2 atlasOffset = uint2(gLightIndex % atlasLightsPerRow, gLightIndex / atlasLightsPerRow); // Offset in the atlas for the current lights
        uv /= float(atlasLightsPerRow);
        uv += float2(atlasOffset) / float(atlasLightsPerRow);
    }

    if (all(uv <= 1))
    {
        if (gShowLightIndexGuiding)
            output.xyz = gLightIndexGuidingTexture.SampleLevel(gPointSampler, uv, 0) * gLightIndexGuidingScale;
        else {
            float guidingValue = gGuidingTexture.SampleLevel(gPointSampler, uv, 0);
            output.xyz = guidingValue * gColorScaleFactor;
            if (guidingValue < 1 && gIsFixedGuidingMode)
                output.xy += gLightIndexGuidingTexture.SampleLevel(gPointSampler, uv, 0) * gLightIndexGuidingScale;
        }
    }
    gDebug[pixel] = output; 
}
