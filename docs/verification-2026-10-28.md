# Verification record: 2026-10-28

This is a local Windows verification record, not a release certification. The
reference gateway remains unchanged at `b6dde4da8ad4f083c66ab9f1f3770758d623af76`.
The initial gates below were recorded before the first source commit. The
current source baseline is `00e1ada`; later sections describe subsequent local
verification. No public application release is claimed.

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

Localization-update APK hashes (superseded by the swipe-removal update below;
the earlier AAB still contains the pre-localization code):

| Artifact | SHA-256 |
| --- | --- |
| `flutter-apk/app-release.apk` (unsigned) | `fd56f0aab58a1d1c28e8b2e0af917f62170c64efd06d056f3875ce79d2f6efcb` |
| `flutter-apk/app-local-test.apk` (test-signed release-mode copy) | `ad93267389e785b7cd3bde0c73503fa3ba720bc2cefbfbcb2a390da2c7650051` |

The post-update welcome-screen capture is
`build/reports/android/phone-error-localization.png`; despite its filename it
does not show the connection-error banner.

## Initial right-swipe connection removal (superseded)

The initial Computers screen change offered a right-swipe removal gesture with a
visible hint and a destructive-color background. Normal taps still connect, and left
swipes do not remove anything. A shared Chinese/English confirmation names the
gateway and explains which phone-local records are removed; remote gateways and
conversations are not deleted. The existing authenticated removal action uses
the same confirmation. Assistive technology can invoke the card's dismiss action.

Cards remain in the saved list until local cleanup succeeds. Cancellation or a
storage error leaves the card available, errors remain localized, and pending
removals block duplicate gestures and connection taps. Removing an active
connection clears its editor and invalidates late connection results.

- Flutter analysis: passed without issues.
- Flutter unit/widget tests: 70 passed; one separate host FFI placeholder skipped.
  The 12 new cases cover swipe direction, confirmation/cancellation, correct
  target and last-item removal, normal taps, storage failure, duplicate attempts,
  compact large-text layouts in both themes, and active-session/lifecycle safety.
  The final recheck passed formatting with no changes, analysis, and all 70 tests.
- Release APK rebuilt for all three ABIs. All 21 packaged native-library checks
  and the 16 KB APK ZIP alignment check passed. No Rust or gateway changes.
- The separately test-signed copy uses the same Android debug certificate and
  was installed over the existing app on the Lenovo L71091 through wireless ADB.
  Installation returned `Success`; the launch command succeeded and the app
  process was present. The original first-install timestamp remained unchanged.
  No uninstall, data clear, or deletion of the user's saved gateways was run.
  A follow-up read of the installed `base.apk` confirmed its SHA-256 matches the
  current test-signed APK listed below. Signature and 16 KB ZIP alignment checks
  also passed again; no additional installation was needed.
- The phone remained locked, so the physical right-swipe/confirmation UI was not
  visually checked. Gesture and cancellation behavior is verified by widget tests.
- These swipe-removal source changes have not been committed or pushed yet.

Initial right-swipe APKs (superseded by the correction below; the AAB was not rebuilt):

| Artifact | SHA-256 |
| --- | --- |
| `flutter-apk/app-release.apk` (unsigned) | `430b590fa8029b14b16a82d949247ab7268e1e3a0d4ed2bebed8d2d93dcb6ab5` |
| `flutter-apk/app-local-test.apk` (test-signed release-mode copy) | `452f6405cbc291c40e9d753d2ab918f7a0ff8fe9cc4a9d3d9c3d7c500dbfe956` |

## Left-swipe correction

The required gesture is from right to left: the card moves left and reveals the
removal action on its right edge. The Chinese/English hint and README now match.
Rightward swipes do not trigger removal. Confirmation, cancellation, normal taps,
and the phone-local deletion scope are unchanged.

- Flutter analysis and formatting checks passed.
- Flutter unit/widget tests: 71 passed; one separate host FFI placeholder skipped.
  Direction tests now exercise leftward drags in both languages. A new partial-drag
  regression checks that the card moves left while the removal action stays on
  the right edge; cancellation leaves the saved gateway untouched.
- The three-ABI release APK rebuilt successfully. All 21 native-library checks,
  the test signing-certificate check, and 16 KB ZIP alignment passed.
- Wireless ADB replacement installation returned `Success`. The installed
  `base.apk` hash matches the corrected test-signed APK below. Launch returned
  `Status: ok` and the application process was present. No uninstall, data clear,
  or saved-gateway deletion ran; the first-install timestamp stayed unchanged.
