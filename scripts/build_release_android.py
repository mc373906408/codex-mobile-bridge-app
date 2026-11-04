"""Build ordinary CI packages, requiring a persistent release key when publishing."""

import base64
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from build_commands import ROOT
from package_release import package_android


SIGNING = ("BRIDGE_KEYSTORE_BASE64", "BRIDGE_KEYSTORE_PASSWORD", "BRIDGE_KEY_ALIAS", "BRIDGE_KEY_PASSWORD")


def build(env, execute=subprocess.run):
    publish = env.get("BRIDGE_PUBLISH") == "true"
    if publish and any(not env.get(name) for name in SIGNING):
        raise RuntimeError("Publishing requires all four BRIDGE signing secrets; unsigned/debug APKs are not released")
    build_env = {key: value for key, value in env.items() if key not in SIGNING}
    build_env.pop("BRIDGE_KEYSTORE_PATH", None)
    with tempfile.TemporaryDirectory(prefix="bridge-release-key-") as directory:
        if publish:
            key = Path(directory) / "release.jks"
            key.write_bytes(base64.b64decode(env["BRIDGE_KEYSTORE_BASE64"], validate=True))
            build_env.update({name: env[name] for name in SIGNING[1:]})
            build_env["BRIDGE_KEYSTORE_PATH"] = str(key)
        execute([sys.executable, "scripts/build_android.py"], cwd=ROOT, env=build_env, check=True)
        if publish:
            package_android()


if __name__ == "__main__":
    build(dict(os.environ))
