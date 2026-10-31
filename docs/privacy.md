# Privacy and permissions: developer inventory

This document describes the current implementation. It is not a final legal
privacy policy or a claim of store approval. A publisher must add their identity,
contact, legal disclosures, and verified third-party SDK details before release.

## Data flow

- Ordinary connections send authentication, conversation, attachment, and control
  traffic directly to the selected gateway. That gateway and its coding clients
  can use model providers under the gateway operator's rules.
- Users may separately add an exact canonical HTTPS hosted or independent selfhost
  cloud origin and pair an encrypted relay connection. Credentials are isolated
  by origin and account ID. A short-lived invitation, key confirmation, encrypted
  proof, and explicit approval on the original local desktop are mandatory; cloud
  account membership alone never authorizes a computer or a chat action.
- The cloud protocol encrypts control with Noise KK and previews with separate
  single-message Noise K keys. Operators still process account/login, entitlement,
  device/routing, traffic and delivery metadata, and ciphertext. This source tree
  is not evidence of a deployed hosted service. Mobile shows entitlement but has
  no purchase, redemption, or external-purchase links.
- The app has no app-owned analytics endpoint or model-provider API-key store.
  Android release/profile are vendor-SDK-free by default; a production U-Push
  variant requires build-time opt-in and separate native consent. The Lenovo debug
  trial cannot authorize it. The iOS `cloud` variant adds APNs and a notification
  service extension; ordinary iOS does not. See [cloud notifications](cloud-notifications.md).
- On Android, the ordinary foreground listener reads direct-gateway notification
  events when OS permissions allow, even while chat is in the background. It reuses
  the authenticated Rust transport. Cloud notification reads, endpoint registration,
  receipt reconciliation, and heartbeats use a separate passive controller.
  Enabling a production push endpoint additionally requires current native consent
  and OS notification permission. Authenticated disabled-endpoint updates may still
  be attempted after denial or withdrawal while the cloud account remains enabled.
- Public gateways require valid HTTPS. Plain HTTP is limited to the explicitly
  supported literal private/loopback addresses; traffic on such a LAN is not
  encrypted. Use HTTPS on untrusted networks.
- Markdown is rendered natively. Remote scripts/HTML are not executed, and
  arbitrary external images are not fetched. Gateway attachments are fetched
  only through the scoped authenticated transport.

## Local data

| Data | Storage and scope |
| --- | --- |
| Gateway credentials | OS-backed secure storage, bound to the exact saved URL |
| Cloud account index and credentials | OS-backed secure storage, scoped to the exact canonical HTTPS origin and account ID |
| Relay control/binding credentials | OS-backed secure storage for the saved computer and approved cloud identity; never shared with the notification extension |
| Computer URLs and preferences | Application-private SQLite |
| Draft text and attachment references | SQLite, scoped to gateway, account, provider, host, and session |
| Unconfirmed operations | SQLite records needed for user reconciliation; never automatically replayed |
| Conversation history | Bounded process memory; not a complete disk archive |
| In-app read markers | Local preferences |
| Android permission-prompt bookkeeping, scoped event hashes, opaque tap routes | Application-private Android preferences; bounded, no conversation bodies |
| Lenovo U-Push test choice and notice version | Separate application-private Android preferences; no secrets, tokens, or chat data |
| Native cloud consent and notice version | Separate Android preferences or iOS native metadata; independent of Lenovo trial consent and OS permission |
| Android cloud preview credentials | AES-GCM-sealed application-private preferences, using an Android Keystore wrapping key; no control/account credentials |
| Android cloud receipts and baseline | Bounded durable application-private metadata: opaque routes, binding/notification IDs, expiry and ACK state; no preview bodies |
| iOS cloud routing, consent and receipts | Bounded atomic/fsync App Group JSON, excluded from backup and protected until first device authentication; no keys or preview bodies |
| iOS cloud preview credentials | Separate shared Keychain access group, `AfterFirstUnlockThisDeviceOnly`, nonsynchronizable; unavailable to ordinary iOS builds |
| App-owned push registration result | Native process memory; consented production tokens are registered with the selected cloud service, while debug token copying requires an explicit foreground action |
| Vendor push installation/delivery metadata | The consented SDK manages its own private preferences/database, and APNs/U-Push process delivery metadata; withdrawal is not a metadata-deletion request |

Removing a saved computer attempts logout and clears its local credentials and
associated local state. Offline removal cannot prove that the remote gateway
session has been revoked: use the gateway's device-management controls for that.
Android backup is disabled for application data. iOS account/control and preview
Keychain settings are device-local; shared metadata is excluded from backup.
Platform transfer/backup and real shared-Keychain access still need device verification.

