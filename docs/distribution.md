# Distribution build procedure

## Android

The GitHub APK app ID is `dev.waken.bridge_mobile`, independent from the reference app.
Store registration remains a separate step before submitting to an app store.
Android 8 (API 26) is the minimum; compile/target SDK is 36, with the exact NDK
and supporting tools recorded in `toolchains.json`.

`python scripts/build_android.py` creates unsigned release APK/AAB files. For a
signed build, provide all four environment variables from a protected local
environment or CI secret store:

Builds call `verify_build_snapshot.py`: lockfiles are enforced and the current
SDK/generated-code hashes are recorded in `build/reports/build-snapshot.json`.
They do not upgrade SDKs/dependencies or regenerate FFI. Run `prepare_build.py`
explicitly when updating that snapshot, then review and test the changes.

| Variable | Value |
| --- | --- |
| `BRIDGE_KEYSTORE_PATH` | Absolute path to an independent keystore |
| `BRIDGE_KEYSTORE_PASSWORD` | Keystore password |
| `BRIDGE_KEY_ALIAS` | Key alias |
| `BRIDGE_KEY_PASSWORD` | Key password |

Do not put passwords on a command line, in `gradle.properties`, or in Git. The
repository ignores common keystore/profile extensions as defense in depth.
Use `apksigner verify --verbose --print-certs` on the final APK and compare the
signing certificate with the intended channel identity. An unsigned APK is not
installable; a debug-signed APK is not a distribution deliverable.
Do not run another Flutter command against the same checkout while packaging;
debug/integration tests and release builds share generated plugin registrants.

The build helper verifies every packaged `.so`, including Flutter, the Rust
core, and scanner dependencies. It checks ELF program headers, not just section
alignment. The 16 KB LOAD requirement covers arm64/x86_64 libraries and all Rust
variants. A 32-bit scanner library with 4 KB LOAD alignment is explicitly labeled
as legacy 4 KB-device code, not asserted to pass the 64-bit gate. Unsupported x86
32-bit packaging is excluded. The helper also runs SDK `zipalign` for APKs and the pinned, SHA-256-verified
Google bundletool for AAB configuration. Reports include artifact hashes so
results cannot be silently transferred to a different package.

The Android TLS companion is maintained locally at the 0.2.0 JNI ABI to handle
CRL-only certificates without misclassifying an unavailable OCSP endpoint.
System trust, hostname, validity and handshake checks remain enabled. Review
`third_party/rustls-platform-verifier/README.md` when updating the Rust verifier.

Cloud HTTPS and encrypted relay WebSockets both use `rustls-platform-verifier`.
The WebSocket client passes an explicit Rustls connector instead of probing for
native CA files, which does not find the Android/iOS system trust stores.
Android initializes the shared verifier before any FFI networking; iOS uses
`Security.framework`. There is no certificate-check bypass or insecure fallback.
Rust regression tests cover the connector, trusted upgrades, untrusted/expired
certificates, hostname mismatches, and cross-origin redirect rejection.

An AAB is not an installed APK. In addition to the bundle configuration check,
generate device APKs with bundletool/the Play internal track and test those exact
signed outputs. Install the final APK on a device/emulator whose
`adb shell getconf PAGE_SIZE` is `16384`; check launch, JNI initialization,
authentication, camera, attachments, and lifecycle behavior. Store approval and
real-gateway behavior are not implied by these checks.

The Google Play and domestic APK channels share one core implementation. There
is no FCM, OEM push, or Google Play Services-dependent scanner download. The
bundled scanner does include Google ML Kit libraries; that is not the same as
requiring the Google Play Services application on a device. Review its exact
resolved dependencies and privacy disclosures for each release.

## iOS

Use macOS/Xcode/CocoaPods and the latest stable SDKs. `ios/Podfile`, the runner project,
and the Rust pod integration target iOS 15. `flutter build ios --release
--no-codesign` is only the compile gate.

Before an archive/export:

