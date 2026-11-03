# Android TLS Companion

`android/app/src/main/kotlin/org/rustls/platformverifier/CertificateVerifier.kt`
is adapted from the MIT-licensed Android companion 0.2.0 of
[rustls-platform-verifier](https://github.com/rustls/rustls-platform-verifier),
at source revision `252e25161a91af476cbea620e29d277592d27ec7`.
The accompanying MIT license is retained in this directory.

The local source keeps the 0.2.0 JNI API used by the Rust verifier. Test root
overrides are disabled in every app build, including debug. Gradle rejects
companion ABI updates until this adapter is reviewed.

## Compatibility Fix

For a trusted certificate without an OCSP responder or staple, the revocation
checker uses CRLs without falling back to an absent OCSP endpoint. The existing
best-effort `SOFT_FAIL` policy applies to indeterminate CRL status. Confirmed
revocations and other validation failures still fail. Stapled or published OCSP
retains the upstream verification path.

Android's CRL connect timeout is limited to three seconds per endpoint at app
startup so unavailable CA infrastructure does not exhaust normal HTTP connect
timeouts. No proxy, certificate trust override, or cloud-origin migration is
introduced. Certificate chain, validity, server usage, platform distrust policy,
hostname verification and TLS handshake signatures remain checked by the
platform companion and Rust verifier.

Regression tests cover missing/present OCSP, DER parsing and failure categories.
`integration_test/cloud_tls_test.dart` exercises the packaged native cloud HTTP
client on a phone: untrusted local TLS is rejected, the official capabilities
endpoint is read without credentials, and an IP origin cannot bypass hostname
verification. It does not log in, pair devices, or edit saved connections.
See [upstream issue 221](https://github.com/rustls/rustls-platform-verifier/issues/221)
for the CRL-only certificate behavior and misleading revocation classification.
