# MirrorLean server-mode — Phase 1 results (TLS transport)

- Status: **done** (Phase 1 of `plans/server-mode.md`)
- Date: 2026-08-20
- Deliverables: `MirrorLean/ServerMode.lean` (root, pure Lean),
  `server-mode/native/mirrorlean_tls.c` + `.h`, `server-mode/Test/ServerMode.lean`
  (loopback tests), `server-mode/test/gen-test-certs.sh`, lakefile updates.

## 1. Structural finding: Lake 5 module ownership (revises the Phase 0 layout)

A `lean_lib` named `MirrorLean` (the root package's library) **owns every
`MirrorLean.*` module** in any workspace that contains it: Lake's
`LeanLibConfig.isBuildableModule` uses `roots.any (root.isPrefixOf mod ∧
globs.matches root)` with **no source-file existence check**. A separate
package therefore **cannot** host `MirrorLean/ServerMode.lean` while the root
package is a Lake dependency: Lake resolves the module to the root package
and fails with "no such file".

Resolution (this is effectively the plan's D2 *primary* option, "optional root
module", with the native part staying opt-in):

- **Root package**: `MirrorLean/ServerMode.lean` and
  `MirrorLean/ServerMode/Discovery.lean` (pure Lean — extern *declarations*
  only, no C, no OpenSSL headers). The root `lakefile.toml` is untouched.
  `lake build` compiles them (pure Lean), but baseline executables never
  extract their objects from the static archive (nothing imports them), so
  the baseline keeps **no OpenSSL linkage** — verified: `ldd`/`nm` on
  `test`/`smoke` show no libssl and no `mirrorlean_tls_*` symbols.
- **server-mode package**: everything native — `native/mirrorlean_tls.c/.h`,
  the `native_tls` object target, `Test/ServerMode.lean` + `Test/Discovery.lean`
  exes with `moreLinkObjs := #[native_tls]` and explicit
  `moreLinkArgs := #["-lssl","-lcrypto"]` (Lake propagates a library's
  `moreLinkObjs` into importing executables but **not** `moreLinkArgs`).

Users import `MirrorLean.ServerMode` and build the opt-in server-mode targets
for the native pieces.

## 2. What was built

- `native/mirrorlean_tls.c` / `.h` — stable C ABI:
  - TLS 1.3 only (`TLS_client_method`, min == max == `TLS1_3_VERSION`).
  - CA loading + `SSL_VERIFY_PEER`; client cert/key + `check_private_key`.
  - SNI (`SSL_set_tlsext_host_name`) and hostname/SAN verification
    (`SSL_set1_host`).
  - POSIX `getaddrinfo` connect (IPv4+IPv6), `SSL_set_fd`, `SSL_connect`.
  - `read` (0 = clean EOF), `write` (all-bytes loop), `close` (best-effort
    two-step `SSL_shutdown`), `peer_cert_sha256` (32 bytes via
    `X509_digest`+`EVP_sha256`), `client_cert_warning` (< 7 days expiry).
  - Human-readable errors in caller buffers: `ERR_error_string_n` for the
    OpenSSL queue **plus** `X509_verify_cert_error_string` for the specific
    verification reason (e.g. "unable to get local issuer certificate",
    "Hostname mismatch").
  - POSIX key-file permission check (0600; group/other readable → error
    before connecting); Windows skips it.
  - Lean-facing `mirrorlean_tls_lean_*` wrappers using the Phase 0 ABI
    (IO results returned directly; `lean_mk_io_user_error` payloads;
    `UInt16`/`UInt64` unboxed; `ByteArray` via `lean_sarray_*`).
- `MirrorLean/ServerMode.lean` — `TlsClientConfig` (ca/cert/key, optional
  `serverName`, optional `expectedCertSha256`), `connectMirrorTls : IO
  Transport` (throws `IO.userError` on setup failure, same contract as
  `spawnMirror`/`connectMirror`), `connectMirrorTls' : IO (Except
  MirrorError Transport)` using the new `MirrorError.tls`, hex helpers, and
  debug logging behind `MIRRORLEAN_DEBUG_TLS=1` (line lengths) /
  `MIRRORLEAN_DEBUG_TLS_PLAIN=1` (full plaintext). Reuses the shared
  newline framer `MirrorLean.recvLine` (exposed from `Transport.lean`, no
  behavior change).
- `MirrorLean/Error.lean` — added `MirrorError.tls (msg : String)` +
  rendering (no exhaustive matchers elsewhere, so the baseline is
  unaffected).
- `server-mode/Test/ServerMode.lean` — loopback tests against
  `openssl s_server -rev -Verify 1 -tls1_3` with ephemeral certs.

## 3. Verification (all green)

```
# baseline (root) — unchanged behaviour, no OpenSSL anywhere
lake build && lake build test && lake build smoke     # all green
.lake/build/bin/test                                   # 115 tests, 0 failures
ldd .lake/build/bin/{test,smoke}                       # no libssl/libcrypto
nm   .lake/build/bin/{test,smoke} | grep mirrorlean_tls  # 0 symbols
git diff --quiet lakefile.toml                         # root config untouched

# server-mode (opt-in)
cd server-mode && lake build                            # spike + tests
.lake/build/bin/spike                                   # SPIKE RESULT: ALL PASS
.lake/build/bin/server-mode-test                        # SERVER-MODE TESTS: ALL PASS
```

Loopback test results (ephemeral PKI from `test/gen-test-certs.sh`):

| check | result |
|---|---|
| happy path: palindrome echoed over TLS 1.3 mTLS | PASS |
| fingerprint pin: correct `cert-sha256` connects | PASS |
| fingerprint pin: wrong pin rejected (mismatch) | PASS |
| wrong CA: handshake rejected ("verification failed") | PASS |
| hostname mismatch: rejected ("Hostname mismatch") | PASS |
| key file mode 0644: rejected before connect | PASS |
| client-cert expiry warning (< 7 days) surfaces | seen in log ("expires within 7 days (2 days)") |

## 4. Notes / deferred

- The full "direct register replay against real `ModelMirrors --server --tls`"
  gate is `MIRROR_BIN`-gated (apalache + ModelMirrors binary); the transport
  itself is proven by the loopback suite. Phase 4 (qa-docs) wires the real
  E2E smoke over mTLS.
- `s_server` sends its CA in the chain, so a wrong trust anchor yields error
  19 ("self-signed certificate in certificate chain") rather than 20; the
  loopback test checks the generic "verification failed" for that case.
- Connection/handshake timeouts are not yet enforced (blocking sockets);
  listed as Phase 5 hardening.
- OpenSSL linked statically into server-mode executables from the toolchain's
  bundled `libssl.a` (3.6.0); system headers (libssl-dev) are needed only to
  compile `mirrorlean_tls.c`.
