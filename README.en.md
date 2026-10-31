# Bridge Mobile

[简体中文](README.md) | English

A native Flutter + Rust client for your own
[codex-mobile-bridge](https://github.com/try2love/codex-mobile-bridge) gateway.
Compatibility baseline: gateway v2.1.6, commit `b6dde4da8ad4f083c66ab9f1f3770758d623af76`.
Ordinary direct connections need no changes to that baseline gateway. Cloud relay
requires a protocol-capable desktop gateway and a separate cloud service. This app
is not an arbitrary RPC or desktop IPC proxy.

### What Is Included

- Multiple computers, password login, and single-use QR pairing.
- Codex, Claude Code/Cowork, and DeepSeek session lists, search, and paged history.
- Capability-gated creation, continuation, messages, attachments, approvals,
  interruption, and model/effort selection.
- Codex SSE/long polling and desktop-provider detail polling through Rust.
- Local drafts, an in-app inbox, English/Chinese, light/dark themes, and
  phone/tablet layouts.
- Automatic Android background notifications for task completion and confirmation
  requests, with a test action and authenticated conversation navigation.
- OS secure credential storage; SQLite for configuration, drafts, and uncertain
  operations, not complete conversation archives.

Ordinary connections access the selected gateway directly. An explicitly configured
hosted/selfhost account can also use the end-to-end encrypted relay; pairing still
requires approval on the original local desktop. No model API-key storage or remote
HTML execution is implemented.
Cloud account/pairing/settings UI, production Android U-Push integration, and an
iOS APNs cloud flavor now exist in source. Signing, actual vendor delivery, and
background device acceptance remain unverified; see [cloud notifications](docs/cloud-notifications.md).
Android release/profile remain vendor-SDK-free by default; production push requires
both a build-time opt-in and separate native device consent. The debug
[Lenovo-only U-Push trial](docs/umeng-push-test.md) remains a manual experiment and
cannot authorize production cloud push.
The QR scanner uses its bundled Android recognition model; Google Play Services
does not need to be installed on the user's device. FCM/separate OEM channels,
terminal/Git/file workbenches, coding-client account switching, and client lifecycle
management are deferred.

**Chat and control writes are never automatically replayed.** A timeout or ambiguous
reply leaves the operation pending review, even after restarting. Inspect the actual remote
conversation before explicitly clearing a pending operation.

#### Choose and Preview Images

Tap **+ > Photos** beside the composer to open the system image selector.
Clients that support arbitrary attachments also offer a separate **Files** entry.
Selected images appear above the composer: tap to enlarge/pinch-zoom, or use the
corner close button to remove one from the draft. The strip scrolls horizontally,
with a maximum of eight attachments and 20 MiB per file.

Selection uploads the attachment to the current gateway; only **Send** submits
the message. Returning from the system picker waits for fresh authority in the
original conversation/account instead of silently dropping the selection. A
connection wait timeout asks the user to reconnect and choose again. Acknowledged
uploads survive backgrounding in their original draft; uncertain writes are never
replayed. Preview supports PNG, JPEG, GIF and WebP without all-files permission.

#### Return Home

Tap the top-left bridge icon to return to the Computers screen from a conversation,
conversation list, or sign-in screen. The header shows the icon without a brand
title. Returning home saves the current draft and stops live reads without removing
saved connections, credentials, or pending-operation records. If the draft cannot
be saved, the editor stays open. The home button is disabled during a pending write.
Automatic Android notification monitoring continues on the home screen.

#### Remove A Saved Connection

On the Computers screen, swipe a gateway card **from right to left**. Confirm
the gateway name and address in the removal dialog, or cancel to restore the
card. A normal tap still connects; swiping right does not delete anything.
Removal clears that connection's saved credentials, drafts and pending records
on the phone, not the gateway or conversations on the computer. Sign-in is not
required to remove a saved connection.

#### Android Background Notifications

Task notifications start automatically with the app. There is no in-app toggle
or **Stop listening** action, and the old saved off setting is ignored on upgrade.
Android 13+ requests the OS notification permission on first startup, then starts
listening after a grant. Denial does not cause repeated prompts on every launch.
Grant it later through **Settings > Android notifications > Notification permissions**;
returning to the app restores listening automatically. **Send test notification**
checks the local notification channel only, not gateway event delivery. Keep both
task-activity and background-connection notification channels enabled.

- A foreground service reads `/api/mobile/events` directly from saved gateways.
  No gateway modification, Google services, or third-party push account is needed.
  Gateways must be reachable, authenticated, and advertise notifications.
- Another read starts about 12 seconds after each round finishes. Timeouts extend
  the interval. Returning home, backgrounding, or removing the recent-task card
  does not deliberately stop the listener; Android may still reclaim its process.
- Initial connections and account/stream changes establish a quiet baseline.
  Permission restoration preserves deduplication. Catch-up is limited to ten recent alerts per gateway per round, with
  at most twenty local notification routes. Older activity remains in the inbox.
- Notifications contain generic event labels and a computer name, not conversation
  bodies. The public lock-screen version omits the name. Taps recheck identity and
  the event before opening its original provider/environment; they never submit
  messages, approve requests, or activate a client automatically.
- Continuous networking and a timeout-bounded CPU wake lease consume extra battery.
  Battery settings are opened only on request; exemptions are not changed silently.
  Doze, OEM battery policies, disconnection, force-stop, and process reclamation can
  interrupt or delay delivery. This is not guaranteed kill-resistant cloud push.
- There is no boot receiver. Reopening the app automatically restores listening
  when Android permissions allow it. OS notification and battery controls still apply.
  Removing a gateway also clears its local notifications and deduplication state.

### Development

Flutter and Rust/Cargo follow the latest **stable** channels; Dart comes with
Flutter. Dart/Rust dependencies no longer pin exact releases. `toolchains.json`,
`.fvmrc`, and `rust-toolchain.toml` describe the channel policy; minimum OS
requirements and Android platform installation specifications remain unchanged.
Platform builds refresh SDKs and dependencies before regenerating FFI. Lockfiles
record that build's resolution snapshot, not a permanent upgrade restriction.
The resolved Dart/Rust flutter_rust_bridge and generator releases must match.

```sh
python scripts/prepare_build.py
python scripts/check_toolchains.py
```

Python 3.11+ is required by the build helpers. Windows also needs Visual Studio
with the C++ desktop toolchain for host-side Rust tests. Put Flutter, Rust, and
Python on PATH; the Android helper supplies the isolated Java/SDK environment.
Run Flutter tests, analysis, and builds sequentially in a checkout: they share
generated plugin registration files. Concurrent debug/test and release commands
can insert the test-only integration plugin into a release build.
The build helpers deliberately do not pass `--no-pub` to platform builds: on
Flutter that flag also skips mode-specific plugin
regeneration, leaving the debug integration plugin in a subsequent release.

#### Windows Android Build

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

Production cloud push is a separate release/profile opt-in: `BRIDGE_ANDROID_PUSH=umeng`,
with `UMENG_PRODUCTION_APP_KEY` and `UMENG_PRODUCTION_MESSAGE_SECRET` injected by a
secure build environment, plus optional `UMENG_PRODUCTION_CHANNEL`. Debug trial
credentials/consent do not carry over. The client Message Secret is not the server's
`UMENG_APP_MASTER_SECRET`. Vendor packaging must independently pass ABI/16 KB,
signing, privacy, and device gates; old SDK-free artifact results do not cover it.

Release signing is opt-in through `BRIDGE_KEYSTORE_PATH`,
`BRIDGE_KEYSTORE_PASSWORD`, `BRIDGE_KEY_ALIAS`, and `BRIDGE_KEY_PASSWORD`.
All four must be provided together. Never commit signing files or secrets.
Release builds do not silently fall back to a debug key. See
[release gates](docs/release-checklist.md) and [distribution](docs/distribution.md).

#### Tests

```sh
python -m unittest discover -s scripts/tests -v
cargo fmt --manifest-path rust/Cargo.toml -- --check
cargo clippy --manifest-path rust/Cargo.toml --all-targets --locked -- -D warnings
python scripts/test_rust.py
flutter --no-version-check --suppress-analytics analyze
flutter --no-version-check --suppress-analytics test
python scripts/test_native.py
```

Native packaging has an additional toolchain regression test: from
`rust_builder/cargokit/build_tool/`, run `dart pub upgrade`, then
`dart test test/project_toolchain_test.dart`. See that vendored directory's
`LOCAL_PATCHES.md` for stable-channel and refreshed build-snapshot integration.

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

#### iOS

On macOS with complete Xcode, CocoaPods, Flutter and rustup, configure your own
Apple ID, development team and device provisioning, then:

```sh
python scripts/build_ios.py
```

The helper refreshes stable SDKs/dependencies and verifies the exported signed
development IPA. Signing/export failures never fall back to unsigned output or
accept an old IPA. Use `--export-method app-store` or `--export-options-plist <file>`
for other distribution methods. Explicit `--compile-only` checks an unsigned
build and does not produce an installable IPA. Actual iPhone testing, signing
permissions and store acceptance remain separate requirements.

Ordinary iOS has no APNs/NSE or shared preview Keychain. For the cloud flavor, copy
the public `ios/Cloud.example.xcconfig` to the ignored `ios/Cloud.local.xcconfig`,
configure your own bundle IDs, App Group, preview Keychain group, and Team, then run
`python scripts/build_ios.py --flavor cloud --compile-only`. This remains unsigned;
shared Keychain access, APNs, and extension lifetime need final signed-device
acceptance. Structural and macOS Swift/C ABI checks are documented in
[cloud notifications](docs/cloud-notifications.md).

### Structure

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
in [docs/protocol.md](docs/protocol.md). CI refreshes stable SDKs/dependencies,
checks FFI version consistency, runs native tests, builds Android artifacts,
and defines a separate unsigned macOS/iOS build gate;
an unexecuted workflow is not a passed gate.

### Licenses And Privacy

This project uses the root MIT license. The original bridge mark is maintained
as `assets/branding/bridge-mark.svg`; `scripts/generate_icons.py` regenerates its
platform PNG/ICO files with Pillow. IBM Plex font licenses are retained and
available in the app's open-source license screen. Do not reuse the reference
app's signing identity or store listing.

Read the [privacy and permission inventory](docs/privacy.md) before testing or
distribution. It is a developer inventory, not a finalized legal/store policy.
