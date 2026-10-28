"""Build Android artifacts with isolated tools and verify their native packaging."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from urllib.parse import urlparse

from bootstrap_android import download

ROOT = Path(__file__).resolve().parents[1]
ABI_TARGETS = {"armeabi-v7a": "android-arm", "arm64-v8a": "android-arm64", "x86_64": "android-x64"}


def command(*args):
    executable = shutil.which(args[0])
    if not executable:
        raise RuntimeError(f"Missing tool on PATH: {args[0]}")
    result = [executable, *args[1:]]
    if os.name == "nt" and executable.endswith((".bat", ".cmd")):
        result = [os.environ.get("COMSPEC", "cmd.exe"), "/d", "/c", *result]
    return result


def environment(versions):
    env = dict(os.environ)
    marker = ROOT / ".local/android-env.json"
    if marker.exists():
        local = json.loads(marker.read_text(encoding="utf-8"))
        if not local.get("verified"):
            raise RuntimeError("Run scripts/bootstrap_android.py again: the local SDK is not verified")
        env.update(JAVA_HOME=local["java_home"], ANDROID_HOME=local["android_home"], ANDROID_SDK_ROOT=local["android_home"])
    sdk = env.get("ANDROID_HOME") or env.get("ANDROID_SDK_ROOT")
    java = env.get("JAVA_HOME")
    if not sdk or not java:
        raise RuntimeError("Set ANDROID_HOME and JAVA_HOME, or run scripts/bootstrap_android.py on Windows")
    sdk = Path(sdk)
    env.update(ANDROID_HOME=str(sdk), ANDROID_SDK_ROOT=str(sdk))
    suffix = ".exe" if os.name == "nt" else ""
    zipalign = sdk / f"build-tools/{versions['android_build_tools']}/zipalign{suffix}"
    for file in (zipalign, sdk / f"platforms/android-{versions['android_compile_sdk']}/android.jar",
                 sdk / f"ndk/{versions['android_ndk']}/source.properties", Path(java) / f"bin/java{suffix}"):
        if not file.is_file():
            raise RuntimeError(f"Missing Android build component: {file}")
    env["PATH"] = os.pathsep.join([str(Path(java) / "bin"), str(sdk / "platform-tools"), env["PATH"]])
    temporary = ROOT / ".tmp"
    temporary.mkdir(exist_ok=True)
    options = [f'-Djdk.net.unixdomain.tmpdir="{temporary.as_posix()}"', "-Djava.net.preferIPv4Stack=true"]
    proxy = urlparse(env.get("HTTPS_PROXY", env.get("HTTP_PROXY", "")))
    if proxy.hostname:
        if proxy.scheme != "http" or proxy.username or proxy.password:
            raise RuntimeError("Java build tools require an unauthenticated HTTP proxy")
        for protocol in ("http", "https"):
            options.extend([f"-D{protocol}.proxyHost={proxy.hostname}", f"-D{protocol}.proxyPort={proxy.port or 80}"])
        options.append("-Dhttp.nonProxyHosts=localhost|127.*")
    env["JAVA_TOOL_OPTIONS"] = " ".join([env.get("JAVA_TOOL_OPTIONS", ""), *options]).strip()
    return env, zipalign


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--format", choices=("apk", "aab", "both"), default="both")
    parser.add_argument("--debug", action="store_true", help="Build a debug APK, never a distribution artifact")
    parser.add_argument("--abi", action="append", choices=ABI_TARGETS, help="Default: all three supported ABIs")
    args = parser.parse_args()
    if args.debug and args.format != "apk":
        parser.error("--debug requires --format apk")
    versions = json.loads((ROOT / "toolchains.json").read_text(encoding="utf-8"))
    env, zipalign = environment(versions)
    abis = args.abi or list(ABI_TARGETS)
    mode = "debug" if args.debug else "release"
    subprocess.run([sys.executable, "scripts/check_toolchains.py"], cwd=ROOT, env=env, check=True)
    subprocess.run(command("flutter", "--no-version-check", "--suppress-analytics", "pub", "get", "--enforce-lockfile"),
                   cwd=ROOT, env=env, check=True)
    for kind in (("apk", "aab") if args.format == "both" else (args.format,)):
        target = "apk" if kind == "apk" else "appbundle"
        subprocess.run(command("flutter", "--no-version-check", "--suppress-analytics", "build", target,
                               f"--{mode}", "--target-platform=" + ",".join(ABI_TARGETS[abi] for abi in abis)),
                       cwd=ROOT, env=env, check=True)
        artifact = ROOT / (f"build/app/outputs/flutter-apk/app-{mode}.apk" if kind == "apk"
                           else "build/app/outputs/bundle/release/app-release.aab")
        if not artifact.is_file():
            raise RuntimeError(f"Flutter reported success without producing {artifact}")
        report = ROOT / f"build/reports/android/{artifact.name}.json"
        verify = [sys.executable, "scripts/check_android_artifact.py", str(artifact), "--json", str(report)]
        for abi in abis:
            verify.extend(["--expect-abi", abi])
        if not args.debug:
            verify.append("--release")
        if kind == "apk":
            verify.extend(["--zipalign", str(zipalign)])
        else:
            verify.extend(["--bundletool", str(download(versions["bundletool"]))])
        subprocess.run(verify, cwd=ROOT, env=env, check=True)
        print(f"Artifact: {artifact}\nVerification: {report}", flush=True)
    if args.debug:
        print("DEBUG signature only; do not distribute as a release.")
    elif not os.environ.get("BRIDGE_KEYSTORE_PATH"):
        print("UNSIGNED release build. Supply the four BRIDGE signing variables for distribution.")
    print("Device tests and store approval are separate, still-required release gates.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Android build failed: {error}", file=sys.stderr)
        sys.exit(1)