- The phone remained locked, so the corrected physical gesture is not claimed
  as visually verified. Leftward movement, right-side reveal, and cancellation
  were checked by widget tests.

Left-swipe APKs (superseded by the home-navigation update below; the AAB was not rebuilt):

| Artifact | SHA-256 |
| --- | --- |
| `flutter-apk/app-release.apk` (unsigned) | `adbb89870598f3e713719e965e1661b7c7aed4a5b3aa3219e27d67341cf93bba` |
| `flutter-apk/app-local-test.apk` (test-signed release-mode copy) | `ea60b66055400449e3d1a353697b40c9810f8e10f3862872839951eb380ea80d` |

## Icon-only home navigation

The top-left logo is now a labelled home button, with no visible `BRIDGE` title.
It returns from the conversation list, editor, or sign-in screen to the Computers
screen. Navigation saves the current draft and stops live reads, but does not
remove saved gateways, credentials, or unresolved-operation records. Failed draft
persistence keeps the editor open. Navigation is blocked during a write; duplicate
taps, edits during navigation, late reads, and foreground reconnects cannot replace
the destination. Homepage feature labels also wrap on compact large-text screens.

- Flutter analysis and formatting checks passed.
- Flutter unit/widget tests: 81 passed; one separate host FFI placeholder skipped.
  Ten added tests cover the icon-only header and accessible touch target, Chinese
  and English compact layouts, returning from chat and connection errors, draft
  and pending-operation restoration, persistence failure, stale results, and
  navigation/lifecycle/write races. Existing left-swipe removal tests still pass.
- The three-ABI release APK rebuilt successfully. All 21 native-library checks,
  the matching test-signing certificate, and 16 KB ZIP alignment passed.
- Wireless replacement installation returned `Success`. The installed APK hash
  matches the home-navigation test-signed copy below. Launch returned `Status: ok`
  and the app process was present. The first-install timestamp stayed unchanged;
  no uninstall, data clear, or gateway removal ran.
- The phone remained locked. The physical icon tap and final visible header were
  not visually checked; navigation and absence of the title are covered by tests.

Home-navigation APKs (superseded by the resume fix below; the AAB was not rebuilt):

| Artifact | SHA-256 |
| --- | --- |
| `flutter-apk/app-release.apk` (unsigned) | `4983c47e3e4752a9794fa9332afcbb141f48e764ebdc52193a6b9b353d8afc10` |
| `flutter-apk/app-local-test.apk` (test-signed release-mode copy) | `ff3c842c50763d39e98ccd2908224daed4bba3df96aafde8c541e4d77f75ca45` |

## Homepage controls after resume

The disabled-homepage report was reproduced in a widget test before changing
production code. Returning from the background can render an `inactive` frame
before `resumed`. That frame disables the controls while `foreground` is false.
`setForeground(true)` then updated the model but returned early on the Computers
screen without notifying listeners, leaving the rendered callbacks disabled.

Foreground transitions now notify listeners before any no-gateway or ongoing
home-navigation early return. This refresh does not reset `busy`, replay writes,
or discard pending operations, drafts, or credentials.

- Flutter unit/widget tests: 87 passed; one separate host FFI placeholder skipped.
- Six added tests cover repeated background/resume cycles on the initial home
  screen and after returning home, in Chinese and English; visible inactive
  frames; usable add/connection/removal controls after resume; listener updates
  without connecting a gateway; and retaining a real pending-operation lock.
- The reproducer failed before the fix with a null add-button callback despite
  `foreground == true` and `busy == false`, then passed after the notification fix.
- Flutter analysis and formatting passed. The three-ABI APK rebuilt successfully;
  all 21 native-library checks, the signing-certificate check, and 16 KB ZIP
  alignment passed.
- Wireless replacement installation returned `Success`. The installed `base.apk`
  hash matches the resume-fix test APK below. Launch returned `Status: ok` and the
  app process was present. The original first-install timestamp was preserved;
  no uninstall, data clear, gateway deletion, or message submission ran.
- The phone remained locked, so the real-device background/resume interaction
  is not claimed as visually verified. The regression was reproduced and checked
  through Flutter lifecycle-driven widget tests.

Current APKs (the AAB was not rebuilt):

| Artifact | SHA-256 |
| --- | --- |
| `flutter-apk/app-release.apk` (unsigned) | `2df49c987154ee86338144ce9f5b7c879ae21e9f530db3dede87669f707d5ce2` |
| `flutter-apk/app-local-test.apk` (test-signed release-mode copy) | `4fb2fec58c7ba3e7215269ee9c75823a2fd33c91f31a03aaa993222d021c43e5` |

