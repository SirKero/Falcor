# CMAKE generated file: DO NOT EDIT!
# Generated by "Unix Makefiles" Generator, CMake Version 3.30

# Delete rule output on recipe failure.
.DELETE_ON_ERROR:

#=============================================================================
# Special targets provided by cmake.

# Disable implicit rules so canonical targets will work.
.SUFFIXES:

# Disable VCS-based implicit rules.
% : %,v

# Disable VCS-based implicit rules.
% : RCS/%

# Disable VCS-based implicit rules.
% : RCS/%,v

# Disable VCS-based implicit rules.
% : SCCS/s.%

# Disable VCS-based implicit rules.
% : s.%

.SUFFIXES: .hpux_make_needs_suffix_list

# Command-line flag to silence nested $(MAKE).
$(VERBOSE)MAKESILENT = -s

#Suppress display of executed commands.
$(VERBOSE).SILENT:

# A target that is always out of date.
cmake_force:
.PHONY : cmake_force

#=============================================================================
# Set environment variables for the build.

# The shell in which to execute make rules.
SHELL = /bin/sh

# The CMake executable.
CMAKE_COMMAND = "C:/Program Files/CMake/bin/cmake.exe"

# The command to remove a file.
RM = "C:/Program Files/CMake/bin/cmake.exe" -E rm -f

# Escaping for special characters.
EQUALS = =

# The top-level source directory on which CMake was run.
CMAKE_SOURCE_DIR = C:/Users/jonas/Documents/Falcor/Falcor

# The top-level build directory on which CMake was run.
CMAKE_BINARY_DIR = C:/Users/jonas/Documents/Falcor/Falcor/cmake

# Include any dependencies generated for this target.
include Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/depend.make
# Include any dependencies generated by the compiler for this target.
include Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/compiler_depend.make

# Include the progress variables for this target.
include Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/progress.make

# Include the compile flags for this target's objects.
include Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/flags.make

bin/shaders/RenderPasses/FLIPPass/ComputeLuminance.cs.slang: C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/FLIPPass/ComputeLuminance.cs.slang
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --blue --bold --progress-dir=C:/Users/jonas/Documents/Falcor/Falcor/cmake/CMakeFiles --progress-num=$(CMAKE_PROGRESS_1) "FLIPPass: Copying shader ComputeLuminance.cs.slang"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/FLIPPass && "C:/Program Files/CMake/bin/cmake.exe" -E copy_if_different C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/FLIPPass/ComputeLuminance.cs.slang C:/Users/jonas/Documents/Falcor/Falcor/cmake/bin/shaders/RenderPasses/FLIPPass/ComputeLuminance.cs.slang

bin/shaders/RenderPasses/FLIPPass/flip.hlsli: C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/FLIPPass/flip.hlsli
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --blue --bold --progress-dir=C:/Users/jonas/Documents/Falcor/Falcor/cmake/CMakeFiles --progress-num=$(CMAKE_PROGRESS_2) "FLIPPass: Copying shader flip.hlsli"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/FLIPPass && "C:/Program Files/CMake/bin/cmake.exe" -E copy_if_different C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/FLIPPass/flip.hlsli C:/Users/jonas/Documents/Falcor/Falcor/cmake/bin/shaders/RenderPasses/FLIPPass/flip.hlsli

bin/shaders/RenderPasses/FLIPPass/FLIPPass.cs.slang: C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/FLIPPass/FLIPPass.cs.slang
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --blue --bold --progress-dir=C:/Users/jonas/Documents/Falcor/Falcor/cmake/CMakeFiles --progress-num=$(CMAKE_PROGRESS_3) "FLIPPass: Copying shader FLIPPass.cs.slang"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/FLIPPass && "C:/Program Files/CMake/bin/cmake.exe" -E copy_if_different C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/FLIPPass/FLIPPass.cs.slang C:/Users/jonas/Documents/Falcor/Falcor/cmake/bin/shaders/RenderPasses/FLIPPass/FLIPPass.cs.slang

