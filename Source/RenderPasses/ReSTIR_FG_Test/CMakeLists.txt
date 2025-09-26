add_plugin(ReSTIR_FG_Test)

target_sources(ReSTIR_FG_Test PRIVATE
    ReSTIR_FG_Test.cpp
    ReSTIR_FG_Test.h
    
    EvaluateReservoirs.cs.slang
    ResampleReservoirFG.cs.slang
    ResampleReservoirCaustic.cs.slang
    StructsAndHelpers.slang
    GenerateInitialSamples.rt.slang
    TracePhotons.rt.slang
)

target_copy_shaders(ReSTIR_FG_Test RenderPasses/ReSTIR_FG_Test)
target_source_group(ReSTIR_FG_Test "RenderPasses")

