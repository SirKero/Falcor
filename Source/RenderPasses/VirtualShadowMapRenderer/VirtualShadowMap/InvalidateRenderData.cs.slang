import VirtualShadowMapData; 


#ifndef NUM_CLIPMAPS 
#define NUM_CLIPMAPS 1
#endif

#define data gVirtualShadowMapData

[numthreads(32, 1, 1)]
void main(uint index: SV_DispatchThreadID)
{
    data.invalidateRenderData(index);
    data.resetRenderBuffer();
}