1. Register the independent bundle ID and configure the correct team/profile.
2. Verify camera/local-network usage strings in English and Chinese.
3. Run the native integration test and real-gateway flows on an iPhone.
4. Build with `python scripts/build_ios.py --export-method app-store` or supply
   `--export-options-plist` for the intended export options. The helper verifies
   the reviewed snapshot, uses `pod install --deployment`, and verifies the newly
   exported signed IPA. Dependency updates are a separate explicit preparation.
5. Inspect the signed archive, entitlement set, included privacy manifests, and
   third-party license inventory. Test the resulting TestFlight build.

Apple credentials, provisioning, and store metadata are not stored in this
repository. The macOS workflow has no Apple signing secrets. GitHub Releases
include an explicitly named `ios-unsigned.ipa`, packaged from the ordinary app
with `scripts/package_release.py ios` while preserving executable permissions.
Users must sign that IPA themselves before sideloading; it is not a signed export,
TestFlight build, or directly installable download. Signed export errors in
`build_ios.py` still fail rather than falling back to unsigned packaging.

The cloud CI job also packages `bridge-mobile-<version>-ios-cloud-unsigned.ipa`
in the `ios-cloud-for-user-signing-<commit>` artifact. Download the artifact ZIP
from the successful cloud job and extract its IPA; the outer Actions ZIP itself
is not an IPA. `ios-cloud-build.json` records the source commit, IPA SHA-256,
bundle ID, notification extension check and shared group identifiers. On macOS,
the corresponding commands are:

```sh
python scripts/build_ios.py --compile-only --flavor cloud
python scripts/package_release.py ios --flavor cloud
```

Installing the cloud IPA requires signing both `Runner.app` and its
`BridgeNotificationService.appex` with compatible profiles. The registered app
identities, APNs entitlement, App Group and shared Keychain group must match the
final signed app's configuration. Simply renaming the ZIP or stripping the
extension does not provide cloud push. Use `ios/Cloud.local.xcconfig` with your
team's registered identifiers for a signed build, then
`python scripts/build_ios.py --flavor cloud --export-method ad-hoc` (registered
test devices) or the intended `--export-options-plist`. A TestFlight export uses
the App Store distribution path and must be uploaded to App Store Connect.
No Apple signing material is bundled in the unsigned download.

## GitHub Releases

The `Native Client` workflow publishes on a `v*` tag matching `pubspec.yaml`, or
with the explicit `publish` workflow-dispatch input. Add release notes at
`docs/releases/v<version>.md` first. Both platform jobs must pass before the
publisher creates a draft, uploads assets, and makes the release public.

Configure `BRIDGE_KEYSTORE_BASE64`, `BRIDGE_KEYSTORE_PASSWORD`, `BRIDGE_KEY_ALIAS`,
and `BRIDGE_KEY_PASSWORD` as Actions secrets. The first is the base64-encoded
independent Android keystore; keep an offline backup of the key and passwords.
Publishing fails if any secret is missing. A temporary runner key is removed after
the build. Ordinary CI builds remain unsigned.

The release contains a signed universal Android APK (ARMv7/ARM64/x86_64), an
unsigned ordinary iOS IPA, per-platform build reports, and `SHA256SUMS.txt`.
The final check binds both package hashes to the same source commit and version.
Android package/version and release certificate are checked with Android SDK
tools. These ordinary variants do not enable vendor push credentials or APNs.
Existing debug-signed installations cannot be upgraded in place to the independent
release certificate; uninstalling those development installations deletes local data.

## Public release preparation

- Replace the developer privacy inventory with the publisher's reviewed policy,
  contact address, retention/deletion terms, and channel disclosures.
- Audit dependency licenses, bundled assets, permissions, and required-reason
  API declarations against the exact signed artifact.
- Prepare an isolated, non-private review gateway and clear setup instructions.
- Check current Google Play target SDK and Apple's remote-client review rules.
  Describe the actual capabilities; do not hide them to avoid review.
- Record real-device and real-gateway results separately for Codex local/CLI/
  SSH/WSL, Claude Code/Cowork, and DeepSeek.

References: [Android 16 KB guide](https://developer.android.com/guide/practices/page-sizes),
[Apple review guidelines](https://developer.apple.com/app-store/review/guidelines/).
