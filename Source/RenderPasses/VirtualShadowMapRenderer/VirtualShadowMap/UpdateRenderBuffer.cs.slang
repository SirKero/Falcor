import VirtualShadowMapData; 


#ifndef NUM_CLIPMAPS 
#define NUM_CLIPMAPS 1
#endif

#define data gVirtualShadowMapData

[numthreads(16, 16, 1)]
void main(uint2 pixel: SV_DispatchThreadID)
{
    for (uint index = 1;  index < NUM_CLIPMAPS + 1; ++index)
    {
        uint clipMapLevel = NUM_CLIPMAPS - index;
        data.updateRenderBuffer(pixel, clipMapLevel);
    }
}
