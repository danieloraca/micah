use std::{env, path::PathBuf, process::Command};

fn main() {
    println!("cargo:rerun-if-changed=native/companion.m");
    println!("cargo:rerun-if-changed=native/keychain.m");
    assert_eq!(
        env::var("CARGO_CFG_TARGET_OS").unwrap(),
        "macos",
        "This MVP requires macOS"
    );
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let mut objects = Vec::new();
    for name in ["companion", "keychain"] {
        let object = out.join(format!("{name}.o"));
        let status = Command::new("/usr/bin/xcrun")
            .args([
                "clang",
                "-fobjc-arc",
                "-fblocks",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-Wno-unused-parameter",
                "-mmacosx-version-min=13.0",
                "-c",
            ])
            .arg(format!("native/{name}.m"))
            .args(["-o"])
            .arg(&object)
            .status()
            .expect("Apple Command Line Tools are required");
        assert!(status.success(), "Native UI compilation failed");
        objects.push(object);
    }
    let status = Command::new("/usr/bin/ar")
        .arg("rcs")
        .arg(out.join("libcompanion_ui.a"))
        .args(objects)
        .status()
        .unwrap();
    assert!(status.success(), "Native library archive failed");
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=companion_ui");
    for framework in [
        "AppKit",
        "AVFoundation",
        "Speech",
        "Foundation",
        "Security",
        "LocalAuthentication",
    ] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
}
