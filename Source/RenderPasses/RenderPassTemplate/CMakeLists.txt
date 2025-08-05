add_plugin(RenderPassTemplate)

target_sources(RenderPassTemplate PRIVATE
    RenderPassTemplate.cpp
    RenderPassTemplate.h
)

target_copy_shaders(RenderPassTemplate RenderPasses/RenderPassTemplate)
target_source_group(RenderPassTemplate "RenderPasses")
