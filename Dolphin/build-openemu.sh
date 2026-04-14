#!/bin/bash
# Build script for Dolphin.oecoreplugin (OpenEmu integration)
#
# This script configures and builds Dolphin's static libraries using CMake
# with bundled dependencies (no Homebrew dylibs for redistributable libs),
# then builds the plugin via Xcode.
#
# Prerequisites: brew install minizip-ng cmake
# (minizip-ng's bundled version has a ppmd fetch issue in flattened repos)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build-arm64"
XCODE_PROJECT="${SCRIPT_DIR}/Dolphin.xcodeproj"

echo "=== Configuring CMake (bundled static libs, no ffmpeg) ==="
# Force bundled versions of all redistributable libraries to avoid:
#  1) ABI mismatches (e.g. Homebrew fmt v12 vs bundled fmt v11 → linker errors)
#  2) Dynamic linking against Homebrew dylibs (e.g. liblzo2 → dlopen failures
#     on user machines without Homebrew)
#
# minizip-ng must use the system version because its bundled build tries to
# git-fetch ppmd, which fails in flattened (non-submodule) repo layouts.
cmake -S "${SCRIPT_DIR}" -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DUSE_SYSTEM_LIBS=OFF \
    "-DUSE_SYSTEM_MINIZIP-NG=ON" \
    -DUSE_SYSTEM_CURL=ON \
    -DENCODE_FRAMEDUMPS=OFF \
    -DENABLE_QT=OFF \
    -DENABLE_NOGUI=OFF \
    -DMACOS_CODE_SIGNING=ON \
    -DMACOS_CODE_SIGNING_IDENTITY="-"

echo ""
echo "=== Building CMake static libraries ==="
cmake --build "${BUILD_DIR}" --config Release -j "$(sysctl -n hw.ncpu)"

echo ""
echo "=== Building Dolphin.oecoreplugin via Xcode ==="
xcodebuild -project "${XCODE_PROJECT}" \
    -target "Dolphin" \
    -configuration Release \
    build

echo ""
echo "=== Verifying no Homebrew dylib dependencies ==="
PLUGIN_BIN="${SCRIPT_DIR}/build/Release/Dolphin.oecoreplugin/Contents/MacOS/Dolphin"
if [ -f "${PLUGIN_BIN}" ]; then
    HOMEBREW_DEPS=$(otool -L "${PLUGIN_BIN}" | grep -c '/opt/homebrew' || true)
    if [ "${HOMEBREW_DEPS}" -gt 0 ]; then
        echo "WARNING: Plugin has ${HOMEBREW_DEPS} Homebrew dependencies."
        echo "Run fix_dylibs.sh to embed them:"
        echo "  ./fix_dylibs.sh ${SCRIPT_DIR}/build/Release/Dolphin.oecoreplugin"
    else
        echo "OK: No Homebrew dependencies found."
    fi
else
    echo "WARNING: Plugin binary not found at ${PLUGIN_BIN}"
    echo "Check build output for the correct location."
fi

echo ""
echo "=== Done ==="
echo "Plugin: ${SCRIPT_DIR}/build/Release/Dolphin.oecoreplugin"
echo "Deploy: cp -R build/Release/Dolphin.oecoreplugin ~/Library/Application\\ Support/Bit/Cores/"
