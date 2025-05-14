#pragma once
#include "AccelShadowData.slang"
#include "../SharedShadowDefines.slang"

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
struct AccelShadowRayData {
    float4 visibility;
    float4 hitDepth;

    __init() {
        this.visibility = float4(0.0);
        this.hitDepth = float4(-1.0);
    }
}
#else
struct AccelShadowRayData {
    float visibility;
    float sampleCount;

    __init() {
        this.visibility = 0.0;
        this.sampleCount = 0.0;
    }
}
#endif

struct AccelShadowAttribs {
    float2 pixel;
}

struct AccelShadowShader
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
    StructuredBuffer<float> gAccelShadowData[COUNT_LIGHTS];
    Texture2DArray<float> gMaskShadowMap;

    SamplerState gMaskSampler;

    void traceAccelShadowInline(inout AccelShadowRayData rayData, uint lightIdx, const RayDesc ray) {
        RayQuery<RAY_FLAG_NONE> rayQuery;
        uint rayFlags = 0;
        uint instanceMask = 1 << lightIdx;
        rayQuery.TraceRayInline(gShadowAS, rayFlags, instanceMask, ray);
        const uint aabbIdx = lightIdx;
        // Start tracing
        while (rayQuery.Proceed()) {
            AABB aabb = gShadowAABBs[aabbIdx][rayQuery.CandidatePrimitiveIndex()];
            // Check if hit is valid
            if (!aabb.contains(ray.Origin))
                continue;

            float transparency = gAccelShadowData[aabbIdx][rayQuery.CandidatePrimitiveIndex()];
            rayData.visibility += transparency;
            rayData.sampleCount++;
        }
    }

    void traceAccelShadowPCFInline(inout AccelShadowRayData rayData, uint lightIdx, const RayDesc ray, float4 weight) {
        RayQuery<RAY_FLAG_NONE> rayQuery;
        uint rayFlags = 0;
        uint instanceMask = 1 << lightIdx;
        rayQuery.TraceRayInline(gShadowAS, rayFlags, instanceMask, ray);
        const uint aabbIdx = lightIdx;
        // Start tracing
        while (rayQuery.Proceed()) {
            AABB aabb = gShadowAABBs[aabbIdx][rayQuery.CandidatePrimitiveIndex()];
            // Check if hit is valid
            if (!aabb.contains(ray.Origin))
                continue;

            //Get relative position for gather weight
            float2 aabbCenter = (aabb.minPoint.xy + aabb.maxPoint.xy) / 2.0; // Pixel center
            float2 sampleDir = aabbCenter - ray.Origin.xy;
            float w = weight[0];
            if (sampleDir.x < 0 && sampleDir.y < 0)
                w = weight[3];
            else if (sampleDir.x >= 0) {
                if (sampleDir.y < 0)
                    w = weight[2];
                else
                    w = weight[1];
            }

            float transparency = gAccelShadowData[aabbIdx][rayQuery.CandidatePrimitiveIndex()];
            rayData.visibility += transparency * w;
            rayData.sampleCount += w;
        }
    }

    float3 eval(uint lightIdx, float3 posW, bool isDirectional = false, uint maskFlag = TRANSPARENCY_MASK_FLAG_NONE) {
        float4 shadowPos = mul(gShadowMapVP[lightIdx], float4(posW, 1));

        if (!isDirectional) {
            shadowPos.xyz /= shadowPos.w;
            shadowPos.z = (shadowPos.w - gNear) / (gFar - gNear); // Linear distance
        }
        shadowPos.y *= -1;                                    // Flip
        shadowPos.xy = shadowPos.xy * 0.5 + 0.5;              // UV from [-1,1] to [0,1]

        bool validShadow = true;
        // Check if inside the SM
        if (any(shadowPos.xy < 0.0) || any(shadowPos.xy > 1.0)) {
            if (!isDirectional) {
                return float3(-1.f);
            }
            validShadow = false;
        }

        #if SHADOW_ACCEL_PCF
            float2 gatherUV;
            float4 gatherWeight = getGatherWeights(shadowPos.xy, gSMSize.x, gatherUV);
            float2 shadowPixel = gatherUV.xy * gSMSize;
        #else
            float2 shadowPixel = floor(shadowPos.xy * gSMSize) + 0.5;
        #endif
        float dist = isDirectional ? shadowPos.z : shadowPos.w;

         // Raytraced shadows as fallback
        if (!validShadow)
            return float3(-1.0);

        float visibilitySM = 1.0;
        //Use Opaque SM
        if ((maskFlag & TRANSPARENCY_MASK_FLAG_USE_SM) != 0) {
            uint2 shadowPixelU = uint2(shadowPixel);
            #if SHADOW_ACCEL_PCF
                visibilitySM = 0.0;
                float4 shadowZ = gMaskShadowMap.Gather(gMaskSampler, float3(gatherUV.xy, lightIdx));
                [unroll]
                for (uint i = 0; i < 4; i++) {
                    if (dist <= shadowZ[i]) {
                        visibilitySM += gatherWeight[i];
                    }
                }
                if (visibilitySM <= 0)
                    return float3(0);
            #else
                float shadowZ = gMaskShadowMap[uint3(shadowPixelU, lightIdx)];
                if(dist > shadowZ)
                    return float3(0);
            #endif
        }

        AccelShadowRayData rayData = AccelShadowRayData();
        RayDesc ray;
        ray.Origin = float3(shadowPixel.x, shadowPixel.y, dist);
        ray.Direction = float3(0, 0, -1);
        ray.TMin = 0;
        ray.TMax = 1e-10;

        uint rayFlags = 0;
        uint instanceMask = 1 << lightIdx;
   
        #if SHADOW_ACCEL_PCF
            traceAccelShadowPCFInline(rayData, lightIdx, ray, gatherWeight);
        #else
            traceAccelShadowInline(rayData, lightIdx, ray);
        #endif

        float visibility = (rayData.sampleCount > 0) ? (rayData.visibility / rayData.sampleCount) : 1.0;
        
        return min(visibility, visibilitySM);
    }
    
} gAccelShadow;
