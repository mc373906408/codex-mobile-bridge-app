# Local integration patches

The upstream Cargokit license is retained in `LICENSE`. This vendored copy has
the following Bridge Mobile-specific changes; preserve them when refreshing it:

- `build_tool/lib/src/project_toolchain.dart` reads the application's stable
  channel policy instead of requiring an obsolete exact compiler pin.
- `build_tool/lib/src/builder.dart` installs targets and compiles with that
  channel. Cargo's `--locked` consumes the reviewed build snapshot.
  `scripts/prepare_build.py` is the separate explicit update operation.
- Build-tool version ranges remain open, but both runner scripts use the checked-in
  build-tool `pubspec.lock` with `pub get --enforce-lockfile`. They compile its own
  entrypoint to the designated temporary directory using the selected Dart SDK;
  no temporary root package or implicit dependency upgrade is created.
- `build_tool/test/project_toolchain_test.dart` verifies stable selection and
  missing/invalid configuration. Run `dart pub get --enforce-lockfile`, then
  `dart test test/project_toolchain_test.dart` from `build_tool/`.
- The iOS pod phase logs only build metadata, never the complete environment
  that could contain signing or provider credentials.

These are build-integration changes, not edits to the reference Python gateway.
