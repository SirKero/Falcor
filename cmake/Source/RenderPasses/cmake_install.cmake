# Install script for directory: C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses

# Set the install prefix
if(NOT DEFINED CMAKE_INSTALL_PREFIX)
  set(CMAKE_INSTALL_PREFIX "C:/Program Files (x86)/Falcor")
endif()
string(REGEX REPLACE "/$" "" CMAKE_INSTALL_PREFIX "${CMAKE_INSTALL_PREFIX}")

# Set the install configuration name.
if(NOT DEFINED CMAKE_INSTALL_CONFIG_NAME)
  if(BUILD_TYPE)
    string(REGEX REPLACE "^[^A-Za-z0-9_]+" ""
           CMAKE_INSTALL_CONFIG_NAME "${BUILD_TYPE}")
  else()
    set(CMAKE_INSTALL_CONFIG_NAME "")
  endif()
  message(STATUS "Install configuration: \"${CMAKE_INSTALL_CONFIG_NAME}\"")
endif()

# Set the component getting installed.
if(NOT CMAKE_INSTALL_COMPONENT)
  if(COMPONENT)
    message(STATUS "Install component: \"${COMPONENT}\"")
    set(CMAKE_INSTALL_COMPONENT "${COMPONENT}")
  else()
    set(CMAKE_INSTALL_COMPONENT)
  endif()
endif()

# Is this installation the result of a crosscompile?
if(NOT DEFINED CMAKE_CROSSCOMPILING)
  set(CMAKE_CROSSCOMPILING "FALSE")
endif()

# Set path to fallback-tool for dependency-resolution.
if(NOT DEFINED CMAKE_OBJDUMP)
  set(CMAKE_OBJDUMP "C:/Strawberry/c/bin/objdump.exe")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/AccumulatePass/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/BlitPass/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/BSDFViewer/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/CameraPath/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/DebugPasses/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/DLSSPass/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/ErrorMeasurePass/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/ErrorOverlay/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/FLIPPass/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/GBuffer/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/ImageLoader/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/LightTrace/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/MinimalPathTracer/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/MinimalPathTracerShadowMap/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/ModulateIllumination/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/NRDPass/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/OptixDenoiser/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/PathBenchmark/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/PathTracer/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/PathTracerShadowMap/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/PerlinNoise/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/PhotonMapper/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/PixelInspectorPass/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/RayTracedSoftShadows/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/RenderPassTemplate/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/ReSTIR_FG/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/ReSTIR_GI/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/ReSTIR_GI_Shadow/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/RTAO/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/RTXDIPass/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/SceneDebugger/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/SDFEditor/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/ShadowPass/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/SimplePostFX/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/SVGFPass/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/TAA/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/TestPasses/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/TestPathSM/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/TestShadowMap/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/ToneMapper/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/TransparencyPathTracer/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/Utils/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/VideoRecorder/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/WhittedRayTracer/cmake_install.cmake")
endif()

