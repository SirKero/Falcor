
#ifndef COUNT_LIGHTS
#define COUNT_LIGHTS 1
#endif

#ifndef MAX_SAMPLES_PER_PIXEL_X
#define MAX_SAMPLES_PER_PIXEL_X 8
#endif

#ifndef MAX_SAMPLES_PER_PIXEL_Y
#define MAX_SAMPLES_PER_PIXEL_Y 1
#endif

#ifndef USE_MSAA_JITTER
#define USE_MSAA_JITTER 0
#endif

Texture2D<float> gSampleDistribution[COUNT_LIGHTS];
RWStructuredBuffer<uint4> gPixelSample[COUNT_LIGHTS];
RWBuffer<uint> gPixelSampleCounter;
RWTexture2D<float4> gTestTexture[COUNT_LIGHTS];

cbuffer CB {
    uint2 gSMRes;
    uint2 gDispatchDim;
    uint gMipCount;
    uint gFrameCount;
}

cbuffer JitterSamples {
    float2 gJitterSamples[MAX_SAMPLES_PER_PIXEL_X * MAX_SAMPLES_PER_PIXEL_Y];
}

// DX11 Standard multisampling pattern (https://learn.microsoft.com/en-us/windows/win32/api/d3d11/ne-d3d11-d3d11_standard_multisample_quality_levels?redirectedfrom=MSDN)
// Offsets are (xMin, xMax, yMin, yMax)
static const float2 kMSAAPattern2[4] = { float2(-0.25, -0.25), float2(0.25, 0.25), float2(-0.25, 0.25), float2(0.25, -0.25) };

static const float2 kMSAAPattern4[4] = { float2(-0.125, -0.375), float2(0.375, -0.125), float2(-0.375, 0.125), float2(0.125, 0.375)
                                      };
static const float2 kMSAAPattern8[8] = { float2(0.0625, -0.1875),  float2(-0.0625, 0.1875), float2(0.3125, 0.0625), float2(-0.1875, -0.3125),
                                        float2(-0.3125, 0.3125), float2(-0.4375, -0.0625), float2(0.1875, 0.4375),   float2(0.4375, -0.4375)
                                      };
                                      
static const bool kUseMSAAJitterPattern = USE_MSAA_JITTER;
static const uint2 kMaxSamplesPerPixel = uint2(MAX_SAMPLES_PER_PIXEL_X, MAX_SAMPLES_PER_PIXEL_Y);
static const bool kUseOptimizedSampleDistribution = USE_OPTIMIZED_SAMPLE_DISTRIBUTION;
static const float kFP16PrecisionGuard = 5e-4; //To avoid errors due to fp16 precision

