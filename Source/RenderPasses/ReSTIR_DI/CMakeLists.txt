add_plugin(ReSTIR_DI)

target_sources(ReSTIR_DI PRIVATE
    ReSTIR_DI.cpp
    ReSTIR_DI.h
	InitialSamples.cs.slang
	Resample.cs.slang
	FinalizeSamples.cs.slang
	StructsAndHelpers.slang
)

target_copy_shaders(ReSTIR_DI RenderPasses/ReSTIR_DI)
target_source_group(ReSTIR_DI "RenderPasses")
