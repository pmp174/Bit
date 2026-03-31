#!/bin/bash
# Install pending Xcode project files
# Run this script AFTER closing Xcode to safely install the pending project files.
# Usage: bash install-pending-projects.sh

set -e

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Installing Pending Xcode Project Files ==="
echo ""

# Check if Xcode is running
if pgrep -x "Xcode" > /dev/null 2>&1; then
    echo "ERROR: Xcode is still running. Please close Xcode first."
    exit 1
fi

# 1. Install Dolphin.xcodeproj
DOLPHIN_PENDING="$BASE_DIR/Dolphin/Dolphin-project.pbxproj.pending"
DOLPHIN_DEST="$BASE_DIR/Dolphin/Dolphin.xcodeproj/project.pbxproj"
if [ -f "$DOLPHIN_PENDING" ]; then
    mkdir -p "$BASE_DIR/Dolphin/Dolphin.xcodeproj"
    cp "$DOLPHIN_PENDING" "$DOLPHIN_DEST"
    echo "[OK] Installed Dolphin.xcodeproj/project.pbxproj"
else
    echo "[SKIP] Dolphin pending file not found"
fi

# 2. Install MAME.xcodeproj
MAME_PENDING="$BASE_DIR/Mame/MAME-project.pbxproj.pending"
MAME_DEST="$BASE_DIR/Mame/MAME.xcodeproj/project.pbxproj"
if [ -f "$MAME_PENDING" ]; then
    mkdir -p "$BASE_DIR/Mame/MAME.xcodeproj"
    cp "$MAME_PENDING" "$MAME_DEST"
    echo "[OK] Installed MAME.xcodeproj/project.pbxproj"
else
    echo "[SKIP] MAME pending file not found"
fi

# 3. Add Wii system plugin to main OpenEmu project
MAIN_PBXPROJ="$BASE_DIR/OpenEmu/OpenEmu.xcodeproj/project.pbxproj"
if [ -f "$MAIN_PBXPROJ" ]; then
    # Check if Wii is already added
    if grep -q "D99E287890004DDD" "$MAIN_PBXPROJ"; then
        echo "[SKIP] Wii system plugin already present in main project"
    else
        echo "Adding Wii system plugin to main OpenEmu project..."

        # We use python3 for reliable multi-line text insertion
        python3 << 'PYEOF'
import re

pbxproj_path = r"""MAIN_PBXPROJ_PLACEHOLDER"""
with open(pbxproj_path, 'r') as f:
    content = f.read()

# === 1. Add PBXBuildFile entries ===
# Insert after the last Atomiswave build file entry
wii_build_files = """		D99E287890004DDD0000000D /* OEWiiSystemController.swift in Sources */ = {isa = PBXBuildFile; fileRef = D99E287890004DDD0000000C /* OEWiiSystemController.swift */; };
		D99E287890004DDD0000000F /* Images.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = D99E287890004DDD0000000E /* Images.xcassets */; };
		D99E287890004DDD00000011 /* Controller-Preferences.plist in Resources */ = {isa = PBXBuildFile; fileRef = D99E287890004DDD00000010 /* Controller-Preferences.plist */; };
		D99E287890004DDD00000013 /* Keyboard-Mappings.plist in Resources */ = {isa = PBXBuildFile; fileRef = D99E287890004DDD00000012 /* Keyboard-Mappings.plist */; };
		D99E287890004DDD00000015 /* Controller-Mappings.plist in Resources */ = {isa = PBXBuildFile; fileRef = D99E287890004DDD00000014 /* Controller-Mappings.plist */; };
		D99E287890004DDD00000016 /* OpenEmuSystem.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = C6D120CC17112DE600E868A8 /* OpenEmuSystem.framework */; };
		D99E287890004DDD00000017 /* Wii.oesystemplugin in Copy System Plugins to App Plugins */ = {isa = PBXBuildFile; fileRef = D99E287890004DDD00000002 /* Wii.oesystemplugin */; settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }; };
		D99E287890004DDD0000001A /* OEWiiSystemResponder.m in Sources */ = {isa = PBXBuildFile; fileRef = D99E287890004DDD0000001B /* OEWiiSystemResponder.m */; };
"""

