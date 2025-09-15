add_plugin(PhotonGuiding)

target_sources(PhotonGuiding PRIVATE
    PhotonGuiding.cpp
    PhotonGuiding.h
    TracePhoton.rt.slang
    TraceCamera.rt.slang
    GuidingTextureGenMipTraverseChain.cs.slang
    GuidingCounterReduce.cs.slang
    StructsAndHelpers.slang
)

target_copy_shaders(PhotonGuiding RenderPasses/PhotonGuiding)
target_source_group(PhotonGuiding "RenderPasses")
