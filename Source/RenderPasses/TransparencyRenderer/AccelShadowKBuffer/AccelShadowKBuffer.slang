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

#if SHADOW_ACCEL_PCF
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

struct AccelShadowKBufferAttribs {
    float2 rangeZ;
#if SHADOW_ACCEL_PCF
    float2 pixel;
#endif
}

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

    inline void handelAccelShadowHit(inout AccelShadowKBufferRayData rayData, const AccelShadowKBufferData shadowData, const AccelShadowKBufferAttribs attribs, const float3 origin) {

        const float linZ = origin.z;
        float2 rangeZ = attribs.rangeZ;
                    
        // Shadow Data is x->lengthfirstbox , y-> transparency first box, z -> transparency second box
        rangeZ.y = rangeZ.x + shadowData.firstBoxRange;
        float vis = shadowData.transparencyEnd;
        float factor = 1.0;
        float middleDepth = (rangeZ.x + rangeZ.y) / 2.0;
        // in first box
        if (linZ < rangeZ.y) {
            // factor = max(2.0 - saturate((linZ - rangeZ.x) / (rangeZ.y - rangeZ.x)), 1.0);
            // factor = linZ - rangeZ.x;
            factor = 1.0 / abs(middleDepth - linZ); // TODO stochastic approach?

            vis = shadowData.transparencyStart;
        }
        float distMiddleToLinZ = abs(middleDepth - linZ);
        distMiddleToLinZ = middleDepth;

    #if SHADOW_ACCEL_PCF
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
    #else
        if (kUseNormalizationFactor) {
            rayData.visibility += vis * factor;
            rayData.hitDepth = max(rayData.hitDepth, 0.0) + factor;
        }
        else if (rayData.hitDepth < 0 || distMiddleToLinZ < rayData.hitDepth) {
            rayData.visibility = vis;
            rayData.hitDepth = distMiddleToLinZ;
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
            AccelShadowKBufferAttribs attribs = {};
            attribs.rangeZ = float2(aabb.minPoint.z, aabb.maxPoint.z);
            #if SHADOW_ACCEL_PCF
                attribs.pixel = (aabb.minPoint.xy + aabb.maxPoint.xy) / 2.0; // Pixel center
            #endif

            // Check if hit is valid
            if (!aabb.contains(ray.Origin))
                continue;

            AccelShadowKBufferData shadowData = AccelShadowKBufferData( gAccelShadowData[rayQuery.CandidateInstanceIndex()][rayQuery.CandidatePrimitiveIndex()]);
            handelAccelShadowHit(rayData, shadowData, attribs, ray.Origin);
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

        float visibility = 0;

    #if SHADOW_ACCEL_PCF

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
        if (rayData.hitDepth <= 0.0)
            visibility = 1.0;
        else {
            if (kUseNormalizationFactor)
                rayData.visibility /= max(rayData.hitDepth, 1e-8);
            visibility = rayData.visibility;
        }
    #endif

        return visibility;
    }
    
} gAccelShadowKBuffer;
