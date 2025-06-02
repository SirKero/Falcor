#include "../SharedShadowDefines.slang"
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"


import Rendering.Materials.TexLODHelpers;
import Rendering.Materials.TexLODTypes;
import Scene.Raytracing;
import Scene.Intersection;
import Utils.Sampling.SampleGenerator;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;

#ifndef USE_BLACKLIST
#define USE_BLACKLIST 0
#endif

cbuffer CB
{
    uint gLightIdx; // Current light index
    float3 gLightPos;
    bool gIsDirectional; // is directional
    uint gMipCount;
    uint2 gSMRes;
    uint gFrameCount;
    uint _pad;
    float4x4 gInvViewProjection; // Inverse view projection
    float4x4 gViewProjection;    // View Projection for current light
}

// Textures
Texture2DArray<float> gMask; // Non-Opaque object mask
Texture2D<float> gSampleDistribution; //sample Distribution
RWBuffer<float> gShadowMap;           // Shadow map
Buffer<float2> gHaltonSamples;
RWBuffer<uint> gDispatchFeedbackBuffer;

SamplerState gMaskSampler;

static const bool kUseHaltonSamplePattern = USE_HALTON_SAMPLE_PATTERN;
static const uint kNumHaltonSamples = NUM_HALTON_SAMPLES;
static const bool kUseMask = USE_MASK; // USe mask to reject
static const uint kMultFactor = MASK_ISM_MULT_FACTOR;
//Soft Shadows
static const bool kUseRandomSoftShadows = USE_RANDOM_RANDOM_SOFT_SHADOWS;
static const float kRandomSoftShadowsPosRadius = RANDOM_SOFT_SHADOWS_POS_RADIUS; // For Point and Spot
static const float kRandomSoftShadowsDirSpread = RANDOM_SOFT_SHADOWS_DIR_SPREAD; // For Directional lights

struct RayData
{
    float depth;

    __init() {
        this.depth = FLT_MAX;
    }
}


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

}

[shader("anyhit")]
void anyHit(inout RayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    //Alpha text is only used when the blacklist is used (else all non-opaque geometry is culled)
    #if USE_BLACKLIST
        GeometryInstanceID instanceID = getGeometryInstanceID();
        VertexData v = getVertexData(instanceID, PrimitiveIndex(), attribs);
        const uint materialID = gScene.getMaterialID(instanceID);
        let lod = ExplicitLodTextureSampler(0.f);

        if(gScene.materials.isCastShadow(materialID))
            IgnoreHit();

        if (gScene.materials.alphaTest(v, materialID, lod, MIN_OPACITY)) 
            IgnoreHit();
    #endif
}

[shader("closesthit")]
void closestHit(inout RayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;
    VertexData v = gScene.getVertexData(triangleHit);

    float4 posH = mul(gViewProjection, float4(v.posW, 1.0));
    rayData.depth = gIsDirectional ? posH.z : posH.w; // Linear depth
}

