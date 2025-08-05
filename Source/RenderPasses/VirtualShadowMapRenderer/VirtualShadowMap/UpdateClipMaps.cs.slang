import VirtualShadowMapData; 


#ifndef NUM_CLIPMAPS 
#define NUM_CLIPMAPS 1
#endif

#define data gVirtualShadowMapData

[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    uint2 texel = pixel % data.gVirtualClipMapSize;
    uint clipMapLevel = pixel.x / data.gVirtualClipMapSize.x;
    data.assignMemory(texel, clipMapLevel);
}
