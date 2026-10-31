"""Verify stable SDK selection and matching Dart/Rust/generated FFI versions."""

from functools import partial
import json
import re
import subprocess
import sys
import tomllib

from build_commands import ROOT, environment, output


def bridge_version(root):
    packages = tomllib.loads((root / "rust/Cargo.lock").read_text())["package"]
    native = {package["version"] for package in packages if package["name"] == "flutter_rust_bridge"}
    text = (root / "pubspec.lock").read_text()
    block = re.search(r"(?m)^  flutter_rust_bridge:\n((?: {4,}[^\n]*\n)+)", text)
    version = re.search(r'^    version: "([^"]+)"$', block[1], re.MULTILINE) if block else None
    if version is None or native != {version[1]}:
        raise RuntimeError("Dart and Rust must resolve the same flutter_rust_bridge release")
    return version[1]


def check(root, capture):
    policy = json.loads((root / "toolchains.json").read_text())
    flutter = json.loads(capture(["flutter", "--no-version-check", "--version", "--machine"]))
    actual = {
        "flutter": flutter["frameworkVersion"],
        "dart": flutter["dartSdkVersion"].split()[0],
        "rust": capture(["rustc", "+stable", "--version"]).split()[1],
        "cargo": capture(["cargo", "+stable", "--version"]).split()[1],
        "flutter_rust_bridge": bridge_version(root),
        "codegen": capture(["flutter_rust_bridge_codegen", "--version"]).split()[1],
    }
    for key, version in actual.items():
        print(f"{key}: {version}")
    channel = tomllib.loads((root / "rust-toolchain.toml").read_text())["toolchain"]["channel"]
    flutter_channel = json.loads((root / ".fvmrc").read_text())["flutter"]
    crate = tomllib.loads((root / "rust/Cargo.toml").read_text())["dependencies"]["flutter_rust_bridge"]
    dart = re.search(r"(?m)^  flutter_rust_bridge: (\S+)\s*$", (root / "pubspec.yaml").read_text())
    checks = {
        "Stable Flutter channel": flutter["channel"] == flutter_channel == policy["flutter"] == "stable",
        "Bundled Dart SDK": policy["dart"] == "bundled",
        "Stable Rust channel": channel == policy["rust"] == "stable" and "-" not in actual["rust"],
        "Cargo matches Rust": actual["cargo"] == actual["rust"],
        "Latest FRB dependency policy": policy["flutter_rust_bridge"] == "latest" and crate == "*"
        and dart is not None and dart[1] == "any",
        "Matching FFI generator": actual["codegen"] == actual["flutter_rust_bridge"],
    }
    for label, ok in checks.items():
        print(f"{label}: {'OK' if ok else 'MISMATCH'}")
    return int(not all(checks.values()))


def main():
    return check(ROOT, partial(output, env=environment()))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError, ValueError) as error:
        print(f"Toolchain check failed: {error}", file=sys.stderr)
        sys.exit(1)
