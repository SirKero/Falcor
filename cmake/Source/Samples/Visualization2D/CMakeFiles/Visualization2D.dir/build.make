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
include Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/depend.make
# Include any dependencies generated by the compiler for this target.
include Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/compiler_depend.make

# Include the progress variables for this target.
include Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/progress.make

# Include the compile flags for this target's objects.
include Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/flags.make

bin/shaders/Samples/Visualization2D/Visualization2d.ps.slang: C:/Users/jonas/Documents/Falcor/Falcor/Source/Samples/Visualization2D/Visualization2d.ps.slang
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --blue --bold --progress-dir=C:/Users/jonas/Documents/Falcor/Falcor/cmake/CMakeFiles --progress-num=$(CMAKE_PROGRESS_1) "Visualization2D: Copying shader Visualization2d.ps.slang"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/Samples/Visualization2D && "C:/Program Files/CMake/bin/cmake.exe" -E copy_if_different C:/Users/jonas/Documents/Falcor/Falcor/Source/Samples/Visualization2D/Visualization2d.ps.slang C:/Users/jonas/Documents/Falcor/Falcor/cmake/bin/shaders/Samples/Visualization2D/Visualization2d.ps.slang

bin/shaders/Samples/Visualization2D/VoxelNormals.ps.slang: C:/Users/jonas/Documents/Falcor/Falcor/Source/Samples/Visualization2D/VoxelNormals.ps.slang
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --blue --bold --progress-dir=C:/Users/jonas/Documents/Falcor/Falcor/cmake/CMakeFiles --progress-num=$(CMAKE_PROGRESS_2) "Visualization2D: Copying shader VoxelNormals.ps.slang"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/Samples/Visualization2D && "C:/Program Files/CMake/bin/cmake.exe" -E copy_if_different C:/Users/jonas/Documents/Falcor/Falcor/Source/Samples/Visualization2D/VoxelNormals.ps.slang C:/Users/jonas/Documents/Falcor/Falcor/cmake/bin/shaders/Samples/Visualization2D/VoxelNormals.ps.slang

Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/Visualization2D.cpp.obj: Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/flags.make
Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/Visualization2D.cpp.obj: Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/includes_CXX.rsp
Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/Visualization2D.cpp.obj: C:/Users/jonas/Documents/Falcor/Falcor/Source/Samples/Visualization2D/Visualization2D.cpp
Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/Visualization2D.cpp.obj: Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/compiler_depend.ts
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green --progress-dir=C:/Users/jonas/Documents/Falcor/Falcor/cmake/CMakeFiles --progress-num=$(CMAKE_PROGRESS_3) "Building CXX object Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/Visualization2D.cpp.obj"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/Samples/Visualization2D && C:/Strawberry/c/bin/c++.exe $(CXX_DEFINES) $(CXX_INCLUDES) $(CXX_FLAGS) -MD -MT Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/Visualization2D.cpp.obj -MF CMakeFiles/Visualization2D.dir/Visualization2D.cpp.obj.d -o CMakeFiles/Visualization2D.dir/Visualization2D.cpp.obj -c C:/Users/jonas/Documents/Falcor/Falcor/Source/Samples/Visualization2D/Visualization2D.cpp

Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/Visualization2D.cpp.i: cmake_force
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green "Preprocessing CXX source to CMakeFiles/Visualization2D.dir/Visualization2D.cpp.i"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/Samples/Visualization2D && C:/Strawberry/c/bin/c++.exe $(CXX_DEFINES) $(CXX_INCLUDES) $(CXX_FLAGS) -E C:/Users/jonas/Documents/Falcor/Falcor/Source/Samples/Visualization2D/Visualization2D.cpp > CMakeFiles/Visualization2D.dir/Visualization2D.cpp.i

Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/Visualization2D.cpp.s: cmake_force
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green "Compiling CXX source to assembly CMakeFiles/Visualization2D.dir/Visualization2D.cpp.s"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/Samples/Visualization2D && C:/Strawberry/c/bin/c++.exe $(CXX_DEFINES) $(CXX_INCLUDES) $(CXX_FLAGS) -S C:/Users/jonas/Documents/Falcor/Falcor/Source/Samples/Visualization2D/Visualization2D.cpp -o CMakeFiles/Visualization2D.dir/Visualization2D.cpp.s

# Object files for target Visualization2D
Visualization2D_OBJECTS = \
"CMakeFiles/Visualization2D.dir/Visualization2D.cpp.obj"

# External object files for target Visualization2D
Visualization2D_EXTERNAL_OBJECTS =

bin/Visualization2D.exe: Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/Visualization2D.cpp.obj
bin/Visualization2D.exe: Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/build.make
bin/Visualization2D.exe: Source/Falcor/libFalcor.dll.a
bin/Visualization2D.exe: external/fmt/libfmt.a
bin/Visualization2D.exe: C:/Users/jonas/Documents/Falcor/Falcor/external/packman/python/libs/python310.lib
bin/Visualization2D.exe: C:/Users/jonas/Documents/Falcor/Falcor/external/packman/slang/bin/windows-x64/release/slang.lib
bin/Visualization2D.exe: C:/Users/jonas/Documents/Falcor/Falcor/external/packman/slang/bin/windows-x64/release/gfx.lib
bin/Visualization2D.exe: Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/linkLibs.rsp
bin/Visualization2D.exe: Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/objects1.rsp
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green --bold --progress-dir=C:/Users/jonas/Documents/Falcor/Falcor/cmake/CMakeFiles --progress-num=$(CMAKE_PROGRESS_4) "Linking CXX executable ../../../bin/Visualization2D.exe"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/Samples/Visualization2D && "C:/Program Files/CMake/bin/cmake.exe" -E rm -f CMakeFiles/Visualization2D.dir/objects.a
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/Samples/Visualization2D && C:/Strawberry/c/bin/ar.exe qc CMakeFiles/Visualization2D.dir/objects.a @CMakeFiles/Visualization2D.dir/objects1.rsp
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/Samples/Visualization2D && C:/Strawberry/c/bin/c++.exe -Wl,--whole-archive CMakeFiles/Visualization2D.dir/objects.a -Wl,--no-whole-archive -o ../../../bin/Visualization2D.exe -Wl,--out-implib,libVisualization2D.dll.a -Wl,--major-image-version,0,--minor-image-version,0 @CMakeFiles/Visualization2D.dir/linkLibs.rsp

# Rule to build all files generated by this target.
Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/build: bin/Visualization2D.exe
.PHONY : Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/build

Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/clean:
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/Samples/Visualization2D && $(CMAKE_COMMAND) -P CMakeFiles/Visualization2D.dir/cmake_clean.cmake
.PHONY : Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/clean

Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/depend: bin/shaders/Samples/Visualization2D/Visualization2d.ps.slang
Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/depend: bin/shaders/Samples/Visualization2D/VoxelNormals.ps.slang
	$(CMAKE_COMMAND) -E cmake_depends "Unix Makefiles" C:/Users/jonas/Documents/Falcor/Falcor C:/Users/jonas/Documents/Falcor/Falcor/Source/Samples/Visualization2D C:/Users/jonas/Documents/Falcor/Falcor/cmake C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/Samples/Visualization2D C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/DependInfo.cmake "--color=$(COLOR)"
.PHONY : Source/Samples/Visualization2D/CMakeFiles/Visualization2D.dir/depend
