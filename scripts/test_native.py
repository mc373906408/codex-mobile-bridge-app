"""Build the real Rust library and exercise it through Flutter's generated FFI."""

from functools import partial
import json
import os
from pathlib import Path
import sys

from build_commands import environment, output, run

TEST_TIMEOUT_SECONDS = 60


def main():
    env = environment()
    execute = partial(run, env=env)
    execute(["cargo", "+stable", "build", "--manifest-path", "rust/Cargo.toml", "--locked"])
    metadata = json.loads(output(["cargo", "+stable", "metadata", "--manifest-path", "rust/Cargo.toml", "--format-version", "1", "--no-deps"], env=env))
    name = "bridge_native.dll" if os.name == "nt" else "libbridge_native.dylib" if sys.platform == "darwin" else "libbridge_native.so"
    library = Path(metadata["target_directory"]) / "debug" / name
    if not library.is_file():
        raise RuntimeError(f"Native build produced no library at {library}")
    execute(["flutter", "--no-version-check", "--suppress-analytics", "test", "test/native_bridge_test.dart",
             f"--dart-define=BRIDGE_NATIVE_LIB={library.as_posix()}"], timeout=TEST_TIMEOUT_SECONDS)


if __name__ == "__main__":
    main()
