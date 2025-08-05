#pragma once

//import Rendering.ShadowMaps.ShadowTestFunctions;
//import Rendering.ShadowMaps.ShadowMapHelpers;
//__exported import Scene.Raytracing;
//__exported import Scene.Intersection;
import VirtualShadowMapData;

#ifndef NUM_CLIPMAPS
#define NUM_CLIPMAPS 1
#endif

#define data gVirtualShadowMapData

struct VirtualShadowMapShader
{
    /** Caculates the shadow value by evaluating the shadow acceleration structure
     * \param[in] index of the current light
     * \param[in] world position of the current hit
     * \param[in] is the light directional (ortho projection)
     * \param[in] Importance. Is used to weight the access texture. Should be in (0, 1]
     * \return visibility in [0,1]
     */

    cbuffer ReadAdjustments
    {
        float gDepthBias;
    }

    float eval(uint lightIdx, float3 posW) {
        uint clipMapLevel = 0;
        uint clipMapIdx = data.posWToClipMapIdx(posW);
        if (clipMapIdx >= NUM_CLIPMAPS)
            return 1.0;
        float projectedPositionZ = mul(data.gViewProjection[clipMapIdx], float4(posW, 1.0)).z;
        float compareDepth = data.readShadowValue(posW) + gDepthBias; 
        //float compareDepth = data.onlyReadClipMapX(posW, clipMapLevel) + 0.01;
        if (compareDepth > projectedPositionZ)
            return 1.0;
        else
            return 0.0;
    }
} gVirtualShadowMapEval;