//
// Shader entry point for ray generation shader.
//
[shader("raygeneration")]
void rayGen()
{
     uint2 pixel = DispatchRaysIndex().xy;
    const uint2 frameDim = DispatchRaysDimensions().xy;
    float2 pixelOffset = float2(0.5);
    float4 boxPixelOffset = float4(-0.5, 0.5, -0.5, 0.5); // Pixel offset to create AABB (xMin, xMax, yMin, yMax)

    const uint2 smRes = gSMRes;
    
    //
    //Sample Distribution
    //

    // Go through the mip chain
    float pixelCenterOffest = 0.5;

    float totalSamples = float(gSampleDistribution.Load(uint3(0, 0, gMipCount - 1))); // Total number of allowed samples
    totalSamples *= kMultFactor;
    const uint idx1D = pixel.x + pixel.y * frameDim.x; // Create an 1D weight from 2D

    if (idx1D == 0)
        gDispatchFeedbackBuffer[gLightIdx] = uint(round(totalSamples));

    if (idx1D > totalSamples)
        return;
    
    int mipMulFactor = 1; // Default Mip 0
    uint index = idx1D;
    uint sampleCount = 1;
    int subpixelIndex = 0;

    // IDSM Travers algorithm
    {
         // For this version we always traverse the whole mip chain, as every sample is at least 1
        uint2 mipIdx = uint2(0); // Top left
        uint2 selectedMipIdx = mipIdx;
        uint weightIdx = idx1D; // Uint weight for traversal
        uint choosenSampleCount = 0;
        int pixelIndex = 0; //Start index for the selected pixel
        uint prevMipRes = 1; // Mip res for previous iteration
        const uint highestMip = gMipCount - 2;
        uint selectedMipLevel = highestMip;
        for (int m = highestMip; m >= 0; m--) {
            uint4 mipSamples;
            mipSamples[0] = uint(round(gSampleDistribution.Load(uint3(mipIdx.x, mipIdx.y, m))));
            mipSamples[1] = uint(round(gSampleDistribution.Load(uint3(mipIdx.x + 1, mipIdx.y, m))));
            mipSamples[2] = uint(round(gSampleDistribution.Load(uint3(mipIdx.x, mipIdx.y + 1, m))));
            mipSamples[3] = uint(round(gSampleDistribution.Load(uint3(mipIdx.x + 1, mipIdx.y + 1, m))));
            mipSamples *= kMultFactor;
            uint totalSamples = mipSamples[0] + mipSamples[1] + mipSamples[2] + mipSamples[3];
            uint currSamples = 0; //Total for select in loop
            uint selectedSubpixel = 0;  //Selected subpixel id
            uint numSamples = 0;        // Number of samples for that subpixel index
            for (uint x = 0; x < 4 && totalSamples > 0; x++) {
                numSamples = mipSamples[x];
                currSamples += numSamples;
                selectedSubpixel = x;
                if (weightIdx < currSamples)
                    break;
            }
            // If total is reduced, abort and use the higher level
            if (totalSamples < choosenSampleCount)
                break;

            // Update weight idx
            uint prevSampleIdx = currSamples - numSamples;
            weightIdx -= prevSampleIdx;
            choosenSampleCount = numSamples;

            // Get start pixel index
            for (uint i = 0; i < selectedSubpixel; i++)
                pixelIndex += mipSamples[i];

            // Update idx for next it
            if (selectedSubpixel == 1 || selectedSubpixel == 3)
                mipIdx.x += 1;
            if (selectedSubpixel > 1) // 2 or 3
                mipIdx.y += 1;

            selectedMipLevel = m;
            selectedMipIdx = mipIdx;
            mipIdx *= 2; // Update for new resolution
            prevMipRes *= 2;
        }
        // Get pixel on default resolution
        float2 relPixel = float2(selectedMipIdx) / prevMipRes;
        pixel = uint2((relPixel * smRes) + 0.5);
        subpixelIndex = max(idx1D - pixelIndex,0);

        sampleCount = choosenSampleCount;
        index = idx1D % choosenSampleCount;
        mipMulFactor = 1 << selectedMipLevel; // Multiplier for Mip level
    }
    // Fetch a sample with the IDSM algorithm
    if (sampleCount <= 0)
        return;

     uint samplesSq = uint(sqrt(sampleCount)); // Num samples should be set capped to grids (e.g. 2x2, 3x3, 4x4)
    const float subpixelSize = 1.0 / samplesSq;
    float2 subpixelLoc = float2(subpixelIndex % samplesSq, subpixelIndex / samplesSq);
    float2 borderMin = subpixelLoc * subpixelSize;

    //SampleGenerator sg = SampleGenerator(pixel, gFrameCount + 34 * gLightIdx);

    if (kUseHaltonSamplePattern) {
        uint jitterIdx = (subpixelLoc.x + (subpixelLoc.y * samplesSq) + gFrameCount) % kNumHaltonSamples;
        pixelOffset = gHaltonSamples[jitterIdx]; // pixel offset in [0,1]
    }

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

    //
    // Dispatch Sample / Create Shadow Map
    //

    float2 pixelSample = pixel + pixelCenterOffest + pixelOffset;

    float2 relFramePos = pixelSample / smRes;
    float maskVal = 1.0;
    if(kUseMask)
        maskVal = gMask.SampleLevel(gMaskSampler, float3(relFramePos, gLightIdx), 0);

    relFramePos = relFramePos * 2.0 - 1.0; // From [0,1] to [-1,1]
    relFramePos.y *= -1.f;

    RayData rayData = RayData();

    bool valid = true;
    
    valid = maskVal > TRANSPARENCY_MASK_COMPAIRE_VALUE; // 1.0/255.0

    if (valid) {
        float3 lightPos = gLightPos;
        float2 rndOffset = float2(0);
        // Random offset for position
        if (kUseRandomSoftShadows) {
            SampleGenerator sg = SampleGenerator(DispatchRaysIndex().xy, gFrameCount);
            if (gIsDirectional) {
                rndOffset = sample_disk_concentric(sampleNext2D(sg));
                rndOffset *= 1.0 / gSMRes * kRandomSoftShadowsDirSpread;
            } else {
                float3 rndPosOffset = sample_sphere(sampleNext2D(sg));
                lightPos += rndPosOffset * kRandomSoftShadowsPosRadius;
            }
        }

        float4 posWPixelNear = mul(gInvViewProjection, float4(relFramePos + rndOffset, 0.0, 1.0));
        float4 posWPixelFar = mul(gInvViewProjection, float4(relFramePos, 1.0, 1.0));

        posWPixelNear.xyz /= posWPixelNear.w;
        posWPixelFar.xyz /= posWPixelFar.w;
        float3 rayDirection;
        if (gIsDirectional) {
            rayDirection = posWPixelFar.xyz - posWPixelNear.xyz;
        } else {
            rayDirection = posWPixelNear.xyz - lightPos;
        }

        RayDesc ray;
        if (gIsDirectional) {
            ray.TMin = 0;
            ray.TMax = length(rayDirection);
            ray.Origin = posWPixelNear.xyz;
            ray.Direction = rayDirection / ray.TMax;
        } else {
            ray.TMin = length(rayDirection);                 // Always start at depth 0
            ray.TMax = distance(lightPos, posWPixelFar.xyz); // Real far for the pixel
            ray.Origin = lightPos;
            ray.Direction = rayDirection / ray.TMin; // World direction
        }

        // Trace ray
        uint rayFlags = USE_BLACKLIST ? RAY_FLAG_NONE : RAY_FLAG_CULL_NON_OPAQUE;
        TraceRay(gScene.rtAccel, rayFlags, kInstanceNoParticle /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayData);
    }

    //uint insertIndex = idx1D + frameDim.x * frameDim.y * kMultFactor * gLightIdx;
    gShadowMap[idx1D] = rayData.depth;
}
