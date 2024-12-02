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
    float gNear;
    float gFar;
    uint gLightIdx;     //LightIndex
    uint gMipCount;     // Number of mips
    float4x4 gViewProj;
    float4x4 gInvViewProj; // Inverse view projection
    float4x4 gInvProj;
    float4x4 gInvView;
    float4 gFrustumPlanes[4]; //Top, Bottom, Left, Right Planes of frustum
}

cbuffer JitterSamples {
    float2 gJitterSamples[MAX_SAMPLES_PER_PIXEL_X * MAX_SAMPLES_PER_PIXEL_Y];
}

RWStructuredBuffer<AABB> gAABB;
RWBuffer<uint> gCounter;
RWStructuredBuffer<SHADOW_DATA_FORMAT> gData;
RWTexture2D<uint> gAccessCounter;
Texture2D<uint> gSampleDistribution;
StructuredBuffer<uint4> gPixelSample;
Buffer<uint> gPixelSampleCounter;

SamplerState gPointSampler;

static const bool kUseSampleDistribution = USE_SAMPLE_DISTRIBUTION_IN_GEN;
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
    rayData.depth = posH.w; // Linear depth
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

//Checks if any part of the AABB is in front of the plane
//Assumes everything is in World space
bool isInFrontOfPlane(const float3 planeN, const float planeDist, const AABB aabb) {
    float3 c = aabb.center();
    float3 e = aabb.maxPoint - c; // Positive extends
    // Compute the projection interval radius of b onto L(t) = b.c + t * p.n
    float r = dot(e, abs(planeN));

    //A intersection would be if the signed distance is between [-r, r], but we only want to check if
    //any part of the box is in front of the plane, hence we test if the distance is [-inf, -r]
    return -r <= (dot(planeN, c) - planeDist);
}

//Checks if the AABB is inside of the cameras frustum
bool aabbIsVisible(AABB aabb, uint2 smSize){
    // Convert to World space AABB
    float3 points[8] = {
        aabb.minPoint,
        float3(aabb.maxPoint.x, aabb.minPoint.y, aabb.minPoint.z),
        float3(aabb.maxPoint.x, aabb.maxPoint.y, aabb.minPoint.z),
        float3(aabb.minPoint.x, aabb.maxPoint.y, aabb.minPoint.z),
        float3(aabb.minPoint.x, aabb.minPoint.y, aabb.maxPoint.z),
        float3(aabb.maxPoint.x, aabb.minPoint.y, aabb.maxPoint.z),
        float3(aabb.maxPoint.x, aabb.maxPoint.y, aabb.maxPoint.z),
        float3(aabb.minPoint.x, aabb.maxPoint.y, aabb.maxPoint.z),
    };
    AABB aabbWorld = AABB(float3(FLT_MAX), float3(-FLT_MAX));
    [unroll]
    for (uint i = 0; i < 8; i++) {
        float2 ndc = (2.0 * points[i].xy / smSize) - 1.0;
        ndc.y *= -1.0;
        float4 rayDir = mul(gInvProj, float4(ndc, 1.0, 1.0));
        rayDir.xyz /= rayDir.z;                       // Normalize z
        float3 posView = rayDir.xyz * (-points[i].z); // view is negative Z
        float4 worldPos = mul(gInvView, float4(posView, 1.0));
        aabbWorld.minPoint = min(aabbWorld.minPoint, worldPos.xyz);
        aabbWorld.maxPoint = max(aabbWorld.maxPoint, worldPos.xyz);
    }

    bool visible = true;
    [unroll]
    for (uint i = 0; i < 4; i++) {
        visible &= isInFrontOfPlane(gFrustumPlanes[i].xyz, gFrustumPlanes[i].w, aabbWorld);
    }

    return visible;
}

