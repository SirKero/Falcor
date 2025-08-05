import VirtualShadowMapData; 

#ifndef NUM_CLIPMAPS 
#define NUM_CLIPMAPS 1
#endif

RWTexture2D<float4> gDebugOut;

void displayVirtualClipMaps(uint2 pixel, uint2 outPutDimension, uint scalingFactor)
{
    uint2 virtualClipMapSize = gVirtualShadowMapData.gVirtualClipMapSize;
    uint2 clipMapLevel = pixel / (virtualClipMapSize * scalingFactor);
    uint2 clipMapSlots = outPutDimension / (virtualClipMapSize * scalingFactor);
    uint2 padding = outPutDimension % (virtualClipMapSize * scalingFactor);
    uint clipMapIdx = clipMapSlots.x * clipMapLevel.y + clipMapLevel.x;
    if (clipMapIdx >= NUM_CLIPMAPS)
    {
        gDebugOut[pixel] = float4(0.0, 0.0, 0.0, 1.0); 
        return;
    }
    uint2 virtualPixel = (pixel / scalingFactor) % virtualClipMapSize;
    gDebugOut[pixel] = float4(gVirtualShadowMapData.gVirtualClipMaps[clipMapIdx][virtualPixel], 0.0, 0.0, 1.0);
}

[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    uint2 gOutPutDimension = uint2(1920, 1080);
    if (any(pixel >= gOutPutDimension))
    {
        return;
    }
    displayVirtualClipMaps(pixel, gOutPutDimension, 20);
}
