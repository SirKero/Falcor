
Texture2D<uint> gGuidingMapLight;
Texture2D<uint> gGuidingMapDirection;
Texture2D<uint> gMapLightToDirection;

RWTexture2D<float4> gDebug;

cbuffer CB
{
    uint2 gDispatchSize; // Dispatch Dimensions
    int gSelectedLightIndex;
    uint gMinCountToCreateGM;   

    float gScaleLightGM;
    float3 gColorLightGM;

    float gScaleDirGM;
    float3 gColorDirGM;

    float3 gSelectLightModeColor; 
    bool gUseLightSelectModeHelper;

    bool gMappingShowDirectionalGM;
}

static const bool kUseMapping = USE_MAPPING;                    //Mapping scheme enabled/disabled
static const uint kMappingInvalidIndex = MAPPING_INVALID_INDEX; //Invalid index for mapping
static const uint kLightGMSize = LIGHT_GM_SIZE;                 //Size of the light guiding map
static const uint kDirGMSize = DIR_GM_SIZE;                     //Size of the whole directiona guiding map atlas
static const uint kGuidingTextureSize = GUIDING_TEXTURE_SIZE;   //Size of one directional guiding map
static const uint kMapTextureSize = MAP_TEXTURE_SIZE;           //Size of the map

[numthreads(16, 16, 1)]
void main(uint3 dispatchID: SV_DispatchThreadID, uint3 localInvocationID: SV_GroupThreadID, uint3 workGroupID: SV_GroupID)
{
    const uint2 pixel = dispatchID.xy;
    if (any(pixel > gDispatchSize))
        return;

    float4 output = float4(0, 0, 0, 1);
    float2 uv = (float2(pixel) + 0.5) / float2(min(gDispatchSize.x, gDispatchSize.y)); //Square UV (write topLeft)

    if (all(uv <= 1))
    {
        //Zoom in on selected light
        if (gSelectedLightIndex >= 0 && !gUseLightSelectModeHelper)
        {
            uint2 lightPixel = uint2(gSelectedLightIndex % kLightGMSize, gSelectedLightIndex / kLightGMSize);
            uint lightGMValue = gGuidingMapLight[lightPixel];
            output.xyz = lightGMValue * gScaleLightGM * gColorLightGM;

            uint2 dirGMPixel = uint2(0);
            bool dirGMValid = false;
            if (kUseMapping)
            {
                //Get Mapping Index
                uint mapIndex = gMapLightToDirection[lightPixel];
                // If Mapping is valid, read directional guiding map
                if (mapIndex < kMappingInvalidIndex)
                {
                    uint2 mapPixel = uint2(mapIndex % kMapTextureSize, mapIndex / kMapTextureSize) * kGuidingTextureSize; // Offset to selected map (top left)
                    uint2 localPixel = uint2(floor(uv * kGuidingTextureSize));
                    dirGMPixel = mapPixel + localPixel;
                    dirGMValid = true;
                }
            } else
            {
                dirGMValid = lightGMValue > gMinCountToCreateGM;
                dirGMPixel = lightPixel * kGuidingTextureSize; // Top left
                dirGMPixel += uint2(floor(uv * kGuidingTextureSize)); //Local offset
            }

            if (dirGMValid) {
                uint dirGMValue = gGuidingMapDirection[dirGMPixel];
                output.xyz = dirGMValue * gScaleDirGM * gColorDirGM;
            }

            gDebug[pixel] = output;
            return;
        }

        // Get Value from light GM
        uint2 lightPixel = uint2(floor(uv * kLightGMSize));
        uint lightIndex = lightPixel.x + lightPixel.y * kLightGMSize;
        uint lightGMValue = gGuidingMapLight[lightPixel];
        output.xyz = lightGMValue * gScaleLightGM * gColorLightGM;      

        if (kUseMapping)
        {
            // Get Mapping Index
            uint mapIndex = gMapLightToDirection[lightPixel];
            //If Mapping is valid, read directional guiding map
            if (mapIndex < kMappingInvalidIndex)
            {
                uint2 mapPixel = uint2(mapIndex % kMapTextureSize, mapIndex / kMapTextureSize) * kGuidingTextureSize; // Offset to selected map (top left)
                uint2 localPixel = uint2(floor(uv * kLightGMSize * kGuidingTextureSize)) % kGuidingTextureSize;
                mapPixel += localPixel;
                uint dirGMValue = gGuidingMapDirection[mapPixel];
                output.xyz = dirGMValue * gScaleDirGM * gColorDirGM;
            }

            // We lazily overwrite light select helper
            if (gUseLightSelectModeHelper && gSelectedLightIndex >= 0)
            {
               
                if (lightIndex == gSelectedLightIndex)
                    output.xyz = gSelectLightModeColor;
            }

            // We lazily overwrite the output if the GM should be shown
            if (gMappingShowDirectionalGM)
            {
                uint2 dirGMPixel = uint2(floor(uv * kDirGMSize));
                uint dirGMValue = gGuidingMapDirection[dirGMPixel];
                output.xyz = dirGMValue * gScaleDirGM * gColorDirGM;
            }
        }
        else
        {
            // Read directional GM if it is valid and overwrite Output
            if (lightGMValue > gMinCountToCreateGM)
            {
                uint2 dirGMPixel = uint2(floor(uv * kDirGMSize));
                uint dirGMValue = gGuidingMapDirection[dirGMPixel];
                output.xyz = dirGMValue * gScaleDirGM * gColorDirGM;
            }

            // We lazily overwrite light select helper
            if (gUseLightSelectModeHelper && gSelectedLightIndex >= 0)
            {
                uint lightIndex = lightPixel.x + lightPixel.y * kLightGMSize;
                if (lightIndex == gSelectedLightIndex)
                    output.xyz = gSelectLightModeColor;
            }
        }
    }
    gDebug[pixel] = output;
}
