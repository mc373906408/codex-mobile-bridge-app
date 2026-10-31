# Cloud relay and notifications

This describes local source implementation, not a deployed service or a signed,
device-accepted push release. Ordinary direct gateway connections remain available.
See [privacy](privacy.md) and [release gates](release-checklist.md) before distributing
either cloud variant.

## Account, pairing and control boundaries

- Add the exact canonical HTTPS origin of a hosted or independent selfhost server.
  Credentials are scoped to that origin and account ID; redirects, a similar domain,
  or membership in another account cannot migrate a credential or approval.
- Hosted service entitlement is account-wide service days. Mobile shows status;
  it provides no purchase, redemption, or external-purchase link. Desktop handles
  redemption. Selfhost capability is reported separately by the server.
- A short-lived invitation, key confirmation, encrypted proof, and explicit approval
  on the original local desktop are required. Logging into the same cloud account
  does not authorize a computer. The relay never replaces the coding-client owner.
- Control records use Noise KK and are bounded to 32 KiB. Preview keys are separate
  and use single-message Noise K. A preview key cannot send or approve a command.
- Direct/relay selection preserves the original gateway/account/host/session and
  unconfirmed-operation records. There are no offline commands or automatic replay
  of writes whose result is unknown.

## Delivery and consent

The desktop creates one durable random notification ID per event and approved
binding. Direct and vendor deliveries share that ID. The native receipt must be
persisted before a direct ACK or reconciliation. A live direct lease lasts 45
seconds; events expire after one hour. Initial observation is a quiet baseline,
not a burst of historical completion alerts.

`CloudPushController` performs passive authenticated notification reads, endpoint
registration, receipt reconciliation, and direct heartbeats. It does not execute
chat commands or treat a notification tap as an approval. A tap selects the
authenticated original conversation, subject to fresh scope checks.

Native cloud consent is independent of Android's OS permission and of the Lenovo
debug trial. Denial or withdrawal does not disable ordinary direct gateway access.
OS permission, current consent version, binding activity, expiry, receipt IDs,
and native storage/key availability still gate rendering. Missing/unavailable keys
or invalid previews permit only fixed generic local text or suppression, never
remote HTML, images, arbitrary links, or unauthenticated conversation actions.

Preview plaintext is at most 1 KiB; the complete APNs JSON is at most 4 KiB. Cloud
operators and vendors still process account/routing/installation/delivery metadata
and ciphertext. End-to-end preview encryption is not a claim that a vendor SDK
collects no metadata or that delivery is guaranteed after force-stop.

## Android variants

Ordinary release/profile builds are vendor-SDK-free by default. Debug keeps the
separate [Lenovo manual trial](umeng-push-test.md); it is not a production cloud
device registration or consent grant.

Production release/profile integration requires:

- `BRIDGE_ANDROID_PUSH=umeng`.
- `UMENG_PRODUCTION_APP_KEY` and `UMENG_PRODUCTION_MESSAGE_SECRET`, both provided
  through a secure build environment; optional `UMENG_PRODUCTION_CHANNEL`.
- A separately reviewed native notice, currently `cloud-umeng-push-v1`, and an
  explicit saved grant. Other Android variants use `cloud-notifications-v1`.
- The matching server-side application key and `UMENG_APP_MASTER_SECRET`, stored
  only on the server. The Android Message Secret is not the App Master Secret.

Client build credentials are extractable from a distributed APK; environment
injection prevents source-control disclosure, not extraction. No real signing or
vendor credential is required by the isolated compilation helper:

```sh
python -B scripts/test_android_cloud.py
```

It compiles the default and opt-in Kotlin/native integration and runs debug unit
checks using nonfunctional fixtures. It strips real signing/vendor variables.
It is not an APK/AAB, device-registration, vendor-delivery, or 16 KB artifact pass.
Run the artifact alignment and signing gates on the exact production variant and
ABI set; historical SDK-free and ARM64 debug-trial artifacts cannot cover it.