## Android background notifications

This section records the earlier opt-in build. The automatic-startup update
recorded later in this document supersedes its switch and stop-action behavior.

An opt-in Android foreground service now keeps the shared Flutter/Rust engine
available for notification-only gateway reads. It supplies task-completion and
confirmation notifications, a permission-aware settings switch, a local test
action, scoped persistent deduplication, and authenticated notification navigation.
No gateway source/configuration, cloud push registration, or real task was changed.

- Flutter unit/widget tests: **115 passed**; the host FFI placeholder was skipped
  in this run and exercised separately with the compiled library below. Coverage
  includes quiet baselines, persistent deduplication, account/stream isolation,
  late reads after disable/removal, multiple gateways, failed delivery, bounded
  catch-up, login-required taps, original desktop execution hosts, and both UI languages.
- Rust tests: **34 passed**, including nine notification transport/validation tests.
  The event interface exposes no conversation title/body and does not reset the
  active authentication epoch on every poll. In-flight revoked epochs are rejected.
- Real host FFI smoke test: **1 passed**, including notification batch/session
  serialization and equality with in-app inbox event IDs.
- Flutter static analysis and Rust Clippy (`-D warnings`): passed with no issues.
- Python artifact/tooling tests: **23 passed**; the loopback-only notification
  fixture also passed Python compilation.
- Three-ABI unsigned release APK: built successfully; all 21 ELF checks and
  16 KB ZIP alignment passed. The test-signed copy retains the existing debug
  signing certificate. The AAB was not rebuilt for this change.

### Isolated Android 16 emulator

The workspace's 16 KB AVD was started as a read-only clone without a visible
window. Bridge's synthetic emulator data was reset only after verifying the
emulator identity; no physical-device data clear ran. Google Play Services stayed
disabled. A transient emulator System UI startup ANR was dismissed with Wait;
the subsequent app and notification interactions completed normally.

- Denied the real OS notification permission prompt: the switch stayed off and
  no foreground notification appeared. Granted the subsequent prompt: the service
  started with `remoteMessaging` type `0x200` and connected to the synthetic gateway.
- Sent a local test notification. Injected synthetic completion and confirmation
  events while the app was backgrounded and while the emulator was asleep. Both
  produced actual system notifications with generic labels, not fixture title/body.
- Swiped the Bridge recent-task card away, verified it was removed, injected a
  further event, and observed ongoing foreground service delivery. Reopening the
  Activity reattached to the retained engine and displayed its existing chat.
- Tapping an actual notification opened the fixture's original Codex/local chat.
  The first build exposed a settings-sheet overlay hiding the chat; the final
  build dismisses it. A new widget regression and the final release APK's actual
  notification tap both confirm that the conversation is visible immediately.
- Replacement-install/reopen retained opt-in and notification cursors; prior
  events were not replayed. A new event on the final build was delivered normally.
- On the final build, disabling from settings on the home screen stopped reads,
  removed all Bridge notifications, stopped the service, and released the wake
  lease. A new injected event while disabled produced no read or notification.
- The fixture counted **zero application writes** throughout. These are synthetic
  end-to-end tests, not confirmation that the user's actual tasks have delivered.

Visual evidence is under `build/reports/android/`: `notification-settings-android16.png`,
`notification-shade-android16.png`, and `notification-open-chat-android16.png`.

### Physical-device replacement install

- Wireless ADB installation of the final test-signed release-mode APK returned
  `Success`; launch returned `Status: ok`, and the application process was present.
- The installed APK SHA-256 matches the final test copy below. The original
  `2026-10-28 10:11:30` first-install timestamp was preserved. No uninstall,
  data clear, credential deletion, gateway removal, or message submission ran.
- The Lenovo phone remained locked. `POST_NOTIFICATIONS` is **not granted** and
  the feature defaults off. The user must unlock, enable Settings > Android
  notifications > Background task notifications, and allow notifications.
- A read-only unauthenticated gateway probe advertised `notifications: true`;
  no gateway configuration or credentials were changed. Actual authenticated
  task delivery on the phone is not yet verified.

APKs from the opt-in implementation (the AAB still predates notifications):

| Artifact | SHA-256 |
| --- | --- |
| `flutter-apk/app-release.apk` (unsigned) | `1f16344775d54a6e2cfd39dde324394177246897ceb9c93bb326e67a1b252e1a` |
| `flutter-apk/app-local-test.apk` (test-signed release-mode copy) | `483060706c407ebbc8cdfdf3d862f71980b82e9cf5a2b353d727711e3350504a` |

