//! Embeds the application manifest into the main executable on MSVC targets.
fn main() {
    println!("cargo:rerun-if-changed=app.manifest");
    let target = std::env::var("TARGET").unwrap_or_default();
    if target.ends_with("windows-msvc") {
        let manifest = std::path::Path::new(&std::env::var("CARGO_MANIFEST_DIR").unwrap())
            .join("app.manifest");
        println!("cargo:rustc-link-arg-bins=/MANIFEST:EMBED");
        println!(
            "cargo:rustc-link-arg-bins=/MANIFESTINPUT:{}",
            manifest.display()
        );
        println!("cargo:rustc-link-arg-bins=/MANIFESTUAC:NO");
    }
}
