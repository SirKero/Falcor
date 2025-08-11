add_plugin(VarianceSoftShadows)

target_sources(VarianceSoftShadows PRIVATE
	CreateHierarchicalShadowMap.cs.slang
	CreateSAT.cs.slang
	GenerateShadowMap.3d.slang
	Shade.cs.slang
    VarianceSoftShadows.cpp
    VarianceSoftShadows.h
)

target_copy_shaders(VarianceSoftShadows RenderPasses/VarianceSoftShadows)
target_source_group(VarianceSoftShadows "RenderPasses")
