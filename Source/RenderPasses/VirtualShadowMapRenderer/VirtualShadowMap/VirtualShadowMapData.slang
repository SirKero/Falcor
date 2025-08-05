#pragma once

#ifndef NUM_CLIPMAPS
#define NUM_CLIPMAPS 1
#endif

struct VirtualShadowMapShaderData
{
    cbuffer SMCB
    {
        float3 gCameraPosW;
        uint gClipMap0Extention;
        uint gRenderBudget;
        int2 gClipMapOriginOffsets[2 * NUM_CLIPMAPS];
        uint2 gClipMapSize;
        uint2 gPageSize;
        uint2 gVirtualClipMapSize;
    }

    cbuffer ShadowVPs
    {
        float4x4 gViewProjection[NUM_CLIPMAPS];
        float4x4 gInvViewProjection[NUM_CLIPMAPS]; //Only valid if there is a directional light
    }

    cbuffer MemoryManagementResources
    {
        uint gCountBufferSize;
        uint gRenderBufferSize;
        uint gAvailableMemorySize;
    }

    RWTexture2D<uint> gVirtualClipMapsRW[NUM_CLIPMAPS];
    Texture2D<uint> gVirtualClipMaps[NUM_CLIPMAPS];

    RWTexture2D<float> gPhysicalClipMapsRW[NUM_CLIPMAPS];
    Texture2D<float> gPhysicalClipMaps[NUM_CLIPMAPS];

    RWBuffer<uint> gAvailableMemoryStack[NUM_CLIPMAPS];
    RWBuffer<uint> gStackCounter;
    RWBuffer<uint> gRenderBuffer;

    //public:
    void writeShadowValue(float distance, float3 posW)
    {
    }
    //Function to retrieve the shadow value from the lowest possible mip map level
    float readShadowValue(float3 posW)
    {
        uint clipMapIdx = posWToClipMapIdx(posW);
        uint2 virtualAddress;
        uint2 offset;
        uint status;
        uint clipMapLevel;
        for (; clipMapIdx < NUM_CLIPMAPS; ++clipMapIdx)
        {
            uint4 packedData = posWToVirtualAddressWithOffset(posW, clipMapIdx);
            //apply the origin shift offset to the virtual texel
            //gClipMapOriginOffsets contains the overall origin offset until last frame in position 2 * clip map level and the origin offset of this frame in position 2 * clip map level + 1
            //adding 2 * gVirtualClipMapSize to avoid negative modulo 
            virtualAddress = (packedData.xy + gClipMapOriginOffsets[2 * clipMapIdx] + gClipMapOriginOffsets[2 * clipMapIdx + 1] + 2 * gVirtualClipMapSize) % gVirtualClipMapSize;
            offset = packedData.zw;
            status = getStatus(gVirtualClipMaps[clipMapIdx][virtualAddress]);
            clipMapLevel = clipMapIdx;
            if (isActive(status))
            {
                break;
            }
        }
        if (!isActive(status))
        {
            return 1.0;
        }
        uint address = getAddress(gVirtualClipMaps[clipMapLevel][virtualAddress]);
        uint2 texel = convertAddressToTexel(address);
        return gPhysicalClipMaps[clipMapLevel][texel + offset];
    }
    
    float onlyReadClipMapX(float3 posW, uint clipMapIdx)
    {
        uint4 packedData = posWToVirtualAddressWithOffset(posW, clipMapIdx);
        uint2 virtualAddress = (packedData.xy + gClipMapOriginOffsets[clipMapIdx * 2] + gClipMapOriginOffsets[clipMapIdx * 2 + 1] + 2 * gVirtualClipMapSize) % gVirtualClipMapSize;
        uint2 offset = packedData.zw;
        uint status = getStatus(gVirtualClipMaps[clipMapIdx][virtualAddress]);
        if (!isActive(status))
        {
            return 1.0;
        }
        uint address = getAddress(gVirtualClipMaps[clipMapIdx][virtualAddress]);
        uint2 texel = convertAddressToTexel(address);
        return gPhysicalClipMaps[clipMapIdx][texel + offset];
    }

