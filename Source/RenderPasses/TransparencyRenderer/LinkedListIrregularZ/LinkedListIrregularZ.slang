#pragma once
#include "LinkedListIrregularZData.slang"

import Rendering.ShadowMaps.ShadowTestFunctions;
import Rendering.ShadowMaps.ShadowMapHelpers;
__exported import Scene.Raytracing;
__exported import Scene.Intersection;

#ifndef COUNT_LIGHTS
#define COUNT_LIGHTS 1
#endif

struct AccelShadowRayData {
    float visibility;
    float hitDepth;

    __init() {
        this.visibility = 1.0;
        this.hitDepth = -1.0;
    }
}

struct AccelShadowAttribs {
    float2 pixel;
}

struct AccelIrregularZShader
{
    static const uint kMaxAtomicWeight = 64;                      // Max value to be added on the atomic counter

    cbuffer SMCB
    {
        uint2 gSMSize;
        float gNear;
        float gFar;
    }

    cbuffer ShadowVPs
    {
        float4x4 gShadowMapVP[COUNT_LIGHTS];
        float4x4 gStaggeredDirVP; //Only valid if there is a directional light
    }

    StructuredBuffer<LinkedListNode> gAccelShadowData[COUNT_LIGHTS];
    RWTexture2D<uint> gAccessCounter[COUNT_LIGHTS];

    float getLinkedVisibility(LinkedListNode n, float dist, uint lightIdx)
    {
        float visibility = 1.0;
        // from the way we construct the linked list neighbors, we know that we start with n.depth < depth
        while (n.depth < dist)
        {
            visibility = n.visibility;
            if (n.next == 0) break;
            n = gAccelShadowData[lightIdx][n.next];
        }

        return visibility;
    }

    /** Caculates the shadow value by evaluating the shadow acceleration structure
     * \param[in] index of the current light
     * \param[in] world position of the current hit
     * \param[in] is the light directional (ortho projection)
     * \param[in] unshadowed luminance estimate of the point. Is used to weight the access texture. Should be in (0, 1]
     * \return visibility in [0,1]
     */
    float eval(uint lightIdx, float3 posW, bool isDirectional = false, float luminance = 1.0) {
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
                return 0.f;
            }
            validShadow = false;
        }
  
        const float2 shadowPixel = floor((shadowPos.xy * gSMSize) - 0.5) ; // shadowPos.xy * gSMSize; //TODO strange fix for normal
        float dist = isDirectional ? shadowPos.z : shadowPos.w;

        // Add access
        uint2 uShadowPixel;
        bool validBackprojection = true;
        if(isDirectional){
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

        uint backprojectionWeight = clamp(uint(luminance * kMaxAtomicWeight),1, kMaxAtomicWeight);
        if(validBackprojection)
            InterlockedAdd(gAccessCounter[lightIdx][uShadowPixel], backprojectionWeight);

        //Raytraced shadows as fallback
        if (!validShadow)
            return -1.f;

        //TODO go through the mip chain and get the corresponding head buffer index
        uint index = uShadowPixel.y * gSMSize.x + uShadowPixel.x;

        float visibility = 1.0;
        //dist = dist - 1e-2;       // TODO better bias
        
        LinkedListNode n = gAccelShadowData[lightIdx][index];
        // traverse visibility until dist is reached
        while (n.depth < dist) {
            visibility = n.visibility;
            if (n.next == 0) break;
            n = gAccelShadowData[lightIdx][n.next];
        }
        
        return visibility;
    }
    
} gLinkedListIrregularZ;
