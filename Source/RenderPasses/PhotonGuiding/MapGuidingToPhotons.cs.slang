#ifndef COUNT_LIGHTS
#define COUNT_LIGHTS 1
#endif

Texture2D<float> gSrc;
RWTexture2D<float> gDst;

#if IS_LIGHT_PASS
    // Mapping Resources
    RWTexture2D<uint> gMapLightIdxToDirGM;   // Used if "isLightIdxPass", else it is cleared
    RWTexture2D<uint> gMapDirToLightIndexRW;   // Used if "isLightIdxPass", else unused
    RWBuffer<uint> gMapLightIdxToDirCounter; // If "isLightIdxPass" counter is increased, else it is cleared

    Texture2D<uint> gMapLightIdxToDirGMPrev; // If "isLightIdxPass" it is lastFrames gMapLightIdxToDirGM, else gMapDirToLightIndex
    Texture2D<uint> gReservedPhotonsPerLight;
    StructuredBuffer<uint> gReservedPhotons;
#else
    Texture2D<uint> gMapDirToLightIndex; //Mapping for Dir GM to Light Index
#endif

cbuffer CB {
    uint2 gDispatchDim;
    uint gDistributedPhotons;
    uint gGuidingTextureRes;

    uint gLightIdxRes;
    uint gMinPhotonsPerLight; // Guranteed less than kMinPhotonsNeededForLightGuiding
    uint gMapTextureSize;
    uint _pad;
}

static const uint kMinPhotonsNeededForLightGuiding = LIGHT_GUIDING_MIN_PHOTONS;
static const bool kUseAtlasOptimization = USE_ATLAS_OPTIMIZATION;
static const uint kAtlasOptimizationMaxIndex = ATLAS_OPTIMIZATION_MAX_INDEX;
static const uint kAtlasOptiMinPhotonsToCreate = ATLAS_OPTIMIZATION_MIN_PHOTONS_TO_CREATE;
static const bool kUseDistanceBasedMinPhoton = USE_DISTANCE_BASED_MIN_PHOTON;

static const uint kMapIndexMax = 0xFFFF;
[numthreads(16, 16, 1)]
void main(uint3 thdID: SV_DispatchThreadID)
{
    const uint2 pixel = thdID.xy;
    if (any(pixel > gDispatchDim))
        return;

    float numberPhotons = 0;
    #if IS_LIGHT_PASS
        const uint lightIndex = pixel.x + pixel.y * gLightIdxRes;
        //Valid light
        if (lightIndex < COUNT_LIGHTS) {
            if (kUseDistanceBasedMinPhoton)
            {
                int freePhotons = int(gDistributedPhotons) - int(gReservedPhotons[0]);
                uint minPhotonsPerLight = gMinPhotonsPerLight;
                if (freePhotons > 0)
                    minPhotonsPerLight = gReservedPhotonsPerLight[pixel];
                else
                    freePhotons = max(0, gDistributedPhotons - (COUNT_LIGHTS * minPhotonsPerLight));
                numberPhotons = gDst[pixel] * freePhotons + minPhotonsPerLight;
            } else
            {
                numberPhotons = floor(gDst[pixel] * gDistributedPhotons) + gMinPhotonsPerLight;
            }
            //Get Atlas Map index
            if (kUseAtlasOptimization) {
                // Qualifies for directional guiding
                uint prevMapIndex = gMapLightIdxToDirGMPrev[pixel];
                uint mapIndex = kMapIndexMax;
                bool useMapping = (prevMapIndex < kAtlasOptimizationMaxIndex) && (numberPhotons > kMinPhotonsNeededForLightGuiding); //If previous index is valid the lower amount is fine
                useMapping |= numberPhotons > kAtlasOptiMinPhotonsToCreate; // Else the higher amount of photons is needed to create the directional guiding texture
                if (useMapping) {
                    InterlockedAdd(gMapLightIdxToDirCounter[0], 1, mapIndex);
                }
                if (mapIndex < kAtlasOptimizationMaxIndex)
                {
                    gMapLightIdxToDirGM[pixel] = mapIndex;
                    uint2 mapPixel = uint2(mapIndex % gMapTextureSize, mapIndex / gMapTextureSize);
                    gMapDirToLightIndexRW[mapPixel] = lightIndex;
                }
            }
        }
            
    #else
        uint2 lightIndexPixel = uint2(0); // Pixel in light index texture
        uint lightIndex = COUNT_LIGHTS;
        if (kUseAtlasOptimization) {
            uint2 mapPixel = pixel / gGuidingTextureRes;

            lightIndex = gMapDirToLightIndex[mapPixel];
            lightIndexPixel = uint2(lightIndex % gLightIdxRes, lightIndex / gLightIdxRes);

            // Clear Prev Atlas optimization resources
            /*
            bool clearCounter = (pixel.x + pixel.y) == 0;
            if (clearCounter)
                gMapLightIdxToDirCounter[0] = 0;
            */
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
    #endif

    gDst[pixel] = numberPhotons;
}
