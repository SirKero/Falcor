#include "../RayLodHelper.slang"
#include "IDSMLinkedListData.slang"
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
#include "../SharedShadowDefines.slang"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.SampleGenerator;

#ifndef NUM_LIGHTS
#define NUM_LIGHTS 1
#endif

//Maximum index 
#ifndef MAX_IDX
#define MAX_IDX 1
#endif

#ifndef TRACE_NON_OPAQUE_ONLY
#define TRACE_NON_OPAQUE_ONLY 0
#endif

/** Payload for shadow ray. (32B)
*/
struct RayData
{
    float3 currentTransmittance;
    float dist;
    float3 sampleTransmittance;
    float depth;

    __init() {
        this.dist = -1.0;
        this.depth = 1.0;
        this.currentTransmittance = float3(1.0);
        this.sampleTransmittance = float3(1.0);
    }

    const bool isOpaque() {
        return sampleTransmittance.x < 0;
    }
};

cbuffer CB
{
    uint gFrameCount; // Current frame count
    float3 gLightPos; // Current Light Position
    bool gIsDirectional; // Is light a directional light (posW invalid)
    float3 gLightDir;   //Light Direction
    float gFar;
    uint gLightIdx;     //LightIndex
    uint gMipCount;     // Number of mips
    uint2 gSMRes;       // ShadowMap resolution
    float gSpreadAngle;
    uint _pad;
    float4x4 gViewProj;
    float4x4 gInvViewProj; // Inverse view projection
}

RWBuffer<uint> gCounter;
RWStructuredBuffer<IDSMLinkedListNode> gData;
RWTexture2D<uint> gAccessCounter;
Texture2D<float> gSampleDistribution;
Buffer<float2> gHaltonSamples;

static const float kMidpointPercentage = MIDPOINT_PERCENTAGE; // Percentage of distance the midpoint is set
static const float kMidpointDepthBias = MIDPOINT_DEPTH_BIAS; // Depth bias for midpoint
static const bool kUseOptimizedSampleDistribution = USE_OPTIMIZED_SAMPLE_DISTRIBUTION;
static const float kMinOpacity = MIN_OPACITY;
static const float kMaxTransmittance = 1.0 - kMinOpacity;
static const float kPixelOffset = ACCEL_BOXES_PIXEL_OFFSET; // Either 0.5(Normal) or 1.0(PCF)
static const uint kMipLevels = SAMPLE_DIST_MIPS;
static const uint kNumHaltonSamples = NUM_HALTON_SAMPLES;
static const bool kUseHaltonSamplePattern = USE_HALTON_SAMPLE_PATTERN;
static const bool kUseRandomSoftShadows = USE_RANDOM_RANDOM_SOFT_SHADOWS;
static const float kRandomSoftShadowsPosRadius = RANDOM_SOFT_SHADOWS_POS_RADIUS; // For Point and Spot
static const float kRandomSoftShadowsDirSpread = RANDOM_SOFT_SHADOWS_DIR_SPREAD; // For Directional lights
static const bool kUseMidpointBias = true; // Uses min between midpoint and a high bias (0.08% of lights far)
static const bool kIncludeCastShadowInstanceMaskBit = INCLUDE_CAST_SHADOW_INSTANCE_MASK_BIT;

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

// Get next hightest float
float ulp(float f)
{
    int i = asint(f);
    return abs(asfloat(i + 1) - f);
}

inline float getMidpointDepth(float lastHitDepth, float distanceDifference) {
    float midpointDepth = 0;
    if (kUseMidpointBias)
        midpointDepth = lastHitDepth + min(distanceDifference * kMidpointPercentage, kMidpointDepthBias);
    else
        midpointDepth = lastHitDepth + distanceDifference * kMidpointPercentage;

    return midpointDepth;
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
    //  Alpha test for non-opaque geometry.
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;

    VertexData v = gScene.getVertexData(triangleHit);
    const uint materialID = gScene.getMaterialID(triangleHit.instanceID);

    if (!gScene.materials.isAlphaTestSupported(materialID))
        return;

    ITextureSampler lod = ExplicitLodTextureSampler(0.f);
    float2 ddx = float2(0);
    float2 ddy = float2(0);
    // LOD
    if (kShadowLODMode == TexLODMode::RayCones)
    {
        computeAnisotropicAxesRayCones(triangleHit, v, -WorldRayDirection(), RayTCurrent(), gSpreadAngle, ddx, ddy);
        lod = ExplicitGradientTextureSampler(ddx, ddy);
    }
    /* //TODO camera parameter is not correct for shadow maps
    else if (kShadowLODMode == TexLODMode::RayDiffs)
    {
        computeRayDifferentials(triangleHit, -WorldRayDirection(), RayTCurrent(), gScene.camera, kInvFrameDim, ddx, ddy); 
        lod = ExplicitGradientTextureSampler(ddx, ddy);
    }
    */
    float3 transmittance = float3(0.0);

    if(kUseColorTransparency){
        ShadingData sd = gScene.materials.prepareShadingData(v, materialID, -WorldRayDirection(), lod);
        //uint hints = (uint)MaterialInstanceHints::AdjustShadingNormal;
        let mi = gScene.materials.getMaterialInstance(sd, lod);
        // Emissive lights
        BSDFProperties bsdfProperties = mi.getProperties(sd);
        float3 color = bsdfProperties.diffuseReflectionAlbedo + bsdfProperties.specularReflectionAlbedo;
        //Normalize color
        float maxColor = max(max(color.x, color.y), color.z);
        color /= maxColor;
        if(sd.opacity < kMinOpacity)
            transmittance = 1.0;
        else
            transmittance = color * (1.0 - sd.opacity);
    }else{
        transmittance = 1.0 - float3(gScene.materials.getMaterialOpacity(v, materialID, lod));
    }

    // If hit is transparent (alpha < 1e-7)
    if (all(transmittance > kMaxTransmittance))
        IgnoreHit();

    // Commit hit
    if (RayTCurrent() < rayData.dist) {
        rayData.sampleTransmittance = transmittance;
        rayData.dist = RayTCurrent();
    }
}