[numthreads(16, 16, 1)]
void main(uint3 thdID: SV_DispatchThreadID)
{
    /* Old version that need thdID * MaxSamplesPerPixel dispatches
    uint2 pixel = thdID.xy;
    float2 pixelOffset = float2(0);
    float4 boxPixelOffset = float4(-0.5, 0.5, -0.5, 0.5); // Pixel offset to create AABB (xMin, xMax, yMin, yMax)
    uint2 smRes = gSMRes;
    const uint smIdx = thdID.z;

    // Go through the mip chain
    float pixelCenterOffest = 0.5;

    uint subpixelID = 1 + pixel.x % kMaxSamplesPerPixel.x + (pixel.y % kMaxSamplesPerPixel.y) * kMaxSamplesPerPixel.x;
    pixel /= kMaxSamplesPerPixel;
    float2 relPixel = (float2(pixel) + 0.5) / smRes;

    uint numSamples = 0;
    int mipLevel = 1;
    uint mipRes = 2;
    for (int m = gMipCount - 2; m >= 0; m--) {
        uint2 mipPos = uint2(relPixel * mipRes);
        numSamples = gSampleDistribution[smIdx].Load(uint3(mipPos, m));
        mipLevel = m;
        // If a sample from the mip chain was choosen, always use 4 samples for that pixel
        if (m > 0 && numSamples <= 4) {
        //if (numSamples <= 4) { // This version handles disocclusion better but is slower as more samples are traced
            numSamples = 4;
            break;
        }
        mipRes *= 2;
    }

    // Check if pixel should be evaluated
    int mipMulFactor = 1 << mipLevel;
    if (mipLevel > 0 && any(pixel % mipMulFactor != 0))
        return;

    // Cap samples to availible patterns
    if (kUseMSAAJitterPattern) {
        if (numSamples > 2 && numSamples <= 4)
            numSamples = 4;
        else if (numSamples > 4 && numSamples <= 8)
            numSamples = 8;
    } else {
        {
            float numSampleSqrt = sqrt(float(numSamples));
            //numSampleSqrt = floor(numSampleSqrt); // Underestimate samples (e.g. 8 -> 4 )
            numSampleSqrt = round(numSampleSqrt); // take the closest sample count
            numSamples = uint(numSampleSqrt);
            numSamples *= numSamples;
        }
    }

    if (numSamples < subpixelID)
        return;

    numSamples = min(numSamples, kMaxSamplesPerPixel.x * kMaxSamplesPerPixel.y);

    // DirectX Multisample pattern
    if (numSamples > 1) {
        uint jitterBuffId = subpixelID - 1; // From [1, numSamples] to [0, numSamples - 1]
        if (kUseMSAAJitterPattern)
        {
            switch (numSamples) {
            case 2:
                pixelOffset = kMSAAPattern2[jitterBuffId + 2 * (gFrameCount % 2)];
                break;
            case 4:
                pixelOffset = kMSAAPattern4[jitterBuffId];
                break;
            case 8:
                pixelOffset = kMSAAPattern8[jitterBuffId];
            }

            // Calc box offset
            float2 border = float2(-0.5, 0.5);
            if (numSamples == 2) {
                boxPixelOffset = float4(border.x - pixelOffset.x, border.y - pixelOffset.x, border.x - pixelOffset.y, border.y - pixelOffset.y);
            } else { // numSamples == 4 || numSaples == 8
                // X
                border = pixelOffset.x >= 0 ? float2(0.0, 0.5) : float2(-0.5, 0.0);
                boxPixelOffset.xy = float2(border.x - pixelOffset.x, border.y - pixelOffset.x);
                // Y
                border = pixelOffset.y >= 0 ? float2(0.0, 0.5) : float2(-0.5, 0.0);
                boxPixelOffset.zw = float2(border.x - pixelOffset.y, border.y - pixelOffset.y);
            }
        } else // Jitter Buffer
        {
            pixelOffset = gJitterSamples[jitterBuffId]; // pixel offset in [0,1]
            uint samplesSq = sqrt(numSamples); // Num samples should be set capped to grids (e.g. 2x2, 3x3, 4x4)
            const float subpixelSize = 1.0 / samplesSq;
            float2 subpixelLoc = float2(jitterBuffId % samplesSq, jitterBuffId / samplesSq);
            float2 borderMin = subpixelLoc * subpixelSize;
            // X
            float2 border = float2(borderMin.x, borderMin.x + subpixelSize) - 0.5; // From [0, 1] to [-0.5,0.5]
            pixelOffset.x = border.x + pixelOffset.x * subpixelSize; // Offset from [0,1] in pixel to [0,1] in subpixel
            boxPixelOffset.xy = float2(border.x - pixelOffset.x, border.y - pixelOffset.x);
            // Y
            border = float2(borderMin.y, borderMin.y + subpixelSize) - 0.5; // From [0, 1] to [-0.5,0.5]
            pixelOffset.y = border.x + pixelOffset.y * subpixelSize;
            boxPixelOffset.zw = float2(border.x - pixelOffset.y, border.y - pixelOffset.y);
        }
    }

    pixelOffset *= mipMulFactor;
    boxPixelOffset *= mipMulFactor;
    pixelCenterOffest *= mipMulFactor;

    float2 pixelSample = pixel + pixelCenterOffest + pixelOffset;
    */

    //New Version. Distributes ray by traversing the mip chain

    uint2 pixel = thdID.xy;
    float2 pixelOffset = float2(0);
    float4 boxPixelOffset = float4(-0.5, 0.5, -0.5, 0.5); // Pixel offset to create AABB (xMin, xMax, yMin, yMax)
    const uint2 smRes = gSMRes;
    const uint2 dispatchDim = gDispatchDim;
    const uint smIdx = thdID.z;

    // Go through the mip chain
    float pixelCenterOffest = 0.5;

    float totalSamples = float(gSampleDistribution[smIdx].Load(uint3(0, 0, gMipCount - 1))); // Total number of allowed samples
    totalSamples = min(totalSamples, dispatchDim.x * dispatchDim.y);
    uint idx1D = pixel.x + pixel.y * dispatchDim.x; // Create an 1D weight from 2D
    if (idx1D > totalSamples)
        return;

    int mipMulFactor = 1; // Default Mip 0
    uint index = idx1D;
    uint sampleCount = 1;

    if (!kUseOptimizedSampleDistribution)
    {
        float weight = idx1D / totalSamples; // weight in [0,1]
        // Go through the mip chain
        int mipLevel = gMipCount - 2;
        uint2 mipIdx = uint2(0); // Top left
        uint2 selectedMipIdx = mipIdx;
        uint prevMipRes = 1; // Mip res for previous iteration
        float choosenSampleCount = 1.0;
        bool potentiallyStop = false;
        for (int m = gMipCount - 2; m >= 0; m--) {
            float4 mipSamples;
            mipSamples[0] = gSampleDistribution[smIdx].Load(uint3(mipIdx.x, mipIdx.y, m));
            mipSamples[1] = gSampleDistribution[smIdx].Load(uint3(mipIdx.x + 1, mipIdx.y, m));
            mipSamples[2] = gSampleDistribution[smIdx].Load(uint3(mipIdx.x, mipIdx.y + 1, m));
            mipSamples[3] = gSampleDistribution[smIdx].Load(uint3(mipIdx.x + 1, mipIdx.y + 1, m));
            float totalMipSamples = mipSamples[0] + mipSamples[1] + mipSamples[2] + mipSamples[3];
            float sampleWeight = weight * totalMipSamples;
            float currSamples = 0.0;
            uint selectedSubpixel = 0;
            float numSamples = 0;
            for (uint x = 0; x < 4; x++) {
                numSamples = mipSamples[x];
                currSamples += numSamples;
                selectedSubpixel = x;
                if (sampleWeight < currSamples)
                    break;
            }
            // Update weight
            currSamples -= numSamples;
            weight = saturate((sampleWeight - currSamples) / numSamples);

            // Check if sample can be accepted
            if (potentiallyStop)
                if (floor(choosenSampleCount) > numSamples)
                    break;

            // If we are below 4 samples, the sample is potentially accepted.
            // In the next iteration we look if the sample count is still the same. If this is the case we go deeper in the mip chain,
            // else the sample from the previous iteration is accepted
            choosenSampleCount = numSamples;
            if (numSamples <= 4) {
                potentiallyStop = true;
            }
            mipLevel = m;

            // Update idx for next it
            if (selectedSubpixel == 1 || selectedSubpixel == 3)
                mipIdx.x += 1;
            if (selectedSubpixel > 1) // 2 or 3
                mipIdx.y += 1;

            selectedMipIdx = mipIdx;
            mipIdx *= 2; // Update for new resolution
            prevMipRes *= 2;
        }
        // Get pixel on default resolution
        float2 relPixel = float2(selectedMipIdx) / prevMipRes;
        pixel = uint2((relPixel * smRes) + 0.5);
        if (choosenSampleCount <= 0)
            return;
        choosenSampleCount = max(choosenSampleCount, 1.0);
        mipMulFactor = 1 << mipLevel; // Multiplier for Mip level
        // Get next lowest sample count
        float sampleSqrt = sqrt(float(choosenSampleCount));
        sampleSqrt = floor(sampleSqrt); // Underestimate samples (e.g. 8 -> 4). Other samples should be distributed randomly
        sampleCount = uint(sampleSqrt);
        sampleCount *= sampleCount;

        // Get an index from the choosenSampleCount. Theoretically this amount of samples should be produced
        index = uint(idx1D % uint(choosenSampleCount));
        bool randOffset = (index / sampleCount) >= 1; // TODO add
        if (randOffset) return;
        sampleCount = min(sampleCount, kMaxSamplesPerPixel.x * kMaxSamplesPerPixel.y); // cap to sample count
        index = index % sampleCount;
    }
    else // Optimized Version. Distributed samples are forced uints
    {
        // For this version we always traverse the whole mip chain, as every sample is at least 1
        uint2 mipIdx = uint2(0); // Top left
        uint2 selectedMipIdx = mipIdx;
        uint weightIdx = idx1D; //Uint weight for traversal
        uint choosenSampleCount = 1;
        uint prevMipRes = 1; // Mip res for previous iteration
        for (int m = gMipCount - 2; m >= 0; m--) {
            float4 mipSamples;
            mipSamples[0] = gSampleDistribution[smIdx].Load(uint3(mipIdx.x, mipIdx.y, m));
            mipSamples[1] = gSampleDistribution[smIdx].Load(uint3(mipIdx.x + 1, mipIdx.y, m));
            mipSamples[2] = gSampleDistribution[smIdx].Load(uint3(mipIdx.x, mipIdx.y + 1, m));
            mipSamples[3] = gSampleDistribution[smIdx].Load(uint3(mipIdx.x + 1, mipIdx.y + 1, m));
            uint currSamples = 0;
            uint selectedSubpixel = 0;
            uint numSamples = 0;
            for (uint x = 0; x < 4; x++) {
                numSamples = uint(round(mipSamples[x]));
                currSamples += numSamples;
                selectedSubpixel = x;
                if (weightIdx < currSamples)
                    break;
            }
            // Update weight idx
            uint prevSampleIdx = currSamples - numSamples;
            weightIdx -= prevSampleIdx;
            choosenSampleCount = numSamples;

            // Update idx for next it
            if (selectedSubpixel == 1 || selectedSubpixel == 3)
                mipIdx.x += 1;
            if (selectedSubpixel > 1) // 2 or 3
                mipIdx.y += 1;

            selectedMipIdx = mipIdx;
            mipIdx *= 2; // Update for new resolution
            prevMipRes *= 2;
        }
        // Get pixel on default resolution
        float2 relPixel = float2(selectedMipIdx) / prevMipRes;
        pixel = uint2((relPixel * smRes) + 0.5);

        sampleCount = choosenSampleCount;
        index = idx1D % choosenSampleCount;

    }

    uint jitterIdx = idx1D % (kMaxSamplesPerPixel.x * kMaxSamplesPerPixel.y); //TODO separate jitter from sample count
    pixelOffset = gJitterSamples[jitterIdx]; // pixel offset in [0,1]
    uint samplesSq = uint(sqrt(sampleCount));   // Num samples should be set capped to grids (e.g. 2x2, 3x3, 4x4)
    const float subpixelSize = 1.0 / samplesSq;
    float2 subpixelLoc = float2(index % samplesSq, index / samplesSq);
    float2 borderMin = subpixelLoc * subpixelSize;
    // X
    float2 border = float2(borderMin.x, borderMin.x + subpixelSize) - 0.5; // From [0, 1] to [-0.5,0.5]
    pixelOffset.x = border.x + pixelOffset.x * subpixelSize; // Offset from [0,1] in pixel to [0,1] in subpixel
    boxPixelOffset.xy = float2(border.x - pixelOffset.x, border.y - pixelOffset.x);
    // Y
    border = float2(borderMin.y, borderMin.y + subpixelSize) - 0.5; // From [0, 1] to [-0.5,0.5]
    pixelOffset.y = border.x + pixelOffset.y * subpixelSize;
    boxPixelOffset.zw = float2(border.x - pixelOffset.y, border.y - pixelOffset.y);

    pixelOffset *= mipMulFactor;
    boxPixelOffset *= mipMulFactor;
    pixelCenterOffest *= mipMulFactor;

    float2 pixelSample = pixel + pixelCenterOffest + pixelOffset;

    //Store in buffer
    uint insertIdx = 0;
    InterlockedAdd(gPixelSampleCounter[smIdx], 1u, insertIdx);
    uint offsetXY = f32tof16(boxPixelOffset.x - kFP16PrecisionGuard) | (f32tof16(boxPixelOffset.y + kFP16PrecisionGuard) << 16);
    uint offsetZW = f32tof16(boxPixelOffset.z - kFP16PrecisionGuard) | (f32tof16(boxPixelOffset.w + kFP16PrecisionGuard) << 16);
    gPixelSample[smIdx][insertIdx] = uint4(asuint(pixelSample.x),asuint(pixelSample.y), offsetXY, offsetZW);
}
