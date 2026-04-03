#!/bin/bash
# Build PPSSPP as a static library for linking into the OpenEmu core plugin
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PPSSPP_DIR="$SCRIPT_DIR/../ppsspp"
BUILD_DIR="$SCRIPT_DIR/build"
LIBRETRO_DIR="$PPSSPP_DIR/libretro"

mkdir -p "$BUILD_DIR"

echo "Building PPSSPP static library..."

# Build with the libretro Makefile and produce object files
cd "$LIBRETRO_DIR"

# Clean previous build
make platform=osx TARGET_ARCH=arm64 WITH_DYNAREC=1 clean 2>/dev/null || true

# Build object files (the Makefile will compile all sources)
make platform=osx TARGET_ARCH=arm64 WITH_DYNAREC=1 -j$(sysctl -n hw.ncpu) 2>&1

# If the dylib was produced, extract object files into a static library
if [ -f "ppsspp_libretro.dylib" ]; then
    echo "Build successful - dylib produced"

    # Collect all .o files produced by the build
    find "$PPSSPP_DIR" -name "*.o" -newer "$BUILD_DIR" 2>/dev/null > "$BUILD_DIR/objects.txt"

    # Create static library from all object files
    ar rcs "$BUILD_DIR/libppsspp.a" $(find "$PPSSPP_DIR" -name "*.o" | grep -v "libretro\.o" | head -800)

    echo "Static library created at $BUILD_DIR/libppsspp.a"
    ls -la "$BUILD_DIR/libppsspp.a"
else
    echo "Build failed - no dylib produced"
    exit 1
fi

echo "Done!"
