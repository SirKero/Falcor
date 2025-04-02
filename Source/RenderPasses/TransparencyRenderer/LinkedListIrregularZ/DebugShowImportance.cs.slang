cbuffer CB
{
    uint2 gDispatchSize; // Target Dim
    uint2 gSMRes;        // Render Dim
    float gScaleFactorIM;  // Scale Factor
    float gScaleFactorSD;  // Scale Factor
}

// Inputs
Texture2D<float> gSampleDistribution;
Texture2D<uint> gImportanceMap;

// Outputs
RWTexture2D<float4> gDebug;

static const float4 kClearColor = float4(0, 0, 0, 1);
static const float4 kBorderColor = float4(0, 1, 0, 1);

[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    //Out of bounds
    if (any(pixel >= gDispatchSize))
        return;

    uint2 renderArea = uint2(gSMRes.x * 2 + 1, gSMRes.y);

    // Clear
    if (any(pixel > renderArea)) {
        gDebug[pixel] = kClearColor;
        return;
    }

    // Border
    if (any(pixel == uint2(0)) || any(pixel == (gSMRes+1)) || any(pixel == renderArea)) {
        gDebug[pixel] = kBorderColor;
        return;
    }

    bool isSampleDistribution = pixel.x > gSMRes.x;

    // Copy and scale
    uint2 fetchPixel = isSampleDistribution ? uint2(pixel.x - gSMRes.x - 2 , pixel.y - 1) : pixel - 1;
    float importanceValue = 0.0;
    if (isSampleDistribution)
        importanceValue = gSampleDistribution[fetchPixel] / gScaleFactorSD;
    else
        importanceValue = gImportanceMap[fetchPixel] / gScaleFactorIM;

    gDebug[pixel] = float4(importanceValue, importanceValue, importanceValue, 1.0);
}
