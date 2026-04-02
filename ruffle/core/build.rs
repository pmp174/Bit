fn main() {
    let out_dir: std::path::PathBuf = std::env::var("OUT_DIR").unwrap().into();

    // Try the normal build first. If it fails (e.g. Java not installed),
    // fall back to a previously built playerglobal.swf + native_table.rs.
    let result = build_playerglobal::build_playerglobal(
        "../".into(),
        out_dir.clone(),
        cfg!(feature = "known_stubs"),
    );

    if let Err(e) = result {
        eprintln!("Warning: build_playerglobal failed: {e}");
        eprintln!("Attempting to use pre-built playerglobal artifacts...");

        // Search for a previous build's output directory
        let target_dir = std::path::Path::new("../target");
        let mut found = false;

        if target_dir.exists() {
            for profile in &["release", "debug"] {
                let build_dir = target_dir.join(profile).join("build");
                if !build_dir.exists() {
                    continue;
                }
                if let Ok(entries) = std::fs::read_dir(&build_dir) {
                    for entry in entries.flatten() {
                        let name = entry.file_name();
                        let name_str = name.to_string_lossy();
                        if name_str.starts_with("ruffle_core-") {
                            let candidate = entry.path().join("out");
                            let swf = candidate.join("playerglobal.swf");
                            let table = candidate.join("native_table.rs");
                            if swf.exists() && table.exists() {
                                let dst_swf = out_dir.join("playerglobal.swf");
                                let dst_table = out_dir.join("native_table.rs");
                                // Only copy if destination differs or doesn't exist
                                if !dst_swf.exists() || swf != dst_swf {
                                    std::fs::copy(&swf, &dst_swf)
                                        .expect("Failed to copy playerglobal.swf");
                                }
                                if !dst_table.exists() || table != dst_table {
                                    std::fs::copy(&table, &dst_table)
                                        .expect("Failed to copy native_table.rs");
                                }
                                // Also copy actionscript_stubs.rs if it exists
                                let stubs = candidate.join("actionscript_stubs.rs");
                                if stubs.exists() {
                                    let dst_stubs = out_dir.join("actionscript_stubs.rs");
                                    if !dst_stubs.exists() {
                                        let _ = std::fs::copy(&stubs, &dst_stubs);
                                    }
                                }
                                eprintln!("Using pre-built artifacts from {}", candidate.display());
                                found = true;
                                break;
                            }
                        }
                    }
                }
                if found {
                    break;
                }
            }
        }

        if !found {
            panic!("Failed to build playerglobal: {e}\nNo pre-built artifacts found either. Please install Java or run a full build first.");
        }
    }

    // This is overly conservative - it will cause us to rebuild playerglobal.swf
    // if *any* files in this directory change, not just .as files.
    // However, this script is fast to run, so it shouldn't matter in practice.
    // If Cargo ever adds glob support to 'rerun-if-changed', we should use it.
    println!("cargo:rerun-if-changed=src/avm2/globals/");
}
