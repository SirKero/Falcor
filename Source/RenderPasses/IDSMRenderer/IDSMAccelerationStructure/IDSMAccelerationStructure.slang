#pragma once
#include "../ImportanceMapHelpers/HeadIndexFromSampleDistribution.slang"
#include "../SharedShadowDefines.slang"

import Rendering.ShadowMaps.ShadowTestFunctions;
import Rendering.ShadowMaps.ShadowMapHelpers;
__exported import Scene.Raytracing;
__exported import Scene.Intersection;

#ifndef COUNT_LIGHTS
#define COUNT_LIGHTS 1
#endif

#ifndef ACCEL_USE_RAY_INLINE
#define ACCEL_USE_RAY_INLINE 1
#endif

#ifndef ACCEL_USE_ONE_AABB_FOR_ALL_LIGHTS
#define ACCEL_USE_ONE_AABB_FOR_ALL_LIGHTS 1
#endif

#ifndef USE_COLOR_TRANSPARENCY
#define USE_COLOR_TRANSPARENCY 0
#endif

#if USE_COLOR_TRANSPARENCY
#define SHADOW_DATA_FORMAT float3
#else
#define SHADOW_DATA_FORMAT float
#endif

struct ASShadowRayData {
    SHADOW_DATA_FORMAT visibility;
    float sampleCount;

    __init() {
        this.visibility = 0.0;
        this.sampleCount = 0.0;
    }
}

struct AccelShadowAttribs {
    float2 pixel;
}

struct IDSMAccelerationStructure
{
    static const bool kAccelUseRayInline = ACCEL_USE_RAY_INLINE;       // TODO currently ignored and always assumed true
    static const uint kMaxAtomicWeight = IMPORTANCE_MAX_ATOMIC_WEIGHT;                      // Max value to be added on the atomic counter
    static const bool kUseOneAABBForAllLight = ACCEL_USE_ONE_AABB_FOR_ALL_LIGHTS;
    static const uint kMaskISMMultFactor = MASK_ISM_MULT_FACTOR; // Multiplication factor for the ISM used by the mask

    cbuffer SMCB
    {
        uint2 gSMSize;
        float gNear;
        float gFar;
        uint gMipCount;      // Count of mip in the sample distribution texture
        uint gMaxBufferSize; // Max size of the buffer
    }

    cbuffer ShadowVPs
    {
        float4x4 gShadowMapVP[COUNT_LIGHTS];
        float4x4 gStaggeredDirVP; //Only valid if there is a directional light
    }

    RaytracingAccelerationStructure gShadowAS;
    StructuredBuffer<AABB> gShadowAABBs[COUNT_LIGHTS];
    StructuredBuffer<SHADOW_DATA_FORMAT> gAccelShadowData[COUNT_LIGHTS];
    RWTexture2D<uint> gImportanceMap[COUNT_LIGHTS];
    Texture2D<uint> gSampleDistribution[COUNT_LIGHTS];
    Texture2DArray<float> gShadowMask;
    Buffer<float> gMaskShadowMap[COUNT_LIGHTS];

    SamplerState gLinearSampler;
    SamplerState gPointSampler;

    void traceAccelShadowInline(inout ASShadowRayData rayData, uint lightIdx, const RayDesc ray) {
        RayQuery<RAY_FLAG_NONE> rayQuery;
        uint rayFlags = 0;
        uint instanceMask = kUseOneAABBForAllLight ? 0xFF : 1 << lightIdx;
        rayQuery.TraceRayInline(gShadowAS, rayFlags, instanceMask, ray);
        const uint aabbIdx = kUseOneAABBForAllLight ? 0 : lightIdx;
        // Start tracing
        while (rayQuery.Proceed()) {
            AABB aabb = gShadowAABBs[aabbIdx][rayQuery.CandidatePrimitiveIndex()];

            // Check if hit is valid
            if (!aabb.contains(ray.Origin))
                continue;

            SHADOW_DATA_FORMAT transparency = gAccelShadowData[aabbIdx][rayQuery.CandidatePrimitiveIndex()];
            rayData.visibility += transparency;
            rayData.sampleCount += 1;
        }
    }

