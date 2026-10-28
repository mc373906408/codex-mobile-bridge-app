# Release gates

Builds, contract tests, device tests, signing, and store approval are separate
gates. Never infer a passed gate from another one.

## Automated

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
ABI scope, test-only signatures, and unverified gates. Re-run against each release.

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

## iOS and distribution

macOS, Xcode, an Apple developer account, signing profiles, and an iPhone are
required. Windows analysis/widget tests do not verify an iOS build. Build using
the pinned SDK on macOS, then archive/export with the intended provisioning
profile. Use iOS deployment target 15.0 in the app and Rust build integration.

The application identifier is independent from the reference gateway app.
Configure release signing outside version control; never use a debug signature
as a release artifact. A provisional identifier must be registered before
publishing. Do not reuse upstream store identities, icons, or signing keys.

Prepare a privacy policy (direct gateway traffic, local drafts, OS secure
  storage, no cloud relay, no model API keys, no app-owned telemetry/push SDK), camera/file
permission explanations, third-party licenses, domestic-channel declarations,
and an isolated review gateway. Check Apple's current remote-client review
requirements and Google Play's current target SDK requirements before release.
No promise of store approval is made.

Deferred: APNs, FCM, OEM pushes, terminal/Git/file workbenches, client lifecycle
management, account switching, Goal, advanced queues, HarmonyOS NEXT.
