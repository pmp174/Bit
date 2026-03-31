#!/usr/bin/env python3
"""Modify OpenEmuKit project.pbxproj to add RetroAchievements files."""

pbxproj_path = "/Users/darbymartinez/Downloads/OpenEmuARM64-metal4-shaders-core-updates-master/OpenEmuKit/OpenEmuKit.xcodeproj/project.pbxproj"

with open(pbxproj_path, 'r') as f:
    content = f.read()

def mkid(n):
    return "000000000000AA{:010X}".format(n)

# === ID ASSIGNMENTS ===
FR_H   = mkid(1)   # OERetroAchievementsManager.h
FR_M   = mkid(2)   # OERetroAchievementsManager.m
BF_M   = mkid(38)  # OERetroAchievementsManager.m build file

fr_src_c = [
    ("rc_client.c", mkid(3)),
    ("rc_version.c", mkid(4)),
    ("rc_util.c", mkid(5)),
    ("rc_compat.c", mkid(6)),
    ("rc_libretro.c", mkid(7)),
    ("rc_client_external.c", mkid(8)),
    ("rc_client_raintegration.c", mkid(9)),
]
fr_rcheevos_c = [
    ("lboard.c", mkid(10)),
    ("runtime.c", mkid(11)),
    ("format.c", mkid(12)),
    ("rc_validate.c", mkid(13)),
    ("consoleinfo.c", mkid(14)),
    ("condset.c", mkid(15)),
    ("runtime_progress.c", mkid(16)),
    ("alloc.c", mkid(17)),
    ("condition.c", mkid(18)),
    ("trigger.c", mkid(19)),
    ("memref.c", mkid(20)),
    ("value.c", mkid(21)),
    ("operand.c", mkid(22)),
    ("richpresence.c", mkid(23)),
]
fr_rhash_c = [
    ("aes.c", mkid(24)),
    ("hash_zip.c", mkid(25)),
    ("hash_disc.c", mkid(26)),
    ("hash_encrypted.c", mkid(27)),
    ("hash.c", mkid(28)),
    ("cdreader.c", mkid(29)),
    ("md5.c", mkid(30)),
    ("hash_rom.c", mkid(31)),
]
fr_rurl_c = [
    ("url.c", mkid(32)),
]
fr_rapi_c = [
    ("rc_api_editor.c", mkid(33)),
    ("rc_api_common.c", mkid(34)),
    ("rc_api_user.c", mkid(35)),
    ("rc_api_runtime.c", mkid(36)),
    ("rc_api_info.c", mkid(37)),
]

all_c_files = fr_src_c + fr_rcheevos_c + fr_rhash_c + fr_rurl_c + fr_rapi_c
bf_c = {}
for i, (name, fr_id) in enumerate(all_c_files):
    bf_c[name] = mkid(39 + i)

GRP_RETROACHIEVEMENTS = mkid(74)
GRP_RCHEEVOS = mkid(75)
GRP_SRC = mkid(76)
GRP_RCHEEVOS_SUB = mkid(77)
GRP_RHASH = mkid(78)
GRP_RURL = mkid(79)
GRP_RAPI = mkid(80)

NL = '\n'

# ============================================================
# 1. Add PBXBuildFile entries
# ============================================================
bf_lines = []
bf_lines.append('\t\t{} /* OERetroAchievementsManager.m in Sources */ = {{isa = PBXBuildFile; fileRef = {} /* OERetroAchievementsManager.m */; }};'.format(BF_M, FR_M))
for name, fr_id in all_c_files:
    bf_id = bf_c[name]
    bf_lines.append('\t\t{} /* {} in Sources */ = {{isa = PBXBuildFile; fileRef = {} /* {} */; }};'.format(bf_id, name, fr_id, name))

bf_insert = NL.join(bf_lines) + NL
content = content.replace(
    '/* End PBXBuildFile section */',
    bf_insert + '/* End PBXBuildFile section */'
)