`scripts/notification_fixture.py` serves only synthetic, read-only application
routes on loopback. Its explicit `/__fixture/event` test endpoint injects a fake
completion or request, and `/__fixture/state` counts reads and rejected application
writes. It never invokes a real coding client.

## Automatic notification startup

The follow-up removes the app-level notification flag, settings switch, and
ongoing notification's stop action. Startup and foreground resume now request
listening automatically. The retired `enabled` preference is removed on upgrade.
Android 13+ requests its runtime permission at the first eligible foreground
startup; a saved request marker prevents automatic prompt loops after denial or
dismissal. Returning from Android settings after a grant restores listening.
Permission revocation stops reads without discarding deduplication, and starts
still require a foreground Activity. No OS permission or battery limit is bypassed.

### Automated checks and package

- Flutter unit/widget tests: **122 passed**, with one host-FFI placeholder skipped.
  Coverage includes automatic startup/resume, first permission grant, denied
  permission across resumes/recreation, settings grants, background initialization,
  late reads after revocation, permission-restoration deduplication, the retired
  state field, startup retries, and switch-free Chinese/English layouts.
- Flutter static analysis: **no issues**. Rust code did not change in this follow-up;
  its earlier test/FFI results are not represented as a new run.
- Three-ABI release APK build succeeded. All **21 ELF** packaging checks passed;
  the test-signed APK also passed `zipalign -c -P 16 4` and signature verification.
  It retains the existing Android debug certificate, not a distribution identity.

### Isolated emulator

The read-only Android 16 / 16 KB AVD remained isolated from real gateway data,
with Google Play Services disabled. The actual previous APK was installed and
its switch was enabled, granted permission, then turned off. Its preferences
were checked to contain `enabled=false`, with no foreground listener, before
replacement-installing the new APK.

- Upgrade removed the old preference and automatically started the `remoteMessaging`
  listener from the home screen. The saved synthetic gateway remained present,
  connected 1/1, and existing fixture history was quietly baselined.
- The actual settings sheet had no notification switch. The ongoing system
  notification had no actions. A background completion produced a real task
  notification; tapping it dismissed the settings sheet and opened the original
  synthetic Codex/local conversation without a write.
- With the OS permission reset on the emulator only, startup showed the real
  permission dialog automatically, without pressing an app control. Denial left
  no service, notification, or active wake lease. Both warm resume and cold restart
  remained prompt-free; event-read counters stayed unchanged while denied.
- Granting permission through the app's link to Android notification settings,
  then returning to Bridge, automatically restored the foreground service, active
  wake lease, gateway reads, and the 1/1 listening status. Deduplication survived.
- The fixture recorded **zero application writes** across these checks. Host
  background helpers were interrupted before the additional screen-off rerun;
  this follow-up does not claim a new screen-off/recent-task-removal result.

Evidence: `build/reports/android/automatic-notification-verification.json`,
`automatic-notification-settings-android16.png`,
`automatic-notification-shade-android16.png`, and
`automatic-notification-open-chat-android16.png`. Flutter logs are in
`.tmp/notification-automatic-tests.log` and `.tmp/notification-automatic-analysis.log`.

### Phone replacement install

- Wireless ADB replacement installation returned **Success** and launching returned
  **Status: ok**. The installed SHA-256 matches the test-signed APK below. The original
  `2026-10-28 10:11:30` first-install timestamp remained unchanged; no uninstall,
  app-data clear, credential deletion, gateway removal, or task submission ran.
- The Android 13 Lenovo phone now reports notification permission **granted**;
  no command changed its OS permission. It remained locked, and no notification
  service or wake lease was active at the final check. Unlocking and foregrounding
  the app is still needed to verify automatic startup on that physical device.
- Real-gateway task notification delivery remains unverified. Phone evidence is
  `build/reports/android/automatic-notification-phone.json`.

Current APKs (the AAB still predates notifications):

| Artifact | SHA-256 |
| --- | --- |
| `flutter-apk/app-release.apk` (unsigned) | `e73c837a30ee00533ae38e0f37a16af37160deb09bd187220e5ac7e80168c4b5` |
| `flutter-apk/app-local-test.apk` (test-signed release-mode copy) | `deefc17eefad79e586ad0a8d0b71dacf3e3845e7694e50b251740528662acf54` |

## Attachment picker and preview follow-up

