add_plugin(CausticRenderer)

target_sources(CausticRenderer PRIVATE
    CausticRenderer.cpp
    CausticRenderer.h
	Lighting.cs.slang
	TraceCaustics.rt.slang
	StructsAndFunctions.slang
)

target_copy_shaders(CausticRenderer RenderPasses/CausticRenderer)
target_source_group(CausticRenderer "RenderPasses")
