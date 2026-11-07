"""Stage verified APK / explicitly unsigned IPA and a hash-bound release manifest."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile

from build_commands import ROOT, command
from check_ios_artifact import check_app

IOS_PAYLOAD = PurePosixPath("Payload/Runner.app")
EXECUTABLE_BITS = 0o111
ZIP_MODE_SHIFT = 16


def version():
    match = re.search(r"(?m)^version: (\d+\.\d+\.\d+)\+(\d+)\s*$", (ROOT / "pubspec.yaml").read_text())
    if not match:
        raise ValueError("Release requires an explicit semantic version and build number")
    tag = "v" + match[1]
    if os.environ.get("GITHUB_REF_TYPE") == "tag" and os.environ.get("GITHUB_REF_NAME") != tag:
        raise ValueError("Git tag must match pubspec.yaml")
    return tag, match[2]


def assets():
    path = ROOT / "build/release-assets"
    path.mkdir(parents=True, exist_ok=True)
    return path


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def record(platform, artifact, signing, **extra):
    snapshot = json.loads((ROOT / "build/reports/build-snapshot.json").read_text())
    report = {"tag": version()[0], "commit": os.environ.get("GITHUB_SHA"), "artifact": artifact.name,
              "sha256": sha256(artifact), "signing": signing, "snapshot": snapshot, **extra}
    (assets() / f"{platform}-build.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


def package_android():
    from build_android import environment
    tag, build_number = version()
    versions = json.loads((ROOT / "toolchains.json").read_text())
    tools_env, zipalign = environment(versions)
    source = ROOT / "build/app/outputs/flutter-apk/app-release.apk"
    signer = zipalign.with_name("apksigner.bat" if os.name == "nt" else "apksigner")
    certificate = subprocess.check_output(command([str(signer), "verify", "--verbose", "--print-certs", str(source)], tools_env),
                                          env=tools_env, text=True)
    if "CN=Android Debug" in certificate:
        raise ValueError("A debug certificate cannot sign a public release")
    digest = re.search(r"Signer #1 certificate SHA-256 digest: ([0-9a-fA-F]+)", certificate)
    if not digest:
        raise ValueError("APK signing certificate was not verified")
    aapt = zipalign.with_name("aapt.exe" if os.name == "nt" else "aapt")
    metadata = subprocess.check_output([str(aapt), "dump", "badging", str(source)], env=tools_env, text=True)
    if not re.search(r"package: name='dev\.waken\.bridge_mobile' versionCode='" + build_number
                     + r"' versionName='" + re.escape(tag[1:]) + "'", metadata):
        raise ValueError("APK identity/version does not match the release")
    artifact = assets() / f"bridge-mobile-{tag}-android.apk"
    shutil.copyfile(source, artifact)
    record("android", artifact, "release", certificate_sha256=digest[1].lower(),
           native_verification=json.loads((ROOT / "build/reports/android/app-release.apk.json").read_text()))
    print(f"Verified signed APK: {artifact.name}; certificate SHA256: {digest[1]}")


def write_ios_archive(source, artifact, execute):
    with tempfile.TemporaryDirectory(prefix="bridge-ipa-") as directory:
        payload = Path(directory) / "Payload"
        payload.mkdir()
        shutil.copytree(source, payload / "Runner.app", symlinks=True)
        # AppleDouble sidecars such as ._Runner.app are mistaken for apps by SideStore.
        execute(["ditto", "--norsrc", "--noextattr", "--noqtn", "--noacl",
                 "-c", "-k", "--keepParent", str(payload), str(artifact)], check=True)


def verify_ios_member(member):
    path = PurePosixPath(member.filename)
    if any(part.startswith("._") or part in ("__MACOSX", ".DS_Store") for part in path.parts):
        raise ValueError(f"IPA contains macOS metadata: {path}")
    if path.is_absolute() or ".." in path.parts:
        raise ValueError(f"Unsafe IPA archive entry: {path}")
    if path in (IOS_PAYLOAD.parent, IOS_PAYLOAD) and not member.is_dir():
        raise ValueError(f"IPA payload directory is a file: {path}")
    if path != IOS_PAYLOAD.parent and not path.is_relative_to(IOS_PAYLOAD):
        raise ValueError("IPA must contain only Payload/Runner.app")


def verify_ios_archive(artifact, executable):
    with zipfile.ZipFile(artifact) as archive:
        if archive.testzip() is not None:
            raise ValueError("IPA payload is corrupt")
        for member in archive.infolist():
            verify_ios_member(member)
        if str(IOS_PAYLOAD / "Info.plist") not in archive.namelist():
            raise ValueError("IPA payload is missing Info.plist")
        member = archive.getinfo(str(IOS_PAYLOAD / executable))
        if not (member.external_attr >> ZIP_MODE_SHIFT) & EXECUTABLE_BITS:
            raise ValueError("IPA lost executable permissions")


def package_ios():
    tag, build_number = version()
    source = ROOT / "build/ios/iphoneos/Runner.app"
    check_app(source, cloud=False)
    info = plistlib.loads((source / "Info.plist").read_bytes())
    if (info["CFBundleIdentifier"], info["CFBundleShortVersionString"], info["CFBundleVersion"]) != (
            "dev.waken.bridgeMobile", tag[1:], build_number):
        raise ValueError("iOS identity/version does not match the release")
    artifact = assets() / f"bridge-mobile-{tag}-ios-unsigned.ipa"
    write_ios_archive(source, artifact, subprocess.run)
    verify_ios_archive(artifact, info["CFBundleExecutable"])
    record("ios", artifact, "unsigned-requires-user-signing")
    print(f"Unsigned IPA for user signing: {artifact.name}")


def manifest():
    tag, _ = version()
    expected = {"android": (f"bridge-mobile-{tag}-android.apk", "release"),
                "ios": (f"bridge-mobile-{tag}-ios-unsigned.ipa", "unsigned-requires-user-signing")}
    for platform, (name, signing) in expected.items():
        report = json.loads((assets() / f"{platform}-build.json").read_text())
        if (report["tag"], report["commit"], report["artifact"], report["signing"], report["sha256"]) != (
                tag, os.environ.get("GITHUB_SHA"), name, signing, sha256(assets() / name)):
            raise ValueError(f"{platform} artifact does not match its release build")
    files = sorted(path for path in assets().iterdir() if path.name != "SHA256SUMS.txt")
    (assets() / "SHA256SUMS.txt").write_text("".join(f"{sha256(path)}  {path.name}\n" for path in files), encoding="utf-8")
    print(f"Release {tag}: both packages verified against commit {os.environ.get('GITHUB_SHA')}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("version", "ios", "manifest"))
    action = parser.parse_args().action
    if action == "version":
        print(version()[0])
    elif action == "ios":
        package_ios()
    else:
        manifest()
