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

Removing a saved computer attempts logout and clears its local credentials and
associated local state. Offline removal cannot prove that the remote gateway
session has been revoked: use the gateway's device-management controls for that.
Android backup is disabled for application data. The iOS credential setting is
device-local. Platform transfer/backup behavior still needs device verification.

## Permissions and dependencies

- **Network / local network:** direct gateway access. iOS provides a local-network
  explanation; denying access must leave an actionable connection error.
- **Camera:** optional QR pairing. Manual URL/password entry remains available.
- **File picker:** user-selected attachment bytes. The app does not implement
  a general filesystem workbench or request all-files access.
- **Clipboard:** explicit user copying of code/text, not background clipboard
  collection.
- **Scanner:** `mobile_scanner` with bundled Android ML Kit recognition. It does
  not require a Google Play Services model download. Inspect the resolved
  native SDKs and their policies before making channel-specific data-collection
  declarations; absence of app-owned analytics is not an audit of every SDK.
- **Fonts/build integration:** IBM Plex OFL files and Cargokit licensing are
  retained. Flutter's license screen also lists registered package notices.

No APNs, FCM, OEM push, notification listener, background task-stop service, or
cloud account synchronization is implemented. Backgrounding cancels reads; it
does not stop the gateway's remote task.
