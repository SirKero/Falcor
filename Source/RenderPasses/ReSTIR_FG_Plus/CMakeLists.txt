add_plugin(ReSTIR_FG_Plus)

target_sources(ReSTIR_FG_Plus PRIVATE
    ReSTIR_FG_Plus.cpp
    ReSTIR_FG_Plus.h

    StructsAndHelpers.slang
    NextEventEstimationHelper.slang

    TracePhotons.rt.slang
    TraceCamera.rt.slang
    BackprojectCaustics.cs.slang
   
    ResamplePathReservoir.cs.slang
    ResampleReservoirCaustic.cs.slang
	EvaluateReservoirs.cs.slang
)

target_copy_shaders(ReSTIR_FG_Plus RenderPasses/ReSTIR_FG_Plus)
target_source_group(ReSTIR_FG_Plus "RenderPasses")