# Find the end of PBXBuildFile section and insert before it
content = content.replace(
    '/* End PBXBuildFile section */',
    wii_build_files + '/* End PBXBuildFile section */'
)

# === 2. Add PBXContainerItemProxy entry ===
wii_container_proxy = """		D99E287890004DDD00000018 /* PBXContainerItemProxy */ = {
			isa = PBXContainerItemProxy;
			containerPortal = 2A37F4A9FDCFA73011CA2CEA /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = D99E287890004DDD00000001;
			remoteInfo = Wii;
		};
"""
content = content.replace(
    '/* End PBXContainerItemProxy section */',
    wii_container_proxy + '/* End PBXContainerItemProxy section */'
)

# === 3. Add PBXFileReference entries ===
wii_file_refs = """		D99E287890004DDD00000002 /* Wii.oesystemplugin */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = "Wii.oesystemplugin"; sourceTree = BUILT_PRODUCTS_DIR; };
		D99E287890004DDD00000003 /* Wii-Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Wii-Info.plist"; sourceTree = "<group>"; };
		D99E287890004DDD0000000C /* OEWiiSystemController.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OEWiiSystemController.swift; sourceTree = "<group>"; };
		D99E287890004DDD0000000E /* Images.xcassets */ = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Images.xcassets; sourceTree = "<group>"; };
		D99E287890004DDD00000010 /* Controller-Preferences.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Controller-Preferences.plist"; sourceTree = "<group>"; };
		D99E287890004DDD00000012 /* Keyboard-Mappings.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Keyboard-Mappings.plist"; sourceTree = "<group>"; };
		D99E287890004DDD00000014 /* Controller-Mappings.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Controller-Mappings.plist"; sourceTree = "<group>"; };
		D99E287890004DDD0000001B /* OEWiiSystemResponder.m */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; path = OEWiiSystemResponder.m; sourceTree = "<group>"; };
		D99E287890004DDD0000001C /* OEWiiSystemResponder.h */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = OEWiiSystemResponder.h; sourceTree = "<group>"; };
		D99E287890004DDD0000001D /* OEWiiSystemResponderClient.h */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = OEWiiSystemResponderClient.h; sourceTree = "<group>"; };
"""
content = content.replace(
    '/* End PBXFileReference section */',
    wii_file_refs + '/* End PBXFileReference section */'
)

# === 4. Add to Copy System Plugins build phase ===
content = content.replace(
    '\t\t\t\tC88D176780003CCC00000017 /* Atomiswave.oesystemplugin in Copy System Plugins to App Plugins */,\n\t\t\t);\n\t\t\tname = "Copy System Plugins to App Plugins";',
    '\t\t\t\tC88D176780003CCC00000017 /* Atomiswave.oesystemplugin in Copy System Plugins to App Plugins */,\n\t\t\t\tD99E287890004DDD00000017 /* Wii.oesystemplugin in Copy System Plugins to App Plugins */,\n\t\t\t);\n\t\t\tname = "Copy System Plugins to App Plugins";'
)

# === 5. Add PBXFrameworksBuildPhase ===
wii_frameworks = """		D99E287890004DDD00000007 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				D99E287890004DDD00000016 /* OpenEmuSystem.framework in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
"""
content = content.replace(
    '/* End PBXFrameworksBuildPhase section */',
    wii_frameworks + '/* End PBXFrameworksBuildPhase section */'
)

# === 6. Add PBXGroup entries ===
# Add the Wii group to System Plugins group
content = content.replace(
    '\t\t\t\tC88D176780003CCC00000004 /* Atomiswave */,\n\t\t\t);\n\t\t\tname = "System Plugins";',
    '\t\t\t\tC88D176780003CCC00000004 /* Atomiswave */,\n\t\t\t\tD99E287890004DDD00000004 /* Wii */,\n\t\t\t);\n\t\t\tname = "System Plugins";'
)

