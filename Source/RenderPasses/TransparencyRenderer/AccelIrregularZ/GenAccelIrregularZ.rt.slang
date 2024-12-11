#include "AccelIrregularZData.slang"
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;

#ifndef MAX_ELEMENTS
#define MAX_ELEMENTS 256
#endif

#ifndef NUM_LIGHTS
#define NUM_LIGHTS 1
#endif

//Maximum index 
#ifndef MAX_IDX
#define MAX_IDX 1
#endif

#ifndef ACCEL_USE_FRUSTUM_CULLING
#define ACCEL_USE_FRUSTUM_CULLING 0
#endif

#ifndef MAX_SAMPLES_PER_PIXEL_X
#define MAX_SAMPLES_PER_PIXEL_X 8
#endif

#ifndef MAX_SAMPLES_PER_PIXEL_Y
#define MAX_SAMPLES_PER_PIXEL_Y 1
#endif

/** Payload for shadow ray.
*/
struct RayData
{
    float dist;
    float depth;
    float currentTransmittance;

    __init() {
        this.dist = -1.0;
        this.depth = 1.0;
        this.currentTransmittance = 1.0;
    }
};

cbuffer CB
{
    uint gFrameCount; // Current frame count
    float3 gLightPos; // Current Light Position
    bool gIsDirectional; //Is light a directional light (posW invalid)
    float gFar;
    uint gLightIdx;     //LightIndex
    uint gMipCount;     // Number of mips
    uint2 gSMRes;       // ShadowMap resolution
    uint2 _pad;
    float4x4 gViewProj;
    float4x4 gInvViewProj; // Inverse view projection
}

cbuffer JitterSamples {
    float2 gJitterSamples[MAX_SAMPLES_PER_PIXEL_X * MAX_SAMPLES_PER_PIXEL_Y];
}

RWStructuredBuffer<AABB> gAABB;
RWBuffer<uint> gCounter;
RWStructuredBuffer<SHADOW_DATA_FORMAT> gData;
RWTexture2D<uint> gAccessCounter;
Texture2D<float> gSampleDistribution;
StructuredBuffer<uint4> gPixelSample;
Buffer<uint> gPixelSampleCounter;

SamplerState gPointSampler;

static const bool kUseSampleDistribution = USE_SAMPLE_DISTRIBUTION_IN_GEN;
static const bool kUseOptimizedSampleDistribution = USE_OPTIMIZED_SAMPLE_DISTRIBUTION;
static const float kMinOpacity = 1e-7;
static const float kPixelOffset = ACCEL_BOXES_PIXEL_OFFSET; // Either 0.5(Normal) or 1.0(PCF)
static const uint kRayFlags = ACCEL_RAY_FLAGS;
static const uint kMipLevels = SAMPLE_DIST_MIPS;
static const bool kUseMSAAJitterPattern = USE_MSAA_JITTER;
static const uint2 kMaxSamplesPerPixel = uint2(MAX_SAMPLES_PER_PIXEL_X, MAX_SAMPLES_PER_PIXEL_Y);
static const bool kUseOneAABBForAllLights = USE_ONE_AABB_BUFFER_FOR_ALL_LIGHTS;
static const float kMergeDistance = ACCEL_MERGE_BOX_DIST;

// DX11 Standard multisampling pattern (https://learn.microsoft.com/en-us/windows/win32/api/d3d11/ne-d3d11-d3d11_standard_multisample_quality_levels?redirectedfrom=MSDN)
// Offsets are (xMin, xMax, yMin, yMax)
static const float2 kMSAAPattern2[4] = { float2(-0.25, -0.25), float2(0.25, 0.25), float2(-0.25, 0.25), float2(0.25, -0.25) };

static const float2 kMSAAPattern4[4] = { float2(-0.125, -0.375), float2(0.375, -0.125), float2(-0.375, 0.125), float2(0.125, 0.375)
                                      };
static const float2 kMSAAPattern8[8] = { float2(0.0625, -0.1875),  float2(-0.0625, 0.1875), float2(0.3125, 0.0625), float2(-0.1875, -0.3125),
                                        float2(-0.3125, 0.3125), float2(-0.4375, -0.0625), float2(0.1875, 0.4375),   float2(0.4375, -0.4375)
                                      };
