# Local integration patches

The upstream Cargokit license is retained in `LICENSE`. This vendored copy has
the following Bridge Mobile-specific changes; preserve them when refreshing it:

- `build_tool/lib/src/project_toolchain.dart` reads the application's stable
  channel policy instead of requiring an obsolete exact compiler pin.
- `build_tool/lib/src/builder.dart` installs targets and compiles with that
  channel. Cargo's `--locked` consumes the freshly updated build snapshot;
  `scripts/prepare_build.py` refreshes it before platform packaging.
- Build-tool dependencies are unrestricted and refreshed with `pub upgrade`,
  including when rebuilding the cached Dart runner. Its SDK constraint has no
  artificial upper bound that would reject future stable Dart releases.
- `build_tool/test/project_toolchain_test.dart` verifies stable selection and
  missing/invalid configuration. Run `dart pub upgrade`, then
  `dart test test/project_toolchain_test.dart` from `build_tool/`.
- The iOS pod phase logs only build metadata, never the complete environment
  that could contain signing or provider credentials.

These are build-integration changes, not edits to the reference Python gateway.