# Add the Wii group definition and Supporting Files subgroup
wii_groups = """		D99E287890004DDD00000004 /* Wii */ = {
			isa = PBXGroup;
			children = (
				D99E287890004DDD0000000C /* OEWiiSystemController.swift */,
				D99E287890004DDD0000001C /* OEWiiSystemResponder.h */,
				D99E287890004DDD0000001B /* OEWiiSystemResponder.m */,
				D99E287890004DDD0000001D /* OEWiiSystemResponderClient.h */,
				D99E287890004DDD00000005 /* Supporting Files */,
			);
			path = Wii;
			sourceTree = "<group>";
		};
		D99E287890004DDD00000005 /* Supporting Files */ = {
			isa = PBXGroup;
			children = (
				D99E287890004DDD0000000E /* Images.xcassets */,
				D99E287890004DDD00000003 /* Wii-Info.plist */,
				D99E287890004DDD00000012 /* Keyboard-Mappings.plist */,
				D99E287890004DDD00000014 /* Controller-Mappings.plist */,
				D99E287890004DDD00000010 /* Controller-Preferences.plist */,
			);
			name = "Supporting Files";
			sourceTree = "<group>";
		};
"""
content = content.replace(
    '/* End PBXGroup section */',
    wii_groups + '/* End PBXGroup section */'
)

# === 7. Add to Products group ===
content = content.replace(
    '\t\t\t\tC88D176780003CCC00000002 /* Atomiswave.oesystemplugin */,\n\t\t\t);\n\t\t\tname = Products;',
    '\t\t\t\tC88D176780003CCC00000002 /* Atomiswave.oesystemplugin */,\n\t\t\t\tD99E287890004DDD00000002 /* Wii.oesystemplugin */,\n\t\t\t);\n\t\t\tname = Products;'
)

# === 8. Add PBXNativeTarget ===
wii_target = """		D99E287890004DDD00000001 /* Wii */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = D99E287890004DDD0000000B /* Build configuration list for PBXNativeTarget "Wii" */;
			buildPhases = (
				D99E287890004DDD00000006 /* Sources */,
				D99E287890004DDD00000007 /* Frameworks */,
				D99E287890004DDD00000008 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = Wii;
			productName = Wii;
			productReference = D99E287890004DDD00000002 /* Wii.oesystemplugin */;
			productType = "com.apple.product-type.bundle";
		};
"""
content = content.replace(
    '/* End PBXNativeTarget section */',
    wii_target + '/* End PBXNativeTarget section */'
)

# === 9. Add to project targets list ===
content = content.replace(
    '\t\t\t\tC88D176780003CCC00000001 /* Atomiswave */,\n\t\t\t);\n\t\t};\n/* End PBXProject section */',
    '\t\t\t\tC88D176780003CCC00000001 /* Atomiswave */,\n\t\t\t\tD99E287890004DDD00000001 /* Wii */,\n\t\t\t);\n\t\t};\n/* End PBXProject section */'
)

# === 10. Add PBXResourcesBuildPhase ===
wii_resources = """		D99E287890004DDD00000008 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				D99E287890004DDD0000000F /* Images.xcassets in Resources */,
				D99E287890004DDD00000011 /* Controller-Preferences.plist in Resources */,
				D99E287890004DDD00000013 /* Keyboard-Mappings.plist in Resources */,
				D99E287890004DDD00000015 /* Controller-Mappings.plist in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
"""
content = content.replace(
    '/* End PBXResourcesBuildPhase section */',
    wii_resources + '/* End PBXResourcesBuildPhase section */'
)

# === 11. Add PBXSourcesBuildPhase ===
wii_sources = """		D99E287890004DDD00000006 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				D99E287890004DDD0000000D /* OEWiiSystemController.swift in Sources */,
				D99E287890004DDD0000001A /* OEWiiSystemResponder.m in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
"""
content = content.replace(
    '/* End PBXSourcesBuildPhase section */',
    wii_sources + '/* End PBXSourcesBuildPhase section */'
)