bin/shaders/RenderPasses/FLIPPass/ToneMappers.slang: C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/FLIPPass/ToneMappers.slang
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --blue --bold --progress-dir=C:/Users/jonas/Documents/Falcor/Falcor/cmake/CMakeFiles --progress-num=$(CMAKE_PROGRESS_4) "FLIPPass: Copying shader ToneMappers.slang"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/FLIPPass && "C:/Program Files/CMake/bin/cmake.exe" -E copy_if_different C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/FLIPPass/ToneMappers.slang C:/Users/jonas/Documents/Falcor/Falcor/cmake/bin/shaders/RenderPasses/FLIPPass/ToneMappers.slang

Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/FLIPPass.cpp.obj: Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/flags.make
Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/FLIPPass.cpp.obj: Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/includes_CXX.rsp
Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/FLIPPass.cpp.obj: C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/FLIPPass/FLIPPass.cpp
Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/FLIPPass.cpp.obj: Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/compiler_depend.ts
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green --progress-dir=C:/Users/jonas/Documents/Falcor/Falcor/cmake/CMakeFiles --progress-num=$(CMAKE_PROGRESS_5) "Building CXX object Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/FLIPPass.cpp.obj"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/FLIPPass && C:/Strawberry/c/bin/c++.exe $(CXX_DEFINES) $(CXX_INCLUDES) $(CXX_FLAGS) -MD -MT Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/FLIPPass.cpp.obj -MF CMakeFiles/FLIPPass.dir/FLIPPass.cpp.obj.d -o CMakeFiles/FLIPPass.dir/FLIPPass.cpp.obj -c C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/FLIPPass/FLIPPass.cpp

Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/FLIPPass.cpp.i: cmake_force
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green "Preprocessing CXX source to CMakeFiles/FLIPPass.dir/FLIPPass.cpp.i"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/FLIPPass && C:/Strawberry/c/bin/c++.exe $(CXX_DEFINES) $(CXX_INCLUDES) $(CXX_FLAGS) -E C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/FLIPPass/FLIPPass.cpp > CMakeFiles/FLIPPass.dir/FLIPPass.cpp.i

Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/FLIPPass.cpp.s: cmake_force
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green "Compiling CXX source to assembly CMakeFiles/FLIPPass.dir/FLIPPass.cpp.s"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/FLIPPass && C:/Strawberry/c/bin/c++.exe $(CXX_DEFINES) $(CXX_INCLUDES) $(CXX_FLAGS) -S C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/FLIPPass/FLIPPass.cpp -o CMakeFiles/FLIPPass.dir/FLIPPass.cpp.s

# Object files for target FLIPPass
FLIPPass_OBJECTS = \
"CMakeFiles/FLIPPass.dir/FLIPPass.cpp.obj"

# External object files for target FLIPPass
FLIPPass_EXTERNAL_OBJECTS =

bin/plugins/FLIPPass.dll: Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/FLIPPass.cpp.obj
bin/plugins/FLIPPass.dll: Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/build.make
bin/plugins/FLIPPass.dll: Source/Falcor/libFalcor.dll.a
bin/plugins/FLIPPass.dll: external/fmt/libfmt.a
bin/plugins/FLIPPass.dll: C:/Users/jonas/Documents/Falcor/Falcor/external/packman/python/libs/python310.lib
bin/plugins/FLIPPass.dll: C:/Users/jonas/Documents/Falcor/Falcor/external/packman/slang/bin/windows-x64/release/slang.lib
bin/plugins/FLIPPass.dll: C:/Users/jonas/Documents/Falcor/Falcor/external/packman/slang/bin/windows-x64/release/gfx.lib
bin/plugins/FLIPPass.dll: Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/linkLibs.rsp
bin/plugins/FLIPPass.dll: Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/objects1.rsp
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green --bold --progress-dir=C:/Users/jonas/Documents/Falcor/Falcor/cmake/CMakeFiles --progress-num=$(CMAKE_PROGRESS_6) "Linking CXX shared library ../../../bin/plugins/FLIPPass.dll"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/FLIPPass && "C:/Program Files/CMake/bin/cmake.exe" -E rm -f CMakeFiles/FLIPPass.dir/objects.a
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/FLIPPass && C:/Strawberry/c/bin/ar.exe qc CMakeFiles/FLIPPass.dir/objects.a @CMakeFiles/FLIPPass.dir/objects1.rsp
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/FLIPPass && C:/Strawberry/c/bin/c++.exe -shared -o ../../../bin/plugins/FLIPPass.dll -Wl,--out-implib,libFLIPPass.dll.a -Wl,--major-image-version,0,--minor-image-version,0 -Wl,--whole-archive CMakeFiles/FLIPPass.dir/objects.a -Wl,--no-whole-archive @CMakeFiles/FLIPPass.dir/linkLibs.rsp

# Rule to build all files generated by this target.
Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/build: bin/plugins/FLIPPass.dll
.PHONY : Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/build

Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/clean:
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/FLIPPass && $(CMAKE_COMMAND) -P CMakeFiles/FLIPPass.dir/cmake_clean.cmake
.PHONY : Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/clean

Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/depend: bin/shaders/RenderPasses/FLIPPass/ComputeLuminance.cs.slang
Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/depend: bin/shaders/RenderPasses/FLIPPass/FLIPPass.cs.slang
Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/depend: bin/shaders/RenderPasses/FLIPPass/ToneMappers.slang
Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/depend: bin/shaders/RenderPasses/FLIPPass/flip.hlsli
	$(CMAKE_COMMAND) -E cmake_depends "Unix Makefiles" C:/Users/jonas/Documents/Falcor/Falcor C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/FLIPPass C:/Users/jonas/Documents/Falcor/Falcor/cmake C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/FLIPPass C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/DependInfo.cmake "--color=$(COLOR)"
.PHONY : Source/RenderPasses/FLIPPass/CMakeFiles/FLIPPass.dir/depend
