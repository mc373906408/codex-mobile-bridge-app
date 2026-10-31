# Release gates

Builds, contract tests, device tests, signing, and store approval are separate
gates. Never infer a passed gate from another one.

## Automated: historical SDK-free artifacts

- [x] `python scripts/check_toolchains.py`
- [x] `cargo fmt --manifest-path rust/Cargo.toml -- --check`
- [x] `cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings`
- [x] `cargo test --manifest-path rust/Cargo.toml --locked`
- [x] `flutter analyze`
- [x] `flutter test`
- [x] Native FFI async/stream/cancellation smoke test
- [x] Unsigned release APK and AAB build
- [x] Synthetic native integration test on a 16 KB Android emulator
- [x] Release-mode emulator launch and read-only synthetic gateway UI with Play Services disabled (test signature only)
- [ ] `flutter build appbundle --release` with an independent signing key
- [x] `flutter build apk --release` with bundled QR scanning and no Play Services runtime requirement or push SDK
- [x] All 64-bit ELF libraries and all Rust-core variants have 16 KB-compatible LOAD alignment; 32-bit third-party libraries are reported separately
- [x] `zipalign -c -P 16 -v 4 <apk>` succeeds
- [x] AAB bundletool configuration requests `PAGE_ALIGNMENT_16K`
- [ ] Install and run the final independently signed distribution APK on a 16 KB Android emulator/device

Checked gates refer to the local 2026-10-28 run, not a remotely executed CI job.
See [verification record](verification-2026-10-28.md) for exact artifact hashes,
ABI scope, test-only signatures, and unverified gates. They do not cover the current
dirty cloud changes, a production U-Push APK/AAB, or the iOS cloud flavor. Re-run
against each release and its exact variant/ABI set.

## Cloud continuation: final-release gates

The account/pairing/settings UI, encrypted relay, Android production opt-in,
iOS APNs/NSE source, and CI checks are implemented locally. See
[cloud notifications](cloud-notifications.md) for commands and privacy/storage
boundaries. Current source/unit/helper results are recorded in the server's
`docs/implementation-status.md`; they are not final artifact or device acceptance.

- [ ] Repeat pinned toolchain, core/preview Rust format/lint/tests, Flutter analyze/tests, real host FFI, Python helpers, and shared Noise-vector checks on the final release revision
- [ ] Observe successful hosted CI for that same revision, including Linux Go race/PostgreSQL tests, isolated Compose migration/readiness, and macOS Swift/C ABI tests
- [ ] Verify ordinary Android release/profile remain SDK-free and do not contain debug-trial or production vendor credentials
- [ ] Build the explicit production `BRIDGE_ANDROID_PUSH=umeng` APK/AAB; verify every packaged native ABI, 16 KB ELF/ZIP/bundle alignment, dependency inventory, and independent signing
- [ ] Review production U-Push disclosure/dependencies; prove neither client build nor artifact contains the server App Master Secret
- [ ] Build ordinary and `cloud` iOS variants serially; verify ordinary has no APNs/NSE/shared preview vault and cloud has exactly the intended extension and preview archive
- [ ] Check final Mach-O architectures, minimum iOS 15.0, signatures/profiles, App Group and separate preview Keychain access group on the actual app/NSE artifacts
- [ ] Verify shared metadata backup exclusion/file protection and preview-only `AfterFirstUnlockThisDeviceOnly` Keychain access on an iPhone

## Cloud devices and delivery (not provider acceptance)

Use the exact independently signed variants, non-production accounts, and generic
test content. The Lenovo 2026-10-29 manual-console snapshot is separate historical
debug-trial evidence, not production cloud acceptance.

- [ ] Hosted/selfhost capabilities, exact origin/account isolation, entitlement expiry, and desktop-only redemption with no mobile purchase/redemption links
- [ ] Five-minute QR, key comparison, encrypted proof, original local desktop approval, rejected stale/reused invitations, and binding revocation
- [ ] Native consent pending/denied/withdrawn/version-changed, OS permission/channel denial, durable-save failure, and unchanged ordinary direct functionality
- [ ] Foreground/background/locked/killed-process delivery, missing/unavailable preview keys, malformed/expired payloads, safe generic fallback or suppression, and NSE timeout with exactly one completion
- [ ] Shared durable direct/push notification IDs, receipt-before-ACK, 45-second lease, one-hour expiry, quiet initial/re-enabled baseline, and restart/race deduplication
- [ ] Token/endpoint rotation, account disable/logout, offline withdrawal/revocation, and late callbacks; distinguish local disable, server endpoint disable, and vendor metadata deletion
- [ ] Cold/warm notification taps revalidate the original account/binding/host/conversation and never submit a command, approval, or unknown-write replay

## Physical devices and real gateway (not synthetic tests)

- [ ] Android 8+ and current Android: password / QR / denied camera permission
- [ ] iPhone iOS 15+: password / QR / local network permission
- [ ] Codex local, CLI, SSH, and WSL routing retains the original owner
- [ ] Claude Code, Cowork, and DeepSeek list/history/control as advertised
- [ ] Multiline CJK input, keyboard resizing, attachment selection, long lists
- [ ] Bad certificate, cross-origin redirect, expired/reused QR, revoked device
- [ ] Weak network, SSE interruption, interrupted write, no automatic replay
- [ ] Out-of-order pages, stale approvals, account changes, duplicate taps
- [ ] Background/resume does not interrupt or restart a remote task
- [ ] Tablet master/detail and phone navigation, both themes and languages
- [ ] Android notification grant/denial, disabled channels, and permission revocation
- [ ] Automatic notification startup/resume, no repeated denied-permission prompts, and upgrade from the old saved off state
- [ ] Android 14+ `remoteMessaging` service start/stop, lock screen, and recent-task removal
- [ ] Real completion/confirmation events, offline recovery, cold/warm taps, expired accounts
- [ ] OEM battery limits, Doze, wake-lease release, and extended battery-consumption testing

## iOS and distribution

macOS, Xcode, an Apple developer account, signing profiles, and an iPhone are
required. Windows analysis/widget tests do not verify an iOS build. Build using
the pinned SDK on macOS, then archive/export with the intended provisioning
profile. Use iOS deployment target 15.0 in the app and Rust build integration.

The application identifier is independent from the reference gateway app.
Configure release signing outside version control; never use a debug signature
as a release artifact. A provisional identifier must be registered before
publishing. Do not reuse upstream store identities, icons, or signing keys.

Prepare a privacy policy covering direct and opt-in encrypted cloud traffic,
operator/vendor routing and installation metadata, local drafts, secure storage,
native receipts, versioned consent and withdrawal limits, no model API-key store,
and the exact SDK inventory of the distributed variant. Include camera/file
permission explanations, third-party licenses, domestic-channel declarations,
and an isolated review gateway. Check Apple's current remote-client review
requirements and Google Play's current target SDK requirements before release.
Include the automatic foreground messaging service, notification permission, and
CPU wake lease in privacy and battery disclosures. Verify the foreground-service
type declaration and any distribution-channel review requirements for this use.
No promise of store approval is made.

Deferred: FCM/independent OEM channels, terminal/Git/file workbenches, coding-client
lifecycle management and account switching, Goal, advanced queues, HarmonyOS NEXT.
APNs/NSE source is no longer deferred, but signed builds and device delivery remain
unchecked release gates.
