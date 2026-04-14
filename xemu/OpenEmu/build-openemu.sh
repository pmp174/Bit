#!/bin/bash
#
# xemu OpenEmu Build Script
#
# Builds xemu as a static library and then assembles the .oecoreplugin bundle.
#
# Usage:
#   ./build-openemu.sh [clean]
#
# Prerequisites:
#   1. First build xemu normally from the xemu/ directory:
#        cd xemu
#        python3 scripts/download-macos-libs.py arm64
#        ./build/pyvenv/bin/pip install pyyaml  # if needed after configure
#        cd build && ninja -j$(sysctl -n hw.ncpu) qemu-system-i386
#
#   2. Then run this script to create the .oecoreplugin:
#        cd OpenEmu && ./build-openemu.sh
#
# Requirements:
#   - Xcode Command Line Tools
#   - meson, ninja (brew install meson ninja)
#   - xemu's pre-built macOS libs (downloaded via scripts/download-macos-libs.py)
#
# Copyright (c) 2024 OpenEmu Team
# SPDX-License-Identifier: BSD-3-Clause

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XEMU_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
XEMU_BUILD_DIR="$XEMU_DIR/build"
PLUGIN_BUILD_DIR="$XEMU_DIR/build-openemu-plugin"
PLUGIN_DIR="$PLUGIN_BUILD_DIR/XEMU.oecoreplugin"
BRIDGE_DIR="$SCRIPT_DIR"

# xemu's pre-built macOS libraries
LIB_PREFIX="$XEMU_DIR/macos-libs/arm64/opt/local"

# Deployment
DEPLOY_DIR="$HOME/Library/Application Support/Bit/Cores"

echo "============================================"
echo "  xemu OpenEmu Plugin Build"
echo "============================================"
echo "xemu source:    $XEMU_DIR"
echo "xemu build:     $XEMU_BUILD_DIR"
echo "Plugin build:   $PLUGIN_BUILD_DIR"
echo "Libraries:      $LIB_PREFIX"
echo ""

# Handle clean
if [ "$1" = "clean" ]; then
    echo "Cleaning plugin build directory..."
    rm -rf "$PLUGIN_BUILD_DIR"
    echo "Done."
    exit 0
fi

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# ============================================
# Step 0: Verify xemu was built
# ============================================
if [ ! -f "$XEMU_BUILD_DIR/qemu-system-i386" ]; then
    echo "ERROR: xemu not built yet. Build it first:"
    echo "  cd $XEMU_DIR"
    echo "  python3 scripts/download-macos-libs.py arm64"
    echo "  mkdir -p build && cd build"
    echo "  ../configure --extra-cflags=\"-DXBOX=1 -DOPENEMU=1 \$(cat config-cflags)\" \\"
    echo "    --target-list=i386-softmmu --disable-cocoa --cross-prefix="
    echo "  ninja -j\$(sysctl -n hw.ncpu) qemu-system-i386"
    exit 1
fi
echo ">>> xemu build verified: $XEMU_BUILD_DIR/qemu-system-i386"

# ============================================
# Step 1: Extract object files into static library
# ============================================
echo ""
echo ">>> Step 1: Creating static library from xemu build..."

mkdir -p "$PLUGIN_BUILD_DIR"
LIBXEMU="$PLUGIN_BUILD_DIR/libxemu.a"

# Collect all relevant .o files from the xemu build
# Exclude: main.o (has main()), test files, tool binaries, qemu-img,
# and conflicting QEMU stub files that duplicate real implementations
echo "Collecting object files..."
find "$XEMU_BUILD_DIR" -name '*.o' \
    ! -path '*/tests/*' \
    ! -path '*/tools/*' \
    ! -path '*qemu-img*' \
    ! -path '*qemu-storage*' \
    ! -path '*qemu-nbd*' \
    ! -name 'main.o' \
    ! -name 'stub-main.o' \
    | grep -v 'stubs_blk-exp-close-all' \
    | grep -v 'stubs_is-daemonized' \
    > "$PLUGIN_BUILD_DIR/obj_list.txt"

