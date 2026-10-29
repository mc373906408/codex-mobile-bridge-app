# Privacy and permissions: developer inventory

This document describes the current implementation. It is not a final legal
privacy policy or a claim of store approval. A publisher must add their identity,
contact, legal disclosures, and verified third-party SDK details before release.

## Data flow

- The app sends authentication, conversation, attachment, and control traffic
  directly to the gateway URL selected by the user. That gateway and its coding
  clients can in turn use model providers under the gateway operator's rules.
- The app has no developer-operated conversation relay, app-owned analytics
  endpoint, or model-provider API-key store. Android debug builds include a
  separately consented, Lenovo-only U-Push trial described below; release and
  profile builds do not include that SDK or its credentials.
- On Android, a foreground service automatically reads notification events directly
  from all saved gateways when OS permissions allow, even while chat is in the background. It reuses the
  authenticated Rust transport and does not register with a cloud push provider.
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
| Computer URLs and preferences | Application-private SQLite |
| Draft text and attachment references | SQLite, scoped to gateway, account, provider, host, and session |
| Unconfirmed operations | SQLite records needed for user reconciliation; never automatically replayed |
| Conversation history | Bounded process memory; not a complete disk archive |
| In-app read markers | Local preferences |
| Android permission-prompt bookkeeping, scoped event hashes, opaque tap routes | Application-private Android preferences; bounded, no conversation bodies |
| Lenovo U-Push test choice and notice version | Separate application-private Android preferences; no secrets, tokens, or chat data |
| App-owned U-Push registration result | Process memory only; token copy requires explicit foreground consent |
| Vendor push installation/delivery metadata | The debug SDK manages its own private preferences/database; withdrawal is not a metadata-deletion request |

Removing a saved computer attempts logout and clears its local credentials and
associated local state. Offline removal cannot prove that the remote gateway
session has been revoked: use the gateway's device-management controls for that.
Android backup is disabled for application data. The iOS credential setting is
device-local. Platform transfer/backup behavior still needs device verification.

## Permissions and dependencies

- **Network / local network:** direct gateway access. iOS provides a local-network
  explanation; denying access must leave an actionable connection error.
- **Camera:** optional QR pairing. Manual URL/password entry remains available.
- **Notifications:** Android `POST_NOTIFICATIONS` runtime grant (Android 13+)
  plus task-activity and ongoing-connection channels. Monitoring is automatic,
  not an app preference; the old off preference is removed on upgrade. The first
  startup requests the OS permission once, without looping on denial or dismissal.
  Users retain Android's permission/channel controls; granting permission later
  automatically resumes monitoring when the app is opened. Public lock-screen
  notifications omit computer names and conversation content.
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

No APNs, FCM, OEM push, access to other apps' notifications, background task-stop
service, or cloud account synchronization is implemented. Backgrounding cancels
chat reads, not the automatic Android notification listener or the gateway's remote
task. Removing a computer clears its notification routes and deduplication state.
OS permission revocation stops notification reads without discarding deduplication;
restoration catches up only on unseen events, within the normal ten-alert bound.
Local test notifications are not proof of end-to-end delivery.

## Lenovo-only U-Push debug trial

The Android companion has a test disclosure for **configured, debuggable Lenovo
builds only**. Eligibility is checked natively using the app's debuggable flag,
device manufacturer/brand, and presence of both client credentials, not a Dart
preference. Release/profile builds and other brands cannot reuse a saved test
grant. The eligibility check itself is local; the consented SDK does send push
registration metadata to its service.

This trial integrates `com.umeng.umsdk:common:10.0.1`, `asms:1.8.7.2`, and
`push:6.7.6` as debug-only dependencies, including the push SDK's transitive
Alibaba/ACCS networking and device-identification dependencies. It tests device
registration and manually sent Umeng-console notifications. Automatic
gateway-triggered fallback delivery is **not implemented**: no device token,
gateway URL, or notification subscription is uploaded to a Bridge push server.

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
need end-to-end verification.
