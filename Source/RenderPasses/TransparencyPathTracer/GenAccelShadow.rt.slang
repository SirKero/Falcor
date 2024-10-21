#include "AccelShadowData.slang"
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

/** Payload for shadow ray.
*/
struct RayData
{
    float dist;
    float depth;
    float currentTransmittance;
    float depthRange;

    __init() {
        this.dist = -1.0;
        this.depth = 1.0;
        this.currentTransmittance = 1.0;
        this.depthRange = 0.0;
    }
};

cbuffer CB
{
    uint gFrameCount; // Current frame count
    float3 gLightPos; // Current Light Position
    float gNear;
    float gFar;
    uint2 _pad;
    float4x4 gViewProj;    // View Projection for current light
    float4x4 gInvViewProj; // Inverse view projection
    float4x4 gInvProj;
    float4x4 gInvView;
    float4x4 gView;
    float4 gFrustumPlanes[4]; //Top, Bottom, Left, Right Planes of frustum
}

RWStructuredBuffer<AABB> gAABB;
RWBuffer<uint> gCounter;
RWStructuredBuffer<SHADOW_DATA_FORMAT> gData;

static const float kDepthBias = AVSM_DEPTH_BIAS;
static const float kNormalBias = AVSM_NORMAL_DEPTH_BIAS;
static const float kMinOpacity = 1e-7;
static const float kPixelOffset = ACCEL_BOXES_PIXEL_OFFSET; //Either 0.5(Normal) or 1.0(PCF)

static const float2 kMSAAPattern[16] = { float2(0.0625, 0.0625), float2(-0.0625, -0.1875), float2(-0.1875, 0.125), float2(0.25, -0.0625),
                                         float2(-0.3125, -0.125),  float2(0.125, 0.3125), float2(0.3125, 0.1875), float2(0.1875, -0.3125),
                                         float2(-0.125, 0.375), float2(0.0, -0.4375),   float2(-0.25, 0.375),     float2(-0.375, 0.25),
                                         float2(-0.5, 0.0),      float2(0.4375, -0.25),    float2(0.375, 0.4375), float2(-0.4375, -0.5)
                                       };

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
    //rayData.depth = posH.w; // Linear depth
    float3 posView = mul(gView, float4(sd.posW, 1.f)).xyz;
    rayData.depth = -1.0 * posView.z; //same as above
    //  float normalBias = (1.0 - abs(dot(WorldRayDirection(), sd.faceN))) * kNormalBias;
    //  rayData.depth = rayData.depth + (kDepthBias * gFar) + (normalBias * gFar);

    //Get the for corners of the pixel to approximate the size of the 3D pixel
    float2 pixel = float2(DispatchRaysIndex().xy) + 0.5;
    const uint2 frameDim = DispatchRaysDimensions().xy;

#if ACCEL_MODE == ACCEL_MODE_NORMALOFFSET
    //Estimate the size of the currently hit plane for the pixel
    float2 ndcCorners[4];
    ndcCorners[0] = (pixel + float2(-kPixelOffset, -kPixelOffset)) / frameDim;
    ndcCorners[1] = (pixel + float2(kPixelOffset, -kPixelOffset)) / frameDim;
    ndcCorners[2] = (pixel + float2(-kPixelOffset, kPixelOffset)) / frameDim;
    ndcCorners[3] = (pixel + float2(kPixelOffset, kPixelOffset)) / frameDim;
    //From [0,1] to [-1,1]
    [unroll]
    for (uint i = 0; i < 4; i++) {
        ndcCorners[i] = ndcCorners[i] * 2.0 - 1.0;
        ndcCorners[i].y *= -1.f;
    }
    float3 rayDir[4];
    //To view space
    for (uint i = 0; i < 4; i++) {
        rayDir[i] = mul(gInvProj, float4(ndcCorners[i], 1.0, 1.0)).xyz;
        // rayDir[i].xyz /= rayDir[i].z; // Normalize z
        rayDir[i] = normalize(rayDir[i]);
    }
    // View normal
    float3 faceN = sd.frontFacing ? sd.faceN : -sd.faceN;
    float3 normalView = normalize(mul(gView, float4(faceN, 0)).xyz);

    float maxDepth = rayData.depth;
    float minDepth = rayData.depth;
    for (uint i = 0; i < 4; i++) {
        float t = 0;
        if (intersectPlane(normalView, posView, rayDir[i], t)) {
            float3 hitView = rayDir[i] * t;
            maxDepth = max(maxDepth, -hitView.z);
            minDepth = min(minDepth, -hitView.z);
        }
    }
    rayData.depthRange = max(max(maxDepth - rayData.depth , rayData.depth - minDepth),1e-4);
