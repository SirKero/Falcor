import VirtualShadowMapData; 


#ifndef NUM_CLIPMAPS 
#define NUM_CLIPMAPS 1
#endif

#define data gVirtualShadowMapData

[numthreads(16, 16, 1)]
void main(int2 pixel: SV_DispatchThreadID)
{
    int2 texel = pixel % (int2) data.gVirtualClipMapSize;
    uint clipMapLevel = pixel.x / data.gVirtualClipMapSize.x;
    data.shiftOrigin(texel, clipMapLevel);
}
