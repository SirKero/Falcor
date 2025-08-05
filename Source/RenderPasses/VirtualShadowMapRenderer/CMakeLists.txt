add_plugin(VirtualShadowMapRenderer)

target_sources(VirtualShadowMapRenderer PRIVATE
	VirtualShadowMap/VirtualShadowMap.h
	VirtualShadowMap/VirtualShadowMap.cpp
	VirtualShadowMap/GenVirtualShadowMap.rt.slang
	VirtualShadowMap/VirtualShadowMap.slang
	VirtualShadowMap/VirtualShadowMapData.slang
	VirtualShadowMap/SampleViewFrustum.cs.slang
	VirtualShadowMap/DebugMemoryPass.cs.slang
	VirtualShadowMap/UpdateOriginShift.cs.slang
	VirtualShadowMap/UpdateClipMaps.cs.slang
	VirtualShadowMap/UpdateRenderBuffer.cs.slang
	VirtualShadowMap/InvalidateRenderData.cs.slang

    VirtualShadowMapRenderer.cpp
    VirtualShadowMapRenderer.h
	ShadeSurface.cs.slang
)

target_copy_shaders(VirtualShadowMapRenderer RenderPasses/VirtualShadowMapRenderer)
target_source_group(VirtualShadowMapRenderer "RenderPasses")