#endif

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

//
// Shader entry point for ray generation shader.
//
[shader("raygeneration")]
void rayGen()
{
    uint2 pixel = DispatchRaysIndex().xy;
    uint2 frameDim = DispatchRaysDimensions().xy;

    float2 pixelSample = pixel + 0.5; //+ kMSAAPattern[gFrameCount % 16];

    float2 relFramePos = pixelSample / frameDim;
    relFramePos = relFramePos * 2.0 - 1.0; // From [0,1] to [-1,1]
    relFramePos.y *= -1.f;

    float4 posWPixelNear = mul(gInvViewProj, float4(relFramePos, 0.f, 1.f));
    float4 posWPixelFar = mul(gInvViewProj, float4(relFramePos, 1.f, 1.f));

    posWPixelNear.xyz /= posWPixelNear.w;
    float3 toNear = posWPixelNear.xyz - gLightPos;

    RayDesc ray;
    ray.TMin = length(toNear); ;                                                                  // Always start at depth 0
    ray.TMax = distance(gLightPos, posWPixelFar.xyz / posWPixelFar.w); // Real far for the pixel
    ray.Origin = gLightPos;
    ray.Direction = normalize(toNear); // World direction

    RayData rayData = RayData();
    bool useRayTracing = true;
    float lastMinDepth = 0.0;
    float lastDepthRange = 0.0;
    float2 lastTransmittances = float2(1.0);
    // Loop to get all possible samples
    for (uint i = 0; (i < MAX_ELEMENTS) && useRayTracing ; i++) {
        rayData.depth = -1;
        rayData.dist = -1;

        //Trace ray
        uint rayFlags = 0;
        TraceRay(gScene.rtAccel, rayFlags, kShadowRayInstanceMask /* kShadowRayInstanceMask instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayData);

    #if ACCEL_MODE  == ACCEL_MODE_SHADOW3D

        // A miss or opaque object ends the ray
        if (i == 0 && rayData.dist < 0)
            return;

        //End ray tracing for the next frame
        if (rayData.currentTransmittance <= kMinOpacity || rayData.dist < 0) {
            useRayTracing = false;
        }

        if (rayData.dist > 0 && i > 0) {
            // Write output
            float3 minPoint = float3(pixelSample.x - kPixelOffset, pixelSample.y - kPixelOffset, lastMinDepth);
            float3 maxPoint = float3(pixelSample.x + kPixelOffset, pixelSample.y + kPixelOffset, rayData.depth);

            AABB aabb = AABB(minPoint, maxPoint);
            #if ACCEL_USE_FRUSTUM_CULLING
                if (aabbIsVisible(aabb, frameDim))
            #endif
                {
                    uint insertIdx = 0;
                    InterlockedAdd(gCounter[0], 1u, insertIdx);
                    if (insertIdx > MAX_IDX)
                        return;

                    gAABB[insertIdx] = aabb;
                    writeData(insertIdx, AccelShadowData(lastTransmittances.y, lastTransmittances.x));
                }
        }
        // Update for next iteration
        if (rayData.dist > 0) {
            ray.TMin = rayData.dist;
            lastMinDepth = rayData.depth;
            lastTransmittances.y = lastTransmittances.x;
            lastTransmittances.x = rayData.currentTransmittance;
        }

    #else // ACCEL_MODE == ACCEL_MODE_NORMALOFFSET

        // A miss or opaque object ends the ray
        if (i == 0 && rayData.dist < 0)
            return;

        //End ray tracing for the next frame
        if (rayData.currentTransmittance <= kMinOpacity || rayData.dist < 0) {
            useRayTracing = false;
        }

        if (rayData.dist > 0 && i>0) {
            // Write output
            float3 minPoint = float3(pixelSample.x - kPixelOffset, pixelSample.y - kPixelOffset, lastMinDepth - lastDepthRange);
            float3 maxPoint = float3(pixelSample.x + kPixelOffset, pixelSample.y + kPixelOffset, max(lastMinDepth + lastDepthRange, rayData.depth - rayData.depthRange));

            AABB aabb = AABB(minPoint, maxPoint);
            #if ACCEL_USE_FRUSTUM_CULLING
                if (aabbIsVisible(aabb, frameDim))
            #endif
                {
                    uint insertIdx = 0;
                    InterlockedAdd(gCounter[0], 1u, insertIdx);
                    if (insertIdx > MAX_IDX)
                        return;
            
                    gAABB[insertIdx] = aabb;
                    writeData(insertIdx, AccelShadowData(lastTransmittances.y, lastTransmittances.x, lastDepthRange * 2));
                }
        }
        // Update for next iteration
        if (rayData.dist > 0) {
            ray.TMin = rayData.dist;
            lastMinDepth = rayData.depth;
            lastDepthRange = rayData.depthRange;
            lastTransmittances.y = lastTransmittances.x;
            lastTransmittances.x = rayData.currentTransmittance;
        }
    #endif
    }

// Insert last element
#if ACCEL_MODE == ACCEL_MODE_SHADOW3D
    if (lastMinDepth < gFar && (lastTransmittances.x < 1.0)) {
        float3 minPoint = float3(pixelSample.x - kPixelOffset, pixelSample.y - kPixelOffset, lastMinDepth);
        float3 maxPoint = float3(pixelSample.x + kPixelOffset, pixelSample.y + kPixelOffset, gFar);

        AABB aabb = AABB(minPoint, maxPoint);
        #if ACCEL_USE_FRUSTUM_CULLING
            if (aabbIsVisible(aabb, frameDim))
        #endif
            {
                uint insertIdx = 0;
                InterlockedAdd(gCounter[0], 1u, insertIdx);
                if (insertIdx > MAX_IDX)
                    return;

                gAABB[insertIdx] = aabb;
                writeData(insertIdx, AccelShadowData(lastTransmittances.x, lastTransmittances.x));
            }
    }
#else // ACCEL_MODE == ACCEL_MODE_NORMALOFFSET
    if (lastMinDepth < gFar && (lastTransmittances.x < 1.0)) {
        float3 minPoint = float3(pixelSample.x - kPixelOffset, pixelSample.y - kPixelOffset, lastMinDepth - lastDepthRange);
        float3 maxPoint = float3(pixelSample.x + kPixelOffset, pixelSample.y + kPixelOffset, max(lastMinDepth + lastDepthRange, gFar));

        AABB aabb = AABB(minPoint, maxPoint);
        #if ACCEL_USE_FRUSTUM_CULLING
            if (aabbIsVisible(aabb, frameDim))
        #endif
            {
                uint insertIdx = 0;
                InterlockedAdd(gCounter[0], 1u, insertIdx);
                if (insertIdx > MAX_IDX)
                    return;

                gAABB[insertIdx] = aabb;
                writeData(insertIdx, AccelShadowData(lastTransmittances.y, lastTransmittances.x, lastDepthRange * 2));
            }
    }
#endif
}
