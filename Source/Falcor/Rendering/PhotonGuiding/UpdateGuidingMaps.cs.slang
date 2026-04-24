
Texture2D<uint> gGuidingMapLight;      // Light Guiding Map used for directional GM Generation. Is null if for light pass
Texture2D<float> gHistogram;           // Histogram weight
RWTexture2D<uint> gGuidingMap;         // The to be updated Guiding Map

cbuffer CB {
    uint gDispatchSize;     //Resolution of the current resource
    uint gIterationCount;   // At 0 temporal accumulation is disabled
    uint gDirectionalResourceSize; // Resolution of a directional resource
    uint gFreePhotonsLight; //Free photons per light (or total photon count if dynamic Pmin is used)

}

static const bool kUseMapping = USE_MAPPING; // Is mapping enabled
static const bool kIsDirectional = IS_DIRECTIONAL;  //True if the current resources are directional
static const uint kLightCount = LIGHT_COUNT;        // Total Light Count
static const uint kReservedPhotonsPerCell = RESERVED_PHOTONS_PER_CELL; // Number of photons that are at least distributed per guiding map cell
static const uint kPhotonsNeededForDirectionalGM = PHOTONS_NEEDED_FOR_DIR_GM; //Light photons needed to create a directional GM

[numthreads(16, 16, 1)]
void main(uint3 thdID: SV_DispatchThreadID)
{
    const uint2 pixel = thdID.xy;
    if(any(pixel > gDispatchSize))
        return;

    // Early out for unused regions.
    // Cannot be used on directional resources if mapping is enabled (TODO handle?)
    //TODO add early out if light dir has not enough photons?
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
    if (kIsDirectional)
    {
        //Get number of photons and return if it is less than required to create a directional Guiding Map
        uint photonsForLight = gGuidingMapLight[lightPixel];
        if (photonsForLight < kPhotonsNeededForDirectionalGM)
            return;
        //Free photons (Total - (cellPhotons * cellCount))
        freePhotons = photonsForLight - (reservedPhotons * gDirectionalResourceSize * gDirectionalResourceSize);
    }
    else
    {
        freePhotons = gFreePhotonsLight;
    }

    // Get Photons per cell using a lower bound approximation of the histogram weight times the free photons
    float histogramWeight = gHistogram[pixel];
    uint photonsPerCell = uint(floor(reservedPhotons + histogramWeight * freePhotons));

    gGuidingMap[pixel] = photonsPerCell;
}
