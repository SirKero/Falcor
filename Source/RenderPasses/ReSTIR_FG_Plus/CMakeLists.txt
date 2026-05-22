add_plugin(ReSTIR_FG_Plus)

target_sources(ReSTIR_FG_Plus PRIVATE
    ReSTIR_FG_Plus.cpp
    ReSTIR_FG_Plus.h

    TracePhotons.rt.slang
    GenerateInitialSamples.rt.slang
    BackprojectCaustics.cs.slang
    EvaluateReservoirs.cs.slang

    StructsAndHelpers.slang
    PhotonHelper.slang
    NextEventEstimationHelper.slang

    ResamplePathReservoir.cs.slang
    ResampleReservoirCaustic.cs.slang

    RetraceReservoirs.rt.slang
    SortSplatReservoirs.cs.slang
    TemporalSplatReservoir.cs.slang
)

target_copy_shaders(ReSTIR_FG_Plus RenderPasses/ReSTIR_FG_Plus)
target_source_group(ReSTIR_FG_Plus "RenderPasses")