# === 12. Add PBXTargetDependency ===
wii_dep = """		D99E287890004DDD00000019 /* PBXTargetDependency */ = {
			isa = PBXTargetDependency;
			target = D99E287890004DDD00000001 /* Wii */;
			targetProxy = D99E287890004DDD00000018 /* PBXContainerItemProxy */;
		};
"""
content = content.replace(
    '/* End PBXTargetDependency section */',
    wii_dep + '/* End PBXTargetDependency section */'
)

# === 13. Add to Build Experimental SystemPlugins dependencies ===
content = content.replace(
    '\t\t\t\tC88D176780003CCC00000019 /* PBXTargetDependency */,\n\t\t\t);\n\t\t\tname = "Build Experimental SystemPlugins";',
    '\t\t\t\tC88D176780003CCC00000019 /* PBXTargetDependency */,\n\t\t\t\tD99E287890004DDD00000019 /* PBXTargetDependency */,\n\t\t\t);\n\t\t\tname = "Build Experimental SystemPlugins";'
)

# === 14. Add XCBuildConfiguration entries ===
wii_configs = """		D99E287890004DDD00000009 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				INFOPLIST_FILE = "SystemPlugins/Wii/Wii-Info.plist";
				PRODUCT_BUNDLE_IDENTIFIER = "org.openemu.$(PRODUCT_NAME:rfc1034identifier)";
				PRODUCT_NAME = "$(TARGET_NAME)";
				WRAPPER_EXTENSION = oesystemplugin;
			};
			name = Debug;
		};
		D99E287890004DDD0000000A /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				INFOPLIST_FILE = "SystemPlugins/Wii/Wii-Info.plist";
				PRODUCT_BUNDLE_IDENTIFIER = "org.openemu.$(PRODUCT_NAME:rfc1034identifier)";
				PRODUCT_NAME = "$(TARGET_NAME)";
				WRAPPER_EXTENSION = oesystemplugin;
			};
			name = Release;
		};
"""
content = content.replace(
    '/* End XCBuildConfiguration section */',
    wii_configs + '/* End XCBuildConfiguration section */'
)

# === 15. Add XCConfigurationList ===
wii_config_list = """		D99E287890004DDD0000000B /* Build configuration list for PBXNativeTarget "Wii" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				D99E287890004DDD00000009 /* Debug */,
				D99E287890004DDD0000000A /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
"""
content = content.replace(
    '/* End XCConfigurationList section */',
    wii_config_list + '/* End XCConfigurationList section */'
)

with open(pbxproj_path, 'w') as f:
    f.write(content)

print("Wii system plugin added to main project successfully.")
PYEOF

        # Fix the placeholder path in the python script
        sed -i '' "s|MAIN_PBXPROJ_PLACEHOLDER|$MAIN_PBXPROJ|" /dev/stdin 2>/dev/null || true

        # Actually run it properly - write python script to temp file first
        PYSCRIPT=$(mktemp /tmp/wii_patch_XXXXXX.py)
        cat > "$PYSCRIPT" << PYEOF2
import re
import sys

pbxproj_path = sys.argv[1]
with open(pbxproj_path, 'r') as f:
    content = f.read()

# Check if already added
if 'D99E287890004DDD' in content:
    print("[SKIP] Wii system plugin already present in main project")
    sys.exit(0)

