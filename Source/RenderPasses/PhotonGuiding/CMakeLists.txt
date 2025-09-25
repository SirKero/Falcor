add_plugin(PhotonGuiding)

target_sources(PhotonGuiding PRIVATE
    PhotonGuiding.cpp
    PhotonGuiding.h
    TracePhoton.rt.slang
    TraceCamera.rt.slang
    GuidingTextureGenMipTraverseChain.cs.slang
    GuidingCounterReduce.cs.slang
    Debug.cs.slang
    StructsAndHelpers.slang
    SharedEnums.slang
	ReSTIR_FG/EvaluateReservoirs.cs.slang
	ReSTIR_FG/GenerateInitialSamples.rt.slang
	ReSTIR_FG/ResampleReservoirCaustic.cs.slang
	ReSTIR_FG/ResampleReservoirFG.cs.slang
)

target_copy_shaders(PhotonGuiding RenderPasses/PhotonGuiding)
target_source_group(PhotonGuiding "RenderPasses")
