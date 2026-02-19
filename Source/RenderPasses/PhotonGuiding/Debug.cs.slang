#ifndef COUNT_TEXTURES
#define COUNT_TEXTURES 1
#endif

Texture2D<float> gGuidingTexture;
Texture2D<float> gLightIndexGuidingTexture;
Texture2D<uint> gMapLightIdxToDirGM;
RWTexture2D<float4> gDebug;

SamplerState gLinearSampler;
SamplerState gPointSampler;


cbuffer CB {
    uint2 gDispatchSize; // Dispatch Dimensions
    uint gGuidingAtlasSize;   // Guiding Texture size
    float gDirGMScaleFactor;

    uint gMapTextureResolution;
    int gLightIndex;
    uint gGuidingTextureSize;
    bool gShowLightIndexGuiding;

    uint gLightIndexGuidingSize;
    float gLightIndexGuidingScale;
    bool gIsFixedGuidingMode;
    bool gShowSelectLight;

    float3 gColorDirGM;
    bool gShowMinPhoton;

    float3 gColorLightGM;
    float gMinPhotonsPerLight;

    float3 gColorExtra;
}

static const bool kUseOptimizedAtlas = USE_OPTIMIZED_ATLAS;
static const uint kMapMaxIndex = 0xFFFF;

[numthreads(16, 16, 1)]
void main(uint3 dispatchID: SV_DispatchThreadID, uint3 localInvocationID: SV_GroupThreadID, uint3 workGroupID: SV_GroupID)
{
    const uint2 pixel = dispatchID.xy;
    if (any(pixel > gDispatchSize))
        return;

    float4 output = float4(0, 0, 0, 1);
    float2 uv = (float2(pixel) + 0.5) / float2(min(gDispatchSize.x,gDispatchSize.y));

    // Scale UV to light area
    if (gLightIndex >= 0 && all(uv <= 1) && !gShowSelectLight) {
        uint2 atlasOffset = uint2(gLightIndex % gLightIndexGuidingSize, gLightIndex / gLightIndexGuidingSize); // Offset in the atlas for the current lights
        uv /= float(gLightIndexGuidingSize);
        uv += float2(atlasOffset) / float(gLightIndexGuidingSize);
    }

    if (all(uv <= 1))
    {
        if (kUseOptimizedAtlas) {
            //For this mode this is the unmodified Guiding Atlas (can flicker)
            if (gShowLightIndexGuiding)
            {
                output.xyz = gGuidingTexture.SampleLevel(gPointSampler, uv, 0) * gDirGMScaleFactor * gColorDirGM;
            }
            else
            {
                float lightGuidingValue = gLightIndexGuidingTexture.SampleLevel(gPointSampler, uv, 0);
                output.xyz = lightGuidingValue * gLightIndexGuidingScale * gColorLightGM;
                if (gShowMinPhoton && lightGuidingValue <= gMinPhotonsPerLight && lightGuidingValue > 0)
                    output.xyz = gColorExtra;
                    
                uint2 lightIndexPixel = (gLightIndex >= 0 && !gShowSelectLight) ? uint2(gLightIndex % gLightIndexGuidingSize, gLightIndex / gLightIndexGuidingSize) : uint2(uv * gLightIndexGuidingSize);
                uint mapIndex = gMapLightIdxToDirGM[lightIndexPixel];
                bool showLightSelected = false;
                if (gShowSelectLight) {
                    uint lightIndex = lightIndexPixel.x + lightIndexPixel.y * gLightIndexGuidingSize;
                    showLightSelected = gLightIndex == lightIndex && gLightIndex >= 0;
                    if (showLightSelected)
                        output.xyz = gColorExtra;
                }

                if (mapIndex < kMapMaxIndex && !showLightSelected) { 
                    uint2 mapPixel = uint2(mapIndex % gMapTextureResolution, mapIndex / gMapTextureResolution) * gGuidingTextureSize;
                    uint2 pixelInAtlas = uint2(floor(uv * gLightIndexGuidingSize * gGuidingTextureSize));
                    mapPixel += pixelInAtlas % gGuidingTextureSize; // local offset
                    output.xyz = gGuidingTexture[mapPixel] * gDirGMScaleFactor * gColorDirGM;
                }
            }
        }
        else
        {
            if (gShowLightIndexGuiding)
                output.xyz = gLightIndexGuidingTexture.SampleLevel(gPointSampler, uv, 0) * gLightIndexGuidingScale * gColorLightGM;
            else {
                float guidingValue = gGuidingTexture.SampleLevel(gPointSampler, uv, 0);
                output.xyz = guidingValue * gDirGMScaleFactor * gColorDirGM;
                if (guidingValue < 1 && gIsFixedGuidingMode) {
                    float lightGuidingValue = gLightIndexGuidingTexture.SampleLevel(gPointSampler, uv, 0);
                    output.xyz += lightGuidingValue * gLightIndexGuidingScale * gColorLightGM;
                    if (gShowMinPhoton && lightGuidingValue <= gMinPhotonsPerLight && lightGuidingValue > 0)
                        output.xyz = gColorExtra;
                }
                if (gShowSelectLight) {
                    uint2 lightIndexPixel = uint2(uv * gLightIndexGuidingSize);
                    uint lightIndex = lightIndexPixel.x + lightIndexPixel.y * gLightIndexGuidingSize;
                    if (gLightIndex == lightIndex && gLightIndex >= 0)
                        output.xyz = gColorExtra;
                }
            }
        }
       
    }
    gDebug[pixel] = output; 
}