## Permissions and dependencies

- **Network / local network:** direct gateways and explicitly selected cloud HTTPS
  origins. iOS provides a local-network explanation; denying access must leave an
  actionable connection error.
- **Camera:** optional QR pairing. Manual URL/password entry remains available.
- **Notifications:** Android `POST_NOTIFICATIONS` runtime grant (Android 13+)
  plus task-activity and ongoing-connection channels. Monitoring is automatic,
  not an app preference; the old off preference is removed on upgrade. The first
  startup requests the OS permission once, without looping on denial or dismissal.
  Users retain Android's permission/channel controls; granting permission later
  automatically resumes monitoring when the app is opened. Public lock-screen
  notifications omit computer names and conversation content.
- **Cloud notifications:** optional, separately versioned native consent gates
  cloud rendering and push registration, even after OS permission is granted.
  Production Android currently uses `cloud-umeng-push-v1`, iOS cloud uses
  `cloud-apns-push-v1`, and non-vendor variants use `cloud-notifications-v1`.
  Declining this consent leaves ordinary direct gateway/chat functionality intact.
- **Foreground service:** `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_REMOTE_MESSAGING`
  support automatic cross-device task-activity delivery. There is no in-app stop
  switch or notification stop action. Service starts require a foreground Activity
  and allowed notification permissions. There is no boot receiver or automatic
  restart after force-stop; reopening the app restores permission-allowed listening.
- **CPU wake lease:** `WAKE_LOCK` supports polling while the screen is off. Each
  lease expires after 90 seconds unless a live listener renews it. Stopping the
  service or removing every gateway releases it. This increases battery use and
  does not bypass Doze/OEM policies; battery exemptions remain a manual user choice.
- **File picker:** user-selected attachment bytes. The app does not implement
  a general filesystem workbench or request all-files access. The separate Photos
  entry filters the system picker to images; it does not scan the photo library.
  Selection uploads to the current gateway after the original conversation/account
  is freshly verified. Local pending previews stay in process memory; stored draft
  references reload previews only through the authenticated gateway transport.
  Image enlargement reuses the loaded bytes and makes no external image request.
- **Clipboard:** explicit user copying of code/text, not background clipboard
  collection. The debug push trial also allows an explicitly requested device
  token copy, marked sensitive on Android 13+. Withdrawal clears a matching
  token copied in the current process, without clearing unrelated content.
- **Scanner:** `mobile_scanner` with bundled Android ML Kit recognition. It does
  not require a Google Play Services model download. Inspect the resolved
  native SDKs and their policies before making channel-specific data-collection
  declarations; absence of app-owned analytics is not an audit of every SDK.
- **Fonts/build integration:** IBM Plex OFL files and Cargokit licensing are
  retained. Flutter's license screen also lists registered package notices.

There is no FCM or independently configured OEM channel, access to other apps'
notifications, or background task-stop service. Cloud accounts and APNs/native
preview source are implemented, not yet a signed/device-accepted rollout.
Backgrounding cancels chat reads, not the ordinary Android notification listener
or the gateway's remote task. Removing a computer clears its local notification
routes and deduplication state. Ordinary OS permission revocation stops rendering
without discarding deduplication; restoration consumes only unseen events within
the normal ten-alert bound. Cloud consent/permission changes reset the quiet
baseline, so re-enabling does not replay old completion alerts.

Cloud previews are bounded to 1 KiB of plaintext and 4 KiB of complete APNs JSON.
The iOS extension checks local consent, binding, expiry and durable receipts, then
decrypts through the isolated Rust C ABI. It has no account/control credentials,
Flutter runtime, or networking. Invalid/unavailable previews can only produce
fixed generic text or be suppressed, not remote HTML/media or arbitrary links.
A tap must revalidate the original authenticated conversation and is not approval.
Direct and vendor channels share a durable random notification ID; receipts must
commit before ACK. A provider's accepted send is not proof of device display.

Cloud consent withdrawal fences new app-owned delivery, clears cloud notifications,
and resets baselines, but retains preview credentials and unexpired receipts for
deduplication/reconciliation. Native push disabling and authenticated server endpoint
disabling are distinct; offline/failed requests do not prove remote revocation.
Removing a saved cloud binding or disabling its cloud account separately clears
local preview storage. Neither path is a claim of deleting vendor-held metadata.
Local test notifications are not proof of end-to-end delivery.

## Lenovo-only U-Push debug trial

