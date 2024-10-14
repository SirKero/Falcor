file(REMOVE_RECURSE
  "../../../bin/plugins/PathTracer.dll"
  "../../../bin/plugins/PathTracer.dll.manifest"
  "../../../bin/plugins/PathTracer.pdb"
  "../../../bin/shaders/RenderPasses/PathTracer/ColorType.slang"
  "../../../bin/shaders/RenderPasses/PathTracer/GeneratePaths.cs.slang"
  "../../../bin/shaders/RenderPasses/PathTracer/GuideData.slang"
  "../../../bin/shaders/RenderPasses/PathTracer/LoadShadingData.slang"
  "../../../bin/shaders/RenderPasses/PathTracer/NRDHelpers.slang"
  "../../../bin/shaders/RenderPasses/PathTracer/Params.slang"
  "../../../bin/shaders/RenderPasses/PathTracer/PathState.slang"
  "../../../bin/shaders/RenderPasses/PathTracer/PathTracer.slang"
  "../../../bin/shaders/RenderPasses/PathTracer/PathTracerNRD.slang"
  "../../../bin/shaders/RenderPasses/PathTracer/ReflectTypes.cs.slang"
  "../../../bin/shaders/RenderPasses/PathTracer/ResolvePass.cs.slang"
  "../../../bin/shaders/RenderPasses/PathTracer/StaticParams.slang"
  "../../../bin/shaders/RenderPasses/PathTracer/TracePass.rt.slang"
  "CMakeFiles/PathTracer.dir/PathTracer.cpp.obj"
  "CMakeFiles/PathTracer.dir/PathTracer.cpp.obj.d"
  "libPathTracer.dll.a"
)

# Per-language clean rules from dependency scanning.
foreach(lang CXX)
  include(CMakeFiles/PathTracer.dir/cmake_clean_${lang}.cmake OPTIONAL)
endforeach()
