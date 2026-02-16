#ifndef COUNT_LIGHTS
#define COUNT_LIGHTS 1
#endif

Texture2D<float> gSrc;
RWTexture2D<float> gDst;

//Mapping Resources
RWTexture2D<uint> gMapLightIdxToDirGM;   // If "isLightIdxPass" current frame, else unused
RWTexture2D<uint> gMapDirToLightIndex;   // If "isLightIdxPass" current frame, else the reverse map for temporal accumulation
RWBuffer<uint> gMapLightIdxToDirCounter; // If "isLightIdxPass" current frame, else the last frame (for clear)

Texture2D<uint> gMapDirToLightIndex2;   // If "isLightIdxPass" unused, else the current frame

cbuffer CB {
    uint2 gDispatchDim;
    uint gDistributedPhotons;
    bool gIsLightIdxPass;

    uint gGuidingTextureRes;
    uint gLightIdxRes;
    uint gMinPhotonsPerLight; // Guranteed less than kMinPhotonsNeededForLightGuiding
    uint gMapTextureSize;
}

static const uint kMinPhotonsNeededForLightGuiding = LIGHT_GUIDING_MIN_PHOTONS;
static const bool kUseAtlasOptimization = USE_ATLAS_OPTIMIZATION;
static const uint kAtlasOptimizationMaxIndex = ATLAS_OPTIMIZATION_MAX_INDEX;

[numthreads(16, 16, 1)]
void main(uint3 thdID: SV_DispatchThreadID)
{
    const uint2 pixel = thdID.xy;
    if (any(pixel > gDispatchDim))
        return;

    float numberPhotons = 0;
    if (gIsLightIdxPass) {
        const uint lightIndex = pixel.x + pixel.y * gLightIdxRes;
        //Valid light
        if (lightIndex < COUNT_LIGHTS) {
            numberPhotons += floor(gDst[pixel] * gDistributedPhotons) + gMinPhotonsPerLight;
            //Get Atlas Map index
            if (kUseAtlasOptimization) {
                // Qualifies for directional guiding
                uint mapIndex = 0xFFFF;
                if (numberPhotons > kMinPhotonsNeededForLightGuiding) {
                    InterlockedAdd(gMapLightIdxToDirCounter[0], 1, mapIndex);
                }
                if (mapIndex < kAtlasOptimizationMaxIndex)
                {
                    gMapLightIdxToDirGM[pixel] = mapIndex;
                    uint2 mapPixel = uint2(mapIndex % gMapTextureSize, mapIndex / gMapTextureSize);
                    gMapDirToLightIndex[mapPixel] = lightIndex;
                }
            }
        }
            
    }
    else {
        uint2 lightIndexPixel = uint2(0); // Pixel in light index texture
        uint lightIndex = COUNT_LIGHTS;
        if (kUseAtlasOptimization) {
            uint2 mapPixel = pixel / gGuidingTextureRes;

            lightIndex = gMapDirToLightIndex2[mapPixel];
            lightIndexPixel = uint2(lightIndex % gLightIdxRes, lightIndex / gLightIdxRes);

            // Clear Prev Atlas optimization resources
            bool clearCounter = (pixel.x + pixel.y) == 0;
            uint2 mapPixelInt = pixel % gGuidingTextureRes;
            bool clearGM = (mapPixelInt.x + mapPixelInt.y) == 0;
            if (clearCounter)
                gMapLightIdxToDirCounter[0] = 0;
            if (clearGM)
                gMapLightIdxToDirGM[mapPixel] = 0xFFFF;
        } else {
            lightIndexPixel = pixel / gGuidingTextureRes;
            lightIndex = lightIndexPixel.x + lightIndexPixel.y * gLightIdxRes;
        }
       
        if (lightIndex < COUNT_LIGHTS)
        {
            float photonsPerLight = gSrc[lightIndexPixel];
            if (photonsPerLight > kMinPhotonsNeededForLightGuiding)
            {
                photonsPerLight -= kMinPhotonsNeededForLightGuiding;
                float percentPhotons = gDst[pixel];
                numberPhotons += floor(percentPhotons * photonsPerLight) + 1;
            } else if (photonsPerLight == kMinPhotonsNeededForLightGuiding) {
                numberPhotons = 1;
            }
        }
    }

    gDst[pixel] = numberPhotons;
}
