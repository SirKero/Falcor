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
include Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/depend.make
# Include any dependencies generated by the compiler for this target.
include Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/compiler_depend.make

# Include the progress variables for this target.
include Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/progress.make

# Include the compile flags for this target's objects.
include Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/flags.make

Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/PathBenchmark.cpp.obj: Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/flags.make
Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/PathBenchmark.cpp.obj: Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/includes_CXX.rsp
Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/PathBenchmark.cpp.obj: C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/PathBenchmark/PathBenchmark.cpp
Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/PathBenchmark.cpp.obj: Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/compiler_depend.ts
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green --progress-dir=C:/Users/jonas/Documents/Falcor/Falcor/cmake/CMakeFiles --progress-num=$(CMAKE_PROGRESS_1) "Building CXX object Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/PathBenchmark.cpp.obj"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/PathBenchmark && C:/Strawberry/c/bin/c++.exe $(CXX_DEFINES) $(CXX_INCLUDES) $(CXX_FLAGS) -MD -MT Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/PathBenchmark.cpp.obj -MF CMakeFiles/PathBenchmark.dir/PathBenchmark.cpp.obj.d -o CMakeFiles/PathBenchmark.dir/PathBenchmark.cpp.obj -c C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/PathBenchmark/PathBenchmark.cpp

Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/PathBenchmark.cpp.i: cmake_force
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green "Preprocessing CXX source to CMakeFiles/PathBenchmark.dir/PathBenchmark.cpp.i"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/PathBenchmark && C:/Strawberry/c/bin/c++.exe $(CXX_DEFINES) $(CXX_INCLUDES) $(CXX_FLAGS) -E C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/PathBenchmark/PathBenchmark.cpp > CMakeFiles/PathBenchmark.dir/PathBenchmark.cpp.i

Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/PathBenchmark.cpp.s: cmake_force
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green "Compiling CXX source to assembly CMakeFiles/PathBenchmark.dir/PathBenchmark.cpp.s"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/PathBenchmark && C:/Strawberry/c/bin/c++.exe $(CXX_DEFINES) $(CXX_INCLUDES) $(CXX_FLAGS) -S C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/PathBenchmark/PathBenchmark.cpp -o CMakeFiles/PathBenchmark.dir/PathBenchmark.cpp.s

# Object files for target PathBenchmark
PathBenchmark_OBJECTS = \
"CMakeFiles/PathBenchmark.dir/PathBenchmark.cpp.obj"

# External object files for target PathBenchmark
PathBenchmark_EXTERNAL_OBJECTS =

bin/plugins/PathBenchmark.dll: Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/PathBenchmark.cpp.obj
bin/plugins/PathBenchmark.dll: Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/build.make
bin/plugins/PathBenchmark.dll: Source/Falcor/libFalcor.dll.a
bin/plugins/PathBenchmark.dll: external/fmt/libfmt.a
bin/plugins/PathBenchmark.dll: C:/Users/jonas/Documents/Falcor/Falcor/external/packman/python/libs/python310.lib
bin/plugins/PathBenchmark.dll: C:/Users/jonas/Documents/Falcor/Falcor/external/packman/slang/bin/windows-x64/release/slang.lib
bin/plugins/PathBenchmark.dll: C:/Users/jonas/Documents/Falcor/Falcor/external/packman/slang/bin/windows-x64/release/gfx.lib
bin/plugins/PathBenchmark.dll: Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/linkLibs.rsp
bin/plugins/PathBenchmark.dll: Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/objects1.rsp
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green --bold --progress-dir=C:/Users/jonas/Documents/Falcor/Falcor/cmake/CMakeFiles --progress-num=$(CMAKE_PROGRESS_2) "Linking CXX shared library ../../../bin/plugins/PathBenchmark.dll"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/PathBenchmark && "C:/Program Files/CMake/bin/cmake.exe" -E rm -f CMakeFiles/PathBenchmark.dir/objects.a
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/PathBenchmark && C:/Strawberry/c/bin/ar.exe qc CMakeFiles/PathBenchmark.dir/objects.a @CMakeFiles/PathBenchmark.dir/objects1.rsp
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/PathBenchmark && C:/Strawberry/c/bin/c++.exe -shared -o ../../../bin/plugins/PathBenchmark.dll -Wl,--out-implib,libPathBenchmark.dll.a -Wl,--major-image-version,0,--minor-image-version,0 -Wl,--whole-archive CMakeFiles/PathBenchmark.dir/objects.a -Wl,--no-whole-archive @CMakeFiles/PathBenchmark.dir/linkLibs.rsp

# Rule to build all files generated by this target.
Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/build: bin/plugins/PathBenchmark.dll
.PHONY : Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/build

Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/clean:
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/PathBenchmark && $(CMAKE_COMMAND) -P CMakeFiles/PathBenchmark.dir/cmake_clean.cmake
.PHONY : Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/clean

Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/depend:
	$(CMAKE_COMMAND) -E cmake_depends "Unix Makefiles" C:/Users/jonas/Documents/Falcor/Falcor C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/PathBenchmark C:/Users/jonas/Documents/Falcor/Falcor/cmake C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/PathBenchmark C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/DependInfo.cmake "--color=$(COLOR)"
.PHONY : Source/RenderPasses/PathBenchmark/CMakeFiles/PathBenchmark.dir/depend
