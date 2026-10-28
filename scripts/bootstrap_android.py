"""Install isolated Android/JDK build tools, with verified upstream archives."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import urllib.request
from urllib.parse import unquote, urlparse
import zipfile

ROOT = Path(__file__).resolve().parents[1]
LOCAL = ROOT / ".local"


def fetch(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "BridgeMobile-build-setup"}), timeout=90)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def download(package):
    url, expected = package["url"], package["sha256"]
    name = unquote(urlparse(url).path.rsplit("/", 1)[-1])
    folder = LOCAL / "downloads"
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / name
    if target.exists() and digest(target) == expected:
        return target
    print(f"Downloading {name}", flush=True)
    partial = target.with_name(target.name + ".part")
    with fetch(url) as response, partial.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            output.write(chunk)
    actual = digest(partial)
    if actual != expected:
        raise RuntimeError(f"Checksum mismatch for {name}")
    partial.replace(target)
    print(f"Verified SHA-256: {actual}", flush=True)
    return target


def extract_without_root(archive, destination):
    destination = destination.resolve()
    if not destination.is_relative_to(LOCAL.resolve()):
        raise RuntimeError("Extraction must remain in this project's .local directory")
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as source:
        for member in source.infolist():
            parts = Path(member.filename).parts
            if len(parts) < 2:
                continue
            target = destination.joinpath(*parts[1:]).resolve()
            if not target.is_relative_to(destination):
                raise RuntimeError("Unsafe archive entry")
            if member.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.open(member) as src, target.open("wb") as dst:
                    while chunk := src.read(1024 * 1024):
                        dst.write(chunk)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--accept-licenses", action="store_true", help="Accept the Android SDK licenses for this installation")
    parser.add_argument("--with-emulator", action="store_true", help="Also install the pinned 16 KB test image and emulator")
    args = parser.parse_args()
    if os.name != "nt":
        raise RuntimeError("This bootstrap is for Windows; CI uses setup-java/setup-android")
    versions = json.loads((ROOT / "toolchains.json").read_text(encoding="utf-8"))
    sdk = LOCAL / "android-sdk"
    jdk = LOCAL / "jdk-21"
    if not (jdk / "bin/java.exe").exists():
        extract_without_root(download(versions["windows_bootstrap"]["jdk"]), jdk)
    if f'SEMANTIC_VERSION="{versions["java"]}"' not in (jdk / "release").read_text():
        raise RuntimeError("Existing isolated JDK does not match toolchains.json; refusing to replace it")
    manager = sdk / "cmdline-tools/latest/bin/android.exe"
    if not manager.exists():
        extract_without_root(download(versions["windows_bootstrap"]["android_tools"]), sdk / "cmdline-tools/latest")
    if f'Pkg.Revision={versions["android_command_line_tools"]}' not in (manager.parent.parent / "source.properties").read_text().splitlines():
        raise RuntimeError("Existing Android command-line tools do not match toolchains.json")
    env = dict(os.environ, JAVA_HOME=str(jdk), ANDROID_HOME=str(sdk), ANDROID_SDK_ROOT=str(sdk))
    env["PATH"] = str(jdk / "bin") + os.pathsep + env["PATH"]
    temporary = ROOT / ".tmp"
    temporary.mkdir(exist_ok=True)
    # Windows usernames/temp paths can exceed Java's Unix-domain socket limit.
    options = [f'-Djdk.net.unixdomain.tmpdir="{temporary.as_posix()}"', "-Djava.net.preferIPv4Stack=true"]
    proxy = urlparse(env.get("HTTPS_PROXY", env.get("HTTP_PROXY", "")))
    if proxy.hostname:
        if proxy.scheme != "http" or proxy.username or proxy.password:
            raise RuntimeError("Use an unauthenticated local HTTP proxy for the Java build tools")
        for protocol in ("http", "https"):
            options.extend([f"-D{protocol}.proxyHost={proxy.hostname}", f"-D{protocol}.proxyPort={proxy.port or 80}"])
        options.append("-Dhttp.nonProxyHosts=localhost|127.*")
    env["JAVA_TOOL_OPTIONS"] = " ".join([env.get("JAVA_TOOL_OPTIONS", ""), *options]).strip()
    command = [str(manager), "--no-metrics", f"--sdk={sdk}", "sdk", "install"]
    if args.accept_licenses:
        print("Android CLI 23 manages licenses during installation; the deprecated --licenses wrapper is not used.", flush=True)
    packages = [
        (f'platform-tools@{versions["android_platform_tools"]}', "platform-tools/adb.exe"),
        (f'platforms/android-{versions["android_compile_sdk"]}@{versions["android_platform_revision"]}', f'platforms/android-{versions["android_compile_sdk"]}/android.jar'),
        (f'build-tools/{versions["android_build_tools"]}', f'build-tools/{versions["android_build_tools"]}/zipalign.exe'),
        (f'ndk/{versions["android_ndk"]}', f'ndk/{versions["android_ndk"]}/toolchains/llvm/prebuilt/windows-x86_64/bin/clang.exe'),
        (f'cmake/{versions["android_cmake"]}', f'cmake/{versions["android_cmake"]}/bin/cmake.exe'),
    ]
    packages.extend((f"platforms/android-{api}@{revision}", f"platforms/android-{api}/android.jar")
                    for api, revision in versions.get("android_plugin_platforms", {}).items())
    if args.with_emulator:
        packages.extend([
            (f'emulator@{versions["android_emulator"]}', "emulator/emulator.exe"),
            (versions["android_test_image"], versions["android_test_image"].split("@")[0] + "/system.img"),
        ])
    # Call the executable directly: cmd.exe splits unquoted semicolon package IDs.
    for package, expected_file in packages:
        print(f"Installing {package}", flush=True)
        # The CLI emits thousands of progress lines even with redirected output.
        log = temporary / (package.replace("/", "-").replace("@", "-") + ".log")
        with log.open("w", encoding="utf-8") as output:
            result = subprocess.run([*command, package], stdin=subprocess.DEVNULL,
                                    stdout=output, stderr=subprocess.STDOUT, env=env)
        if result.returncode:
            raise RuntimeError(f"Installing {package} failed; inspect {log}")
        if not (sdk / expected_file).is_file():
            raise RuntimeError(f"SDK command completed without installing {expected_file}")
        print(f"Verified {expected_file}", flush=True)
    state = {"java_home": str(jdk), "android_home": str(sdk), "ndk": versions["android_ndk"], "verified": True}
    (LOCAL / "android-env.json").write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(state, indent=2), flush=True)


if __name__ == "__main__":
    main()
