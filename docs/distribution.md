# Distribution build procedure

## Android

The app ID is `dev.waken.bridge_mobile`, independent from the reference app. The
maintainer must confirm/register this provisional ID before a public release.
Android 8 (API 26) is the minimum; compile/target SDK is 36, with the exact NDK
and supporting tools recorded in `toolchains.json`.

`python scripts/build_android.py` creates unsigned release APK/AAB files. For a
signed build, provide all four environment variables from a protected local
environment or CI secret store:

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

Use macOS/Xcode/CocoaPods and the pinned SDKs. `ios/Podfile`, the runner project,
and the Rust pod integration target iOS 15. `flutter build ios --release
--no-codesign` is only the compile gate.

Before an archive/export:

1. Register the independent bundle ID and configure the correct team/profile.
2. Verify camera/local-network usage strings in English and Chinese.
3. Run the native integration test and real-gateway flows on an iPhone.
4. Build with `flutter build ipa --release` using the intended export options.
5. Inspect the signed archive, entitlement set, included privacy manifests, and
   third-party license inventory. Test the resulting TestFlight build.

Apple credentials, provisioning, and store metadata are deliberately not stored
in this repository. The checked-in macOS workflow has no signing secrets and
does not publish anything.

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