The user confirmed real task notifications arrived after enabling the gateway's
mobile notification channel. That is user-reported delivery, not a new automated
end-to-end notification result. This follow-up changes only the mobile app and its
synthetic test fixtures; no gateway source or runtime configuration was changed.

### Changes and automated checks

- The composer now offers separate Photos and Files entries. Photos requests
  `FileType.image` instead of routing all attachments through a generic file view.
  Only clients advertising arbitrary-file support see the Files entry.
- Draft images have thumbnails, filename labels, removal controls and a fullscreen
  pinch-zoom preview. The bounded horizontal strip avoids stacking eight attachments
  over a compact keyboard. Aspect-preserving decode limits prevent forced square
  image decoding. Already-loaded images are reused for fullscreen viewing.
- A picker result may arrive before Android resume and gateway reauthentication.
  It now waits up to 30 seconds for fresh authority in the original session/account,
  without holding the write lock or automatically replaying a write. Changed scopes
  are discarded; timeout is reported. An acknowledged upload survives backgrounding
  in the original draft, and uncertain uploads refresh the pending-review records.
- Flutter unit/widget suite: **142 passed**, one host-FFI placeholder skipped.
  The 20 new tests cover photo/file selection, cancellation, draft preview/restore,
  compact Chinese light/dark layouts, 20 MiB limits (known size and streamed),
  delayed resume, account/session changes, timeout/disposal, background upload
  acknowledgement, image-only sending and no replay after an uncertain upload.
- Static analysis: **no issues**. Existing Rust/native protocol code and dependency
  versions did not change; previous Rust test results are not a new run here.

Logs: `.tmp/attachment-full-tests.log`, `.tmp/attachment-analysis.log`, and
`.tmp/attachment-build.log`.

### Isolated emulator and phone installation

The Android 16 / 16 KB read-only AVD used a generated checkerboard PNG and a
loopback-only fixture. Google Play Services remained disabled. The fixture accepts
only the exact generated test image; every task/control write is rejected.

- The actual system photo selector displayed the generated picture. Choosing it
  returned to a live conversation with a visible draft thumbnail and enabled Send.
- Tapping the thumbnail opened the fullscreen image at the correct aspect ratio.
  Background/resume and leaving/reopening the conversation restored the thumbnail.
  Removing the attachment removed the strip and disabled an otherwise empty Send.
- Fixture counters: **one accepted synthetic upload**, three authenticated-route
  preview reads, and **zero task/control writes**. Neither the real gateway nor
  the user's photos were used for this check.
- Three-ABI release APK build passed all **21 ELF** checks. The test-signed copy
  passed APK alignment and signature verification, retaining the existing Android
  debug certificate. The AAB was not rebuilt.
- Wireless ADB replacement installation on the Lenovo Android 13 phone returned
  **Success**; launch succeeded and the installed SHA-256 matched. The original
  `2026-10-28 10:11:30` first-install timestamp was unchanged. No uninstall, data
  clear, credential deletion, gateway removal or real task submission was performed.
  The phone's own gallery/real-image upload still needs user confirmation.

Evidence: `build/reports/android/attachment-emulator.json`, `attachment-phone.json`,
`attachment-source-android16.png`, `attachment-picker-android16.png`,
`attachment-draft-android16.png`, and `attachment-preview-android16.png`.

Latest APKs:

| Artifact | SHA-256 |
| --- | --- |
| `flutter-apk/app-release.apk` (unsigned) | `0be2757242e1d10032d4ac9edda876753a67e7fa3bdc74756a0975ecdfad5890` |
| `flutter-apk/app-local-test.apk` (test-signed release-mode copy) | `a5c47df5bd99e724eaca73229a28291c0e073752fc574b53ba26fd8cdccc9c70` |

## Not verified

- Physical Android workflows beyond the installation/launch check above,
  Android 8 minimum-version runtime behavior, and real Codex/Claude/Cowork/DeepSeek
  gateways and execution-owner routing.
- Camera permission/QR pairing and attachments on physical devices, weak mobile
  networks, actual gateway session revocation, and store-delivered packages.
- Independently instrumented real-gateway Android notification delivery beyond the
  user's confirmation, OEM/Doze reliability, extended battery impact, and
  foreground-service acceptance by distribution channels.
- Any iOS compilation, signing, or iPhone testing: this host is Windows. The
  macOS CI job is defined but has not been run or claimed as successful.
- Independent distribution keystore, App Store provisioning, Play internal
  testing, channel-specific compliance, and store approval.

Unsigned artifacts and test-only signatures are not public release packages.
