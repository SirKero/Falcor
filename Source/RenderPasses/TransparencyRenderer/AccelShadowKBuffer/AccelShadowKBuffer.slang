#pragma once
#include "AccelShadowKBufferData.slang"

import Rendering.ShadowMaps.ShadowTestFunctions;
import Rendering.ShadowMaps.ShadowMapHelpers;
__exported import Scene.Raytracing;
__exported import Scene.Intersection;

#ifndef COUNT_LIGHTS
#define COUNT_LIGHTS 1
#endif

#ifndef SHADOW_ACCEL_PCF
#define SHADOW_ACCEL_PCF 0
#endif

#ifndef ACCEL_USE_RAY_INLINE
#define ACCEL_USE_RAY_INLINE 1
#endif

#if 0
struct AccelShadowKBufferRayData {
    float4 visibility;
    float4 hitDepth;

    __init() {
        this.visibility = float4(0.0);
        this.hitDepth = float4(-1.0);
    }
}
#else
struct AccelShadowKBufferRayData {
    float visibility;
    float hitDepth;

    __init() {
        this.visibility = 0.0;
        this.hitDepth = -1.0;
    }
}
#endif

struct AccelShadowKBufferShader
{
    static const bool kUseNormalizationFactor = false; // TODO make toggable
    static const bool kAccelUseRayInline = ACCEL_USE_RAY_INLINE; //TODO currently ignored and always assumed true

    cbuffer SMCB
    {
        uint2 gSMSize;
        float gNear;
        float gFar;
    }

    cbuffer ShadowVPs
    {
        float4x4 gShadowMapVP[COUNT_LIGHTS];
    }

    RaytracingAccelerationStructure gShadowAS;
    StructuredBuffer<AABB> gShadowAABBs[COUNT_LIGHTS];
    StructuredBuffer<SHADOW_DATA_FORMAT> gAccelShadowData[COUNT_LIGHTS];

    inline void handelAccelShadowHit(inout AccelShadowKBufferRayData rayData, const AABB aabb, const AccelShadowKBufferData shadowData, const float3 origin) {
        //const float2 pixel = (aabb.minPoint.xy + aabb.maxPoint.xy) / 2.0;
        const float linZ = origin.z;
        const float near = aabb.minPoint.z;
        const float far = aabb.maxPoint.z;
        const float boxLength = far - near;

        float vis = shadowData.transparencyEnd; // When no box is hit, it has to be at the end
        float hitDepth = -1.0;
        [unroll]
        for (uint i = 0; i < ACCEL_K_PER_BOX; i++) {
            // Recreate box
            float minBox = near + boxLength * shadowData.nodes[i].rangeStart;
            float maxBox = near + boxLength * shadowData.nodes[i].rangeEnd;
            const float boxVis = shadowData.nodes[i].transparency;
            //Check if linZ is inside
            if ((boxVis > 0) && (linZ > minBox) && (linZ < maxBox)) {
                //vis = shadowData.nodes[i].transparency;
                //float distToMiddle = min(linZ - minBox, maxBox - linZ);
                float middleDist = (minBox + maxBox) / 2.0;
                //Replace Hit
                if (hitDepth < 0 || middleDist < hitDepth) {
                    vis = max(vis, boxVis);
                    hitDepth = middleDist;
                }
            }
        }
        //Set hit depth to a valid value (0 is exact hit, aka endTransparency)
        hitDepth = max(hitDepth, 0.0);

        // Update raydata
        if (rayData.hitDepth < 0 || hitDepth < rayData.hitDepth) {
            rayData.visibility = vis;
            rayData.hitDepth = hitDepth;
        }

       //TODO Support PCF
    #if 0 // SHADOW_ACCEL_PCF
        uint index = 3;
        float2 pixelDiff = attribs.pixel - origin.xy;
        if (pixelDiff.x > 0 && pixelDiff.y < 0)
            index = 2;
        else if (pixelDiff.x > 0 && pixelDiff.y > 0)
            index = 1;
        else if (pixelDiff.x < 0 && pixelDiff.y > 0)
            index = 0;

        if (kUseNormalizationFactor) {
            rayData.visibility[index] += vis * factor;
            rayData.hitDepth[index] = max(rayData.hitDepth[index], 0.0) + factor;
        }
        else if (rayData.hitDepth[index] < 0 || distMiddleToLinZ < rayData.hitDepth[index]) {
            rayData.visibility[index] = vis;
            rayData.hitDepth[index] = distMiddleToLinZ;
        }
    #endif // SHADOW_ACCEL_PCF
        
    }

