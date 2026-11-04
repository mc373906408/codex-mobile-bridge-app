"""Verify and fingerprint the reviewed dependency/generated-code snapshot without upgrading it."""

from functools import partial
import hashlib
import json

from build_commands import ROOT, environment, output, run
from check_toolchains import check


def manifest(root):
    names = ["toolchains.json", "pubspec.lock", "rust/Cargo.lock", "rust_preview/Cargo.lock",
             "ios/Podfile.lock", "rust/src/frb_generated.rs",
             "rust_builder/cargokit/build_tool/pubspec.lock"]
    names += [path.relative_to(root).as_posix() for path in (root / "lib/src/rust").rglob("*.dart")]
    return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in sorted(names)}


def main():
    env = environment()
    capture = partial(output, env=env)
    if check(ROOT, capture):
        raise RuntimeError("Build snapshot toolchains do not match; explicitly prepare and review updates first")
    before = manifest(ROOT)
    run(["flutter", "--no-version-check", "--suppress-analytics", "pub", "get", "--enforce-lockfile"], env=env)
    for name in ("rust", "rust_preview"):
        capture(["cargo", "+stable", "metadata", "--locked", "--no-deps", "--format-version", "1",
                 "--manifest-path", str(ROOT / name / "Cargo.toml")])
    if manifest(ROOT) != before:
        raise RuntimeError("Dependency or generated code changed during snapshot verification")
    report = ROOT / "build/reports/build-snapshot.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps({"source_files": before,
        "flutter": json.loads(capture(["flutter", "--no-version-check", "--version", "--machine"])),
        "rust": capture(["rustc", "+stable", "--version"]).strip()}, indent=2) + "\n", encoding="utf-8")
    print(f"Reviewed build snapshot: {report}")


if __name__ == "__main__":
    main()