/* Unused
static const float2 kMSAAPattern16[16] = { float2(0.0625, 0.0625), float2(-0.0625, -0.1875), float2(-0.1875, 0.125), float2(0.25, -0.0625),
                                         float2(-0.3125, -0.125),  float2(0.125, 0.3125), float2(0.3125, 0.1875), float2(0.1875, -0.3125),
                                         float2(-0.125, 0.375), float2(0.0, -0.4375),   float2(-0.25, 0.375),     float2(-0.375, 0.25),
                                         float2(-0.5, 0.0),      float2(0.4375, -0.25),    float2(0.375, 0.4375), float2(-0.4375, -0.5)
                                       };
*/

/** Setup ShadingData based on loaded vertex/material attributes for a hit point.
    \param[in] hit Hit information.
    \param[in] rayOrigin Ray origin.
    \param[in] rayDir Normalized ray direction.
    \param[in] lod Method for computing texture level-of-detail.
    \return ShadingData struct.
*/
ShadingData loadShadingData(const HitInfo hit, const float3 rayDir, const ITextureSampler lod)
{
    const TriangleHit triangleHit = hit.getTriangleHit();
    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);

    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);

    return sd;
}

//Shaders
[shader("miss")]
void miss(inout RayData rayData)
{
    rayData.dist = -1.0;
}

//
// Shader entry points for TriangleMesh hit groups.
//

[shader("anyhit")]
void anyHit(inout RayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    // Alpha test for non-opaque geometry.
    GeometryInstanceID instanceID = getGeometryInstanceID();
    VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
    const uint materialID = gScene.getMaterialID(instanceID);
    if (gScene.materials.alphaTest(v, materialID, 0.f, kMinOpacity)) IgnoreHit();
}

bool intersectPlane(const float3 N, const float3 p, const float3 ray, out float t) {
    t = 0.0;
    float denom = dot(N, ray);
    if (abs(denom) > 1e-4) {
        t = dot(p, N) / denom;
        return t >= 0;
    }
    return false;
}

[shader("closesthit")]
void closestHit(inout RayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;

    VertexData v = gScene.getVertexData(triangleHit);
    uint materialID = gScene.getMaterialID(triangleHit.instanceID);
    let lod = ExplicitLodTextureSampler(0.f);
    ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -WorldRayDirection(), lod);

    rayData.currentTransmittance = rayData.currentTransmittance * (1.0 - sd.opacity);
    float4 posH = mul(gViewProj, float4(sd.posW, 1.f));
    rayData.depth = gIsDirectional ? posH.z : posH.w; // Linear depth
    rayData.dist = RayTCurrent();
}

void writeData(const uint index, const AccelShadowData shadowData) {
    #if SHADOW_DATA_FORMAT_SIZE == 1
        gData[index] = shadowData.packAsUint();
    #elif SHADOW_DATA_FORMAT_SIZE == 2
        gData[index] = shadowData.packAsUint2(); // Transmittance last sample
    #elif SHADOW_DATA_FORMAT_SIZE == 4
        gData[index] = shadowData.packAsUint4(); // Transmittance last sample
    #endif
}

inline uint getInsertIndex() {
    uint insertIdx = 0;
    const uint lightIdx = kUseOneAABBForAllLights ? 0 : gLightIdx;
    InterlockedAdd(gCounter[lightIdx], 1u, insertIdx);
    return insertIdx;
}

//Writes the shadow map sample. Returns a bool if the insert was sucessfull
inline bool writeSample(float2 pixelSample, float4 boxPixelOffset, float boxMinDepth, float boxMaxDepth, float transmittance, float hitDepth) {
    float3 minPoint = float3(pixelSample.x + boxPixelOffset.x, pixelSample.y + boxPixelOffset.z, boxMinDepth);
    float3 maxPoint = float3(pixelSample.x + boxPixelOffset.y, pixelSample.y + boxPixelOffset.w, boxMaxDepth);

    AABB aabb = AABB(minPoint, maxPoint);
    uint insertIdx = getInsertIndex();
    if (insertIdx > MAX_IDX)
        return false; //Cannot append box

    gAABB[insertIdx] = aabb;
    writeData(insertIdx, AccelShadowData(transmittance, hitDepth));
    return true;
}

