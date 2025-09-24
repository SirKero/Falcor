add_plugin(ReducedVCM)

target_sources(ReducedVCM PRIVATE
    ReducedVCM.cpp
    ReducedVCM.h
    TracePhotonGrittmann.rt.slang
    TracePhotonGrittmannV2.rt.slang
    TracePhotonGrittmannV3.rt.slang
    TracePhotonVCM.rt.slang
    TraceCameraGrittmann.rt.slang
    TraceCameraGrittmannV2.rt.slang
	TraceCameraGrittmannV3.rt.slang
    TraceCameraVCM.rt.slang
    StructsAndHelpers.slang
)

target_copy_shaders(ReducedVCM RenderPasses/ReducedVCM)
target_source_group(ReducedVCM "RenderPasses")
