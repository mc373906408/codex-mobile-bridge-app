# Privacy and permissions: developer inventory

This document describes the current implementation. It is not a final legal
privacy policy or a claim of store approval. A publisher must add their identity,
contact, legal disclosures, and verified third-party SDK details before release.

## Data flow

- The app sends authentication, conversation, attachment, and control traffic
  directly to the gateway URL selected by the user. That gateway and its coding
  clients can in turn use model providers under the gateway operator's rules.
- The app has no developer-operated conversation relay, analytics endpoint,
  system-push registration, or model-provider API-key store.
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
  collection.
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