//
// Shader entry point for ray generation shader.
//
[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    const uint2 frameDim = DispatchRaysDimensions().xy;
    float2 pixelOffset = float2(0);
    float4 boxPixelOffset = float4(-0.5, 0.5, -0.5, 0.5); // Pixel offset to create AABB (xMin, xMax, yMin, yMax)

    const uint2 smRes = gSMRes;

    //Clear access counter
    if (all(pixel < smRes)) {
        gAccessCounter[pixel] = 0; // clear
    }

    // Go through the mip chain
    float pixelCenterOffest = 0.5;

    if (kUseSampleDistribution) {
        float totalSamples = float(gSampleDistribution.Load(uint3(0, 0, gMipCount - 1))); // Total number of allowed samples
        totalSamples = min(totalSamples, frameDim.x * frameDim.y);
        uint idx1D = pixel.x + pixel.y * frameDim.x; // Create an 1D weight from 2D
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
                mipSamples[0] = gSampleDistribution.Load(uint3(mipIdx.x, mipIdx.y, m));
                mipSamples[1] = gSampleDistribution.Load(uint3(mipIdx.x + 1, mipIdx.y, m));
                mipSamples[2] = gSampleDistribution.Load(uint3(mipIdx.x, mipIdx.y + 1, m));
                mipSamples[3] = gSampleDistribution.Load(uint3(mipIdx.x + 1, mipIdx.y + 1, m));
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
            uint weightIdx = idx1D; // Uint weight for traversal
            uint choosenSampleCount = 1;
            uint prevMipRes = 1; // Mip res for previous iteration
            for (int m = gMipCount - 2; m >= 0; m--) {
                float4 mipSamples;
                mipSamples[0] = gSampleDistribution.Load(uint3(mipIdx.x, mipIdx.y, m));
                mipSamples[1] = gSampleDistribution.Load(uint3(mipIdx.x + 1, mipIdx.y, m));
                mipSamples[2] = gSampleDistribution.Load(uint3(mipIdx.x, mipIdx.y + 1, m));
                mipSamples[3] = gSampleDistribution.Load(uint3(mipIdx.x + 1, mipIdx.y + 1, m));
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

        uint jitterIdx = idx1D % (kMaxSamplesPerPixel.x * kMaxSamplesPerPixel.y); // TODO separate jitter from sample count
        pixelOffset = gJitterSamples[jitterIdx];                     // pixel offset in [0,1]
        uint samplesSq = uint(sqrt(sampleCount)); // Num samples should be set capped to grids (e.g. 2x2, 3x3, 4x4)
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
    }else{ //Load data from external pass
        uint sampleCount = gPixelSampleCounter[gLightIdx];
        uint sampleIdx = pixel.x + frameDim.x * pixel.y;
        if(sampleIdx > sampleCount)
            return;

        uint4 pixelData = gPixelSample[sampleIdx];
        pixelOffset.x = asfloat(pixelData.x);
        pixelOffset.y = asfloat(pixelData.y);
        pixel = uint2(0);
        pixelCenterOffest = 0.0;

        boxPixelOffset.x = f16tof32(pixelData.z & 0xFFFF);
        boxPixelOffset.y = f16tof32(pixelData.z >> 16);
        boxPixelOffset.z = f16tof32(pixelData.w & 0xFFFF);
        boxPixelOffset.w = f16tof32(pixelData.w >> 16);
    }

    float2 pixelSample = pixel + pixelCenterOffest + pixelOffset;
   
    float2 relFramePos = pixelSample / smRes;
    relFramePos = relFramePos * 2.0 - 1.0; // From [0,1] to [-1,1]
    relFramePos.y *= -1.f;

    float4 posWPixelNear = mul(gInvViewProj, float4(relFramePos, 0.f, 1.f));
    float4 posWPixelFar = mul(gInvViewProj, float4(relFramePos, 1.f, 1.f));

    posWPixelNear.xyz /= posWPixelNear.w;
    posWPixelFar.xyz /= posWPixelFar.w;
    float3 toNear;
    if (gIsDirectional) {
        toNear = posWPixelFar.xyz - posWPixelNear.xyz;
    } else {
        toNear = posWPixelNear.xyz - gLightPos;
    }
   

    // Add offset to the pixel position if one aabb is used
    // Currently this is solved simple by just adding an offset of the SM size * LightIndex in x direction
    if (kUseOneAABBForAllLights) {
        pixelSample.x += smRes.x * gLightIdx;
    }

    RayDesc ray;
    if (gIsDirectional) {
        ray.TMin = 0;
        ray.TMax = length(toNear);
        ray.Origin = posWPixelNear.xyz;
        ray.Direction = gLightPos; // World direction (stored in pos)
    } else {
        ray.TMin = length(toNear); // Always start at depth 0
        ray.TMax = distance(gLightPos, posWPixelFar.xyz); // Real far for the pixel
        ray.Origin = gLightPos;
        ray.Direction = normalize(toNear); // World direction
    }
    

    RayData rayData = RayData();
    bool useRayTracing = true;
    float2 boxZ = float2(0.0); //Last two middle depths
    float lastHitDepth = 0.0;
    float2 lastTransmittances = float2(1.0); // Store the last two transmittances
    bool mergeLastBox = false;               // Merge the box from the prevoius frame
    const float far = ray.TMax;
    // Loop to get all possible samples
    for (uint i = 0; (i < MAX_ELEMENTS) && useRayTracing; i++) {
        rayData.depth = -1;
        rayData.dist = -1;

        //Trace ray
        TraceRay(gScene.rtAccel, kRayFlags, kShadowRayInstanceMask /* kShadowRayInstanceMask instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayData);

        // A miss on the first hit ends the ray
        if (i == 0 && rayData.dist < 0)
            return;

        //End ray tracing for the next frame
        if (lastTransmittances.y <= kMinOpacity || rayData.dist < 0) {
            useRayTracing = false;
        }

        // Merge boxes for non-opaque hits if they are too close to another
        float distDiff = rayData.depth - lastHitDepth;
        bool mergeBox = i > 1 && distDiff < kMergeDistance && (rayData.currentTransmittance > kMinOpacity); 
        // Update box dims
        if (rayData.dist > 0) {
            if (!mergeLastBox)
                boxZ.y = boxZ.x;
            boxZ.x = lastHitDepth + (distDiff) / 2;           
        }

        // Write output data
        if (rayData.dist > 0 && i > 1 && (!mergeBox)) {
            if (!writeSample(pixelSample, boxPixelOffset, boxZ.y, boxZ.x, lastTransmittances.y, lastHitDepth))
                 return;
        }
        // Update for next iteration
        if (rayData.dist > 0) {
            ray.TMin = rayData.dist + 1e-10;
            lastHitDepth = rayData.depth;
            if(!mergeBox)
                lastTransmittances.y = lastTransmittances.x;
            else
                lastTransmittances.y = lerp(lastTransmittances.y, lastTransmittances.x, 0.05);
            lastTransmittances.x = rayData.currentTransmittance;
            mergeLastBox = mergeBox;            
        }
    }

// Insert last two elements
    if (rayData.dist < 0)
        rayData.depth = far;

    // Update box
    boxZ.y = boxZ.x;
    boxZ.x = lastHitDepth + (rayData.depth - lastHitDepth) / 2;

    if (lastTransmittances.y < 1.0) {
        if (!writeSample(pixelSample, boxPixelOffset, boxZ.y, boxZ.x, lastTransmittances.y, lastHitDepth))
            return;
    }
    // Store last box
    if (lastTransmittances.x < 1.0 && rayData.dist >= 0) {
        if (!writeSample(pixelSample, boxPixelOffset, boxZ.x, far, lastTransmittances.x, rayData.depth))
            return;
    }
}
