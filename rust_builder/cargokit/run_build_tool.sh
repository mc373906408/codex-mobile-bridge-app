#!/usr/bin/env bash
set -e

BASEDIR=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$CARGOKIT_TOOL_TEMP_DIR"
RUNNER_DIR=$(cd "$CARGOKIT_TOOL_TEMP_DIR" && pwd)

if [[ -z $FLUTTER_ROOT ]]; then
  DART=dart
else
  DART="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"
fi

# Use the reviewed build-tool lockfile, not a freshly resolved temporary package.
# Recompile for the selected Dart SDK so an old kernel never requires an upgrade.
cd "$BASEDIR/build_tool"
"$DART" pub get --enforce-lockfile --no-precompile
"$DART" compile kernel bin/build_tool.dart -o "$RUNNER_DIR/build_tool.dill"
"$DART" --packages="$BASEDIR/build_tool/.dart_tool/package_config.json" "$RUNNER_DIR/build_tool.dill" "$@"