# ============================================================
# 2. Add PBXFileReference entries
# ============================================================
fr_lines = []
fr_lines.append('\t\t{} /* OERetroAchievementsManager.h */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = OERetroAchievementsManager.h; sourceTree = "<group>"; }};'.format(FR_H))
fr_lines.append('\t\t{} /* OERetroAchievementsManager.m */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; path = OERetroAchievementsManager.m; sourceTree = "<group>"; }};'.format(FR_M))
for name, fr_id in all_c_files:
    fr_lines.append('\t\t{} /* {} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.c; path = {}; sourceTree = "<group>"; }};'.format(fr_id, name, name))

fr_insert = NL.join(fr_lines) + NL
content = content.replace(
    '/* End PBXFileReference section */',
    fr_insert + '/* End PBXFileReference section */'
)

# ============================================================
# 3. Add PBXGroup entries
# ============================================================

def make_group(gid, name, children_lines, use_path=True):
    """Build a PBXGroup block."""
    lines = []
    lines.append('\t\t{} /* {} */ = {{'.format(gid, name))
    lines.append('\t\t\tisa = PBXGroup;')
    lines.append('\t\t\tchildren = (')
    for cl in children_lines:
        lines.append(cl)
    lines.append('\t\t\t);')
    if use_path:
        lines.append('\t\t\tpath = {};'.format(name))
    else:
        lines.append('\t\t\tname = {};'.format(name))
    lines.append('\t\t\tsourceTree = "<group>";')
    lines.append('\t\t};')
    return NL.join(lines)

# rapi group
rapi_children = ['\t\t\t\t{} /* {} */,'.format(fid, n) for n, fid in fr_rapi_c]
grp_rapi = make_group(GRP_RAPI, 'rapi', rapi_children)

# rurl group
rurl_children = ['\t\t\t\t{} /* {} */,'.format(fid, n) for n, fid in fr_rurl_c]
grp_rurl = make_group(GRP_RURL, 'rurl', rurl_children)

# rhash group
rhash_children = ['\t\t\t\t{} /* {} */,'.format(fid, n) for n, fid in fr_rhash_c]
grp_rhash = make_group(GRP_RHASH, 'rhash', rhash_children)

# rcheevos subdir group
rcheevos_sub_children = ['\t\t\t\t{} /* {} */,'.format(fid, n) for n, fid in fr_rcheevos_c]
grp_rcheevos_sub = make_group(GRP_RCHEEVOS_SUB, 'rcheevos', rcheevos_sub_children)

# src group
src_children = ['\t\t\t\t{} /* {} */,'.format(fid, n) for n, fid in fr_src_c]
src_children.append('\t\t\t\t{} /* rcheevos */,'.format(GRP_RCHEEVOS_SUB))
src_children.append('\t\t\t\t{} /* rhash */,'.format(GRP_RHASH))
src_children.append('\t\t\t\t{} /* rurl */,'.format(GRP_RURL))
src_children.append('\t\t\t\t{} /* rapi */,'.format(GRP_RAPI))
grp_src = make_group(GRP_SRC, 'src', src_children)

# rcheevos group
rcheevos_children = ['\t\t\t\t{} /* src */,'.format(GRP_SRC)]
grp_rcheevos = make_group(GRP_RCHEEVOS, 'rcheevos', rcheevos_children)

# RetroAchievements group
ra_children = [
    '\t\t\t\t{} /* OERetroAchievementsManager.h */,'.format(FR_H),
    '\t\t\t\t{} /* OERetroAchievementsManager.m */,'.format(FR_M),
    '\t\t\t\t{} /* rcheevos */,'.format(GRP_RCHEEVOS),
]
grp_ra = make_group(GRP_RETROACHIEVEMENTS, 'RetroAchievements', ra_children)

all_groups = NL.join([grp_rapi, grp_rurl, grp_rhash, grp_rcheevos_sub, grp_src, grp_rcheevos, grp_ra]) + NL

content = content.replace(
    '/* End PBXGroup section */',
    all_groups + '/* End PBXGroup section */'
)

