"""Build the real Rust library and exercise it through Flutter's generated FFI."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def command(*args):
    executable = shutil.which(args[0])
    if not executable:
        raise RuntimeError(f"Missing tool: {args[0]}")
    result = [executable, *args[1:]]
    if os.name == "nt" and executable.endswith((".bat", ".cmd")):
        result = [os.environ.get("COMSPEC", "cmd.exe"), "/d", "/c", *result]
    return result


def main():
    subprocess.run(command("cargo", "build", "--manifest-path", "rust/Cargo.toml", "--locked"), cwd=ROOT, check=True)
    metadata = json.loads(subprocess.check_output(command("cargo", "metadata", "--manifest-path", "rust/Cargo.toml", "--format-version", "1", "--no-deps"), cwd=ROOT, text=True))
    name = "bridge_native.dll" if os.name == "nt" else "libbridge_native.dylib" if sys.platform == "darwin" else "libbridge_native.so"
    library = Path(metadata["target_directory"]) / "debug" / name
    if not library.is_file():
        raise RuntimeError(f"Native build produced no library at {library}")
    subprocess.run(command("flutter", "--no-version-check", "--suppress-analytics", "test", "test/native_bridge_test.dart",
                           f"--dart-define=BRIDGE_NATIVE_LIB={library.as_posix()}"), cwd=ROOT, check=True)


if __name__ == "__main__":
    main()
