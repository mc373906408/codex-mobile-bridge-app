# Lenovo Android U-Push debug trial

This is a consented device-registration/manual-notification experiment, not a
production push rollout. Chat and the direct gateway notification listener
remain available when it is declined. Analytics/APM and OEM/FCM channels are not
enabled. Automatic gateway-triggered fallback is not connected.

## Build configuration

Set these in the environment inherited by the build process; never paste their
values into a chat, source file, command argument, or checked-in launch config:

- `UMENG_PUSH_APP_KEY`: Android application's AppKey from the Umeng push console.
- `UMENG_PUSH_MESSAGE_SECRET`: client Message Secret from that same application's
  integration settings; it is not the App Master Secret.
- `UMENG_PUSH_CHANNEL`: optional; defaults to `lenovo_test`.

Both client credentials must be present together, or both absent. If Windows
user environment variables were changed after starting Codex/the terminal, the
build process may need to be restarted to inherit them. Verify presence without
printing values. No client build/runtime code reads
`UMENG_PUSH_APP_MASTER_SECRET`; that credential belongs only on a future server.

Build with the repository's isolated toolchain and artifact verifier:

```sh
python scripts/build_android.py --format apk --debug --abi arm64-v8a
```

The debug SDK dependencies are common 10.0.1, asms 1.8.7.2, and push 6.7.6, plus
the push SDK's resolved Alibaba/ACCS dependencies. Debug APKs necessarily contain
the two client credentials; do not publish the APK or generated BuildConfig and
merged-manifest files. Environment injection is not secret protection against
APK extraction. Release/profile have neither the push SDK nor these credentials.
The artifact check must continue to enforce the repository's 64-bit native 16 KB
alignment gate; do not waive it for a vendor library.
Use the ARM64 command above for this Lenovo trial. The resolved transport's
`libtnet-3.1.14.so` passes the ELF gate on ARM64 but not x86_64; a universal debug
APK containing that x86_64 library is not a verified trial artifact. Explicit
ABI filters remain enabled in this project, so the requested ARM64 build does
not accidentally package all three Flutter architectures.

Run Flutter analysis, tests, and Android builds sequentially in this checkout
because they share plugin registrations. Do not add `--no-pub` to a platform
build. Do not run the generic skill integration/rollback scripts over this dirty
checkout: they assume analytics integration and can replace unrelated files.

## Manual device checklist

1. Select a Lenovo test device and explicitly authorize installing the debug APK.
   No install, permission grant, or push send is performed by the build helper.
2. Open Bridge. Allow or decline Android notifications as appropriate. The push
   disclosure waits until that permission prompt is finished and the Activity
   is visible/focused. On a fresh install, decline or leave it pending first;
   verify that chat/direct notifications still work and push is not registered.
3. Review the v2 disclosure and explicitly accept it for this device. A saved
   `lenovo-upush-test-v1` choice must not start the SDK. Other brands, release
   builds, and debug builds without client credentials must have no trial entry.
4. Open Settings and wait for the separate U-Push registration status. Only a
   confirmed registration/enable result makes **Copy test device token**
   available. The native clipboard action never returns the token to Dart or
   logs. Paste it only into the matching Umeng application's test console, not
   into this chat or a repository file.
5. In the [Umeng push console](https://upush.umeng.com), manually send a single
   generic preview notification to that token. Do not send chat text, credentials,
   links, attachments, or remote media. Observe the actual system notification
   shade: Bridge must show fixed local text and its own small icon, regardless
   of the remote title/body. Test foreground/background delivery separately.
   A consented cold-start can display a notification while the new in-memory
   registration callback is pending; this does not make its token copyable.
   Debug builds emit fixed local `BridgeUPushTest` diagnostic event names for
   registration, message arrival, and posting outcomes. These contain no tokens,
   message identifiers, payloads, SDK error text, or credentials; vendor logging
   remains disabled.
6. Tap the notification. It must only open Bridge, without sending a chat action,
   changing gateway state, following an external link, or exposing remote text.
   This custom notification path does not establish console click statistics.
7. Withdraw test consent in Settings. The token-copy action must disappear at
   once. Confirm that the test notifications/components stop, that late callbacks
   cannot restore a token, and that direct gateway notifications remain usable.
   Reopen the app and confirm the declined choice persists. Already-uploaded
   metadata is not deleted by withdrawal; this SDK has no public unregister API.

The `disable` acknowledgement confirms a push switch and local cleanup, not a
full deinitialization of common/asms or proof that every vendor background task
has stopped. Restart the app after withdrawal; the saved decline prevents SDK
initialization in the next process. Do not treat even a confirmed disable as
an unregister or deletion of uploaded metadata. If disabling is not confirmed,
restart before another experiment. If registration fails, verify that both
credentials belong to the same Android push application and the device has
network access; review the disclosure and explicitly retry. The device token is
sensitive registration metadata. Android 13+ marks the clipboard entry sensitive;
Bridge only clears its matching current-process copy on withdrawal.

Compilation and unit/widget tests are not an end-to-end push pass. A production
rollout needs actual device display/withdrawal evidence, reviewed third-party
disclosures, a real production privacy policy, signing/store validation, and a
separate server design that keeps the App Master Secret out of every client.

## Verified test snapshot: 2026-10-29

On a consented Lenovo L71091 running Android 13, generic manual console
notifications reached the system notification shade with Bridge foreground and
with Bridge backgrounded at the launcher while the device was awake/unlocked.
The background notification used the expected channel, fixed local text, and
resource small icon. Tapping the actual notification child opened Bridge and
automatically cleared that notification; direct gateway listening remained active.

The tested ARM64 debug APK passed the ELF/ZIP 16 KB alignment checks and client/
server credential isolation checks. All 16 native unit tests passed. This device
uses 4 KB runtime pages: static alignment is not a 16 KB runtime-device pass.
Lock-screen delivery, OS-killed-process delivery, and device-level withdrawal/
restart behavior were not verified in this snapshot. Successful retests do not
establish the unique cause of the initially missing notification.
