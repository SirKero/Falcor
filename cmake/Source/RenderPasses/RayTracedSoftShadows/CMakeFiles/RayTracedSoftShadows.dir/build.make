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
include Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/depend.make
# Include any dependencies generated by the compiler for this target.
include Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/compiler_depend.make

# Include the progress variables for this target.
include Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/progress.make

# Include the compile flags for this target's objects.
include Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/flags.make

bin/shaders/RenderPasses/RayTracedSoftShadows/RayTracedSoftShadows.rt.slang: C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/RayTracedSoftShadows/RayTracedSoftShadows.rt.slang
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --blue --bold --progress-dir=C:/Users/jonas/Documents/Falcor/Falcor/cmake/CMakeFiles --progress-num=$(CMAKE_PROGRESS_1) "RayTracedSoftShadows: Copying shader RayTracedSoftShadows.rt.slang"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/RayTracedSoftShadows && "C:/Program Files/CMake/bin/cmake.exe" -E copy_if_different C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/RayTracedSoftShadows/RayTracedSoftShadows.rt.slang C:/Users/jonas/Documents/Falcor/Falcor/cmake/bin/shaders/RenderPasses/RayTracedSoftShadows/RayTracedSoftShadows.rt.slang

Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/RayTracedSoftShadows.cpp.obj: Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/flags.make
Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/RayTracedSoftShadows.cpp.obj: Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/includes_CXX.rsp
Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/RayTracedSoftShadows.cpp.obj: C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/RayTracedSoftShadows/RayTracedSoftShadows.cpp
Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/RayTracedSoftShadows.cpp.obj: Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/compiler_depend.ts
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green --progress-dir=C:/Users/jonas/Documents/Falcor/Falcor/cmake/CMakeFiles --progress-num=$(CMAKE_PROGRESS_2) "Building CXX object Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/RayTracedSoftShadows.cpp.obj"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/RayTracedSoftShadows && C:/Strawberry/c/bin/c++.exe $(CXX_DEFINES) $(CXX_INCLUDES) $(CXX_FLAGS) -MD -MT Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/RayTracedSoftShadows.cpp.obj -MF CMakeFiles/RayTracedSoftShadows.dir/RayTracedSoftShadows.cpp.obj.d -o CMakeFiles/RayTracedSoftShadows.dir/RayTracedSoftShadows.cpp.obj -c C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/RayTracedSoftShadows/RayTracedSoftShadows.cpp

Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/RayTracedSoftShadows.cpp.i: cmake_force
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green "Preprocessing CXX source to CMakeFiles/RayTracedSoftShadows.dir/RayTracedSoftShadows.cpp.i"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/RayTracedSoftShadows && C:/Strawberry/c/bin/c++.exe $(CXX_DEFINES) $(CXX_INCLUDES) $(CXX_FLAGS) -E C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/RayTracedSoftShadows/RayTracedSoftShadows.cpp > CMakeFiles/RayTracedSoftShadows.dir/RayTracedSoftShadows.cpp.i

Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/RayTracedSoftShadows.cpp.s: cmake_force
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green "Compiling CXX source to assembly CMakeFiles/RayTracedSoftShadows.dir/RayTracedSoftShadows.cpp.s"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/RayTracedSoftShadows && C:/Strawberry/c/bin/c++.exe $(CXX_DEFINES) $(CXX_INCLUDES) $(CXX_FLAGS) -S C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/RayTracedSoftShadows/RayTracedSoftShadows.cpp -o CMakeFiles/RayTracedSoftShadows.dir/RayTracedSoftShadows.cpp.s

# Object files for target RayTracedSoftShadows
RayTracedSoftShadows_OBJECTS = \
"CMakeFiles/RayTracedSoftShadows.dir/RayTracedSoftShadows.cpp.obj"

# External object files for target RayTracedSoftShadows
RayTracedSoftShadows_EXTERNAL_OBJECTS =

bin/plugins/RayTracedSoftShadows.dll: Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/RayTracedSoftShadows.cpp.obj
bin/plugins/RayTracedSoftShadows.dll: Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/build.make
bin/plugins/RayTracedSoftShadows.dll: Source/Falcor/libFalcor.dll.a
bin/plugins/RayTracedSoftShadows.dll: external/fmt/libfmt.a
bin/plugins/RayTracedSoftShadows.dll: C:/Users/jonas/Documents/Falcor/Falcor/external/packman/python/libs/python310.lib
bin/plugins/RayTracedSoftShadows.dll: C:/Users/jonas/Documents/Falcor/Falcor/external/packman/slang/bin/windows-x64/release/slang.lib
bin/plugins/RayTracedSoftShadows.dll: C:/Users/jonas/Documents/Falcor/Falcor/external/packman/slang/bin/windows-x64/release/gfx.lib
bin/plugins/RayTracedSoftShadows.dll: Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/linkLibs.rsp
bin/plugins/RayTracedSoftShadows.dll: Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/objects1.rsp
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green --bold --progress-dir=C:/Users/jonas/Documents/Falcor/Falcor/cmake/CMakeFiles --progress-num=$(CMAKE_PROGRESS_3) "Linking CXX shared library ../../../bin/plugins/RayTracedSoftShadows.dll"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/RayTracedSoftShadows && "C:/Program Files/CMake/bin/cmake.exe" -E rm -f CMakeFiles/RayTracedSoftShadows.dir/objects.a
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/RayTracedSoftShadows && C:/Strawberry/c/bin/ar.exe qc CMakeFiles/RayTracedSoftShadows.dir/objects.a @CMakeFiles/RayTracedSoftShadows.dir/objects1.rsp
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/RayTracedSoftShadows && C:/Strawberry/c/bin/c++.exe -shared -o ../../../bin/plugins/RayTracedSoftShadows.dll -Wl,--out-implib,libRayTracedSoftShadows.dll.a -Wl,--major-image-version,0,--minor-image-version,0 -Wl,--whole-archive CMakeFiles/RayTracedSoftShadows.dir/objects.a -Wl,--no-whole-archive @CMakeFiles/RayTracedSoftShadows.dir/linkLibs.rsp

# Rule to build all files generated by this target.
Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/build: bin/plugins/RayTracedSoftShadows.dll
.PHONY : Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/build

Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/clean:
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/RayTracedSoftShadows && $(CMAKE_COMMAND) -P CMakeFiles/RayTracedSoftShadows.dir/cmake_clean.cmake
.PHONY : Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/clean

Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/depend: bin/shaders/RenderPasses/RayTracedSoftShadows/RayTracedSoftShadows.rt.slang
	$(CMAKE_COMMAND) -E cmake_depends "Unix Makefiles" C:/Users/jonas/Documents/Falcor/Falcor C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/RayTracedSoftShadows C:/Users/jonas/Documents/Falcor/Falcor/cmake C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/RayTracedSoftShadows C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/DependInfo.cmake "--color=$(COLOR)"
.PHONY : Source/RenderPasses/RayTracedSoftShadows/CMakeFiles/RayTracedSoftShadows.dir/depend
