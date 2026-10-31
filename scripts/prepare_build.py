"""Refresh stable SDKs and latest dependencies, then regenerate matching FFI."""

from functools import partial
import sys

from build_commands import ROOT, environment, run
from check_toolchains import bridge_version

FLUTTER = ["flutter", "--no-version-check", "--suppress-analytics"]


def refresh_sdks(execute):
    execute([*FLUTTER, "channel", "stable"])
    execute([*FLUTTER, "upgrade"])
    execute(["rustup", "update", "stable"])
    execute(["rustup", "component", "add", "--toolchain", "stable", "rustfmt", "clippy"])


def refresh_dependencies(root, execute):
    for directory in (root, root / "rust_builder"):
        execute([*FLUTTER, "pub", "upgrade"], cwd=directory)
    execute(["dart", "pub", "upgrade"], cwd=root / "rust_builder/cargokit/build_tool")
    for directory in ("rust", "rust_preview"):
        execute(["cargo", "+stable", "update", "--manifest-path", str(root / directory / "Cargo.toml")])


def prepare(root, execute):
    refresh_sdks(execute)
    refresh_dependencies(root, execute)
    version = bridge_version(root)
    execute(["cargo", "+stable", "install", "cargo-expand"])
    execute(["cargo", "+stable", "install", "flutter_rust_bridge_codegen", "--version", version])
    execute(["flutter_rust_bridge_codegen", "generate"], cwd=root)
    # FRB's formatter does not use the manifests' Rust 2024 import ordering.
    for directory in ("rust", "rust_preview"):
        execute(["cargo", "+stable", "fmt", "--manifest-path", str(root / directory / "Cargo.toml")])
    execute([sys.executable, str(root / "scripts/check_toolchains.py")])


def main():
    prepare(ROOT, partial(run, env=environment()))


if __name__ == "__main__":
    main()
