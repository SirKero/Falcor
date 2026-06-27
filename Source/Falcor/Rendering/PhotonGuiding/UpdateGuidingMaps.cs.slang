
Texture2D<uint> gGuidingMapLight;      // Light Guiding Map used for directional GM Generation. Is null if for light pass
Texture2D<float> gHistogram;           // Histogram weight
RWTexture2D<uint> gGuidingMap;         // The to be updated Guiding Map

// Mapping Resources. Only bound if mapping is enabled
#if IS_DIRECTIONAL
    Texture2D<uint> gMapDirGMToLightIndex;
#else
    Texture2D<uint> gMapLightIndexToDirGMPrev;
    RWTexture2D<uint> gMapLightIndexToDirGM;
    RWTexture2D<uint> gMapDirGMToLightIndex;
    RWStructuredBuffer<uint> gCounter;
    Texture2D<uint> gPMinPerLight;
#endif

cbuffer CB {
    uint gDispatchSize;     //Resolution of the current resource
    uint gDirectionalResourceSize; // Resolution of a directional resource
    uint gFreePhotonsLight;        // Free photons per light (or total photon count if dynamic Pmin is used)
    uint gDynMinPhotonsPerLight;   //Fallback min size per light.
}

static const bool kIsDirectional = IS_DIRECTIONAL;  //True if the current resources are directional
static const uint kLightCount = LIGHT_COUNT;        // Total Light Count
static const uint kReservedPhotonsPerCell = RESERVED_PHOTONS_PER_CELL; // Number of photons that are at least distributed per guiding map cell
static const uint kPhotonsNeededForDirectionalGM = PHOTONS_NEEDED_FOR_DIR_GM; // Light photons needed to create a directional GM

static const bool kUseMapping = USE_MAPPING; // Is mapping enabled
static const bool kUseDynamicPMin = USE_DYNAMIC_PMIN;   //Is dynamic PMin enabled
static const uint kMappingInvalidIndex = MAPPING_INVALID_INDEX; //Invalid index for mapping
static const uint kMappingPhotonsNeededToCreate = MAPPING_PHOTONS_NEEDED_TO_CREATE; // Minimum amount of photons needed to create a new direction GM with Mapping enabled
static const uint kCounterMappingIndex = COUNTER_MAPPING_INDEX;
static const uint kCounterPMinIndex = COUNTER_PMIN_INDEX;
static const uint kMapTextureSize = MAP_TEXTURE_SIZE;
static const uint kLightGMSize = LIGHT_GM_SIZE;

[numthreads(16, 16, 1)]
void main(uint3 thdID: SV_DispatchThreadID)
{
    const uint2 pixel = thdID.xy;
    if(any(pixel > gDispatchSize))
        return;

    // Early out for unused regions.
    // Cannot be used on directional resources if mapping is enabled
    uint2 lightPixel = pixel;
    if (kIsDirectional)
        lightPixel /= gDirectionalResourceSize;
    if (!(kIsDirectional && kUseMapping)) {
        int lightIndex = kIsDirectional ?
        lightPixel.x + lightPixel.y * (gDispatchSize / gDirectionalResourceSize) :
        lightPixel.x + lightPixel.y * gDispatchSize;

        if (lightIndex >= kLightCount)
            return;
    }

    // Get how many photons are free to be distributed
    uint reservedPhotons = kReservedPhotonsPerCell;
    uint freePhotons;
    #if IS_DIRECTIONAL
        //If Mapping is used, the correct light index needs to be fetched
        if (kUseMapping)
        {
            uint2 mapIndexPixel = pixel / gDirectionalResourceSize;
            uint lightIndex = gMapDirGMToLightIndex[mapIndexPixel];
            //Abort if light index is invalid
            if (lightIndex >= kLightCount)
                return;

            //Update light pixel
            lightPixel = uint2(lightIndex % kLightGMSize, lightIndex / kLightGMSize);
        }

        //Get number of photons and return if it is less than required to create a directional Guiding Map
        uint photonsForLight = gGuidingMapLight[lightPixel];
        if (photonsForLight < kPhotonsNeededForDirectionalGM)
            return;
        //Free photons (Total - (cellPhotons * cellCount))
        freePhotons = photonsForLight - (reservedPhotons * gDirectionalResourceSize * gDirectionalResourceSize);
    #else  // IS_DIRECTIONAL
        // For dynamic PMin load in the reserved amount of photons for the current cell,
        // and calculate free photons
        if (kUseDynamicPMin)
        {
            // Get free photons. gFreePhotonsLight contains all photons for this case
            int freePhotonsDyn = int(gFreePhotonsLight) - gCounter[kCounterPMinIndex];
            reservedPhotons = gDynMinPhotonsPerLight;
            if (freePhotonsDyn > 0)
            {
                reservedPhotons = gPMinPerLight[pixel];
                freePhotons = uint(freePhotonsDyn);
            } else //Fallback
            {
                freePhotons = uint(max(0, int(gFreePhotonsLight) - int(kLightCount * gDynMinPhotonsPerLight)));
            }
        } else //Fix number of photons per cell. Free photon were calculated on CPU
        {
            freePhotons = gFreePhotonsLight;
        }
    #endif //IS_DIRECTIONAL

    // Get Photons per cell using a lower bound approximation of the histogram weight times the free photons
    float histogramWeight = gHistogram[pixel];
    uint photonsPerCell = uint(floor(reservedPhotons + histogramWeight * freePhotons));

    gGuidingMap[pixel] = photonsPerCell;

    #if !IS_DIRECTIONAL
        // If mapping is enabled and the light qualifies, calculate and write mapping indices
        if (kUseMapping)
        {
            // Get previous mapping index to check if mapping was used in the last frame
            uint prevMapIndex = gMapLightIndexToDirGMPrev[pixel];
            // If mapping was set last frame and the photon amount is still higher than the least amount needed,
            // use mapping
            bool useMapping = (prevMapIndex < kMappingInvalidIndex) && (photonsPerCell > kPhotonsNeededForDirectionalGM);
            useMapping |= photonsPerCell > kMappingPhotonsNeededToCreate; //Or create a new if enough photons are needed
            // Get unique mapping index
            uint mapIndex = kMappingInvalidIndex;
            if (useMapping)
                InterlockedAdd(gCounter[kCounterMappingIndex], 1, mapIndex);

            // Write Map and Light Index to the respective textures
            if (mapIndex < kMappingInvalidIndex)
            {
                const uint2 mapPixel = uint2(mapIndex % kMapTextureSize, mapIndex / kMapTextureSize);
                const uint lightIndex = pixel.x + pixel.y * gDispatchSize.x;
                gMapLightIndexToDirGM[pixel] = mapIndex;
                gMapDirGMToLightIndex[mapPixel] = lightIndex;
            }
        }
    #endif
}
