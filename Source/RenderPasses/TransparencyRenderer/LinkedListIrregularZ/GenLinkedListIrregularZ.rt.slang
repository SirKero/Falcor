#include "LinkedListIrregularZData.slang"
#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"
#include "../RayLodHelper.slang"

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

#ifndef NUM_HALTON_SAMPLES
#define NUM_HALTON_SAMPLES 1
#endif

/** Payload for shadow ray. (16B)
*/
struct RayData
{
    float dist;
    float depth;
    float currentTransmittance;
    float sampleOpacity;

    __init() {
        this.dist = -1.0;
        this.depth = 1.0;
        this.currentTransmittance = 1.0;
        this.sampleOpacity = -1.0;
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
    float gSpreadAngle;
    uint _pad;
    float4x4 gViewProj;
    float4x4 gInvViewProj; // Inverse view projection
}

cbuffer JitterSamples {
    float2 gJitterSamples[NUM_HALTON_SAMPLES];
}

RWBuffer<uint> gCounter;
RWStructuredBuffer<LinkedListNode> gData;
RWTexture2D<uint> gAccessCounter;
Texture2D<float> gSampleDistribution;

SamplerState gPointSampler;

static const bool kUseOptimizedSampleDistribution = USE_OPTIMIZED_SAMPLE_DISTRIBUTION;
static const float kMinOpacity = 1e-7;
static const float kPixelOffset = ACCEL_BOXES_PIXEL_OFFSET; // Either 0.5(Normal) or 1.0(PCF)
static const uint kRayFlags = ACCEL_RAY_FLAGS;
static const uint kMipLevels = SAMPLE_DIST_MIPS;
static const uint kNumHaltonSamples = NUM_HALTON_SAMPLES;
static const float kMergeDistance = ACCEL_MERGE_BOX_DIST;
static const bool kUseHaltonSamplePattern = USE_HALTON_SAMPLE_PATTERN;


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
    float opacity = gScene.materials.getMaterialOpacity(v, materialID, lod);

    if (opacity < kMinOpacity)
        IgnoreHit();

    if (RayTCurrent() < rayData.dist) {
        rayData.sampleOpacity = opacity;
        rayData.dist = RayTCurrent();
    }
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

    float opacity = rayData.sampleOpacity;
    if (RayTCurrent() < rayData.dist) {
        opacity = 1.0;
    }
            
    rayData.currentTransmittance = rayData.currentTransmittance * (1.0 - opacity);
    float4 posH = mul(gViewProj, float4(v.posW, 1.f));
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

    if (kUseHaltonSamplePattern) {
        uint jitterIdx = idx1D % kNumHaltonSamples;
        pixelOffset = gJitterSamples[jitterIdx]; // pixel offset in [0,1]
    }
    
    uint samplesSq = uint(sqrt(sampleCount)); // Num samples should be set capped to grids (e.g. 2x2, 3x3, 4x4)
    const float subpixelSize = 1.0 / samplesSq;
    float2 subpixelLoc = float2(subpixelIndex % samplesSq, subpixelIndex / samplesSq);
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
    
    //
    // Dispatch Sample / Create Shadow Map
    //

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
   
    //Prepare ray
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

    LinkedListNode prevNode;
    prevNode.depth = FLT_MAX;
    prevNode.visibility = 1.0;
    prevNode.next = 0;
    uint prevNodeIndex = idx1D;
    uint nodeIndex = prevNodeIndex;
    gData[prevNodeIndex] = prevNode; //Clear TODO remove

    // Loop to get all possible samples
    for (uint i = 0; (i < MAX_ELEMENTS) && useRayTracing; i++) {
        rayData.depth = -1;
        rayData.dist = ray.TMax;
        rayData.sampleOpacity = 1.0;

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
            nodeIndex = getInsertIndex();
            if(nodeIndex > MAX_IDX)
                useRayTracing = false;

            prevNode.next = nodeIndex;
            gData[prevNodeIndex] = prevNode;
        }

        // Update for next iteration
        if (rayData.dist > 0) {
            ray.TMin = rayData.dist + 1e-7;
            lastHitDepth = rayData.depth;
            if(!mergeBox)
                lastTransmittances.y = lastTransmittances.x;
            else
                lastTransmittances.y = lerp(lastTransmittances.y, lastTransmittances.x, 0.05);
            lastTransmittances.x = rayData.currentTransmittance;
            mergeLastBox = mergeBox;

            //Update node
            prevNode.depth = min(rayData.depth + 1e-1, boxZ.x);
            prevNode.visibility = lastTransmittances.y;
            prevNode.next = 0;
            prevNodeIndex = nodeIndex;
        }
    }

// Insert last two elements
    if (rayData.dist < 0)
        rayData.depth = far;

    // Update box
    boxZ.y = boxZ.x;
    boxZ.x = lastHitDepth + (rayData.depth - lastHitDepth) / 2;

    bool storeLastBox = lastTransmittances.x < 1.0 && rayData.dist >= 0;
    if (lastTransmittances.y < 1.0) {
        if(storeLastBox){
            nodeIndex = getInsertIndex();
            if(nodeIndex > MAX_IDX)
                return;
        }
        
        prevNode.next = storeLastBox ? nodeIndex : 0;
        gData[prevNodeIndex] = prevNode;
        prevNode.depth = boxZ.y;
        prevNode.visibility = lastTransmittances.x;
        prevNode.next = 0;
        prevNodeIndex = nodeIndex;
    }
    // Store last box
    if (storeLastBox) {
        gData[prevNodeIndex] = prevNode;
    }
}
