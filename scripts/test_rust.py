"""Compile Rust tests before running them with a hard 60-second timeout."""

import argparse
from functools import partial

from build_commands import environment, run

TEST_TIMEOUT_SECONDS = 60


def test(manifest, execute):
    arguments = ["cargo", "+stable", "test", "--locked", "--manifest-path", manifest]
    execute([*arguments, "--no-run"])
    execute(arguments, timeout=TEST_TIMEOUT_SECONDS)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", default="rust/Cargo.toml")
    args = parser.parse_args()
    test(args.manifest, partial(run, env=environment()))


if __name__ == "__main__":
    main()
