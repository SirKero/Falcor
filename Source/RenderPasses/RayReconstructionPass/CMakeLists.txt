if(NOT (FALCOR_HAS_DLSS AND FALCOR_HAS_D3D12))
    return()
endif()

add_plugin(RayReconstructionPass)

target_sources(RayReconstructionPass PRIVATE
    RayReconstructionPass.cpp
    RayReconstructionPass.h
    NGXWrapper.cpp
    NGXWrapper.h
)

target_link_libraries(RayReconstructionPass PRIVATE dlss)

target_source_group(RayReconstructionPass "RenderPasses")
