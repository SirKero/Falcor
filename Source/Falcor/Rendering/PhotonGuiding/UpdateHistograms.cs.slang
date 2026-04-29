
Texture2D<uint> gTotalContribution;     // Total contribution for the current map
Texture2D<uint> gContribution;          // Contribution Map used to update the Histogram
RWTexture2D<float> gHistogram;          // The to be updated histogram

// Mapping Resources
Texture2D<float> gHistogramPrev; // Read only histogram for previous frame. Only valid for directional
Texture2D<uint> gMapDirectionGMToLightIndex; // Maps from Mapping to Light Index. Is needed to get the correct light index.
Texture2D<uint> gMapLightIndexToDirectionalGMPrev;  //Previous mapping. Needed for correct temporal accumulation

cbuffer CB {
    uint gDispatchSize;     //Resolution of the current resource
    uint gIterationCount;   // At 0 temporal accumulation is disabled
    uint gDirectionalResourceSize; // Resolution of a directional resource
    float gExponentialMovingAverageFactor; //in (0,1]. Lerp factor for exponential moving average
}

static const bool kIsDirectional = IS_DIRECTIONAL;  //True if the current resources are directional
static const uint kLightCount = LIGHT_COUNT;    // Total Light Count

static const bool kUseMapping = USE_MAPPING; // Is mapping enabled
static const uint kLightHistogramSize = LIGHT_HISTOGRAM_SIZE;
static const uint kMapTextureSize = MAP_TEXTURE_SIZE;   //Size of the Map texture

//Returns a uniform weight, if the resource is new (iteration 0 or mapped)
inline float getUniformWeight()
{
    float uniformWeight;
    if (kIsDirectional)
        uniformWeight = 1.0 / (gDirectionalResourceSize * gDirectionalResourceSize); // 1 / (Guiding Map Resolution)
    else
        uniformWeight = 1.0 / kLightCount;
    return uniformWeight;
}

inline float exponentialMovingAverage(float weight, float prevWeight)
{
    return prevWeight * (1.0 - gExponentialMovingAverageFactor) + weight * gExponentialMovingAverageFactor;
}

[numthreads(16, 16, 1)]
void main(uint3 thdID: SV_DispatchThreadID)
{
    const uint2 pixel = thdID.xy;
    if(any(pixel > gDispatchSize))
        return;

    // Early out for unused regions.
    // Cannot be used on directional resources if mapping is enabled (TODO handle with previous counter?)
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

    // Initialize with uniform weight if there is no temporal information.
    // Else, the weight is temporally accumulated
    float weight = 0;
    if (gIterationCount == 0)
        weight = getUniformWeight();
    else
    {
        // Get current contribution and previous weight. If mapping is used, the previous weight needs to be
        // fetched from a seperate texture at the mapping index of the last frame
        float prevWeight = 0;
        if (kIsDirectional && kUseMapping)
        {
            uint lightIndex = gMapDirectionGMToLightIndex[lightPixel]; // Light Pixel is basically the Map index
            if (lightIndex < kLightCount)                              // Valid
            {
                lightPixel = uint2(lightIndex % kLightHistogramSize, lightIndex / kLightHistogramSize); // Get "real" light pixel
                uint prevMappingIndex = gMapLightIndexToDirectionalGMPrev[lightPixel];
                uint2 prevPixel = pixel % gDirectionalResourceSize; // Local Index inside the directional resource
                prevPixel += uint2(prevMappingIndex % kMapTextureSize, prevMappingIndex / kMapTextureSize) * gDirectionalResourceSize; // Offset by map index
                //Get Previous histogram weight
                prevWeight = gHistogramPrev[prevPixel];

                // The contribution also needs to be fetched from the previous pixel, as it was recorded with the previous mapping index
                uint totalContribution = gTotalContribution[lightPixel]; // Light Contribution for normalization
                uint contribution = gContribution[prevPixel];
                weight = totalContribution > 0 ? float(contribution) / totalContribution : 0;

                // Temporal accumulation
                weight = exponentialMovingAverage(weight, prevWeight);
            } else // If mapping is invalid, use uniform weight
            {
                weight = getUniformWeight();
            }

        } else
        {
            // Fetch Contribution and Total Contribution
            uint contribution = gContribution[pixel];

            // Get total contribution index for the current resource.
            // For light it is (0,0) as the total contribution is written in the highest mip level.
            // For a directional resource it is the light pixel, as these are normalized on a per light basis.
            uint2 totalContributionIndex = uint2(0);
            if (kIsDirectional)
                totalContributionIndex = lightPixel;
            uint totalContribution = gTotalContribution[totalContributionIndex];

            // Get current normalized weight and fetch previous weight
            weight = totalContribution > 0 ? float(contribution) / totalContribution : 0;
            prevWeight = gHistogram[pixel];

            //Temporal accumulation
            weight = exponentialMovingAverage(weight, prevWeight);
        }
    }

    //Update Histogram
    gHistogram[pixel] = weight;
}
