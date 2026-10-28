# Verification record: 2026-10-28

This is a local Windows verification record, not a release certification. The
reference gateway remains unchanged at `b6dde4da8ad4f083c66ab9f1f3770758d623af76`.
The implementation is still an uncommitted working tree; no commit, push, or
public release was performed.

## Confirmed gates

| Gate | Result |
| --- | --- |
| Flutter / bundled Dart | 3.47.8 / 3.13.7, exact pins checked |
| Rust / Cargo / FRB generator | 1.99.1 / 1.99.1 / 2.13.0, dependencies checked |
| Android toolchain | JDK, SDK 36, NDK 28.2.13676358, CMake installed and verified |
| Rust format / Clippy | Passed, Clippy warnings denied |
| Rust tests | 25 passed, synthetic gateway contracts and security cases |
| Flutter analysis | Passed, no issues |
| Flutter unit/widget tests | 20 passed; host FFI placeholder skipped in this command |
| Real host Rust FFI | Separate native-library smoke test passed |
| Python build/packaging tests | 23 passed |
| Cargokit exact-toolchain regression | 7 passed with direct Dart test execution |
| Workflow / platform XML | YAML parsed; Android XML and iOS plist syntax checked |
| Android emulator | Isolated API 36 x86_64 emulator booted; PAGE_SIZE = 16384 |
| Emulator Google Play Services | Disabled before native integration testing |

Additional layout regressions cover 320-pixel width, CJK multiline drafts with
the keyboard visible, both themes, and large accessibility text. The settings
sheet overflow found by this testing was fixed with a scrollable body.

## Android build and device gates

Native libraries have compiled for armv7, arm64, and x86_64 using Rust 1.99.1.
Both final artifact builds succeeded. Native compilation and final packaging
were checked separately, and the unsigned originals were kept unchanged.

| Gate | Result |
| --- | --- |
| Packaged native integration test | Passed on 16 KB API 36 emulator: Rust, SQLite, OS secure storage, untrusted TLS rejection, and no write replay |
| Release APK / AAB | Passed; unsigned originals, 96,219,567 / 87,335,455 bytes |
| Packaged ELF checks | 21 libraries per artifact inspected; both 64-bit ABIs and all three Rust variants meet the 16 KB gate |
| Legacy 32-bit dependency | armv7 ML Kit `libbarhopper_v3.so` is 4 KB-aligned and explicitly scoped to legacy 32-bit devices |
| APK ZIP alignment | SDK zipalign `-c -P 16 4` passed |
| AAB configuration | Pinned bundletool reports `PAGE_ALIGNMENT_16K` |
| Release-mode emulator launch | Passed using a separately named Android-debug-signed copy; Google Play Services disabled |
| Release-mode gateway UI | Synthetic read-only connection, session list, and Markdown/code history passed; both themes inspected |

Initial artifacts under `build/app/outputs/` (the APKs were superseded by the
localization update recorded below; the AAB was not rebuilt):

| Artifact | SHA-256 |
| --- | --- |
| `flutter-apk/app-release.apk` (unsigned) | `c2af9b45cafec22e5cd72870eeb9510f19fed034776b7cad276a0318e2964192` |
| `bundle/release/app-release.aab` (unsigned) | `2bddfb88d839584785b7f2f869f9597567f4fca549add7a7c3bbb3a9158c4415` |
| `flutter-apk/app-local-test.apk` (test-signed release-mode copy) | `ac48084ea15c6df748a144a61ef307a42d74c63c339e9cbd46c8b5218952eb87` |

Machine-readable checks and screenshots are under `build/reports/android/`:
`app-release.apk.json`, `app-release.aab.json`, `native-device-test.json`,
`release-emulator-smoke.json`, `release-welcome.png`, `release-chat.png`, and
`release-chat-dark.png`. The native integration test used synthetic HTTP/TLS
servers inside a debug test APK; the separate release-mode check used a
read-only loopback fixture, never the user's private gateway or chats.

