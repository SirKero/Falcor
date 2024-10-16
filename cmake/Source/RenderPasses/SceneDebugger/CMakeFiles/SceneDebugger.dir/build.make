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
include Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/depend.make
# Include any dependencies generated by the compiler for this target.
include Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/compiler_depend.make

# Include the progress variables for this target.
include Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/progress.make

# Include the compile flags for this target's objects.
include Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/flags.make

bin/shaders/RenderPasses/SceneDebugger/SceneDebugger.cs.slang: C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/SceneDebugger/SceneDebugger.cs.slang
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --blue --bold --progress-dir=C:/Users/jonas/Documents/Falcor/Falcor/cmake/CMakeFiles --progress-num=$(CMAKE_PROGRESS_1) "SceneDebugger: Copying shader SceneDebugger.cs.slang"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/SceneDebugger && "C:/Program Files/CMake/bin/cmake.exe" -E copy_if_different C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/SceneDebugger/SceneDebugger.cs.slang C:/Users/jonas/Documents/Falcor/Falcor/cmake/bin/shaders/RenderPasses/SceneDebugger/SceneDebugger.cs.slang

bin/shaders/RenderPasses/SceneDebugger/SharedTypes.slang: C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/SceneDebugger/SharedTypes.slang
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --blue --bold --progress-dir=C:/Users/jonas/Documents/Falcor/Falcor/cmake/CMakeFiles --progress-num=$(CMAKE_PROGRESS_2) "SceneDebugger: Copying shader SharedTypes.slang"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/SceneDebugger && "C:/Program Files/CMake/bin/cmake.exe" -E copy_if_different C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/SceneDebugger/SharedTypes.slang C:/Users/jonas/Documents/Falcor/Falcor/cmake/bin/shaders/RenderPasses/SceneDebugger/SharedTypes.slang

Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/SceneDebugger.cpp.obj: Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/flags.make
Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/SceneDebugger.cpp.obj: Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/includes_CXX.rsp
Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/SceneDebugger.cpp.obj: C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/SceneDebugger/SceneDebugger.cpp
Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/SceneDebugger.cpp.obj: Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/compiler_depend.ts
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green --progress-dir=C:/Users/jonas/Documents/Falcor/Falcor/cmake/CMakeFiles --progress-num=$(CMAKE_PROGRESS_3) "Building CXX object Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/SceneDebugger.cpp.obj"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/SceneDebugger && C:/Strawberry/c/bin/c++.exe $(CXX_DEFINES) $(CXX_INCLUDES) $(CXX_FLAGS) -MD -MT Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/SceneDebugger.cpp.obj -MF CMakeFiles/SceneDebugger.dir/SceneDebugger.cpp.obj.d -o CMakeFiles/SceneDebugger.dir/SceneDebugger.cpp.obj -c C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/SceneDebugger/SceneDebugger.cpp

Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/SceneDebugger.cpp.i: cmake_force
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green "Preprocessing CXX source to CMakeFiles/SceneDebugger.dir/SceneDebugger.cpp.i"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/SceneDebugger && C:/Strawberry/c/bin/c++.exe $(CXX_DEFINES) $(CXX_INCLUDES) $(CXX_FLAGS) -E C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/SceneDebugger/SceneDebugger.cpp > CMakeFiles/SceneDebugger.dir/SceneDebugger.cpp.i

Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/SceneDebugger.cpp.s: cmake_force
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green "Compiling CXX source to assembly CMakeFiles/SceneDebugger.dir/SceneDebugger.cpp.s"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/SceneDebugger && C:/Strawberry/c/bin/c++.exe $(CXX_DEFINES) $(CXX_INCLUDES) $(CXX_FLAGS) -S C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/SceneDebugger/SceneDebugger.cpp -o CMakeFiles/SceneDebugger.dir/SceneDebugger.cpp.s

# Object files for target SceneDebugger
SceneDebugger_OBJECTS = \
"CMakeFiles/SceneDebugger.dir/SceneDebugger.cpp.obj"

# External object files for target SceneDebugger
SceneDebugger_EXTERNAL_OBJECTS =

bin/plugins/SceneDebugger.dll: Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/SceneDebugger.cpp.obj
bin/plugins/SceneDebugger.dll: Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/build.make
bin/plugins/SceneDebugger.dll: Source/Falcor/libFalcor.dll.a
bin/plugins/SceneDebugger.dll: external/fmt/libfmt.a
bin/plugins/SceneDebugger.dll: C:/Users/jonas/Documents/Falcor/Falcor/external/packman/python/libs/python310.lib
bin/plugins/SceneDebugger.dll: C:/Users/jonas/Documents/Falcor/Falcor/external/packman/slang/bin/windows-x64/release/slang.lib
bin/plugins/SceneDebugger.dll: C:/Users/jonas/Documents/Falcor/Falcor/external/packman/slang/bin/windows-x64/release/gfx.lib
bin/plugins/SceneDebugger.dll: Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/linkLibs.rsp
bin/plugins/SceneDebugger.dll: Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/objects1.rsp
	@$(CMAKE_COMMAND) -E cmake_echo_color "--switch=$(COLOR)" --green --bold --progress-dir=C:/Users/jonas/Documents/Falcor/Falcor/cmake/CMakeFiles --progress-num=$(CMAKE_PROGRESS_4) "Linking CXX shared library ../../../bin/plugins/SceneDebugger.dll"
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/SceneDebugger && "C:/Program Files/CMake/bin/cmake.exe" -E rm -f CMakeFiles/SceneDebugger.dir/objects.a
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/SceneDebugger && C:/Strawberry/c/bin/ar.exe qc CMakeFiles/SceneDebugger.dir/objects.a @CMakeFiles/SceneDebugger.dir/objects1.rsp
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/SceneDebugger && C:/Strawberry/c/bin/c++.exe -shared -o ../../../bin/plugins/SceneDebugger.dll -Wl,--out-implib,libSceneDebugger.dll.a -Wl,--major-image-version,0,--minor-image-version,0 -Wl,--whole-archive CMakeFiles/SceneDebugger.dir/objects.a -Wl,--no-whole-archive @CMakeFiles/SceneDebugger.dir/linkLibs.rsp

# Rule to build all files generated by this target.
Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/build: bin/plugins/SceneDebugger.dll
.PHONY : Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/build

Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/clean:
	cd C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/SceneDebugger && $(CMAKE_COMMAND) -P CMakeFiles/SceneDebugger.dir/cmake_clean.cmake
.PHONY : Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/clean

Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/depend: bin/shaders/RenderPasses/SceneDebugger/SceneDebugger.cs.slang
Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/depend: bin/shaders/RenderPasses/SceneDebugger/SharedTypes.slang
	$(CMAKE_COMMAND) -E cmake_depends "Unix Makefiles" C:/Users/jonas/Documents/Falcor/Falcor C:/Users/jonas/Documents/Falcor/Falcor/Source/RenderPasses/SceneDebugger C:/Users/jonas/Documents/Falcor/Falcor/cmake C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/SceneDebugger C:/Users/jonas/Documents/Falcor/Falcor/cmake/Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/DependInfo.cmake "--color=$(COLOR)"
.PHONY : Source/RenderPasses/SceneDebugger/CMakeFiles/SceneDebugger.dir/depend