    void traceAccelShadowInline(inout AccelShadowKBufferRayData rayData, uint lightIdx, const RayDesc ray) {
        RayQuery<RAY_FLAG_NONE> rayQuery;
        uint rayFlags = 0;
        uint instanceMask = 1 << lightIdx;
        rayQuery.TraceRayInline(gShadowAS, rayFlags, instanceMask, ray);

        // Start tracing
        while (rayQuery.Proceed()) {
            AABB aabb = gShadowAABBs[rayQuery.CandidateInstanceIndex()][rayQuery.CandidatePrimitiveIndex()];

            // Check if hit is valid
            if (!aabb.contains(ray.Origin))
                continue;

            SHADOW_DATA_FORMAT packedShadowData[ACCEL_K_PER_BOX];
            const uint dataIndex = rayQuery.CandidatePrimitiveIndex() * ACCEL_K_PER_BOX;
            [unroll]
            for (uint i = 0; i < ACCEL_K_PER_BOX; i++) {
                packedShadowData[i] = gAccelShadowData[rayQuery.CandidateInstanceIndex()][dataIndex + i]; 
            }
            AccelShadowKBufferData shadowData = AccelShadowKBufferData(packedShadowData);
            handelAccelShadowHit(rayData,aabb, shadowData, ray.Origin);
        }
    }

    float eval(uint lightIdx, float3 posW, float3 lightPosW) {
        float4 shadowPos = mul(gShadowMapVP[lightIdx], float4(posW, 1));
        shadowPos.xyz /= shadowPos.w;

        shadowPos.y *= -1;                                    // Flip
        shadowPos.xy = shadowPos.xy * 0.5 + 0.5;              // UV from [-1,1] to [0,1]
        shadowPos.z = (shadowPos.w - gNear) / (gFar - gNear); // Linear distance

        // Check if inside
        if (any(shadowPos.xyz < 0.0) || any(shadowPos.xyz > 1.0))
            return 0.0;

    #if SHADOW_ACCEL_PCF
        float2 gatherUV;
        float4 w = getGatherWeights(shadowPos.xy, gSMSize.x, gatherUV);
        float2 shadowPixel = gatherUV.xy * gSMSize;
    #else
        float2 shadowPixel = floor(shadowPos.xy * gSMSize) + 0.5;
    #endif
        float dist = shadowPos.w;

        AccelShadowKBufferRayData rayData = AccelShadowKBufferRayData();
        RayDesc ray;
        ray.Origin = float3(shadowPixel.x, shadowPixel.y, dist);
        ray.Direction = float3(0, 0, -1);
        ray.TMin = 0;
        ray.TMax = 1e-10;

        uint rayFlags = 0;
        uint instanceMask = 1 << lightIdx;
        //if (kAccelUseRayInline) //TODO Look into supporting TraceRay again
            traceAccelShadowInline(rayData, lightIdx, ray);
        //else
        //    TraceRay(gShadowAS, rayFlags, instanceMask /* instanceInclusionMask */, 2 /* hitIdx */, 1, 2 /* missIdx */, ray, rayData);

        float visibility = rayData.visibility;

    #if 0//SHADOW_ACCEL_PCF

        for (uint i = 0; i < 4; i++) {
            if (rayData.hitDepth[i] <= 0.0)
                visibility += w[i] * 1.0;
            else {
                if (kUseNormalizationFactor)
                    rayData.visibility[i] /= max(rayData.hitDepth[i], 1e-8);
                visibility += w[i] * rayData.visibility[i];
            }
        }
    #else
        if (rayData.hitDepth < 0.0)
            visibility = 1.0;
    #endif

        return visibility;
    }
    
} gAccelShadowKBuffer;
