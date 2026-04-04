# CMakeLists.txt for building PCSX2 as an OpenEmu core plugin (.oecoreplugin bundle)
# Usage: cmake -G Xcode -B build-openemu -S pcsx2/OpenEmu
#   Then open build-openemu/PCSX2.xcodeproj

cmake_minimum_required(VERSION 3.20)
project(PCSX2OpenEmu LANGUAGES C CXX OBJC OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET 14.0)

# ARC is set per-file below after the target is created

# Root paths
set(PCSX2_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/..")
set(PCSX2_SRC "${PCSX2_ROOT}/pcsx2")
set(COMMON_SRC "${PCSX2_ROOT}/common")
set(THIRDPARTY "${PCSX2_ROOT}/3rdparty")

# Preprocessor definitions
add_compile_definitions(
    PCSX2_CORE
    PCSX2_OPENEMU
    __APPLE__
    __POSIX__
    # ENABLE_VULKAN and ENABLE_OPENGL are intentionally NOT defined
    # (PCSX2 uses #ifdef, so even =0 would enable them)
    OUTSIDE_SPEEX
    FLOATING_POINT
    RANDOM_PREFIX=speex
    VIXL_CODE_BUFFER_MALLOC
    VIXL_INCLUDE_TARGET_AARCH64
)

# ============================================================================
# Collect source files
# ============================================================================

# OpenEmu bridge files
set(OPENEMU_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/PCSX2GameCore.mm
    ${CMAKE_CURRENT_SOURCE_DIR}/PCSX2Host.mm
    ${CMAKE_CURRENT_SOURCE_DIR}/pcsx2_openemu_stubs.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/imgui_openemu_stubs.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/linker_stubs.cpp
)

# PCSX2 core sources (excluding x86, Windows, Linux platform dirs)
file(GLOB_RECURSE PCSX2_CORE_SOURCES
    "${PCSX2_SRC}/*.cpp"
    "${PCSX2_SRC}/*.mm"
    "${PCSX2_SRC}/*.m"
    "${PCSX2_SRC}/*.metal"
)

# Exclude platform-specific and x86 files (but keep architecture-independent ones)
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*/x86/.*")
# Add back architecture-independent files from x86/ that the ARM64 recompiler needs
list(APPEND PCSX2_CORE_SOURCES "${PCSX2_SRC}/x86/BaseblockEx.cpp")
# Exclude RecStubs.cpp (replaced by the ARM64 recompiler in arm64/iR5900.cpp)
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*/arm64/RecStubs\\.cpp$")
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*/Windows/.*")
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*/Win32/.*")
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*/Linux/.*")
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*/Renderers/OpenGL/.*")
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*/Renderers/DX11/.*")
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*/Renderers/DX12/.*")
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*/Renderers/Vulkan/.*")
# Exclude the Qt host (we provide our own)
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*/pcsx2-qt/.*")
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*/pcsx2-gsrunner/.*")
# Exclude PCSX2's own Host.cpp since we provide PCSX2Host.mm
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*/pcsx2/Host\\.cpp$")
# Exclude input backends that require SDL/DInput/XInput
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*/Input/SDLInputSource\\.cpp$")
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*/Input/DInputSource\\.cpp$")
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*/Input/XInputSource\\.cpp$")
# Exclude SDL-dependent USB pad force-feedback
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*usb-pad-sdl-ff\\.cpp$")
# Exclude RDebug (debug protocol, references missing IopBios2.h)
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*/RDebug/.*")
# DebugTools is included (SymbolGuardian/SymbolImporter are referenced by core code)
# Exclude SDL/Cubeb audio streams (audio goes through OpenEmu ring buffer)
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*SDLAudioStream\\.cpp$")
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*CubebAudioStream\\.cpp$")
# Exclude platform-specific camera backends (keep cam-macos.mm)
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*cam-windows\\.cpp$")
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*cam-linux\\.cpp$")
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*cam-noop\\.cpp$")
# Exclude IopModuleNames.cpp - it's #include'd from IopBios.cpp, not compiled standalone
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*IopModuleNames\\.cpp$")
# Exclude ImGui directory - OpenEmu handles all UI; these need freetype/plutovg/plutosvg
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*/ImGui/.*")
# SW renderer: include ARM64 files, exclude x86-specific (*.all.*) that need xbyak
list(FILTER PCSX2_CORE_SOURCES EXCLUDE REGEX ".*/Renderers/SW/.*\\.all\\.cpp$")

# Common library sources
file(GLOB_RECURSE COMMON_SOURCES
    "${COMMON_SRC}/*.cpp"
    "${COMMON_SRC}/*.mm"
    "${COMMON_SRC}/*.m"
)
list(FILTER COMMON_SOURCES EXCLUDE REGEX ".*/Windows/.*")
list(FILTER COMMON_SOURCES EXCLUDE REGEX ".*StackWalker\\.cpp$")
# Exclude Linux-specific files EXCEPT LnxHostSys.cpp (POSIX APIs work on macOS)
list(FILTER COMMON_SOURCES EXCLUDE REGEX ".*LnxMisc\\.cpp$")
list(FILTER COMMON_SOURCES EXCLUDE REGEX ".*LnxThreads\\.cpp$")
list(FILTER COMMON_SOURCES EXCLUDE REGEX ".*HTTPDownloaderWinHTTP\\.cpp$")
list(FILTER COMMON_SOURCES EXCLUDE REGEX ".*HTTPDownloaderCurl\\.cpp$")

# 3rdparty sources
# Only include format.cc and os.cc; fmt.cc is a C++20 module file
set(FMT_SOURCES
    "${THIRDPARTY}/fmt/src/format.cc"
    "${THIRDPARTY}/fmt/src/os.cc"
)

file(GLOB_RECURSE VIXL_SOURCES
    "${THIRDPARTY}/vixl/src/*.cc"
    "${THIRDPARTY}/vixl/src/*.cpp"
)

file(GLOB SOUNDTOUCH_SOURCES
    "${THIRDPARTY}/soundtouch/source/SoundTouch/AAFilter.cpp"
    "${THIRDPARTY}/soundtouch/source/SoundTouch/BPMDetect.cpp"
    "${THIRDPARTY}/soundtouch/source/SoundTouch/cpu_detect_x86.cpp"
    "${THIRDPARTY}/soundtouch/source/SoundTouch/FIFOSampleBuffer.cpp"
    "${THIRDPARTY}/soundtouch/source/SoundTouch/FIRFilter.cpp"
    "${THIRDPARTY}/soundtouch/source/SoundTouch/InterpolateCubic.cpp"
    "${THIRDPARTY}/soundtouch/source/SoundTouch/InterpolateLinear.cpp"
    "${THIRDPARTY}/soundtouch/source/SoundTouch/InterpolateShannon.cpp"
    "${THIRDPARTY}/soundtouch/source/SoundTouch/mmx_optimized.cpp"
    "${THIRDPARTY}/soundtouch/source/SoundTouch/PeakFinder.cpp"
    "${THIRDPARTY}/soundtouch/source/SoundTouch/RateTransposer.cpp"
    "${THIRDPARTY}/soundtouch/source/SoundTouch/SoundTouch.cpp"
    "${THIRDPARTY}/soundtouch/source/SoundTouch/sse_optimized.cpp"
    "${THIRDPARTY}/soundtouch/source/SoundTouch/TDStretch.cpp"
)

file(GLOB_RECURSE LIBCHDR_SOURCES "${THIRDPARTY}/libchdr/src/*.c")

file(GLOB_RECURSE RCHEEVOS_SOURCES
    "${THIRDPARTY}/rcheevos/src/*.c"
    "${THIRDPARTY}/rcheevos/src/*.cpp"
)
# Exclude libretro-specific file (requires libretro.h which we don't have)
list(FILTER RCHEEVOS_SOURCES EXCLUDE REGEX ".*rc_libretro\\.c$")
# Exclude rhash directory (disc/ROM hashing - implementations not present in tree)
# But keep md5.c which is needed by the rcheevos core
list(FILTER RCHEEVOS_SOURCES EXCLUDE REGEX ".*/rhash/hash\\.c$")
list(FILTER RCHEEVOS_SOURCES EXCLUDE REGEX ".*/rhash/cdreader\\.c$")
# Exclude external/RA integration client files
list(FILTER RCHEEVOS_SOURCES EXCLUDE REGEX ".*rc_client_external\\.c$")
list(FILTER RCHEEVOS_SOURCES EXCLUDE REGEX ".*rc_client_raintegration\\.c$")

# Use system zstd and lz4 (via Homebrew) since 3rdparty copies are not present
set(ZSTD_SOURCES "")
set(LZ4_SOURCES "")

# ccc (C++ Compiler Collection - used by DebugTools/SymbolGuardian)
file(GLOB CCC_SOURCES "${THIRDPARTY}/ccc/src/ccc/*.cpp")

# demangler - excluded due to C compatibility issues; stubs provided if needed
set(DEMANGLER_SOURCES "")

file(GLOB IMGUI_SOURCES
    "${THIRDPARTY}/imgui/src/imgui.cpp"
    "${THIRDPARTY}/imgui/src/imgui_draw.cpp"
    "${THIRDPARTY}/imgui/src/imgui_tables.cpp"
    "${THIRDPARTY}/imgui/src/imgui_widgets.cpp"
    "${THIRDPARTY}/imgui/src/imgui_demo.cpp"
)

set(XXHASH_SOURCES "")

# Cubeb (macOS AudioUnit backend - compiled for link resolution, runtime uses Null output)
set(CUBEB_SOURCES
    "${THIRDPARTY}/cubeb/src/cubeb.c"
    "${THIRDPARTY}/cubeb/src/cubeb_strings.c"
    "${THIRDPARTY}/cubeb/src/cubeb_audiounit.cpp"
    "${THIRDPARTY}/cubeb/src/cubeb_osx_run_loop.cpp"
    "${THIRDPARTY}/cubeb/src/cubeb_mixer.cpp"
    "${THIRDPARTY}/cubeb/src/cubeb_resampler.cpp"
    "${THIRDPARTY}/cubeb/src/cubeb_utils.cpp"
    "${THIRDPARTY}/cubeb/src/cubeb_log.cpp"
    "${THIRDPARTY}/cubeb/subprojects/speex/resample.c"
)

# LZMA/XZ decompression
file(GLOB LZMA_SOURCES "${THIRDPARTY}/lzma/src/*.c")

# cpuinfo (macOS ARM64 sources only)
add_compile_definitions(CPUINFO_LOG_LEVEL=2)
set(CPUINFO_SOURCES
    "${THIRDPARTY}/cpuinfo/src/api.c"
    "${THIRDPARTY}/cpuinfo/src/init.c"
    "${THIRDPARTY}/cpuinfo/src/log.c"
    "${THIRDPARTY}/cpuinfo/src/cache.c"
    "${THIRDPARTY}/cpuinfo/src/mach/topology.c"
    "${THIRDPARTY}/cpuinfo/src/arm/cache.c"
    "${THIRDPARTY}/cpuinfo/src/arm/uarch.c"
    # arm/tlb.c is an inline include fragment, not standalone
    "${THIRDPARTY}/cpuinfo/src/arm/mach/init.c"
)

# FreeSurround
set(FREESURROUND_SOURCES
    "${THIRDPARTY}/freesurround/src/ChannelMaps.cpp"
    "${THIRDPARTY}/freesurround/src/FreeSurroundDecoder.cpp"
    "${THIRDPARTY}/freesurround/src/kiss_fft.cpp"
    "${THIRDPARTY}/freesurround/src/kiss_fftr.cpp"
)

# Metal shader files - these are compiled manually into a .metallib
# and bundled as a resource, NOT compiled through Xcode's default Metal pipeline
file(GLOB METAL_SHADERS "${PCSX2_SRC}/GS/Renderers/Metal/*.metal")
# Mark .metal files so CMake/Xcode doesn't try to compile them as sources
set_source_files_properties(${METAL_SHADERS} PROPERTIES
    HEADER_FILE_ONLY TRUE
)

# ============================================================================
# Create the bundle target
# ============================================================================

add_library(PCSX2 MODULE
    ${OPENEMU_SOURCES}
    ${PCSX2_CORE_SOURCES}
    ${COMMON_SOURCES}
    ${FMT_SOURCES}
    ${VIXL_SOURCES}
    ${SOUNDTOUCH_SOURCES}
    ${LIBCHDR_SOURCES}
    ${RCHEEVOS_SOURCES}
    ${ZSTD_SOURCES}
    ${LZ4_SOURCES}
    ${IMGUI_SOURCES}
    ${XXHASH_SOURCES}
    ${CUBEB_SOURCES}
    ${CCC_SOURCES}
    ${DEMANGLER_SOURCES}
    ${LZMA_SOURCES}
    ${CPUINFO_SOURCES}
    ${FREESURROUND_SOURCES}
    ${METAL_SHADERS}
)

# Enable ARC for specific files that require it
set_source_files_properties(
    "${COMMON_SRC}/CocoaTools.mm"
    "${CMAKE_CURRENT_SOURCE_DIR}/PCSX2GameCore.mm"
    "${CMAKE_CURRENT_SOURCE_DIR}/PCSX2Host.mm"
    PROPERTIES COMPILE_FLAGS "-fobjc-arc"
)
# Disable ARC for Metal renderer files (they use MRC via MRCHelpers.h)
file(GLOB_RECURSE MTL_OBJCXX_SOURCES "${PCSX2_SRC}/GS/Renderers/Metal/*.mm")
set_source_files_properties(${MTL_OBJCXX_SOURCES} PROPERTIES COMPILE_FLAGS "-fno-objc-arc")
# Also disable ARC for USB camera files that use MRC
file(GLOB_RECURSE USB_EYETOY_SOURCES "${PCSX2_SRC}/USB/usb-eyetoy/*.mm")
set_source_files_properties(${USB_EYETOY_SOURCES} PROPERTIES COMPILE_FLAGS "-fno-objc-arc")

# Set bundle properties
set_target_properties(PCSX2 PROPERTIES
    BUNDLE TRUE
    BUNDLE_EXTENSION "oecoreplugin"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist"
    XCODE_ATTRIBUTE_WRAPPER_EXTENSION "oecoreplugin"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "org.openemu.PCSX2"
)

# ============================================================================
# Include directories
# ============================================================================

target_include_directories(PCSX2 PRIVATE
    ${PCSX2_ROOT}
    ${PCSX2_SRC}
    ${COMMON_SRC}
    ${THIRDPARTY}/fmt/include
    ${THIRDPARTY}/vixl/include
    ${THIRDPARTY}/vixl/include/vixl
    ${THIRDPARTY}/vixl/include/vixl/aarch64
    ${THIRDPARTY}/rapidjson/include
    ${THIRDPARTY}/imgui/include
    ${THIRDPARTY}/soundtouch
    ${THIRDPARTY}/soundtouch/soundtouch
    ${THIRDPARTY}/libchdr/include
    ${THIRDPARTY}/cubeb/include
    ${THIRDPARTY}/cubeb/src
    ${THIRDPARTY}/cubeb/subprojects
    ${THIRDPARTY}/rcheevos/include
    ${THIRDPARTY}/lzma/include
    ${THIRDPARTY}/fast_float/include
    ${THIRDPARTY}/cpuinfo/include
    ${THIRDPARTY}/cpuinfo/src
    ${THIRDPARTY}/cpuinfo/src/cpuinfo
    ${THIRDPARTY}/glad/include
    ${THIRDPARTY}/ccc/src
    ${THIRDPARTY}/simpleini/include
    ${THIRDPARTY}/demangler/include
    ${THIRDPARTY}/freesurround/include
    ${THIRDPARTY}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../OpenEmu-SDK
    "${CMAKE_CURRENT_SOURCE_DIR}/../../OpenEmu/SystemPlugins/PlayStation 2"
    ${CMAKE_CURRENT_SOURCE_DIR}
    /opt/homebrew/include
    /opt/homebrew/include/freetype2
    /opt/homebrew/include/plutovg
)

# ============================================================================
# Link frameworks
# ============================================================================

target_link_libraries(PCSX2 PRIVATE
    "-framework Metal"
    "-framework MetalKit"
    "-framework Cocoa"
    "-framework IOKit"
    "-framework AudioToolbox"
    "-framework CoreAudio"
    "-framework AudioUnit"
    "-framework Carbon"
    "-framework AVFoundation"
    "-framework CoreMedia"
    "-framework CoreVideo"
    "-framework QuartzCore"
    "-framework OpenEmuBase"
    z
    iconv
    /opt/homebrew/lib/libzstd.a
    /opt/homebrew/lib/liblz4.a
    /opt/homebrew/lib/libzip.dylib
    /opt/homebrew/opt/bzip2/lib/libbz2.a
    /opt/homebrew/lib/libryml.dylib
    /opt/homebrew/lib/libc4core.dylib
    /opt/homebrew/lib/libwebp.dylib
    /opt/homebrew/lib/libjpeg.dylib
    /opt/homebrew/lib/libpng.dylib
    "-lpcap"
)

# Link against OpenEmuBase.framework (path may need adjustment)
# For now, set as a search path - actual framework linking done in Xcode
target_link_directories(PCSX2 PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/../../OpenEmu-SDK/build/Release"
)

# Framework search paths for OpenEmuBase
set_target_properties(PCSX2 PROPERTIES
    XCODE_ATTRIBUTE_FRAMEWORK_SEARCH_PATHS "${CMAKE_CURRENT_SOURCE_DIR}/../../OpenEmu-SDK/build/Release"
)

# ============================================================================
# Metal shader compilation and bundling
# ============================================================================

set(METAL_SHADER_DIR "${PCSX2_SRC}/GS/Renderers/Metal")
set(METAL_BUILD_DIR "${CMAKE_BINARY_DIR}/metal-shaders")
set(METALLIB_OUTPUT "${METAL_BUILD_DIR}/Metal23.metallib")
set(COMPILE_SCRIPT "${CMAKE_CURRENT_SOURCE_DIR}/compile_metal_shaders.sh")

# Custom command to compile Metal shaders into a .metallib
add_custom_command(
    OUTPUT ${METALLIB_OUTPUT}
    COMMAND ${COMPILE_SCRIPT} ${METAL_SHADER_DIR} ${METAL_BUILD_DIR}
    DEPENDS ${METAL_SHADERS} ${COMPILE_SCRIPT}
    COMMENT "Compiling Metal shaders into Metal23.metallib"
)
add_custom_target(MetalShaders ALL DEPENDS ${METALLIB_OUTPUT})
add_dependencies(PCSX2 MetalShaders)

# Copy the metallib into the bundle's Resources directory after build
add_custom_command(TARGET PCSX2 POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_BUNDLE_DIR:PCSX2>/Contents/Resources"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${METALLIB_OUTPUT}
        "$<TARGET_BUNDLE_DIR:PCSX2>/Contents/Resources/Metal23.metallib"
    COMMENT "Copying Metal23.metallib to plugin bundle Resources"
)
