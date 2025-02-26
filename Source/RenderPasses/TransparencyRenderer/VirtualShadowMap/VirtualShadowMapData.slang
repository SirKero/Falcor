#pragma once

#ifndef NUM_CLIPMAPS
#define NUM_CLIPMAPS 1
#endif
//import Rendering.ShadowMaps.ShadowTestFunctions;
//import Rendering.ShadowMaps.ShadowMapHelpers;
//__exported import Scene.Raytracing;
//__exported import Scene.Intersection;

struct VirtualShadowMapShaderData
{
    cbuffer SMCB
    {
        uint gClipMap0Extention;
        uint2 gClipMapOrigin;
        uint2 gClipMapSize;
        uint2 gClipMap0Resolution;
        uint2 gTopLeftClipMapCorner;
    }

    cbuffer ShadowVPs
    {
        float4x4 gViewProjection;
        float4x4 gInvViewProjection; //Only valid if there is a directional light
    }

    RWTexture2D<uint2> gVirtualClipMapsRW[NUM_CLIPMAPS];
    Texture2D<uint2> gVirtualClipMaps[NUM_CLIPMAPS];

    RWTexture2D<float> gPhysicalClipMapsRW[NUM_CLIPMAPS];
    Texture2D<float> gPhysicalClipMaps[NUM_CLIPMAPS];

    void writeShadowValue(float distance, float3 posW)
    {
        uint clipMapIdx = posWToClipMapIdx(posW);
        uint2 virtualAddress = posWToVirtualAddress(posW, clipMapIdx);
        uint2 physicalAddress = getPhysicalAddress(posW, clipMapIdx);
        //gVirtualClipMapsRW[clipMapIdx][virtualAddress] = physicalAddress;
        //gPhysicalClipMapsRW[clipMapIdx][physicalAddress] = distance;
    }

    float readShadowValue(float3 posW)
    {
        uint clipMapIdx = posWToClipMapIdx(posW);
        uint2 virtualAddress = posWToVirtualAddress(posW, clipMapIdx);
        uint2 physicalAddress;
        switch (virtualAddress.x)
        {
            default:
                //physicalAddress = gVirtualClipMaps[clipMapIdx][virtualAddress];
                //return gPhysicalClipMaps[clipMapIdx][physicalAddress];
        }
        return float(0);
    }

    float4x4 getViewProjectionMatrixForClipMapN()
    {
        float4x4 viewProjection;
        return viewProjection; 
    }

    uint2 posWToVirtualAddress(float3 posW, uint clipMapIdx)
    {
        uint clipMapIdx = posWToClipMapIdx(posW);
        uint2 virtualAddress;
        return virtualAddress;
    }

    uint2 getPhysicalAddress(float3 posW, uint clipMapIdx)
    {
        uint clipMapIdx = posWToClipMapIdx(posW);
        uint2 physicalAddress;
        return physicalAddress;
    }

    uint posWToClipMapIdx(float3 posW)
    {
        uint clipMap;
        return clipMap;
    }
    
} gVirtualShadowMapData;
