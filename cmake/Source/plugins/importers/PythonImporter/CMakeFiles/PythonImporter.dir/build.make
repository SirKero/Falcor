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
include Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/depend.make
# Include any dependencies generated by the compiler for this target.
include Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/compiler_depend.make

# Include the progress variables for this target.
include Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/progress.make

# Include the compile flags for this target's objects.
include Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/flags.make

Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/PythonImporter.cpp.obj: Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/flags.make
Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/PythonImporter.cpp.obj: Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/includes_CXX.rsp
Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/PythonImporter.cpp.obj: C:/Users/jonas/Documents/Falcor/Falcor/Source/plugins/importers/PythonImporter/PythonImporter.cpp
Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/PythonImporter.cpp.obj: Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/compiler_depend.ts
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green --progress-dir=C:/Users/jonas/Documents/Falcor/Falcor/cmake/CMakeFiles --progress-num=$(CMAKE_PROGRESS_1) "Building CXX object Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/PythonImporter.cpp.obj"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/plugins/importers/PythonImporter && C:/Strawberry/c/bin/c++.exe $(CXX_DEFINES) $(CXX_INCLUDES) $(CXX_FLAGS) -MD -MT Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/PythonImporter.cpp.obj -MF CMakeFiles/PythonImporter.dir/PythonImporter.cpp.obj.d -o CMakeFiles/PythonImporter.dir/PythonImporter.cpp.obj -c C:/Users/jonas/Documents/Falcor/Falcor/Source/plugins/importers/PythonImporter/PythonImporter.cpp

Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/PythonImporter.cpp.i: cmake_force
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green "Preprocessing CXX source to CMakeFiles/PythonImporter.dir/PythonImporter.cpp.i"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/plugins/importers/PythonImporter && C:/Strawberry/c/bin/c++.exe $(CXX_DEFINES) $(CXX_INCLUDES) $(CXX_FLAGS) -E C:/Users/jonas/Documents/Falcor/Falcor/Source/plugins/importers/PythonImporter/PythonImporter.cpp > CMakeFiles/PythonImporter.dir/PythonImporter.cpp.i

Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/PythonImporter.cpp.s: cmake_force
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green "Compiling CXX source to assembly CMakeFiles/PythonImporter.dir/PythonImporter.cpp.s"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/plugins/importers/PythonImporter && C:/Strawberry/c/bin/c++.exe $(CXX_DEFINES) $(CXX_INCLUDES) $(CXX_FLAGS) -S C:/Users/jonas/Documents/Falcor/Falcor/Source/plugins/importers/PythonImporter/PythonImporter.cpp -o CMakeFiles/PythonImporter.dir/PythonImporter.cpp.s

# Object files for target PythonImporter
PythonImporter_OBJECTS = \
"CMakeFiles/PythonImporter.dir/PythonImporter.cpp.obj"

# External object files for target PythonImporter
PythonImporter_EXTERNAL_OBJECTS =

bin/plugins/PythonImporter.dll: Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/PythonImporter.cpp.obj
bin/plugins/PythonImporter.dll: Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/build.make
bin/plugins/PythonImporter.dll: Source/Falcor/libFalcor.dll.a
bin/plugins/PythonImporter.dll: external/fmt/libfmt.a
bin/plugins/PythonImporter.dll: C:/Users/jonas/Documents/Falcor/Falcor/external/packman/python/libs/python310.lib
bin/plugins/PythonImporter.dll: C:/Users/jonas/Documents/Falcor/Falcor/external/packman/slang/bin/windows-x64/release/slang.lib
bin/plugins/PythonImporter.dll: C:/Users/jonas/Documents/Falcor/Falcor/external/packman/slang/bin/windows-x64/release/gfx.lib
bin/plugins/PythonImporter.dll: Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/linkLibs.rsp
bin/plugins/PythonImporter.dll: Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/objects1.rsp
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green --bold --progress-dir=C:/Users/jonas/Documents/Falcor/Falcor/cmake/CMakeFiles --progress-num=$(CMAKE_PROGRESS_2) "Linking CXX shared library ../../../../bin/plugins/PythonImporter.dll"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/plugins/importers/PythonImporter && "C:/Program Files/CMake/bin/cmake.exe" -E rm -f CMakeFiles/PythonImporter.dir/objects.a
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/plugins/importers/PythonImporter && C:/Strawberry/c/bin/ar.exe qc CMakeFiles/PythonImporter.dir/objects.a @CMakeFiles/PythonImporter.dir/objects1.rsp
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/plugins/importers/PythonImporter && C:/Strawberry/c/bin/c++.exe -shared -o ../../../../bin/plugins/PythonImporter.dll -Wl,--out-implib,libPythonImporter.dll.a -Wl,--major-image-version,0,--minor-image-version,0 -Wl,--whole-archive CMakeFiles/PythonImporter.dir/objects.a -Wl,--no-whole-archive @CMakeFiles/PythonImporter.dir/linkLibs.rsp

# Rule to build all files generated by this target.
Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/build: bin/plugins/PythonImporter.dll
.PHONY : Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/build

Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/clean:
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/plugins/importers/PythonImporter && $(CMAKE_COMMAND) -P CMakeFiles/PythonImporter.dir/cmake_clean.cmake
.PHONY : Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/clean

Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/depend:
	$(CMAKE_COMMAND) -E cmake_depends "Unix Makefiles" C:/Users/jonas/Documents/Falcor/Falcor C:/Users/jonas/Documents/Falcor/Falcor/Source/plugins/importers/PythonImporter C:/Users/jonas/Documents/Falcor/Falcor/cmake C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/plugins/importers/PythonImporter C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/DependInfo.cmake "--color=$(COLOR)"
.PHONY : Source/plugins/importers/PythonImporter/CMakeFiles/PythonImporter.dir/depend
