"""Compile/test SDK-free and opt-in push source sets with nonfunctional fixtures."""

import json
import os
from pathlib import Path
import subprocess

from build_android import command, environment

ROOT = Path(__file__).resolve().parents[1]


def main():
    versions = json.loads((ROOT / "toolchains.json").read_text(encoding="utf-8"))
    env, _ = environment(versions)
    # CI never reads distribution credentials or contacts a live push endpoint.
    for key in (
        "BRIDGE_ANDROID_PUSH", "UMENG_PRODUCTION_APP_KEY", "UMENG_PRODUCTION_MESSAGE_SECRET",
        "UMENG_PRODUCTION_CHANNEL", "UMENG_PUSH_APP_KEY", "UMENG_PUSH_MESSAGE_SECRET",
        "UMENG_PUSH_CHANNEL", "BRIDGE_KEYSTORE_PATH", "BRIDGE_KEYSTORE_PASSWORD",
        "BRIDGE_KEY_ALIAS", "BRIDGE_KEY_PASSWORD",
    ):
        env.pop(key, None)
    gradle = command(str(ROOT / "android/gradlew.bat")) if os.name == "nt" else ["sh", "./gradlew"]

    def run(*tasks):
        subprocess.run(
            [*gradle, *tasks, "-Ptarget-platform=android-arm64", "--no-daemon", "--console=plain"],
            cwd=ROOT / "android", env=env, check=True,
        )

    run(":app:testDebugUnitTest", ":app:compileReleaseKotlin", ":app:processReleaseManifest")
    env.update(
        BRIDGE_ANDROID_PUSH="umeng", UMENG_PRODUCTION_APP_KEY="local-build-fixture-only",
        UMENG_PRODUCTION_MESSAGE_SECRET="local-build-fixture-only",
    )
    run(":app:compileReleaseKotlin", ":app:compileProfileKotlin", ":app:processReleaseManifest")
    print("Android default/opt-in compilation and debug unit tests passed; no vendor or device test ran.")


if __name__ == "__main__":
    main()
