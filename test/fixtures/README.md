# Public synthetic cloud identity

`cloud_identity.json` contains deterministic test-only X25519 private/public keys,
UUIDs and an invalid device token. It belongs to no real server, user or device.
The native boundary test replaces its origin with a newly allocated loopback
port and derives the corresponding safety code. It uses the current complete
credential format; retired manual-pairing fields are rejected by Rust tests.
