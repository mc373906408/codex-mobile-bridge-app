# Bridge Mobile

A native Flutter + Rust client for your own
[codex-mobile-bridge](https://github.com/try2love/codex-mobile-bridge) gateway.
Compatibility baseline: gateway v2.1.6, commit `b6dde4da8ad4f083c66ab9f1f3770758d623af76`.
The gateway stays unchanged; this app is not an arbitrary RPC or desktop IPC proxy.

## What Is Included

- Multiple computers, password login, and single-use QR pairing.
- Codex, Claude Code/Cowork, and DeepSeek session lists, search, and paged history.
- Capability-gated creation, continuation, messages, attachments, approvals,
  interruption, and model/effort selection.
- Codex SSE/long polling and desktop-provider detail polling through Rust.
- Local drafts, an in-app inbox, English/Chinese, light/dark themes, and
  phone/tablet layouts.
- OS secure credential storage; SQLite for configuration, drafts, and uncertain
  operations, not complete conversation archives.

No cloud relay, model API-key storage, remote HTML execution, or push SDKs.
The QR scanner uses its bundled Android recognition model; Google Play Services
does not need to be installed on the user's device. System push, terminal/Git/file
workbenches, account switching, and client lifecycle management are deferred.

**Writes are never automatically replayed.** A timeout or ambiguous reply leaves
the operation pending review, even after restarting. Inspect the actual remote
conversation before explicitly clearing a pending operation.

## Development

The exact baseline is in `toolchains.json`: Flutter **3.47.8**, its bundled Dart
**3.13.7**, Rust/Cargo **1.99.1**, and flutter_rust_bridge **2.13.0** on both sides.
Use the checked-in `pubspec.lock`, `rust/Cargo.lock`, `.fvmrc`, and
`rust-toolchain.toml`. Do not run a floating upgrade as part of a build.

```sh
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
flutter --no-version-check --suppress-analytics pub get --enforce-lockfile
python scripts/check_toolchains.py
```

Python 3.11+ is required by the build helpers. Windows also needs Visual Studio
with the C++ desktop toolchain for host-side Rust tests. Put Flutter, Rust, and
Python on PATH; the Android helper supplies the isolated Java/SDK environment.
Run Flutter tests, analysis, and builds sequentially in a checkout: they share
generated plugin registration files. Concurrent debug/test and release commands
can insert the test-only integration plugin into a release build.
The build helpers deliberately do not pass `--no-pub` to platform builds: on
this pinned Flutter version that flag also skips mode-specific plugin
regeneration, leaving the debug integration plugin in a subsequent release.

### Windows Android Build

```sh
python scripts/bootstrap_android.py --accept-licenses
python scripts/build_android.py
```

Bootstrap downloads SHA-256-checked JDK/command-line-tool archives into `.local/`
and verifies the installed SDK, NDK, and CMake files. It does not replace another
project's SDK or change global Flutter configuration. Download progress logs are
under `.tmp/`. An optional unauthenticated local HTTP proxy can be provided with
`HTTP_PROXY` and `HTTPS_PROXY`; no machine-specific proxy is committed.

The build helper creates **unsigned** release outputs by default:

- `build/app/outputs/flutter-apk/app-release.apk`
- `build/app/outputs/bundle/release/app-release.aab`
- `build/reports/android/`: SHA-256, all packaged ELF LOAD alignments, APK ZIP
  alignment, and the AAB's bundletool `PAGE_ALIGNMENT_16K` result.

The 16 KB ELF gate covers both 64-bit ABIs and every Rust-core variant. Legacy
32-bit scanner dependencies are explicitly recorded as 4 KB-only components for
older 32-bit devices; they are not claimed to have 16 KB LOAD alignment.

The [2026-10-28 verification record](docs/verification-2026-10-28.md) lists the
tested artifacts and remaining release gates. The locally produced
`build/app/outputs/flutter-apk/app-local-test.apk` is an installable release-mode
copy signed **only with the Android debug identity** for testing; it is not a
production-signed deliverable. The build helper does not create that test copy
or silently substitute it for an unsigned release.

For an installable development build:

```sh
python scripts/build_android.py --format apk --debug --abi arm64-v8a
```

Release signing is opt-in through `BRIDGE_KEYSTORE_PATH`,
`BRIDGE_KEYSTORE_PASSWORD`, `BRIDGE_KEY_ALIAS`, and `BRIDGE_KEY_PASSWORD`.
All four must be provided together. Never commit signing files or secrets.
Release builds do not silently fall back to a debug key. See
[release gates](docs/release-checklist.md) and [distribution](docs/distribution.md).

### Tests

```sh
python -m unittest discover -s scripts/tests -v
cargo fmt --manifest-path rust/Cargo.toml -- --check
cargo clippy --manifest-path rust/Cargo.toml --all-targets --locked -- -D warnings
cargo test --manifest-path rust/Cargo.toml --locked
flutter --no-version-check --suppress-analytics analyze
flutter --no-version-check --suppress-analytics test
python scripts/test_native.py
```

Native packaging has an additional toolchain regression test: from
`rust_builder/cargokit/build_tool/`, run `dart pub get`, then
`dart run test/project_toolchain_test.dart`. See that vendored directory's
`LOCAL_PATCHES.md` for the exact-version and locked-build fixes.

The ordinary Flutter suite deliberately skips the host FFI smoke test when no
native library path is supplied. `scripts/test_native.py` builds and loads the
real library, then verifies async FFI, persistence, stream cancellation, and
at-most-once writes. All fixtures use synthetic conversations and credentials.

The on-device test additionally exercises the packaged JNI library and the
platform secure store:

```sh
flutter test integration_test/native_startup_test.dart -d <device-id>
```

For Windows 16 KB emulator tooling, use
`python scripts/bootstrap_android.py --with-emulator`. A static alignment report
does not establish that the APK has actually run on a 16 KB device.
With an already booted, explicitly selected device, run
`python scripts/test_android.py --device <adb-serial>` to verify its 16 KB page
size and save a native integration-test report. Use `--page-size 4096` only when
testing a conventional 4 KB device; it is not a substitute for the 16 KB gate.

### iOS

On macOS with Xcode and CocoaPods, install the same Flutter/Rust versions, then:

```sh
flutter pub get --enforce-lockfile
rustup target add aarch64-apple-ios
flutter build ios --release --no-codesign
```

This produces an unsigned build, not an App Store IPA. iOS 15+, actual iPhone
testing, an Apple developer account, an independent bundle ID, provisioning,
and signing remain separate requirements. Windows tests cannot verify iOS.

## Structure

| Path | Responsibility |
| --- | --- |
| `lib/app.dart`, `lib/ui/` | Native widgets and safe conversation presentation |
| `lib/viewmodels/` | Selection generations, lifecycle, drafts, and pending state |
| `lib/data/` | Repository boundary and OS secure storage |
| `rust/src/adapters/` | Codex, Claude, and DeepSeek protocol normalization |
| `rust/src/transport.rs`, `security.rs` | Authentication, strict URLs, TLS, and no automatic replay |
| `rust/src/persistence.rs` | Account-scoped local state and durable write intentions |
| `lib/src/rust/`, `rust/src/frb_generated.rs` | Generated FFI; regenerate together |
| `rust_builder/cargokit/` | Vendored native build integration, with its original license |

Regenerate bindings with `flutter_rust_bridge_codegen generate` after changing
the public Rust API. The allowlisted protocol and authority rules are documented
in [docs/protocol.md](docs/protocol.md). CI checks the pins, runs native tests,
builds Android artifacts, and defines a separate unsigned macOS/iOS build gate;
an unexecuted workflow is not a passed gate.

## Licenses And Privacy

This project uses the root MIT license. The original bridge mark is maintained
as `assets/branding/bridge-mark.svg`; `scripts/generate_icons.py` regenerates its
platform PNG/ICO files with Pillow. IBM Plex font licenses are retained and
available in the app's open-source license screen. Do not reuse the reference
app's signing identity or store listing.

Read the [privacy and permission inventory](docs/privacy.md) before testing or
distribution. It is a developer inventory, not a finalized legal/store policy.