inline uint getInsertIndex() {
    uint insertIdx = 0;
    const uint lightIdx = kUseOneAABBForAllLights ? 0 : gLightIdx;
    InterlockedAdd(gCounter[lightIdx], 1u, insertIdx);
    return insertIdx;
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

    uint2 smRes;
    if(kUseSampleDistribution)
        smRes = uint2(frameDim.x / kMaxSamplesPerPixel.x, frameDim.y / kMaxSamplesPerPixel.y);
    else
        smRes = frameDim;

    //Clear access counter
    if (all(pixel < smRes)) {
        gAccessCounter[pixel] = 0; // clear
    }

    // Go through the mip chain
    float pixelCenterOffest = 0.5;

    if (kUseSampleDistribution) {
        uint subpixelID = 1 + pixel.x % kMaxSamplesPerPixel.x + (pixel.y % kMaxSamplesPerPixel.y) * kMaxSamplesPerPixel.x;
        pixel /= kMaxSamplesPerPixel;
        float2 relPixel = (float2(pixel)+0.5) / smRes;

        uint numSamples = 0;
        int mipLevel = 1;
        uint mipRes = 2;
        for (int m = gMipCount - 2 ; m >= 0; m--) {
            uint2 mipPos = uint2(relPixel * mipRes);
            numSamples = gSampleDistribution.Load(uint3(mipPos,m));
            mipLevel = m;
            // If a sample from the mip chain was choosen, always use 4 samples for that pixel
            if (m > 0 && numSamples <= 4) {
            //if (numSamples <= 4) { //This version handles disocclusion better but is slower as more samples are traced
                numSamples = 4;
                break;
            }
            mipRes *= 2;
        }

        // Check if pixel should be evaluated
        int mipMulFactor = 1 << mipLevel;
        if (mipLevel > 0 && any(pixel % mipMulFactor != 0))
            return;

        //Cap samples to availible patterns
        if (kUseMSAAJitterPattern) {
            if (numSamples > 2 && numSamples <= 4)
                numSamples = 4;
            else if (numSamples > 4 && numSamples <= 8)
                numSamples = 8;
        } else {
            float numSampleSqrt = sqrt(float(numSamples));
            // numSampleSqrt = floor(numSampleSqrt); // Underestimate samples (e.g. 8 -> 4 )
            numSampleSqrt = round(numSampleSqrt); // take the closest sample count
            numSamples = uint(numSampleSqrt);
            numSamples *= numSamples;
        }        

        if (numSamples < subpixelID)
            return;

        numSamples = min(numSamples, kMaxSamplesPerPixel.x * kMaxSamplesPerPixel.y);

        //DirectX Multisample pattern
        if (numSamples > 1) {
            uint jitterBuffId = subpixelID - 1; //From [1, numSamples] to [0, numSamples - 1]
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
                pixelOffset = gJitterSamples[jitterBuffId];  //pixel offset in [0,1]
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
    float3 toNear = posWPixelNear.xyz - gLightPos;

    // Add offset to the pixel position if one aabb is used
    // Currently this is solved simple by just adding an offset of the SM size * LightIndex in x direction
    if (kUseOneAABBForAllLights) {
        pixelSample.x += smRes.x * gLightIdx;
    }

    RayDesc ray;
    ray.TMin = length(toNear);                                          // Always start at depth 0
    ray.TMax = distance(gLightPos, posWPixelFar.xyz / posWPixelFar.w);  // Real far for the pixel
    ray.Origin = gLightPos;
    ray.Direction = normalize(toNear); // World direction

    RayData rayData = RayData();
    bool useRayTracing = true;
    float2 boxZ = float2(0.0); //Last two middle depths
    float lastHitDepth = 0.0;
    float2 lastTransmittances = float2(1.0); // Store the last two transmittances
    bool mergeLastBox = false; //Merge the box from the prevoius frame
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
        if (rayData.dist > 0 && i>1 && (!mergeBox)) {
            float3 minPoint = float3(pixelSample.x + boxPixelOffset.x, pixelSample.y + boxPixelOffset.z, boxZ.y);
            float3 maxPoint = float3(pixelSample.x + boxPixelOffset.y, pixelSample.y + boxPixelOffset.w, boxZ.x);

            AABB aabb = AABB(minPoint, maxPoint);
            #if ACCEL_USE_FRUSTUM_CULLING
                if (aabbIsVisible(aabb, smRes))
            #endif
                {
                    uint insertIdx = getInsertIndex();
                    if (insertIdx > MAX_IDX)
                        return;

                    gAABB[insertIdx] = aabb;
                    writeData(insertIdx, AccelShadowData(lastTransmittances.y, lastHitDepth));
                }
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
        rayData.depth = gFar;

    // Update box
    boxZ.y = boxZ.x;
    boxZ.x = lastHitDepth + (rayData.depth - lastHitDepth) / 2;

    if (lastTransmittances.y < 1.0) {
        float3 minPoint = float3(pixelSample.x + boxPixelOffset.x, pixelSample.y + boxPixelOffset.z, boxZ.y);
        float3 maxPoint = float3(pixelSample.x + boxPixelOffset.y, pixelSample.y + boxPixelOffset.w, boxZ.x);
        AABB aabb = AABB(minPoint, maxPoint);
        #if ACCEL_USE_FRUSTUM_CULLING
            if (aabbIsVisible(aabb, smRes))
        #endif
            {
                uint insertIdx = getInsertIndex();
                if (insertIdx > MAX_IDX)
                    return;

                gAABB[insertIdx] = aabb;
                writeData(insertIdx, AccelShadowData(lastTransmittances.y, lastHitDepth));
            }
    }
    // Store last box
    if (lastTransmittances.x < 1.0 && rayData.dist >= 0) {
        float3 minPoint = float3(pixelSample.x + boxPixelOffset.x, pixelSample.y + boxPixelOffset.z, boxZ.x);
        float3 maxPoint = float3(pixelSample.x + boxPixelOffset.y, pixelSample.y + boxPixelOffset.w, gFar);
        AABB aabb = AABB(minPoint, maxPoint);
        #if ACCEL_USE_FRUSTUM_CULLING
            if (aabbIsVisible(aabb, smRes))
        #endif
            {
                uint insertIdx = getInsertIndex();                
                if (insertIdx > MAX_IDX)
                    return;

                gAABB[insertIdx] = aabb;
                writeData(insertIdx, AccelShadowData(lastTransmittances.x, rayData.depth));
            }
    }
}
