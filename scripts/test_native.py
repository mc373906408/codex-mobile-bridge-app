"""Build the real Rust library and exercise it through Flutter's generated FFI."""

from functools import partial
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from build_commands import ROOT, environment, output, run

TEST_TIMEOUT_SECONDS = 60
PROCESS_TIMEOUT_SECONDS = 300
PREPARE_TIMEOUT_SECONDS = 300
BUILD_TIMEOUT_SECONDS = 1200
FLUTTER = ["flutter", "--no-version-check", "--suppress-analytics"]


def phase(name, arguments, execute, report, phases, timeout):
    started = time.monotonic()
    record = {"phase": name, "status": "running", "timeout_seconds": timeout}
    phases.append(record)
    report.write_text(json.dumps(phases, indent=2) + "\n", encoding="utf-8")
    print(f"[native-ffi] {name}: start (process limit {timeout}s)", flush=True)
    try:
        execute(arguments, timeout=timeout)
        record["status"] = "passed"
    except subprocess.TimeoutExpired:
        record["status"] = "timeout"
        raise
    except Exception as error:
        record["status"] = "failed"
        record["error_type"] = type(error).__name__
        raise
    finally:
        record["elapsed_seconds"] = round(time.monotonic() - started, 3)
        report.write_text(json.dumps(phases, indent=2) + "\n", encoding="utf-8")
        print(f"[native-ffi] {name}: {record['status']} after {record['elapsed_seconds']}s", flush=True)


def main():
    env = environment()
    execute = partial(run, env=env)
    reports = ROOT / "build/reports/native-ffi"
    reports.mkdir(parents=True, exist_ok=True)
    report = reports / "phases.json"
    events = reports / "tests.jsonl"
    events.unlink(missing_ok=True)
    phases = []
    phase("native-build", ["cargo", "+stable", "build", "--manifest-path", "rust/Cargo.toml", "--locked"],
          execute, report, phases, BUILD_TIMEOUT_SECONDS)
    metadata = json.loads(output(["cargo", "+stable", "metadata", "--manifest-path", "rust/Cargo.toml", "--format-version", "1", "--no-deps"], env=env))
    name = "bridge_native.dll" if os.name == "nt" else "libbridge_native.dylib" if sys.platform == "darwin" else "libbridge_native.so"
    library = Path(metadata["target_directory"]) / "debug" / name
    if not library.is_file():
        raise RuntimeError(f"Native build produced no library at {library}")
    phase("flutter-dependencies", [*FLUTTER, "pub", "get", "--enforce-lockfile"],
          execute, report, phases, PREPARE_TIMEOUT_SECONDS)
    # The process includes Flutter startup and compilation. The Dart runner owns
    # the separate per-test timeout, so a cold runner cannot consume its budget.
    phase("flutter-tests", [*FLUTTER, "test", "--no-pub", "--reporter=expanded",
                            f"--timeout={TEST_TIMEOUT_SECONDS}s", f"--file-reporter=json:{events.as_posix()}",
                            "test/native_bridge_test.dart", "test/cloud_native_boundaries_test.dart",
                            "test/native_session_list_test.dart",
                            f"--dart-define=BRIDGE_NATIVE_LIB={library.as_posix()}"],
          execute, report, phases, PROCESS_TIMEOUT_SECONDS)
    desktop = Path(os.environ.get("BRIDGE_DESKTOP_ROOT", ROOT.parent / "codex-mobile-bridge")).resolve()
    if (desktop / "bridge/api/httpd.py").is_file():
        phase("desktop-http-contracts", [*FLUTTER, "test", "--no-pub", "--reporter=expanded",
              "--timeout=120s", "test/native_web_parity_test.dart",
              f"--dart-define=BRIDGE_NATIVE_LIB={library.as_posix()}",
              f"--dart-define=BRIDGE_DESKTOP_ROOT={desktop.as_posix()}"],
              execute, report, phases, PROCESS_TIMEOUT_SECONDS)
    else:
        phases.append({"phase": "desktop-http-contracts", "status": "failed",
                       "reason": "Set BRIDGE_DESKTOP_ROOT to the baseline desktop checkout"})
        report.write_text(json.dumps(phases, indent=2) + "\n", encoding="utf-8")
        raise RuntimeError("Desktop HTTP contracts are required; set BRIDGE_DESKTOP_ROOT to the toolchains.json gateway checkout")


if __name__ == "__main__":
    main()
