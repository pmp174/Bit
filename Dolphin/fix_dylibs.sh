#!/usr/bin/env zsh
# Fix Homebrew dylib dependencies in an already-built Dolphin.oecoreplugin
#
# This copies Homebrew dylibs into the plugin's Frameworks/ directory and
# rewrites the load paths so the plugin is self-contained and works on
# machines without Homebrew.
#
# Usage: ./fix_dylibs.sh [path/to/Dolphin.oecoreplugin]
# Default: /Applications/Bit.app/Contents/PlugIns/Cores/Dolphin.oecoreplugin

set -euo pipefail

PLUGIN="${1:-/Applications/Bit.app/Contents/PlugIns/Cores/Dolphin.oecoreplugin}"
PLUGIN_BIN="${PLUGIN}/Contents/MacOS/Dolphin"
FRAMEWORKS_DIR="${PLUGIN}/Contents/Frameworks"

if [[ ! -f "${PLUGIN_BIN}" ]]; then
    echo "ERROR: Plugin binary not found at ${PLUGIN_BIN}"
    exit 1
fi

echo "Checking ${PLUGIN_BIN} for Homebrew dependencies..."
HOMEBREW_DEPS=("${(@f)$(otool -L "${PLUGIN_BIN}" | grep '/opt/homebrew' | awk '{print $1}')}")

if [[ ${#HOMEBREW_DEPS[@]} -eq 0 || -z "${HOMEBREW_DEPS[1]}" ]]; then
    echo "No Homebrew dependencies found. Plugin is already self-contained."
    exit 0
fi

echo "Found ${#HOMEBREW_DEPS[@]} direct Homebrew dependencies."
echo ""

mkdir -p "${FRAMEWORKS_DIR}"

# Collect all dylibs including transitive deps (recursive)
typeset -A SEEN
ALL_DYLIBS=()

collect_deps() {
    local dylib="$1"
    local name=$(basename "${dylib}")

    if (( ${+SEEN[$name]} )); then
        return
    fi
    SEEN[$name]=1

    if [[ ! -f "${dylib}" ]]; then
        echo "WARNING: ${dylib} not found on this system, skipping"
        return
    fi

    ALL_DYLIBS+=("${dylib}")

    # Check transitive deps (any /opt/homebrew reference)
    local trans=("${(@f)$(otool -L "${dylib}" | grep '/opt/homebrew' | awk '{print $1}')}")
    for tdep in "${trans[@]}"; do
        [[ -z "${tdep}" ]] && continue
        local tname=$(basename "${tdep}")
        [[ "${tname}" == "${name}" ]] && continue  # skip self-reference
        collect_deps "${tdep}"
    done
}

for dep in "${HOMEBREW_DEPS[@]}"; do
    collect_deps "${dep}"
done

echo "Embedding ${#ALL_DYLIBS[@]} dylibs (including transitive deps)..."
for dylib in "${ALL_DYLIBS[@]}"; do
    local name=$(basename "${dylib}")
    echo "  ${name}"
    cp "${dylib}" "${FRAMEWORKS_DIR}/${name}"
    chmod 644 "${FRAMEWORKS_DIR}/${name}"
done

# Build a complete map of all homebrew paths -> @loader_path rewrites.
# This includes the original paths AND any variant paths (e.g. openssl@3 vs openssl).
typeset -A PATH_MAP
for dylib in "${ALL_DYLIBS[@]}"; do
    local name=$(basename "${dylib}")
    PATH_MAP[${dylib}]="${name}"
done

# Also scan embedded dylibs for any homebrew paths we might have missed
for fw_dylib in "${FRAMEWORKS_DIR}"/*.dylib; do
    local refs=("${(@f)$(otool -L "${fw_dylib}" | grep '/opt/homebrew' | awk '{print $1}')}")
    for ref in "${refs[@]}"; do
        [[ -z "${ref}" ]] && continue
        local rname=$(basename "${ref}")
        if [[ -f "${FRAMEWORKS_DIR}/${rname}" ]] && [[ -z "${PATH_MAP[$ref]+x}" ]]; then
            PATH_MAP[${ref}]="${rname}"
        fi
    done
done

# Rewrite the main binary's references
echo ""
echo "Rewriting load commands..."
for orig_path name in "${(@kv)PATH_MAP}"; do
    install_name_tool -change "${orig_path}" "@loader_path/../Frameworks/${name}" "${PLUGIN_BIN}" 2>/dev/null || true
done

# Rewrite inter-dylib references within Frameworks/
for fw_dylib in "${FRAMEWORKS_DIR}"/*.dylib; do
    local fw_name=$(basename "${fw_dylib}")
    # Fix the dylib's own install name
    install_name_tool -id "@loader_path/../Frameworks/${fw_name}" "${fw_dylib}" 2>/dev/null || true

    # Fix all homebrew references
    for orig_path name in "${(@kv)PATH_MAP}"; do
        install_name_tool -change "${orig_path}" "@loader_path/${name}" "${fw_dylib}" 2>/dev/null || true
    done
done

# Re-sign everything
echo "Re-signing..."
for fw_dylib in "${FRAMEWORKS_DIR}"/*.dylib; do
    codesign --force --sign - "${fw_dylib}" 2>/dev/null
done
codesign --force --sign - "${PLUGIN_BIN}"

echo ""
echo "=== Verification ==="
REMAINING=$(otool -L "${PLUGIN_BIN}" | grep -c '/opt/homebrew' || true)
FW_REMAINING=0
for f in "${FRAMEWORKS_DIR}"/*.dylib; do
    local count=$(otool -L "$f" | grep -c '/opt/homebrew' || true)
    FW_REMAINING=$((FW_REMAINING + count))
done

if [[ "${REMAINING}" -eq 0 && "${FW_REMAINING}" -eq 0 ]]; then
    echo "SUCCESS: No Homebrew dependencies remain. Plugin is self-contained."
else
    echo "WARNING: ${REMAINING} refs in binary, ${FW_REMAINING} refs in frameworks"
    [[ "${REMAINING}" -gt 0 ]] && otool -L "${PLUGIN_BIN}" | grep '/opt/homebrew'
fi
