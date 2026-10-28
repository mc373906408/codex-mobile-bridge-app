"""Run the packaged native/secure-store test on an explicitly selected Android device."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

from build_android import command, environment

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="An adb serial; never auto-select a personal device")
    parser.add_argument("--page-size", type=int, choices=(4096, 16384), default=16384)
    args = parser.parse_args()
    versions = json.loads((ROOT / "toolchains.json").read_text(encoding="utf-8"))
    env, _ = environment(versions)
    adb = Path(env["ANDROID_HOME"]) / "platform-tools" / ("adb.exe" if sys.platform == "win32" else "adb")

    def shell(*values):
        return subprocess.check_output([str(adb), "-s", args.device, "shell", *values],
                                       env=env, text=True, encoding="utf-8", timeout=20).strip()

    if shell("getprop", "sys.boot_completed") != "1":
        raise RuntimeError("The selected device has not finished booting")
    size = int(shell("getconf", "PAGE_SIZE"))
    if size != args.page_size:
        raise RuntimeError(f"Expected {args.page_size}-byte pages; selected device reports {size}")
    report = {
        "device": args.device,
        "kind": "emulator" if shell("getprop", "ro.kernel.qemu") == "1" else "physical",
        "android_release": shell("getprop", "ro.build.version.release"),
        "abi": shell("getprop", "ro.product.cpu.abi"),
        "page_size": size,
        "google_play_services_enabled": "package:com.google.android.gms" in shell("pm", "list", "packages", "-e", "com.google.android.gms"),
        "test": "integration_test/native_startup_test.dart",
        "gateway": "synthetic_loopback_only",
        "checks": ["packaged_rust", "os_secure_storage", "sqlite", "untrusted_tls_rejected", "no_write_replay"],
    }
    print(json.dumps(report, indent=2), flush=True)
    subprocess.run(command("flutter", "--no-version-check", "--suppress-analytics", "test",
                           report["test"], "-d", args.device), cwd=ROOT, env=env, check=True)
    artifact = ROOT / "build/app/outputs/flutter-apk/app-debug.apk"
    with artifact.open("rb") as stream:
        report["apk_sha256"] = hashlib.file_digest(stream, "sha256").hexdigest()
    report["status"] = "passed"
    report["release_artifact_test"] = "not_performed"
    target = ROOT / "build/reports/android/native-device-test.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"Native device test passed: {target}")
    print("This tests a debug integration APK, not the final signed release or a real gateway.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"Android device test failed: {error}", file=sys.stderr)
        sys.exit(1)