# === 1. Add PBXBuildFile entries ===
wii_build_files = """\t\tD99E287890004DDD0000000D /* OEWiiSystemController.swift in Sources */ = {isa = PBXBuildFile; fileRef = D99E287890004DDD0000000C /* OEWiiSystemController.swift */; };
\t\tD99E287890004DDD0000000F /* Images.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = D99E287890004DDD0000000E /* Images.xcassets */; };
\t\tD99E287890004DDD00000011 /* Controller-Preferences.plist in Resources */ = {isa = PBXBuildFile; fileRef = D99E287890004DDD00000010 /* Controller-Preferences.plist */; };
\t\tD99E287890004DDD00000013 /* Keyboard-Mappings.plist in Resources */ = {isa = PBXBuildFile; fileRef = D99E287890004DDD00000012 /* Keyboard-Mappings.plist */; };
\t\tD99E287890004DDD00000015 /* Controller-Mappings.plist in Resources */ = {isa = PBXBuildFile; fileRef = D99E287890004DDD00000014 /* Controller-Mappings.plist */; };
\t\tD99E287890004DDD00000016 /* OpenEmuSystem.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = C6D120CC17112DE600E868A8 /* OpenEmuSystem.framework */; };
\t\tD99E287890004DDD00000017 /* Wii.oesystemplugin in Copy System Plugins to App Plugins */ = {isa = PBXBuildFile; fileRef = D99E287890004DDD00000002 /* Wii.oesystemplugin */; settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }; };
\t\tD99E287890004DDD0000001A /* OEWiiSystemResponder.m in Sources */ = {isa = PBXBuildFile; fileRef = D99E287890004DDD0000001B /* OEWiiSystemResponder.m */; };
"""
content = content.replace('/* End PBXBuildFile section */', wii_build_files + '/* End PBXBuildFile section */')

# === 2. Add PBXContainerItemProxy entry ===
wii_proxy = """\t\tD99E287890004DDD00000018 /* PBXContainerItemProxy */ = {
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = 2A37F4A9FDCFA73011CA2CEA /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = D99E287890004DDD00000001;
\t\t\tremoteInfo = Wii;
\t\t};
"""
content = content.replace('/* End PBXContainerItemProxy section */', wii_proxy + '/* End PBXContainerItemProxy section */')

# === 3. Add PBXFileReference entries ===
wii_refs = """\t\tD99E287890004DDD00000002 /* Wii.oesystemplugin */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = "Wii.oesystemplugin"; sourceTree = BUILT_PRODUCTS_DIR; };
\t\tD99E287890004DDD00000003 /* Wii-Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Wii-Info.plist"; sourceTree = "<group>"; };
\t\tD99E287890004DDD0000000C /* OEWiiSystemController.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OEWiiSystemController.swift; sourceTree = "<group>"; };
\t\tD99E287890004DDD0000000E /* Images.xcassets */ = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Images.xcassets; sourceTree = "<group>"; };
\t\tD99E287890004DDD00000010 /* Controller-Preferences.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Controller-Preferences.plist"; sourceTree = "<group>"; };
\t\tD99E287890004DDD00000012 /* Keyboard-Mappings.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Keyboard-Mappings.plist"; sourceTree = "<group>"; };
\t\tD99E287890004DDD00000014 /* Controller-Mappings.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Controller-Mappings.plist"; sourceTree = "<group>"; };
\t\tD99E287890004DDD0000001B /* OEWiiSystemResponder.m */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; path = OEWiiSystemResponder.m; sourceTree = "<group>"; };
\t\tD99E287890004DDD0000001C /* OEWiiSystemResponder.h */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = OEWiiSystemResponder.h; sourceTree = "<group>"; };
\t\tD99E287890004DDD0000001D /* OEWiiSystemResponderClient.h */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = OEWiiSystemResponderClient.h; sourceTree = "<group>"; };
"""
content = content.replace('/* End PBXFileReference section */', wii_refs + '/* End PBXFileReference section */')

# === 4. Add to Copy System Plugins build phase ===
content = content.replace(
    '\t\t\t\tC88D176780003CCC00000017 /* Atomiswave.oesystemplugin in Copy System Plugins to App Plugins */,\n\t\t\t);\n\t\t\tname = "Copy System Plugins to App Plugins";',
    '\t\t\t\tC88D176780003CCC00000017 /* Atomiswave.oesystemplugin in Copy System Plugins to App Plugins */,\n\t\t\t\tD99E287890004DDD00000017 /* Wii.oesystemplugin in Copy System Plugins to App Plugins */,\n\t\t\t);\n\t\t\tname = "Copy System Plugins to App Plugins";'
)

# === 5. Add PBXFrameworksBuildPhase ===
wii_fw = """\t\tD99E287890004DDD00000007 /* Frameworks */ = {
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\tD99E287890004DDD00000016 /* OpenEmuSystem.framework in Frameworks */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};
"""
content = content.replace('/* End PBXFrameworksBuildPhase section */', wii_fw + '/* End PBXFrameworksBuildPhase section */')

