add_plugin(ReSTIR_PT_Test)

target_sources(ReSTIR_PT_Test PRIVATE
    ReSTIR_PT_Test.cpp
    ReSTIR_PT_Test.h
	TracePath.rt.slang
    ResampleRetracePath.rt.slang
    Resample.cs.slang
	EvaluateReservoir.cs.slang
	SharedStructsAndFunctions.slang
	NextEventEstimationHelper.slang
)

target_copy_shaders(ReSTIR_PT_Test RenderPasses/ReSTIR_PT_Test)
target_source_group(ReSTIR_PT_Test "RenderPasses")