Known integration issues resolved during continuation:

- Android CLI 23 package syntax differs from the legacy semicolon wrapper.
  Bootstrap now calls the executable directly and verifies installed files.
- Kotlin incremental caches fail when Pub sources and the project are on
  different Windows drives. Incremental Kotlin compilation is disabled locally
  in the project configuration; no global caches were deleted.
- Vendored Cargokit selected the floating `stable` alias and ignored the pinned
  compiler. It now reads the project pin, recognizes installed versioned
  toolchains, and uses Cargo `--locked`.
- Flutter debug/test and release invocations share plugin registration files.
  Run them sequentially and keep mode-specific pub/plugin generation enabled;
  `--no-pub` skips that generation on the pinned Flutter version.
- Cargokit's encoded Rust flags override `.cargo/config.toml`. `rust/build.rs`
  therefore enforces 16 KB LOAD alignment for the Rust library on every Android
  ABI. The checker explicitly distinguishes legacy 32-bit scanner code from
  the 64-bit Android 16 KB requirement instead of misreporting its alignment.

Reproduce the main local sequence:

```sh
python scripts/test_android.py --device emulator-5560
python scripts/build_android.py
```

## Chinese error messages and physical-device update

The Chinese UI now uses a shared error/notice translation boundary instead of
displaying native exception strings. Known network, authentication, address,
storage, attachment, session-state and HTTP errors have localized messages.
Unknown errors use a safe fallback; exception names, backtraces and arbitrary
gateway response bodies are not shown. Stored errors retain their original
objects so changing the UI language also changes an already-visible error.
Conversation content is unchanged. Native startup failures default to Chinese.

- Flutter analysis: passed without issues.
- Flutter unit/widget tests: 58 passed, including 38 new localization cases;
  the separate host FFI test placeholder remains skipped in this command.
- Regressions include native exceptions with backtraces, gateway status codes,
  unknown diagnostics, add-computer validation, stream errors, notices, locale
  changes, compact light/dark layouts, and preserving unknown-submission locks.
- Release APK rebuilt for all three ABIs; all 21 native-library checks and
  the 16 KB ZIP alignment check passed. Rust sources and TLS policy are unchanged.
- A separately test-signed APK was installed over version 0.1.0 on a Lenovo
  L71091 running Android 13 using `adb install --no-incremental -r`. The signing
  certificate matches the previous installation. No uninstall or data clear ran.
- Installation returned `Success`; the app launched, and a screenshot confirmed
  the saved gateway connection remained present. The phone locked before the
  connection-error banner could be visually rechecked on the physical device.
  Chinese error rendering is verified by widget tests, not claimed as a completed
  real-gateway check.

Updated APK hashes (the earlier AAB still contains the pre-localization code):

| Artifact | SHA-256 |
| --- | --- |
| `flutter-apk/app-release.apk` (unsigned) | `fd56f0aab58a1d1c28e8b2e0af917f62170c64efd06d056f3875ce79d2f6efcb` |
| `flutter-apk/app-local-test.apk` (test-signed release-mode copy) | `ad93267389e785b7cd3bde0c73503fa3ba720bc2cefbfbcb2a390da2c7650051` |

The post-update welcome-screen capture is
`build/reports/android/phone-error-localization.png`; despite its filename it
does not show the connection-error banner.

## Not verified

- Physical Android workflows beyond the installation/launch check above,
  Android 8 minimum-version runtime behavior, and real Codex/Claude/Cowork/DeepSeek
  gateways and execution-owner routing.
- Camera permission/QR pairing and attachments on physical devices, weak mobile
  networks, actual gateway session revocation, and store-delivered packages.
- Any iOS compilation, signing, or iPhone testing: this host is Windows. The
  macOS CI job is defined but has not been run or claimed as successful.
- Independent distribution keystore, App Store provisioning, Play internal
  testing, channel-specific compliance, and store approval.

Unsigned artifacts and test-only signatures are not public release packages.
