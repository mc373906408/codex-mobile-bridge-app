"""Run ordinary Swift policy tests and the real preview-only Swift/Rust C ABI tests."""

from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

from build_ios_preview import ROOT, toolchain


def main():
    if platform.system() != "Darwin":
        raise SystemExit("iOS cloud native tests require macOS; this check cannot be skipped as passing")
    swift = shutil.which("swift")
    if not swift:
        raise SystemExit("iOS cloud native tests require Swift from the selected Xcode toolchain")
    cargo, rustc = toolchain()
    version = subprocess.check_output([rustc, "-vV"], cwd=ROOT, text=True)
    hosts = [line.removeprefix("host: ").strip() for line in version.splitlines() if line.startswith("host: ")]
    if len(hosts) != 1 or hosts[0] not in {"aarch64-apple-darwin", "x86_64-apple-darwin"}:
        raise SystemExit("The preview test library must use a macOS Rust host target")
    host = hosts[0]

    with tempfile.TemporaryDirectory(prefix="bridge-ios-cloud-") as directory:
        scratch = Path(directory)
        base = [swift, "test", "--package-path", str(ROOT / "ios")]
        subprocess.run([*base, "--scratch-path", str(scratch / "ordinary")], cwd=ROOT, check=True)
        subprocess.run([
            cargo, "build", "--locked", "--manifest-path", str(ROOT / "rust_preview/Cargo.toml"),
            "--target", host, "--target-dir", str(scratch / "cargo"), "--lib",
        ], cwd=ROOT, check=True)

        # Cargo also emits a dylib; expose only the archive to Swift's autolinker.
        libraries = scratch / "static"
        libraries.mkdir()
        shutil.copyfile(scratch / "cargo" / host / "debug/libbridge_preview.a",
                        libraries / "libbridge_preview.a")
        subprocess.run([
            *base, "--scratch-path", str(scratch / "native"),
            "-Xswiftc", "-DBRIDGE_CLOUD_PUSH",
            "-Xswiftc", f"-I{ROOT / 'ios/CloudPreviewFFI'}",
            "-Xlinker", f"-L{libraries}", "-Xlinker", "-liconv",
        ], cwd=ROOT, check=True)
    print("Ordinary Swift policy and native Swift/Rust preview tests passed; no Xcode archive or device push ran.")


if __name__ == "__main__":
    main()
