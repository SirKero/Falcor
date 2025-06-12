# Real-Time Importance Deep Shadows Maps with Hardware Ray Tracing

![](docs/images/teaserIDSM.png)

## Introduction
This repository contains the source code and an interactive demo for the soon-to-be-published CGF/EGSR paper.

This protoype implements Importance Deep Shadow Maps (IDSM), a real-time deep shadow algorithm that adaptively distributes Deep Shadow samples based on importance captured from the current camera viewport. Additionally, we propose a novel DSM data structure built on the ray tracing acceleration structure improving performance for scenarios requiring many samples per DSM texel. We also provide commented Slang (similar to hlsl) shaders for parts of our method [here](#shader-for-paper-methods).

This project was implemented using NVIDIA's Falcor rendering framework. See [README_Falcor.md](README_Falcor.md) for the readme provided with Falcor. This prototype includes multiple anti-aliasing implementations, namely [NVIDIA DLSS](https://github.com/NVIDIA/DLSS), [AMD FSR](https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK), and Falcor’s built-in TAA implementation.

The executable demo can be downloaded from the [Releases Page](https://github.com/TU-Clausthal-Rendering/ImportanceDeepShadowMaps/releases/latest). Alternatively the project can be built by following the instructions in [Building Falcor](#building-falcor) or the build instructions in the original [readme](README_Falcor.md).

Teaser:

[Coming Soon]

## Contents:
* [Shader for Paper Methods](#shader-for-paper-methods)
* [Demo usage](#demo-usage)
* [Testing with more Scenes](#testing-with-more-scenes)
* [Falcor Prerequisites (System requirements)](#falcor-prerequisites)
* [Building Falcor](#building-falcor)

## Shader for Paper Methods
We have seperate (commented) shaders for most steps introduced in the paper. The shaders are written in [Slang](https://github.com/shader-slang/slang), which has similar syntax to hlsl. The following sections have seperate shaders:
- [3.1.2 Distributing the Sample Budget](Source/RenderPasses/IDSMRenderer/ImportanceMapHelpers/DistributeBudget.cs.slang)
- [3.1.3 Creating the Sample Distribution](Source/RenderPasses/IDSMRenderer/ImportanceMapHelpers/GenSampleDistribution.cs.slang)
- [3.2.1 Creating Rays from the Sample Distribution](Source/RenderPasses/IDSMRenderer/ImportanceMapHelpers/RaySampleFromSampleDistribution.slang)
- [3.2.2 Acceleration Structure (Sample from the IDSM AS)](Source/RenderPasses/IDSMRenderer/IDSMAccelerationStructure/IDSMAccelerationStructure.slang)
- [3.2.3 Linked List (Fetch head buffer index)](Source/RenderPasses/IDSMRenderer/ImportanceMapHelpers/HeadIndexFromSampleDistribution.slang)

## Demo usage
After downloading the demo from the release page, it can be executed using the `IDSMDemo[SceneName].bat` file. We provide four scenes with the Demo, two are included in the git repo in the `Models` folder (Ship and Multiple Lights Szene). The other two scenes need to be downloaded separately (Emerald Square and Bistro) from the [Releases Page](https://github.com/TU-Clausthal-Rendering/ImportanceDeepShadowMaps/releases/latest) and unziped into the `Models` folder. For more scenes, see the [Testing with more Scenes](#testing-with-more-scenes) section.

To change the settings of our algorithm, navigate to the `IDSM Demo` group in the UI. For more information about a setting, hover over the `(?)`. 

TODO

Controls:
- `WASD` - Camera movement
- `Left Click` + `Mouse movement` - Change camera direction
- `Shift` - Speed up camera movement
- `Q, E` - Camera Down / UP
- `P` - Opens the profiler that shows the Rendertime for each Pass.
- `F9` - Opens the time menu. Animation and camera path speed can be changed here (Scale).
- `F6` - Toggels Graphs UI menu (Enabled by default)

## Testing with more Scenes
Testing with other scenes is possible but requires some additional steps. A detailed desciption will be added later.

Falcor supports a variety of scene types:
- Falcor's `.pyscene` format ([more details](docs/usage/scene-formats.md))
    - e.g. [NVIDIA ORCA](https://developer.nvidia.com/orca)
- GLTF
    - Recommended for Blender exports. Analytic light brightness may need manual adjustments. 
- FBX
    - Often need manual adjustments for glass materials.
- Many PBRT V4 files:
    - e.g. [Benedikt Bitterli's Rendering Resources](https://benedikt-bitterli.me/resources/) or [PBRTv4 scenes repo](https://github.com/mmp/pbrt-v4-scenes)
    - May require manual adjustments of materials, as not all materials match Falcor's material model.

## Falcor Prerequisites
- Windows 10 version 20H2 (October 2020 Update) or newer, OS build revision .789 or newer
- Visual Studio 2022
- [Windows 10 SDK (10.0.19041.0) for Windows 10, version 2004](https://developer.microsoft.com/en-us/windows/downloads/windows-10-sdk/)
- A GPU which supports DirectX Raytracing, such as the NVIDIA Titan V or GeForce RTX
- NVIDIA driver 466.11 or newer

Optional:
- Windows 10 Graphics Tools. To run DirectX 12 applications with the debug layer enabled, you must install this. There are two ways to install it:
    - Click the Windows button and type `Optional Features`, in the window that opens click `Add a feature` and select `Graphics Tools`.
    - Download an offline package from [here](https://docs.microsoft.com/en-us/windows-hardware/test/hlk/windows-hardware-lab-kit#supplemental-content-for-graphics-media-and-mean-time-between-failures-mtbf-tests). Choose a ZIP file that matches the OS version you are using (not the SDK version used for building Falcor). The ZIP includes a document which explains how to install the graphics tools.
- NVAPI, CUDA, OptiX (see below)

## Building Falcor
Falcor uses the [CMake](https://cmake.org) build system. Additional information on how to use Falcor with CMake is available in the [CMake](docs/development/cmake.md) development documetation page.

### Visual Studio
If you are working with Visual Studio 2022, you can setup a native Visual Studio solution by running `setup_vs2022.bat` after cloning this repository. The solution files are written to `build/windows-vs2022` and the binary output is located in `build/windows-vs2022/bin`.