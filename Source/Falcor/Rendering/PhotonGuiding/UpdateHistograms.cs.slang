
Texture2D<uint> gTotalContribution;     // Total contribution for the current map
Texture2D<uint> gContribution;          // Contribution Map used to update the Histogram
RWTexture2D<float> gHistogram;          // The to be updated histogram

cbuffer CB {
    uint gDispatchSize;     //Resolution of the current resource
    uint gIterationCount;   // At 0 temporal accumulation is disabled
    uint gDirectionalResourceSize; // Resolution of a directional resource
    float gExponentialMovingAverageFactor; //in (0,1]. Lerp factor for exponential moving average
}

static const bool kUseMapping = USE_MAPPING; // Is mapping enabled
static const bool kIsDirectional = IS_DIRECTIONAL;  //True if the current resources are directional
static const uint kLightCount = LIGHT_COUNT;    // Total Light Count

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
            // TODO
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
        }

        // Exponential moving average
        weight = prevWeight * (1.0 - gExponentialMovingAverageFactor) + weight * gExponentialMovingAverageFactor;
    }

    //Update Histogram
    gHistogram[pixel] = weight;
}
