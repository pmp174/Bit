#!/bin/bash
# Compiles PCSX2 Metal shaders into Metal23.metallib
# Usage: compile_metal_shaders.sh <shader_dir> <output_dir>

set -e

SHADER_DIR="$1"
OUTPUT_DIR="$2"

if [ -z "$SHADER_DIR" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "Usage: $0 <shader_dir> <output_dir>"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

METAL_CMD=$(xcrun --find metal)
METALLIB_CMD=$(xcrun --find metallib)
SDK=$(xcrun --sdk macosx --show-sdk-path)

# Compile each .metal file to .air
for f in "$SHADER_DIR"/*.metal; do
    base=$(basename "$f" .metal)
    "$METAL_CMD" \
        -isysroot "$SDK" \
        -std=macos-metal2.3 \
        -target air64-apple-macos14.0 \
        -I "$SHADER_DIR" \
        -o "$OUTPUT_DIR/$base.air" \
        -c "$f"
done

# Link all .air files into Metal23.metallib
"$METALLIB_CMD" -o "$OUTPUT_DIR/Metal23.metallib" "$OUTPUT_DIR"/*.air

echo "Metal23.metallib created at $OUTPUT_DIR/Metal23.metallib"