    void updateRequiredPages(float3 posW, uint clipMapLevel)
    {
        uint2 virtualAddress = posWToVirtualAddress(posW, clipMapLevel);
        if (any(virtualAddress >= gVirtualClipMapSize))
        {
            return;
        }
        virtualAddress = (virtualAddress + gClipMapOriginOffsets[clipMapLevel * 2] + gClipMapOriginOffsets[clipMapLevel * 2 + 1] + 2 * gVirtualClipMapSize) % gVirtualClipMapSize;
        uint status = getStatus(gVirtualClipMapsRW[clipMapLevel][virtualAddress]);
        if (!isInactive(status))
        {
            return;
        }
        setPendingForMemory(gVirtualClipMapsRW[clipMapLevel][virtualAddress]);
    }

    void writeThreadID(uint2 threadId, uint clipMapLevel)
    {
        gVirtualClipMapsRW[clipMapLevel][threadId] = threadId.x + threadId.y * gVirtualClipMapSize.x;
    }
    
    void assignMemory(uint2 texel, uint clipMapLevel)
    {
        uint status = getStatus(gVirtualClipMapsRW[clipMapLevel][texel]);
        if (!isPendingForMemory(status))
        {
            return;
        }
        uint address = pop(clipMapLevel);
        setAddress(gVirtualClipMapsRW[clipMapLevel][texel], address);
        setPendingForRender(gVirtualClipMapsRW[clipMapLevel][texel]);
    }

    void invalidatePages(uint2 pixel, uint clipMapLevel)
    {
        uint status = getStatus(gVirtualClipMapsRW[clipMapLevel][pixel]);
        if (isInactive(status))
        {
            return;
        }
        uint address = getAddress(gVirtualClipMapsRW[clipMapLevel][pixel]);
        setInactive(gVirtualClipMapsRW[clipMapLevel][pixel]);
        add(clipMapLevel, address);
    }

    void updateRenderBuffer(uint2 pixel, uint clipMapLevel)
    {
        uint status = getStatus(gVirtualClipMapsRW[clipMapLevel][pixel]);
        if (!isPendingForRender(status))
        {
            return;
        }
        uint index;
        InterlockedAdd(gStackCounter[NUM_CLIPMAPS], 1u, index);
        if (index >= gRenderBufferSize)
        {
            return;
        }
        gRenderBuffer[index] = clipMapLevel * gVirtualClipMapSize.x * gVirtualClipMapSize.y + pixel.x + pixel.y * gVirtualClipMapSize.x;
        setActive(gRenderBuffer[index]);
        setActive(gVirtualClipMapsRW[clipMapLevel][pixel]);
    }

    void shiftOrigin(int2 pixel, uint clipMapLevel)
    {
        uint status = getStatus(gVirtualClipMapsRW[clipMapLevel][pixel]);
        if (isInactive(status))
            return;
        int2 shiftedPixel = (pixel - gClipMapOriginOffsets[clipMapLevel * 2] + gVirtualClipMapSize) % gVirtualClipMapSize - gClipMapOriginOffsets[clipMapLevel * 2 + 1];
        if (all(shiftedPixel < gVirtualClipMapSize) && all(shiftedPixel >= 0))
        {
            return;
        }
        uint address = getAddress(gVirtualClipMapsRW[clipMapLevel][pixel]);
        gVirtualClipMapsRW[clipMapLevel][pixel] = 0;
        add(clipMapLevel, address);
    }

    void resetRenderBuffer()
    {
        gStackCounter[NUM_CLIPMAPS] = 0;
    }

    void invalidateRenderData(uint index)
    {
        setInactive(gRenderBuffer[index]);
    }

