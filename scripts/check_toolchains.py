"""Fail closed when developer/CI tools drift from the reviewed baseline."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[1]


def output(*args):
    executable = shutil.which(args[0])
    if not executable:
        raise RuntimeError(f"Missing executable: {args[0]}")
    command = [executable, *args[1:]]
    if os.name == "nt" and executable.endswith((".bat", ".cmd")):
        command = [os.environ.get("COMSPEC", "cmd.exe"), "/c", *command]
    return subprocess.check_output(command, cwd=ROOT, text=True, encoding="utf-8")


def main():
    expected = json.loads((ROOT / "toolchains.json").read_text())
    flutter = json.loads(output("flutter", "--no-version-check", "--version", "--machine"))
    actual = {
        "flutter": flutter["frameworkVersion"],
        "dart": flutter["dartSdkVersion"].split()[0],
        "rust": output("rustc", "--version").split()[1],
        "flutter_rust_bridge": output("flutter_rust_bridge_codegen", "--version").split()[1],
    }
    failed = False
    for key, version in actual.items():
        ok = version == expected[key]
        print(f"{key}: {version}; expected {expected[key]} {'OK' if ok else 'MISMATCH'}")
        failed |= not ok
    cargo = output("cargo", "--version").split()[1]
    rust_pin = tomllib.loads((ROOT / "rust-toolchain.toml").read_text())["toolchain"]["channel"]
    flutter_pin = json.loads((ROOT / ".fvmrc").read_text())["flutter"]
    crate = tomllib.loads((ROOT / "rust/Cargo.toml").read_text())["dependencies"]["flutter_rust_bridge"]
    lock = tomllib.loads((ROOT / "rust/Cargo.lock").read_text())["package"]
    native_versions = {package["version"] for package in lock if package["name"] == "flutter_rust_bridge"}
    dart_pin = re.search(r"(?m)^  flutter_rust_bridge: (\S+)\s*$", (ROOT / "pubspec.yaml").read_text())
    bridge = expected["flutter_rust_bridge"]
    checks = {
        "Cargo matches Rust": cargo == expected["rust"],
        "rust-toolchain.toml": rust_pin == expected["rust"],
        ".fvmrc": flutter_pin == expected["flutter"],
        "FRB Rust dependency and lock": crate == f"={bridge}" and native_versions == {bridge},
        "FRB Dart dependency": dart_pin is not None and dart_pin.group(1) == bridge,
    }
    for label, ok in checks.items():
        print(f"{label}: {'OK' if ok else 'MISMATCH'}")
        failed |= not ok
    return int(failed)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError, ValueError) as error:
        print(f"Toolchain check failed: {error}", file=sys.stderr)
        sys.exit(1)
