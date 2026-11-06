"""Shared process execution with the standard rustup binaries on PATH."""

import os
from pathlib import Path
import shutil
import subprocess
import importlib.util

ROOT = Path(__file__).resolve().parents[1]


def environment():
    cargo_bin = str(Path.home() / ".cargo/bin")
    spec = importlib.util.spec_from_file_location('p2p_build', ROOT / 'third_party/bridge-p2p/build_support.py')
    support = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(support)
    return {**support.environment(ROOT), "PATH": os.pathsep.join((cargo_bin, os.environ["PATH"]))}


def command(arguments, env):
    executable = shutil.which(arguments[0], path=env["PATH"])
    if not executable:
        raise RuntimeError(f"Missing build tool: {arguments[0]}")
    result = [executable, *arguments[1:]]
    if os.name == "nt" and executable.endswith((".bat", ".cmd")):
        return [env.get("COMSPEC", "cmd.exe"), "/d", "/c", *result]
    return result


def run(arguments, *, env, cwd=ROOT, timeout=None):
    print("$ " + " ".join(map(str, arguments)), flush=True)
    return subprocess.run(command(arguments, env), cwd=cwd, env=env, check=True, timeout=timeout)


def output(arguments, *, env, cwd=ROOT):
    return subprocess.check_output(command(arguments, env), cwd=cwd, env=env, text=True)