    //Stack Management
    uint pop(uint clipMapLevel)
    {
        uint stackIdx; 
        InterlockedAdd(gStackCounter[clipMapLevel], -1, stackIdx);
        return gAvailableMemoryStack[clipMapLevel][(stackIdx - 1) % gAvailableMemorySize];
    }

    void add(uint clipMapLevel, uint value)
    {
        uint stackIdx;
        InterlockedAdd(gStackCounter[clipMapLevel], 1u, stackIdx);
        gAvailableMemoryStack[clipMapLevel][stackIdx % gAvailableMemorySize] = value;
    }

    // private:
    uint getStatus(uint texel)
    {
        return texel & 0xf0000000;
    }

    uint getAddress(uint texel)
    {
        return texel & 0x0fffffff;
    }

    bool isActive(uint status)
    {
        return status == 0x30000000;
    }

    bool isPendingForMemory(uint status)
    {
        return status == 0x10000000;
    }

    bool isPendingForRender(uint status)
    {
        return status == 0x20000000;
    }

    bool isInactive(uint status)
    {
        return status == 0x00000000;
    }

    void setActive(inout uint texel)
    {
        texel = texel & 0x0fffffff;
        texel = texel | 0x30000000;
    }

    void setPendingForMemory(inout uint texel)
    {
        texel = texel & 0x0fffffff;
        texel = texel | 0x10000000;
    }

    void setPendingForRender(inout uint texel)
    {
        texel = texel & 0x0fffffff;
        texel = texel | 0x20000000;
    }

    void setInactive(inout uint texel)
    {
        texel = texel & 0x0fffffff;
    }

    void setAddress(inout uint texel, uint address)
    {
        texel = texel & 0xf0000000;
        texel = texel | address;
    }

    uint3 unpackRenderData(uint data)
    {
        uint clipMapLevel = data / (gVirtualClipMapSize.x * gVirtualClipMapSize.y);
        uint textureBlock = data % (gVirtualClipMapSize.x * gVirtualClipMapSize.y);
        uint2 virtualTexel = uint2(textureBlock % gVirtualClipMapSize.x, textureBlock / gVirtualClipMapSize.x);
        return uint3(clipMapLevel, virtualTexel);
    }

    uint2 posWToVirtualAddress(float3 posW, uint clipMapIdx)
    {
        float2 projectedPosW = mul(gViewProjection[clipMapIdx], float4(posW, 1.f)).xy;
        projectedPosW.y *= -1;
        projectedPosW = projectedPosW * 0.5 + 0.5;
        return uint2(projectedPosW * gVirtualClipMapSize);
    }

    uint4 posWToVirtualAddressWithOffset(float3 posW, uint clipMapIdx)
    {
        float2 projectedPosW = mul(gViewProjection[clipMapIdx], float4(posW, 1.f)).xy;
        projectedPosW.y *= -1;
        projectedPosW = projectedPosW * 0.5 + 0.5;
        int2 virtualAddress = uint2(projectedPosW * gClipMapSize);
        uint2 offset = virtualAddress % gPageSize;
        virtualAddress /= gPageSize;
        return uint4(virtualAddress, offset);
    }

    uint posWToClipMapIdx(float3 posW)
    {
        uint clipMapIdx = 0;
        for (;clipMapIdx < NUM_CLIPMAPS; ++clipMapIdx)
        {
            float2 projectedPos = abs(mul(gViewProjection[clipMapIdx], float4(posW, 1.f)).xy);
            if (projectedPos.x <= 1 && projectedPos.y <= 1)
                break;
        }
        return clipMapIdx;
    }

    uint2 convertAddressToTexel(uint address)
    {
        return uint2(address % gClipMapSize.x, address/gClipMapSize.x);
    }

    uint convertTexelToAddress(uint2 texel)
    {
        return texel.y * gClipMapSize.x + texel.x;
    }

} gVirtualShadowMapData;
