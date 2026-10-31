"""Xcode NSE-only build phase for the offline, preview-only Rust static library."""

import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
TARGETS = {
    "iphoneos": {"arm64": "aarch64-apple-ios"},
    "iphonesimulator": {"arm64": "aarch64-apple-ios-sim", "x86_64": "x86_64-apple-ios"},
}


def rust_targets(platform, architectures):
    if platform not in TARGETS or not architectures:
        raise ValueError("Preview build requires an iOS device or simulator platform and explicit ARCHS")
    try:
        return [TARGETS[platform][arch] for arch in dict.fromkeys(architectures)]
    except KeyError as exc:
        raise ValueError("Unsupported iOS preview architecture") from exc


def toolchain():
    cargo = shutil.which("cargo") or str(Path.home() / ".cargo/bin/cargo")
    rustc = shutil.which("rustc") or str(Path.home() / ".cargo/bin/rustc")
    pin = json.loads((ROOT / "toolchains.json").read_text(encoding="utf-8"))["rust"]
    for executable in (cargo, rustc):
        version = subprocess.check_output([executable, "--version"], cwd=ROOT, text=True).split()
        if len(version) < 2 or version[1] != pin:
            raise SystemExit("Use the repository-pinned Rust toolchain before building the extension")
    return cargo, rustc


def main():
    if os.environ.get("TARGET_NAME") != "BridgeNotificationService":
        raise SystemExit("The preview build phase belongs only to BridgeNotificationService")
    configuration = os.environ.get("CONFIGURATION", "")
    if configuration not in {"Debug-cloud", "Profile-cloud", "Release-cloud"}:
        raise SystemExit("The preview build requires a cloud configuration")
    try:
        targets = rust_targets(os.environ.get("PLATFORM_NAME"), os.environ.get("ARCHS", "").split())
    except ValueError as exc:
        raise SystemExit("Unsupported iOS preview architecture") from exc
    products = Path(os.environ["BUILT_PRODUCTS_DIR"])
    if not products.is_absolute():
        raise SystemExit("Invalid Xcode products directory")
    products = products.resolve()
    if products == Path(products.anchor):
        raise SystemExit("Invalid Xcode products directory")
    output = products / "bridge-preview"
    output.mkdir(parents=True, exist_ok=True)
    cargo, _ = toolchain()
    debug = configuration == "Debug-cloud"
    mode = "debug" if debug else "release"
    libraries = []
    for target in targets:
        subprocess.run([
            cargo, "build", "--locked", "--manifest-path", str(ROOT / "rust_preview/Cargo.toml"),
            "--target", target, "--target-dir", str(output / "cargo"), "--lib",
            *([] if debug else ["--release"]),
        ], cwd=ROOT, check=True)
        libraries.append(output / "cargo" / target / mode / "libbridge_preview.a")
    temporary = output / f".libbridge_preview-{os.getpid()}.a"
    try:
        subprocess.run(["xcrun", "lipo", "-create", *map(str, libraries), "-output", str(temporary)], check=True)
        os.replace(temporary, output / "libbridge_preview.a")
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
