# Local integration patches

The upstream Cargokit license is retained in `LICENSE`. This vendored copy has
the following Bridge Mobile-specific changes; preserve them when refreshing it:

- `build_tool/lib/src/project_toolchain.dart` reads the parent application's
  exact `rust-toolchain.toml` channel. Missing, floating, beta, and nightly pins
  fail closed. Upstream's unconditional `stable` alias ignored our project pin
  and selected Rust 1.96 even though host checks ran Rust 1.99.1.
- `build_tool/lib/src/builder.dart` uses that pin for target installation and
  compilation, and passes `--locked` to Cargo for native packaging too.
- `build_tool/lib/src/rustup.dart` recognizes installed exact-version toolchains
  rather than treating them as custom links and attempting reinstallations.
- `build_tool/test/project_toolchain_test.dart` guards version selection and
  missing/invalid-pin behavior. Run `dart run test/project_toolchain_test.dart`
  from `build_tool/`; direct execution avoids the old test CLI's dependency on
  a frontend-server snapshot removed from current Dart SDKs.

These are build-integration changes, not edits to the reference Python gateway.