Withdrawal blocks new app-owned cloud notifications, clears cloud notifications,
and resets the quiet baseline. Preview credentials and unexpired receipts are
retained for deduplication and reconciliation; withdrawal does not delete the
cloud account or approved binding. Removing a saved binding or disabling its
cloud account is a separate local preview-storage cleanup path.

While the selected cloud account remains enabled, the controller attempts to
disable its server endpoint through authenticated requests, with at most six
attempts per native-state revision. Offline or failed requests are not confirmed
remote revocation. The native SDK disable path is separate: U-Push 6.7.6 has no
public unregister API, and disable is not deletion of vendor installation metadata
or full deinitialization of common/asms. Reopening with a persisted decline must
not initialize the SDK; verify this on a real device.

## iOS variants and storage

Ordinary iOS does not embed the notification service extension, enable APNs, or
share a preview vault. Direct local cloud notifications remain available while
the app can perform authenticated reads; ordinary iOS is not background APNs.

The `cloud` Xcode scheme uses `RunnerCloud` and `BridgeNotificationService`.
Copy the public `ios/Cloud.example.xcconfig` to the ignored
`ios/Cloud.local.xcconfig` and configure your own values:

- `BRIDGE_CLOUD_APP_BUNDLE_ID`, `BRIDGE_CLOUD_NSE_BUNDLE_ID`.
- `BRIDGE_CLOUD_APP_GROUP`, `BRIDGE_CLOUD_PREVIEW_KEYCHAIN_GROUP`.
- `BRIDGE_CLOUD_TEAM`; optional `BRIDGE_CLOUD_APS_ENVIRONMENT`.

Do not commit provisioning profiles, private signing material, vendor secrets,
or production configuration. App Group and Keychain entitlements must agree with
the final registered identities and profiles, not just the Xcode source graph.

Shared routing/consent/receipt metadata is bounded JSON in the App Group, written
atomically with fsync, excluded from backup, and protected until first device
authentication. It contains no preview plaintext or keys. Preview secrets live
in a separate shared Keychain group using `AfterFirstUnlockThisDeviceOnly`, with
no synchronization. The NSE has no cloud account/control credentials, Flutter
runtime, or networking. It only checks local policy/receipts and decrypts the
bounded preview through the isolated Rust C ABI. The native notice is
`cloud-apns-push-v1`; ordinary iOS uses `cloud-notifications-v1`.

On macOS with the pinned Flutter/Rust toolchains and Xcode:

```sh
python -B scripts/check_ios_cloud.py
python -B scripts/test_ios_cloud.py
flutter --no-version-check --suppress-analytics build ios --release --no-codesign
python -B scripts/check_ios_artifact.py build/ios/iphoneos/Runner.app
flutter --no-version-check --suppress-analytics build ios --release --flavor cloud --no-codesign
python -B scripts/check_ios_artifact.py --cloud build/ios/iphoneos/Runner.app
```

Keep Flutter analysis, tests, and builds serial in this checkout. Platform builds
intentionally omit `--no-pub` to regenerate mode-specific plugin registrations.
The Swift runner builds a Darwin-host preview archive in an isolated linker
directory and runs ordinary/native C ABI tests separately. Artifact checks inspect
app/NSE structure; they do not validate signatures, Mach-O architecture, real
shared-Keychain access, or delivery. Linux/Windows source checks cannot run these
native macOS gates.

## Acceptance still required

The existing CI now includes preview Rust lint/tests, Android compilation, Swift
C ABI tests, and serial ordinary/cloud unsigned iOS structure checks. Configuration
in this dirty checkout is not evidence of a completed hosted run.

Test the exact signed variants on real devices: consent denial and withdrawal;
foreground/background/locked/killed states; missing or locked keys; direct/push
race and restart deduplication; quiet baseline; expired/revoked accounts/bindings;
endpoint rotation and offline revocation; and NSE timeout with one safe completion.
Use only generic test content and non-production accounts. Provider acceptance,
native unit tests, and the dated Lenovo console experiment do not establish these
end-to-end cloud gates or store approval.
