use std::{env, path::PathBuf};

fn main() {
    let library_dir = env::var_os("TUI_LIBRARY_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("../../zig-out/lib"));
    println!("cargo:rustc-link-search=native={}", library_dir.display());
    println!("cargo:rustc-link-lib=dylib=tui");
    println!("cargo:rerun-if-env-changed=TUI_LIBRARY_DIR");
}