# === 6. Add Wii group to System Plugins ===
content = content.replace(
    '\t\t\t\tC88D176780003CCC00000004 /* Atomiswave */,\n\t\t\t);\n\t\t\tname = "System Plugins";',
    '\t\t\t\tC88D176780003CCC00000004 /* Atomiswave */,\n\t\t\t\tD99E287890004DDD00000004 /* Wii */,\n\t\t\t);\n\t\t\tname = "System Plugins";'
)

# === 7. Add Wii group definitions ===
wii_groups = """\t\tD99E287890004DDD00000004 /* Wii */ = {
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\tD99E287890004DDD0000000C /* OEWiiSystemController.swift */,
\t\t\t\tD99E287890004DDD0000001C /* OEWiiSystemResponder.h */,
\t\t\t\tD99E287890004DDD0000001B /* OEWiiSystemResponder.m */,
\t\t\t\tD99E287890004DDD0000001D /* OEWiiSystemResponderClient.h */,
\t\t\t\tD99E287890004DDD00000005 /* Supporting Files */,
\t\t\t);
\t\t\tpath = Wii;
\t\t\tsourceTree = "<group>";
\t\t};
\t\tD99E287890004DDD00000005 /* Supporting Files */ = {
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\tD99E287890004DDD0000000E /* Images.xcassets */,
\t\t\t\tD99E287890004DDD00000003 /* Wii-Info.plist */,
\t\t\t\tD99E287890004DDD00000012 /* Keyboard-Mappings.plist */,
\t\t\t\tD99E287890004DDD00000014 /* Controller-Mappings.plist */,
\t\t\t\tD99E287890004DDD00000010 /* Controller-Preferences.plist */,
\t\t\t);
\t\t\tname = "Supporting Files";
\t\t\tsourceTree = "<group>";
\t\t};
"""
content = content.replace('/* End PBXGroup section */', wii_groups + '/* End PBXGroup section */')

# === 8. Add to Products group ===
content = content.replace(
    '\t\t\t\tC88D176780003CCC00000002 /* Atomiswave.oesystemplugin */,\n\t\t\t);\n\t\t\tname = Products;',
    '\t\t\t\tC88D176780003CCC00000002 /* Atomiswave.oesystemplugin */,\n\t\t\t\tD99E287890004DDD00000002 /* Wii.oesystemplugin */,\n\t\t\t);\n\t\t\tname = Products;'
)

# === 9. Add PBXNativeTarget ===
wii_target = """\t\tD99E287890004DDD00000001 /* Wii */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = D99E287890004DDD0000000B /* Build configuration list for PBXNativeTarget "Wii" */;
\t\t\tbuildPhases = (
\t\t\t\tD99E287890004DDD00000006 /* Sources */,
\t\t\t\tD99E287890004DDD00000007 /* Frameworks */,
\t\t\t\tD99E287890004DDD00000008 /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = Wii;
\t\t\tproductName = Wii;
\t\t\tproductReference = D99E287890004DDD00000002 /* Wii.oesystemplugin */;
\t\t\tproductType = "com.apple.product-type.bundle";
\t\t};
"""
content = content.replace('/* End PBXNativeTarget section */', wii_target + '/* End PBXNativeTarget section */')

# === 10. Add to project targets list ===
content = content.replace(
    '\t\t\t\tC88D176780003CCC00000001 /* Atomiswave */,\n\t\t\t);\n\t\t};\n/* End PBXProject section */',
    '\t\t\t\tC88D176780003CCC00000001 /* Atomiswave */,\n\t\t\t\tD99E287890004DDD00000001 /* Wii */,\n\t\t\t);\n\t\t};\n/* End PBXProject section */'
)

