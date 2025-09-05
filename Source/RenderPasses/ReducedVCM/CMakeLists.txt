add_plugin(ReducedVCM)

target_sources(ReducedVCM PRIVATE
    ReducedVCM.cpp
    ReducedVCM.h
    TracePhotonGrittmann.rt.slang
    TracePhotonVCM.rt.slang
    TraceCameraGrittmann.rt.slang
    TraceCameraVCM.rt.slang
    StructsAndHelpers.slang
)

target_copy_shaders(ReducedVCM RenderPasses/ReducedVCM)
target_source_group(ReducedVCM "RenderPasses")
