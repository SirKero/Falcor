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
include Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/depend.make
# Include any dependencies generated by the compiler for this target.
include Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/compiler_depend.make

# Include the progress variables for this target.
include Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/progress.make

# Include the compile flags for this target's objects.
include Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/flags.make

bin/shaders/RenderPasses/AccumulatePass/Accumulate.cs.slang: C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/AccumulatePass/Accumulate.cs.slang
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --blue --bold --progress-dir=C:/Users/jonas/Documents/Falcor/Falcor/cmake/CMakeFiles --progress-num=$(CMAKE_PROGRESS_1) "AccumulatePass: Copying shader Accumulate.cs.slang"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/AccumulatePass && "C:/Program Files/CMake/bin/cmake.exe" -E copy_if_different C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/AccumulatePass/Accumulate.cs.slang C:/Users/jonas/Documents/Falcor/Falcor/cmake/bin/shaders/RenderPasses/AccumulatePass/Accumulate.cs.slang

Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/AccumulatePass.cpp.obj: Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/flags.make
Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/AccumulatePass.cpp.obj: Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/includes_CXX.rsp
Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/AccumulatePass.cpp.obj: C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/AccumulatePass/AccumulatePass.cpp
Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/AccumulatePass.cpp.obj: Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/compiler_depend.ts
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green --progress-dir=C:/Users/jonas/Documents/Falcor/Falcor/cmake/CMakeFiles --progress-num=$(CMAKE_PROGRESS_2) "Building CXX object Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/AccumulatePass.cpp.obj"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/AccumulatePass && C:/Strawberry/c/bin/c++.exe $(CXX_DEFINES) $(CXX_INCLUDES) $(CXX_FLAGS) -MD -MT Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/AccumulatePass.cpp.obj -MF CMakeFiles/AccumulatePass.dir/AccumulatePass.cpp.obj.d -o CMakeFiles/AccumulatePass.dir/AccumulatePass.cpp.obj -c C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/AccumulatePass/AccumulatePass.cpp

Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/AccumulatePass.cpp.i: cmake_force
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green "Preprocessing CXX source to CMakeFiles/AccumulatePass.dir/AccumulatePass.cpp.i"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/AccumulatePass && C:/Strawberry/c/bin/c++.exe $(CXX_DEFINES) $(CXX_INCLUDES) $(CXX_FLAGS) -E C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/AccumulatePass/AccumulatePass.cpp > CMakeFiles/AccumulatePass.dir/AccumulatePass.cpp.i

Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/AccumulatePass.cpp.s: cmake_force
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green "Compiling CXX source to assembly CMakeFiles/AccumulatePass.dir/AccumulatePass.cpp.s"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/AccumulatePass && C:/Strawberry/c/bin/c++.exe $(CXX_DEFINES) $(CXX_INCLUDES) $(CXX_FLAGS) -S C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/AccumulatePass/AccumulatePass.cpp -o CMakeFiles/AccumulatePass.dir/AccumulatePass.cpp.s

# Object files for target AccumulatePass
AccumulatePass_OBJECTS = \
"CMakeFiles/AccumulatePass.dir/AccumulatePass.cpp.obj"

# External object files for target AccumulatePass
AccumulatePass_EXTERNAL_OBJECTS =

bin/plugins/AccumulatePass.dll: Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/AccumulatePass.cpp.obj
bin/plugins/AccumulatePass.dll: Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/build.make
bin/plugins/AccumulatePass.dll: Source/Falcor/libFalcor.dll.a
bin/plugins/AccumulatePass.dll: external/fmt/libfmt.a
bin/plugins/AccumulatePass.dll: C:/Users/jonas/Documents/Falcor/Falcor/external/packman/python/libs/python310.lib
bin/plugins/AccumulatePass.dll: C:/Users/jonas/Documents/Falcor/Falcor/external/packman/slang/bin/windows-x64/release/slang.lib
bin/plugins/AccumulatePass.dll: C:/Users/jonas/Documents/Falcor/Falcor/external/packman/slang/bin/windows-x64/release/gfx.lib
bin/plugins/AccumulatePass.dll: Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/linkLibs.rsp
bin/plugins/AccumulatePass.dll: Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/objects1.rsp
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green --bold --progress-dir=C:/Users/jonas/Documents/Falcor/Falcor/cmake/CMakeFiles --progress-num=$(CMAKE_PROGRESS_3) "Linking CXX shared library ../../../bin/plugins/AccumulatePass.dll"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/AccumulatePass && "C:/Program Files/CMake/bin/cmake.exe" -E rm -f CMakeFiles/AccumulatePass.dir/objects.a
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/AccumulatePass && C:/Strawberry/c/bin/ar.exe qc CMakeFiles/AccumulatePass.dir/objects.a @CMakeFiles/AccumulatePass.dir/objects1.rsp
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/AccumulatePass && C:/Strawberry/c/bin/c++.exe -shared -o ../../../bin/plugins/AccumulatePass.dll -Wl,--out-implib,libAccumulatePass.dll.a -Wl,--major-image-version,0,--minor-image-version,0 -Wl,--whole-archive CMakeFiles/AccumulatePass.dir/objects.a -Wl,--no-whole-archive @CMakeFiles/AccumulatePass.dir/linkLibs.rsp

# Rule to build all files generated by this target.
Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/build: bin/plugins/AccumulatePass.dll
.PHONY : Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/build

Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/clean:
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/AccumulatePass && $(CMAKE_COMMAND) -P CMakeFiles/AccumulatePass.dir/cmake_clean.cmake
.PHONY : Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/clean

Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/depend: bin/shaders/RenderPasses/AccumulatePass/Accumulate.cs.slang
	$(CMAKE_COMMAND) -E cmake_depends "Unix Makefiles" C:/Users/jonas/Documents/Falcor/Falcor C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/AccumulatePass C:/Users/jonas/Documents/Falcor/Falcor/cmake C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/AccumulatePass C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/DependInfo.cmake "--color=$(COLOR)"
.PHONY : Source/RenderPasses/AccumulatePass/CMakeFiles/AccumulatePass.dir/depend
