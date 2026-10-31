"""Build with current stable SDKs and verify a signed IPA or an explicit compile gate."""

import argparse
from functools import partial
import hashlib
from pathlib import Path
import platform
import sys
import tempfile
import zipfile

from build_commands import ROOT, environment, run
from check_ios_artifact import check_app

EXPECTED_APP_COUNT = 1
EXPECTED_IPA_COUNT = 1
FLUTTER = ["flutter", "--no-version-check", "--suppress-analytics"]


def extract_archive(archive, destination):
    with zipfile.ZipFile(archive) as source:
        for member in source.infolist():
            if not (destination / member.filename).resolve().is_relative_to(destination):
                raise ValueError("Unsafe IPA archive entry")
            source.extract(member, destination)


def verify_ipa(artifact, execute, cloud):
    with tempfile.TemporaryDirectory(prefix="bridge-ipa-check-") as directory:
        destination = Path(directory).resolve()
        extract_archive(artifact, destination)
        apps = list((destination / "Payload").glob("*.app"))
        if len(apps) != EXPECTED_APP_COUNT:
            raise RuntimeError("The IPA must contain exactly one application")
        report = check_app(apps[0], cloud=cloud)
        execute(["codesign", "--verify", "--deep", "--strict", str(apps[0])])
    with artifact.open("rb") as stream:
        checksum = hashlib.file_digest(stream, "sha256").hexdigest()
    print(f"Signed IPA: {artifact}\nSHA-256: {checksum}\nBundle ID: {report['bundle_id']}", flush=True)


def build(args, execute):
    ipa_directory = ROOT / "build/ios/ipa"
    previous = {path: path.stat().st_mtime_ns for path in ipa_directory.glob("*.ipa")}
    execute([sys.executable, str(ROOT / "scripts/prepare_build.py")])
    execute(["pod", "update", f"--project-directory={ROOT / 'ios'}"])
    options = ["--release", *(["--flavor", args.flavor] if args.flavor else [])]
    if args.compile_only:
        execute([*FLUTTER, "build", "ios", *options, "--no-codesign"])
        app = ROOT / "build/ios/iphoneos/Runner.app"
        print(check_app(app, cloud=args.flavor == "cloud"))
        print("UNSIGNED compile gate only: no installable IPA, signing or device test.")
        return
    export = ["--export-options-plist", str(args.export_options_plist)] if args.export_options_plist else [
        "--export-method", args.export_method,
    ]
    execute([*FLUTTER, "build", "ipa", *options, *export])
    artifacts = [path for path in ipa_directory.glob("*.ipa")
                 if path.stat().st_mtime_ns != previous.get(path)]
    if len(artifacts) != EXPECTED_IPA_COUNT:
        raise RuntimeError("Flutter did not export a new IPA; inspect the archive/export errors")
    verify_ipa(artifacts[0], execute, args.flavor == "cloud")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flavor", choices=("cloud",))
    parser.add_argument("--compile-only", action="store_true", help="Explicit unsigned compilation, not an IPA")
    export = parser.add_mutually_exclusive_group()
    export.add_argument("--export-method", default="development", choices=("development", "ad-hoc", "app-store", "enterprise"))
    export.add_argument("--export-options-plist", type=Path)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        raise RuntimeError("iOS builds require macOS and a complete Xcode installation")
    build(args, partial(run, env=environment()))


if __name__ == "__main__":
    main()