    /** Caculates the shadow value by evaluating the shadow acceleration structure
     * \param[in] index of the current light
     * \param[in] world position of the current hit
     * \param[in] is the light directional (ortho projection)
     * \param[in] Importance. Is used to weight the access texture. Should be in (0, 1]
     * \return visibility in [0,1]
     */
    float3 eval(uint lightIdx, float3 posW, bool isDirectional = false, float importance = 1.0, uint maskFlag = TRANSPARENCY_MASK_FLAG_NONE) {
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

        // Get mask value
        bool validBackprojection = true;
        if ((maskFlag & TRANSPARENCY_MASK_FLAG_USE_MASK) != 0) {
            float maskVal = gShadowMask.SampleLevel(gLinearSampler, float3(shadowPos.xy, lightIdx), 0);
            validBackprojection = maskVal > TRANSPARENCY_MASK_COMPAIRE_VALUE; // 1.0/255.0
            validShadow &= validBackprojection;
        }

        const float2 shadowPixel = shadowPos.xy * gSMSize;//floor(shadowPos.xy * gSMSize) + 0.5;
        float dist = isDirectional ? shadowPos.z : shadowPos.w;

        // Add access
        uint2 uShadowPixel;
        if (validBackprojection) {
            if (isDirectional) {
                // For directional use the staggered MVP for access
                float2 dirShadowPixel = mul(gStaggeredDirVP, float4(posW, 1)).xy;
                dirShadowPixel.y *= -1;                            // Flip
                dirShadowPixel.xy = dirShadowPixel.xy * 0.5 + 0.5; // UV from [-1,1] to [0,1]
                if (any(dirShadowPixel.xy < 0.0) || any(dirShadowPixel.xy > 1.0))
                    validBackprojection = false;
                uShadowPixel = uint2(dirShadowPixel * gSMSize);
            }
            else
                uShadowPixel = uint2(shadowPixel);
        }
        
        uint backprojectionWeight = clamp(uint(importance * kMaxAtomicWeight),1, kMaxAtomicWeight);
        if(validBackprojection)
            InterlockedAdd(gImportanceMap[lightIdx][uShadowPixel], backprojectionWeight);

        // Raytraced shadows as fallback
        if (!validShadow)
            return float3(-1.0);

        // Use transparent shadow map
        if ((maskFlag & TRANSPARENCY_MASK_FLAG_USE_SM) != 0) {
            //Get head buffer index. We only need y component here (x is for Linked List IDSM)
            int2 selectedIndex = getIndexFromSD(gSampleDistribution[lightIdx], shadowPos.xy, gMipCount - 2, kMaskISMMultFactor);               

            // Check if index is bigger than max size. Can happen if sample count increases drastically compaired to previous frame
            if (selectedIndex.y >= 0 && (selectedIndex.y < gMaxBufferSize * kMaskISMMultFactor)) {
                float maskSMDepth = gMaskShadowMap[lightIdx][selectedIndex.y];
                if (maskSMDepth <= dist)
                    return float3(0.0);
            }
        }

        // If only one AABB is used for all lights, offset the pixel pos
        if (kUseOneAABBForAllLight)
            shadowPixel.x += gSMSize.x * lightIdx;

        ASShadowRayData rayData = ASShadowRayData();
        RayDesc ray;
        ray.Origin = float3(shadowPixel.x, shadowPixel.y, dist);
        ray.Direction = float3(0, 0, -1);
        ray.TMin = 0;
        ray.TMax = 1e-10;

        traceAccelShadowInline(rayData, lightIdx, ray);

        SHADOW_DATA_FORMAT visibility = (rayData.sampleCount > 0) ? (rayData.visibility / rayData.sampleCount) : 1.0;
            
        return visibility;
    }
    
} gIDSMAccelerationStructure;