The Android companion has a test disclosure for **configured, debuggable Lenovo
builds only**. Eligibility is checked natively using the app's debuggable flag,
device manufacturer/brand, and presence of both client credentials, not a Dart
preference. Release/profile builds and other brands cannot reuse a saved test
grant. A production opt-in uses its own notice and credentials. The eligibility
check itself is local; the consented SDK does send push registration metadata
to its service.

This trial integrates `com.umeng.umsdk:common:10.0.1`, `asms:1.8.7.2`, and
`push:6.7.6` for the debug trial, including the push SDK's transitive
Alibaba/ACCS networking and device-identification dependencies. It tests device
registration and manually sent Umeng-console notifications. Automatic
gateway-triggered fallback delivery is **not connected to this trial**: its device
token, gateway URL, and notification subscriptions are not uploaded to a Bridge
push server. The separate production cloud opt-in does not change that boundary.

The prompt waits for a visible, focused Activity and any Android notification
permission prompt to finish. It has no preselected consent. An outside tap
does not dismiss it; Back does not grant consent or immediately reopen it. An
explicit decline is saved and does not prompt again on each launch. Settings
offers review and withdrawal, not a notification on/off switch. An in-flight
save must finish before the dialog reports success. Storage errors fail closed
and do not expose native exception details.
On short screens or with large system text, the decision buttons scroll with
the notice so neither the disclosure nor the choices are clipped.

The notice version is `lenovo-upush-test-v2` in both the Dart UI and native
policy. The preparatory v1 choice, missing/invalid versions, and mismatched
versions do not authorize this SDK. A materially changed disclosure requires a
new version and explicit consent. A current persisted grant may resume push
registration at the next launch, without waiting for another dialog.

`preInit`, `init`, registration, enablement, and `onAppStart()` are gated on
current native consent. SDK components are disabled by default. A local provider
wrapper rechecks consent before creating the vendor provider, including on a
cold start when Android has retained component-enable settings from an earlier
installation. Shared U-App analytics, automatic page and crash collection,
optional IMEI/IMSI/ICCID/Wi-Fi MAC/app-list/referrer collection, SDK debug logs,
log uploads, package listeners, and cross-app pull-up are disabled explicitly.
This is not an audit proving that every vendor component collects no metadata.

Umeng and its Alibaba transport may process identifiers such as Android ID or
OAID, device/app information, network information, and push delivery records.
The integration does not submit chat text, attachments, gateway addresses, or
login credentials to those services. Manual console tests must use generic
content, never sensitive chat/credential data; the vendor SDK can process/cache
an incoming message even though Bridge does not render its remote body.

Bridge's custom renderer displays only fixed local text in the separate
`bridge_umeng_test` notification channel, with a local small icon. The renderer
does not fetch remote media, execute payload deep links, or open arbitrary
external destinations. These restrictions are not a guarantee that the vendor
SDK never processes or fetches remote resources before invoking the handler;
manual console tests must not include remote media or links. A tap only opens
Bridge. OS notification permission and channel controls still apply. This custom
display path is not evidence of verified console click statistics.

Withdrawal immediately removes the app-owned token and blocks test notification
delivery, then requests the SDK's `disable` operation and locally stops its
services/jobs/components and notifications. Version 6.7.6 exposes no public
unregister API; this implementation does not claim to delete the vendor's
registration or metadata. A late register/enable callback cannot restore an
unconsented token. Unconfirmed push disabling is shown separately and prevents a
push restart in the same process. Even a successful disable is not full
deinitialization of common/asms or proof of zero outgoing SDK traffic in that
process. Restart the app after withdrawal: the persisted decline prevents SDK
initialization in the next process. Bridge does not kill the app automatically
and disrupt chat. The existing direct gateway listener is untouched.

Only `UMENG_PUSH_APP_KEY`, `UMENG_PUSH_MESSAGE_SECRET`, and the optional
`UMENG_PUSH_CHANNEL` enter the debug client build. The server-only App Master
Secret is never read by client build/runtime code. Client credentials are
necessarily recoverable from a debug APK; environment injection prevents
source-control disclosure, not APK extraction. Do not distribute this trial as
a production build. See [the setup and device test checklist](umeng-push-test.md).
Code/build checks are not proof of actual notification delivery or legal/store
compliance; real device registration, notification display, and withdrawal still
need end-to-end verification. The dated [2026-10-29 manual-console snapshot](umeng-push-test.md#verified-test-snapshot-2026-10-29)
is historical trial evidence, not acceptance of the current production cloud variant.