OBJ_COUNT=$(wc -l < "$PLUGIN_BUILD_DIR/obj_list.txt" | tr -d ' ')
echo "Found $OBJ_COUNT object files"

# Create static library using libtool (better than ar for large archives on macOS)
echo "Creating libxemu.a..."
libtool -static -o "$LIBXEMU" $(cat "$PLUGIN_BUILD_DIR/obj_list.txt") 2>/dev/null
echo "Created: $LIBXEMU ($(du -h "$LIBXEMU" | cut -f1))"

# Collect .o files with type_init constructors (QOM type registrations).
# These MUST be linked directly because the static archive linker won't
# pull them in — they have no global symbols, only __attribute__((constructor)).
echo "Collecting type_init objects for force-linking..."
FORCE_LINK_DIR="$PLUGIN_BUILD_DIR/force_link_objs"
mkdir -p "$FORCE_LINK_DIR"
rm -f "$FORCE_LINK_DIR"/*.o

# Find all .o files that have type_init constructors (do_qemu_init_*).
# Exclude xemu UI files (ui_xemu*.o) since we stub those functions.
while IFS= read -r obj; do
    case "$(basename "$obj")" in
        ui_xemu*) continue ;;
    esac
    if nm "$obj" 2>/dev/null | grep -q 't _do_qemu_init_'; then
        cp "$obj" "$FORCE_LINK_DIR/"
    fi
done < "$PLUGIN_BUILD_DIR/obj_list.txt"

# Also force-link renderer registration files (use __attribute__((constructor))
# but not the do_qemu_init_ pattern)
for extra_obj in \
    "$XEMU_BUILD_DIR/libqemu-i386-softmmu.a.p/hw_xbox_nv2a_pgraph_null_renderer.c.o" \
    "$XEMU_BUILD_DIR/libqemu-i386-softmmu.a.p/hw_xbox_nv2a_pgraph_gl_renderer.c.o" \
; do
    [ -f "$extra_obj" ] && cp "$extra_obj" "$FORCE_LINK_DIR/"
done

FORCE_LINK_COUNT=$(ls "$FORCE_LINK_DIR"/*.o 2>/dev/null | wc -l | tr -d ' ')
echo "Found $FORCE_LINK_COUNT type_init objects to force-link"
FORCE_LINK_OBJS=$(ls "$FORCE_LINK_DIR"/*.o 2>/dev/null | tr '\n' ' ')

# ============================================
# Step 2: Compile bridge files
# ============================================
echo ""
echo ">>> Step 2: Compiling OpenEmu bridge files..."

BRIDGE_OBJ_DIR="$PLUGIN_BUILD_DIR/bridge_objs"
mkdir -p "$BRIDGE_OBJ_DIR"

# Common flags — match what xemu's configure set up
SDK_PATH=$(xcrun --show-sdk-path)
MACOS_MIN_VER=14.0
COMMON_FLAGS="-arch arm64 -target arm64-apple-macos${MACOS_MIN_VER} -isysroot $SDK_PATH"

# Include paths from xemu build + xemu's macOS libraries
INCLUDE_FLAGS="\
    -I$XEMU_DIR/include \
    -I$XEMU_DIR \
    -I$XEMU_BUILD_DIR \
    -I$LIB_PREFIX/include \
    -I$LIB_PREFIX/include/glib-2.0 \
    -I$LIB_PREFIX/lib/glib-2.0/include \
    -I$LIB_PREFIX/include/pixman-1 \
    -I$XEMU_DIR/../OpenEmu/SystemPlugins/Xbox"

C_FLAGS="$COMMON_FLAGS $INCLUDE_FLAGS -DOPENEMU=1 -DXBOX=1"
OBJCXX_FLAGS="$C_FLAGS -std=c++17 -fobjc-arc -fmodules -fcxx-modules"

# OpenEmu framework paths (for @import OpenEmuBase)
OE_SDK_DIR=""
for _dir in \
    "$XEMU_DIR/../OpenEmu-SDK/build/Release" \
    "$XEMU_DIR/../OpenEmu-SDK/build/Build/Products/Release" \
    "$HOME/Library/Developer/Xcode/DerivedData/OpenEmu-dpfpjajlagusumelncfqtchjqbxy/Build/Products/Release" \
; do
    if [ -d "$_dir/OpenEmuBase.framework" ]; then
        OE_SDK_DIR="$(cd "$_dir" && pwd)"
        break
    fi
done
echo "OpenEmuBase found at: ${OE_SDK_DIR:-NOT FOUND}"
if [ -n "$OE_SDK_DIR" ] && [ -d "$OE_SDK_DIR" ]; then
    OBJCXX_FLAGS="$OBJCXX_FLAGS -F$OE_SDK_DIR"
fi

# Compile C bridge files
for src in xemu_openemu_display.c xemu_openemu_audio.c XEMUHost.c xemu_openemu_stubs.c glo_cgl_override.c; do
    echo "  Compiling $src..."
    clang $C_FLAGS -c "$BRIDGE_DIR/$src" -o "$BRIDGE_OBJ_DIR/${src%.c}.o" 2>&1
done

# Compile Objective-C++ bridge
echo "  Compiling XEMUGameCore.mm..."
clang++ $OBJCXX_FLAGS \
    -c "$BRIDGE_DIR/XEMUGameCore.mm" -o "$BRIDGE_OBJ_DIR/XEMUGameCore.o" 2>&1

echo "Bridge compilation complete."

# ============================================
# Step 3: Link plugin bundle
# ============================================
echo ""
echo ">>> Step 3: Linking XEMU.oecoreplugin..."

PLUGIN_CONTENTS="$PLUGIN_DIR/Contents"
PLUGIN_MACOS="$PLUGIN_CONTENTS/MacOS"
PLUGIN_RESOURCES="$PLUGIN_CONTENTS/Resources"
PLUGIN_FRAMEWORKS="$PLUGIN_CONTENTS/Frameworks"

mkdir -p "$PLUGIN_MACOS" "$PLUGIN_RESOURCES" "$PLUGIN_FRAMEWORKS"

# Copy Info.plist
cp "$BRIDGE_DIR/Info.plist" "$PLUGIN_CONTENTS/"

# Bridge object files
BRIDGE_OBJS="\
    $BRIDGE_OBJ_DIR/glo_cgl_override.o \
    $BRIDGE_OBJ_DIR/xemu_openemu_display.o \
    $BRIDGE_OBJ_DIR/xemu_openemu_audio.o \
    $BRIDGE_OBJ_DIR/XEMUHost.o \
    $BRIDGE_OBJ_DIR/xemu_openemu_stubs.o \
    $BRIDGE_OBJ_DIR/XEMUGameCore.o"

# System frameworks
FRAMEWORKS="\
    -framework Foundation \
    -framework OpenGL \
    -framework IOKit \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework Metal \
    -framework QuartzCore \
    -framework Security \
    -framework Cocoa \
    -framework CoreFoundation"

# Libraries from xemu's macOS libs
LIBS="\
    -L$LIB_PREFIX/lib \
    -lglib-2.0 \
    -lgobject-2.0 \
    -lgio-2.0 \
    -lpixman-1 \
    -lz \
    -lslirp \
    -lsamplerate \
    -lepoxy \
    -lpcap \
    -lffi \
    -liconv \
    -lintl \
    -lpcre2-8 \
    -lelf \
    -lSDL3 \
    -lusb-1.0 \
    -lcurl \
    -L/opt/homebrew/lib \
    -lxxhash"

# OpenEmu frameworks (OpenEmuBase at link time; OpenEmuSystem loaded at runtime by OpenEmu)
OE_FRAMEWORK_FLAGS=""
if [ -n "$OE_SDK_DIR" ] && [ -d "$OE_SDK_DIR" ]; then
    OE_FRAMEWORK_FLAGS="-F$OE_SDK_DIR"
fi
OE_FRAMEWORKS="\
    $OE_FRAMEWORK_FLAGS \
    -framework OpenEmuBase"

echo "Linking..."
clang++ $COMMON_FLAGS \
    -bundle \
    -headerpad_max_install_names \
    -o "$PLUGIN_MACOS/XEMU" \
    $BRIDGE_OBJS \
    $FORCE_LINK_OBJS \
    "$LIBXEMU" \
    $FRAMEWORKS \
    $LIBS \
    $OE_FRAMEWORKS \
    -Wl,-rpath,@loader_path/../Frameworks \
    -Wl,-rpath,@executable_path/../Frameworks \
    2>&1

echo "Plugin linked: $PLUGIN_MACOS/XEMU"

# Copy xemu's dylib dependencies into the plugin's Frameworks directory
echo "Bundling dynamic libraries..."
for dylib in "$LIB_PREFIX/lib/"*.dylib; do
    if [ -f "$dylib" ]; then
        # Resolve symlinks and copy the actual file with the expected name
        cp -L "$dylib" "$PLUGIN_FRAMEWORKS/" 2>/dev/null || true
    fi
done

# Fix dylib install names to use @loader_path
echo "Fixing dylib install name paths..."
for dylib in "$PLUGIN_FRAMEWORKS/"*.dylib; do
    [ -f "$dylib" ] || continue
    DYLIB_NAME=$(basename "$dylib")
    # Update the dylib's own ID
    install_name_tool -id "@loader_path/../Frameworks/$DYLIB_NAME" "$dylib" 2>/dev/null || true
done

# Fix the main binary's references to use @loader_path
echo "Fixing main binary references..."
otool -L "$PLUGIN_MACOS/XEMU" 2>/dev/null | grep '/opt/local/lib\|/usr/local/lib' | awk '{print $1}' | while read OLD_PATH; do
    DYLIB_NAME=$(basename "$OLD_PATH")
    if [ -f "$PLUGIN_FRAMEWORKS/$DYLIB_NAME" ]; then
        install_name_tool -change "$OLD_PATH" "@loader_path/../Frameworks/$DYLIB_NAME" "$PLUGIN_MACOS/XEMU" 2>/dev/null || true
    fi
done

# Fix inter-dylib references within Frameworks/
echo "Fixing inter-dylib references..."
for dylib in "$PLUGIN_FRAMEWORKS/"*.dylib; do
    [ -f "$dylib" ] || continue
    otool -L "$dylib" 2>/dev/null | grep '/opt/local/lib\|/usr/local/lib' | awk '{print $1}' | while read OLD_PATH; do
        REF_NAME=$(basename "$OLD_PATH")
        if [ -f "$PLUGIN_FRAMEWORKS/$REF_NAME" ]; then
            install_name_tool -change "$OLD_PATH" "@loader_path/../Frameworks/$REF_NAME" "$dylib" 2>/dev/null || true
        fi
    done
done

# ============================================
# Step 4: Sign and deploy
# ============================================
echo ""
echo ">>> Step 4: Signing and deploying..."

# Ad-hoc codesign the main binary and any bundled dylibs
codesign --force --sign - "$PLUGIN_MACOS/XEMU" 2>/dev/null || true
for dylib in "$PLUGIN_FRAMEWORKS/"*.dylib; do
    codesign --force --sign - "$dylib" 2>/dev/null || true
done

# Deploy
mkdir -p "$DEPLOY_DIR"
rm -rf "$DEPLOY_DIR/XEMU.oecoreplugin"
cp -R "$PLUGIN_DIR" "$DEPLOY_DIR/"

echo ""
echo "============================================"
echo "  Build complete!"
echo "============================================"
echo "Plugin:      $PLUGIN_DIR"
echo "Deployed to: $DEPLOY_DIR/XEMU.oecoreplugin"
echo ""
echo "Required BIOS files (place in ~/Library/Application Support/Bit/BIOS/):"
echo "  - mcpx_1.0.bin    (512 bytes, Xbox MCPX Boot ROM)"
echo "  - xbox_bios.bin   (256KB or 1MB, Xbox Flash ROM)"
echo ""