# ============================================================
# 4. Add RetroAchievements group to Source group
# ============================================================
old_source_group = '''\t\t05E6959324CA5E1100ACFB35 /* Source */ = {
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t050A9A0E24F9B36400321847 /* Module */,
\t\t\t\t050A9A0A24F9B29300321847 /* OpenEmuKitPrivate */,
\t\t\t\t05E695C924CCD32900ACFB35 /* Classes */,'''

new_source_group = '''\t\t05E6959324CA5E1100ACFB35 /* Source */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t050A9A0E24F9B36400321847 /* Module */,
\t\t\t\t050A9A0A24F9B29300321847 /* OpenEmuKitPrivate */,
\t\t\t\t05E695C924CCD32900ACFB35 /* Classes */,
\t\t\t\t{} /* RetroAchievements */,'''.format(GRP_RETROACHIEVEMENTS)

content = content.replace(old_source_group, new_source_group)

# ============================================================
# 5. Add build file entries to PBXSourcesBuildPhase
# ============================================================
sources_lines = []
sources_lines.append('\t\t\t\t{} /* OERetroAchievementsManager.m in Sources */,'.format(BF_M))
for name, fr_id in all_c_files:
    bf_id = bf_c[name]
    sources_lines.append('\t\t\t\t{} /* {} in Sources */,'.format(bf_id, name))

sources_insert = NL.join(sources_lines)

old_sources_end = '\t\t\t\t0518D6E824F32DD10037101D /* NSEvent+Combine.swift in Sources */,\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n\t\t05EEF0F32707C96B008A03DC'
new_sources_end = '\t\t\t\t0518D6E824F32DD10037101D /* NSEvent+Combine.swift in Sources */,\n{}\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n\t\t05EEF0F32707C96B008A03DC'.format(sources_insert)

content = content.replace(old_sources_end, new_sources_end)

# ============================================================
# 6. Add HEADER_SEARCH_PATHS to build configurations
# ============================================================
header_search = '''\t\t\t\tHEADER_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"$(SRCROOT)/Source/RetroAchievements/rcheevos/include",
\t\t\t\t);'''

# Debug config
old_debug = '''\t\t05E6958824CA5D4200ACFB35 /* Debug */ = {
\t\t\tisa = XCBuildConfiguration;
\t\t\tbaseConfigurationReference = 050A9A0924F9B26C00321847 /* Config.xcconfig */;
\t\t\tbuildSettings = {
\t\t\t\tCLANG_ENABLE_MODULES = YES;'''

new_debug = '''\t\t05E6958824CA5D4200ACFB35 /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbaseConfigurationReference = 050A9A0924F9B26C00321847 /* Config.xcconfig */;
\t\t\tbuildSettings = {{
\t\t\t\tCLANG_ENABLE_MODULES = YES;
{}'''.format(header_search)

content = content.replace(old_debug, new_debug)

# Release config
old_release = '''\t\t05E6958924CA5D4200ACFB35 /* Release */ = {
\t\t\tisa = XCBuildConfiguration;
\t\t\tbaseConfigurationReference = 050A9A0924F9B26C00321847 /* Config.xcconfig */;
\t\t\tbuildSettings = {
\t\t\t\tCLANG_ENABLE_MODULES = YES;'''

new_release = '''\t\t05E6958924CA5D4200ACFB35 /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbaseConfigurationReference = 050A9A0924F9B26C00321847 /* Config.xcconfig */;
\t\t\tbuildSettings = {{
\t\t\t\tCLANG_ENABLE_MODULES = YES;
{}'''.format(header_search)

content = content.replace(old_release, new_release)

# Write the result
with open(pbxproj_path, 'w') as f:
    f.write(content)

print("SUCCESS: project.pbxproj has been updated with all RetroAchievements entries.")
print("  - Added {} PBXBuildFile entries".format(1 + len(all_c_files)))
print("  - Added {} PBXFileReference entries".format(2 + len(all_c_files)))
print("  - Added 7 PBXGroup entries")
print("  - Added RetroAchievements to Source group")
print("  - Added {} entries to PBXSourcesBuildPhase".format(1 + len(all_c_files)))
print("  - Added HEADER_SEARCH_PATHS to Debug and Release configs")