# === 11. Add PBXResourcesBuildPhase ===
wii_res = """\t\tD99E287890004DDD00000008 /* Resources */ = {
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\tD99E287890004DDD0000000F /* Images.xcassets in Resources */,
\t\t\t\tD99E287890004DDD00000011 /* Controller-Preferences.plist in Resources */,
\t\t\t\tD99E287890004DDD00000013 /* Keyboard-Mappings.plist in Resources */,
\t\t\t\tD99E287890004DDD00000015 /* Controller-Mappings.plist in Resources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};
"""
content = content.replace('/* End PBXResourcesBuildPhase section */', wii_res + '/* End PBXResourcesBuildPhase section */')

# === 12. Add PBXSourcesBuildPhase ===
wii_src = """\t\tD99E287890004DDD00000006 /* Sources */ = {
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\tD99E287890004DDD0000000D /* OEWiiSystemController.swift in Sources */,
\t\t\t\tD99E287890004DDD0000001A /* OEWiiSystemResponder.m in Sources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};
"""
content = content.replace('/* End PBXSourcesBuildPhase section */', wii_src + '/* End PBXSourcesBuildPhase section */')

# === 13. Add PBXTargetDependency ===
wii_dep = """\t\tD99E287890004DDD00000019 /* PBXTargetDependency */ = {
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = D99E287890004DDD00000001 /* Wii */;
\t\t\ttargetProxy = D99E287890004DDD00000018 /* PBXContainerItemProxy */;
\t\t};
"""
content = content.replace('/* End PBXTargetDependency section */', wii_dep + '/* End PBXTargetDependency section */')

# === 14. Add to Build Experimental SystemPlugins ===
content = content.replace(
    '\t\t\t\tC88D176780003CCC00000019 /* PBXTargetDependency */,\n\t\t\t);\n\t\t\tname = "Build Experimental SystemPlugins";',
    '\t\t\t\tC88D176780003CCC00000019 /* PBXTargetDependency */,\n\t\t\t\tD99E287890004DDD00000019 /* PBXTargetDependency */,\n\t\t\t);\n\t\t\tname = "Build Experimental SystemPlugins";'
)

# === 15. Add XCBuildConfiguration entries ===
wii_cfgs = """\t\tD99E287890004DDD00000009 /* Debug */ = {
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {
\t\t\t\tINFOPLIST_FILE = "SystemPlugins/Wii/Wii-Info.plist";
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "org.openemu.$(PRODUCT_NAME:rfc1034identifier)";
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tWRAPPER_EXTENSION = oesystemplugin;
\t\t\t};
\t\t\tname = Debug;
\t\t};
\t\tD99E287890004DDD0000000A /* Release */ = {
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {
\t\t\t\tINFOPLIST_FILE = "SystemPlugins/Wii/Wii-Info.plist";
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "org.openemu.$(PRODUCT_NAME:rfc1034identifier)";
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tWRAPPER_EXTENSION = oesystemplugin;
\t\t\t};
\t\t\tname = Release;
\t\t};
"""
content = content.replace('/* End XCBuildConfiguration section */', wii_cfgs + '/* End XCBuildConfiguration section */')

# === 16. Add XCConfigurationList ===
wii_cfglist = """\t\tD99E287890004DDD0000000B /* Build configuration list for PBXNativeTarget "Wii" */ = {
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\tD99E287890004DDD00000009 /* Debug */,
\t\t\t\tD99E287890004DDD0000000A /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t};
"""
content = content.replace('/* End XCConfigurationList section */', wii_cfglist + '/* End XCConfigurationList section */')

with open(pbxproj_path, 'w') as f:
    f.write(content)

print("[OK] Wii system plugin added to main project successfully.")
PYEOF2

        python3 "$PYSCRIPT" "$MAIN_PBXPROJ"
        rm -f "$PYSCRIPT"
    fi
else
    echo "[ERROR] Main project file not found: $MAIN_PBXPROJ"
fi

echo ""
echo "=== Done ==="
echo "You can now open Xcode. The following projects should be available:"
echo "  - Dolphin/Dolphin.xcodeproj  (Dolphin core plugin)"
echo "  - Mame/MAME.xcodeproj        (MAME core plugin)"
echo "  - Wii system plugin           (added to main OpenEmu project)"
echo ""
echo "To build the cores, open each .xcodeproj and build, or use the main project's build scheme."