[shader("closesthit")]
void closestHit(inout RayData rayData, BuiltInTriangleIntersectionAttributes attribs)
{
    TriangleHit triangleHit;
    triangleHit.instanceID = getGeometryInstanceID();
    triangleHit.primitiveIndex = PrimitiveIndex();
    triangleHit.barycentrics = attribs.barycentrics;
    VertexData v = gScene.getVertexData(triangleHit);

    float3 transmittance = rayData.sampleTransmittance;
    rayData.sampleTransmittance = float3(1.0);
    //Case opaque object that does not call the anyHit
    if (RayTCurrent() < rayData.dist) {
        transmittance = 0.0;
        rayData.sampleTransmittance.x = -1.0;
    }
            
    rayData.currentTransmittance = rayData.currentTransmittance * transmittance;
    float4 posH = mul(gViewProj, float4(v.posW, 1.0));
    rayData.depth = gIsDirectional ? posH.z : posH.w; // Linear depth
    rayData.dist = RayTCurrent();
}

inline uint getInsertIndex() {
    uint insertIdx = 0;
    const uint lightIdx = gLightIdx;
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
    float2 pixelOffset = float2(0.5);
    float4 boxPixelOffset = float4(-0.5, 0.5, -0.5, 0.5); // Pixel offset to create AABB (xMin, xMax, yMin, yMax)

    const uint2 smRes = gSMRes;
    
    //Clear access counter
    if (all(pixel < smRes)) {
        gAccessCounter[pixel] = 0; // clear
    }

    //
    //Sample Distribution
    //

    // Go through the mip chain
    float pixelCenterOffest = 0.5;

    float totalSamples = float(gSampleDistribution.Load(uint3(0, 0, gMipCount - 1))); // Total number of allowed samples
    totalSamples = min(totalSamples, frameDim.x * frameDim.y);
    const uint idx1D = pixel.x + pixel.y * frameDim.x; // Create an 1D weight from 2D
    
    if (idx1D > totalSamples)
        return;
    
    int mipMulFactor = 1; // Default Mip 0
    uint index = idx1D;
    uint sampleCount = 1;
    int subpixelIndex = 0;

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
        sampleCount = sampleCount % kNumHaltonSamples;
        index = index % sampleCount;
    }
    else // Optimized Version. Distributed samples are forced uints
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

    if (sampleCount <= 0)
        return;

    uint samplesSq = uint(sqrt(sampleCount)); // Num samples should be set capped to grids (e.g. 2x2, 3x3, 4x4)
    const float subpixelSize = 1.0 / samplesSq;
    float2 subpixelLoc = float2(subpixelIndex % samplesSq, subpixelIndex / samplesSq);
    float2 borderMin = subpixelLoc * subpixelSize;

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

    const float pixelScale = mipMulFactor * subpixelSize;
    //
    // Dispatch Sample / Create Shadow Map
    //

    float2 pixelSample = pixel + pixelCenterOffest + pixelOffset;
   
    float2 relFramePos = pixelSample / smRes;
    relFramePos = relFramePos * 2.0 - 1.0; // From [0,1] to [-1,1]
    relFramePos.y *= -1.f;

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

    float4 posWPixelNear = mul(gInvViewProj, float4(relFramePos + rndOffset, 0.0, 1.0));
    float4 posWPixelFar = mul(gInvViewProj, float4(relFramePos, 1.0, 1.0));

    posWPixelNear.xyz /= posWPixelNear.w;
    posWPixelFar.xyz /= posWPixelFar.w;
    float3 rayDirection;
    if (gIsDirectional) {
        rayDirection = posWPixelFar.xyz - posWPixelNear.xyz;
    } else {
        rayDirection = posWPixelNear.xyz - gLightPos;
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

    RayData rayData = RayData();
    bool rayTracingLoop = true;
    float midpointLast = 0.0;
    float midpointCurrent = 0.0;
    float lastHitDepth = 0.0;
    float3 currTranmittance = float3(1.0);  //Tranmission end of current sample
    float3 prevTransmittance = float3(1.0); //Tranmission end of previous sample
    const float far = ray.TMax;

    IDSMLinkedListNode prevNode;
    prevNode.depth = FLT_MAX;
    prevNode.visibility = 1.0;
    prevNode.next = 0;
    uint prevNodeIndex = idx1D;
    uint nodeIndex = prevNodeIndex;
    const uint instanceMask = getBestParticleShadowPlane(gLightDir,kIncludeCastShadowInstanceMaskBit);
    bool currHitOpaque = false;
    bool prevHitOpaque = false;

    // Loop to get all possible samples
    for (uint i = 0; (i < MAX_ELEMENTS) && rayTracingLoop; i++) {
        rayData.depth = -1;
        rayData.dist = ray.TMax;
        rayData.sampleTransmittance = 1.0;

        // Trace ray
        uint rayFlags = 0;
    #if TRACE_NON_OPAQUE_ONLY
        rayFlags = RAY_FLAG_CULL_OPAQUE;
    #endif
        TraceRay(gScene.rtAccel, rayFlags /*Ray flags*/, instanceMask /* kShadowRayInstanceMask instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayData);

        // A miss on the first hit ends the ray
        if (i == 0 && rayData.dist < 0) {
            break;
        }

        // End Loop for the next iteration if transmittance is smaller as minValue or the ray missed the scene
        if (all(prevTransmittance <= kMinOpacity) || rayData.dist < 0) {
            rayTracingLoop = false;
        }

        // Get difference between last and current depth
        float distDiff = rayData.depth - lastHitDepth;
        // Update midpoint depth values if the ray hit something
        if (rayData.dist >= 0) {
            midpointLast = midpointCurrent;
            midpointCurrent = getMidpointDepth(lastHitDepth, distDiff);
        }

        // Write the sample stating on 3rd iteration(i=2).
        if (rayData.dist >= 0 && i > 1) {
            nodeIndex = getInsertIndex();
            if (nodeIndex > MAX_IDX)
                rayTracingLoop = false;

            prevNode.next = nodeIndex;
            gData[prevNodeIndex] = prevNode;
        }

        // Update depth, transmittance and ray for next iteration
        if (rayData.dist >= 0) {
            prevHitOpaque = currHitOpaque;
            currHitOpaque = rayData.isOpaque();
            float rayOffset = ulp(rayData.dist) * 4.0; // Next highest float x4 seems to work pretty well
            //ray.TMin = currHitOpaque ? min(rayData.dist + kOpaqueHitRayDepthBias * pixelScale, rayData.dist + rayOffset) : rayData.dist + rayOffset; // This a bit of a dirty fix for particles that overlap with solid geometry
            ray.TMin = rayData.dist + rayOffset;
            lastHitDepth = rayData.depth;
            prevTransmittance = currTranmittance;
            currTranmittance = rayData.currentTransmittance;

            // Update node
            prevNode.depth = midpointCurrent;
            #if USE_COLOR_TRANSPARENCY
                prevNode.visibility = prevTransmittance;
            #else
                prevNode.visibility = prevTransmittance.x;
            #endif
            prevNode.next = 0;
            prevNodeIndex = nodeIndex;
        }
    }

    // Insert last two elements
    bool storeLastBox = true;
#if TRACE_NON_OPAQUE_ONLY
    storeLastBox &= any(currTranmittance < 1.0);
    midpointLast = lastHitDepth + kMidpointDepthBias; //No midpoint for this hit
#else
    storeLastBox &= (any(currTranmittance < 1.0) && rayData.dist >= 0);
    midpointLast = midpointCurrent;
#endif
    storeLastBox |= (prevNodeIndex == idx1D) && all(prevTransmittance >= 1.0); //Guarantees that the head buffer is set

#if TRACE_NON_OPAQUE_ONLY
    if (any(prevTransmittance < 1.0) || storeLastBox)
#else
    if (any(prevTransmittance < 1.0))
#endif
    {
        if (storeLastBox){
            nodeIndex = getInsertIndex();
            if(nodeIndex > MAX_IDX)
                return;
        }

        prevNode.next = storeLastBox ? nodeIndex : 0;
        gData[prevNodeIndex] = prevNode;
        prevNode.depth = midpointLast;
        #if USE_COLOR_TRANSPARENCY
            prevNode.visibility = currTranmittance;
        #else
            prevNode.visibility = currTranmittance.x;
        #endif
        prevNode.next = 0;
        prevNodeIndex = nodeIndex;
    }

    // Store last box
    if (storeLastBox) {
        gData[prevNodeIndex] = prevNode;
    }
}
