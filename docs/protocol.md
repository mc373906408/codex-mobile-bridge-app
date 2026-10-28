# Gateway protocol boundary

Compatibility baseline: codex-mobile-bridge v2.1.6, commit
`b6dde4da8ad4f083c66ab9f1f3770758d623af76`. The reference repository is
read-only. This application does not communicate with private desktop IPC.

## Authentication and addressing

- A connection is an explicit origin plus optional `/d/<32 lowercase hex>`
  relay prefix. A pairing URL may additionally contain `#pair=<43 URL-safe
  characters>`. Fragments are never sent as part of an HTTP URL.
- HTTPS with normal certificate verification is mandatory except for literal
  RFC1918/loopback IPv4, `localhost`, and IPv6 loopback. No arbitrary `.local`
  names, shorthand IPv4, credentials, query strings, or other paths.
- `GET /api/auth` advertises `cookieName`, `authenticated`, `csrf`,
  `draftIdentity`, `transport`, `notifications`, and authenticated computer
  metadata. A passwordless gateway can be authenticated without a cookie.
- Password login: `POST /api/login` with `username`, `password`, `remember`.
  Pairing: `POST /api/pair` with `token`. Always send the HTTP origin, including
  the port but excluding a relay path. Write bodies have Content-Length, not
  chunked transfer encoding. Capture Set-Cookie on successful responses.
- Mobile UA includes `BridgeMobile/0.1.0-Android` or
  `BridgeMobile/0.1.0-iOS`. This affects credential lifetime only, not identity.
- Redirects and automatic HTTP retries are disabled. Credentials are bound to
  the exact saved gateway URL, not `instanceId`. A 401 or SSE logout invalidates
  credentials and current control authority.

## Allowlisted application operations

| Function | Codex | Claude / DeepSeek |
| --- | --- | --- |
| Discovery | `GET /api/clients`, `/api/codex/entries` | `GET /api/clients` |
| Sessions | `GET /api/sessions?q=&offset=&source=all` | `GET /api/desktop-sessions/{provider}/list` |
| Page | `GET /api/sessions/{id}/timeline?host=&limit=&before=` | `GET .../detail?sessionId=&historyLimit=&historyBefore=` |
| Updates | `/events?host=` (SSE) or `/poll?host=&after=` | Poll `detail` |
| Projects | `GET /api/projects` (optional `entry`) | `GET .../projects` |
| Create | `POST /api/sessions` with `project,title,id` | `POST .../create` with `projectKey,title,text,id` |
| Continue | `POST .../{id}/reconnect?host=` with `activate:true` | `POST .../resume` (when advertised) |
| Send | `POST .../{id}/send?host=` with `text,id,mode,attachments` | `POST .../send` with `sessionId,text,id,mode,attachments` |
| Stop | `POST .../{id}/stop?host=` | `POST .../stop` with `sessionId,id` |
| Approval | `POST .../{id}/respond?host=` with `requestId,response` | `POST .../respond` with `sessionId,id,requestId,decision,answers` |
| Models | `GET .../{id}/catalog?host=&kind=models` | `GET .../catalog?sessionId=&section=models` |
| Settings | `POST .../{id}/settings?host=` with `model,effort` | `POST .../settings` with `sessionId,id,model,effort` |
| Attach | Raw bytes `POST .../{id}/uploads?host=&id=&name=` | Raw bytes `POST .../uploads?sessionId=&id=&name=` |
| Inbox | `GET /api/mobile/events?after=` | Same shared endpoint; no push registration |

`...` on desktop routes means `/api/desktop-sessions/claude` or
`/api/desktop-sessions/deepseek`. Desktop session IDs are opaque strings, not
UUIDs. Codex IDs are canonical UUIDs; every route retains its execution host.

## Safety and state

Codex `timeline.rows` is presentation and `timeline.meta` supplies current
control state. `access.canSend/canInterrupt/canApprove/canReconnect/
canChangeModel` are independent. Desktop `detail.messages` is presentation;
`detail.session`, `capabilities`, and `connectionState` supply authority.
Historical pages never grant capabilities or restore approvals. Live authority
is re-read before mutation, and its identity/fingerprint must still match.

An operation is durably recorded in SQLite before any write request. Unknown
responses, timeouts, and process crashes remain pending reconciliation. Do not
automatically retry a write, including with the same ID. Only explicit gateway
receipts count as accepted; HTTP 200 alone is insufficient. Codex's
`400 / code=send_not_submitted` is a definite rejection. Desktop
`status=unknown` is not. Known blocked preflight responses are not success.

Drafts and pending writes are scoped by computer, provider, execution
environment, session ID, gateway identity, and account identity. SQLite contains
no credentials or complete chat history. The OS-backed secure store contains
the credential bundle. Switching accounts never migrates a draft automatically.

Streams are cancellable. Pausing the app cancels reads only; it never calls
stop, activates an owner, starts a client, or sends a message. Resuming requires
new authentication and control state. Flutter independently guards stale
completions with a selection generation and a history revision.

All test conversations, passwords, session identifiers, and certificates are
synthetic. Remote HTML/scripts and arbitrary remote image URLs are not executed
or fetched. Unsupported approval types remain desktop-only.
