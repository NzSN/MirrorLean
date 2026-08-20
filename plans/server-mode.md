# MirrorLean — ModelMirrors server-mode support plan

- Status: **implemented (phases 0–5 complete) — see plans/status.md**
- Recorded: 2026-08-19; phases landed 2026-08-19/20 (commits 686c82e → 68ee784 + uncommitted Phase 4/5 work)
- Authoritative upstream design: https://github.com/NzSN/ModelMirrors/blob/main/docs/server-mode-design.md
- Authoritative session protocol: https://github.com/NzSN/ModelMirrors/blob/main/docs/protocol-spec.md
- Local implementation context: `MirrorLean/Transport.lean`, `MirrorLean/Client.lean`, `docs/design.md`

## 1. Goal

Add first-class ModelMirrors **server-mode client support** to MirrorLean:

- Connect to `ModelMirrors --server <port> --tls --cert <server.crt> --key <server.key> --ca <ca.crt> [--registry <url>] [--jobs <n>]`.
- Optional discovery through the Consul-compatible service registry.
- Fingerprint pinning (`cert-sha256` from registry metadata) after the TLS handshake.
- Keep the existing JSON-lines session protocol and all `runClient*` / `ExploreSession` code unchanged.

Out of scope for this plan:

- Legacy UDP broadcast discovery (superseded in the upstream design).
- PSK + HMAC authenticated mode (documented alternative; not implemented by ModelMirrors).
- Mirror-side functionality (MirrorLean remains a client).
- `--root` filesystem confinement and per-IP DoS hardening (mirror-side concerns).

## 2. Current state

Already present in MirrorLean:

| Capability | Where | Status |
|---|---|---|
| JSON-lines framing over stdio | `Transport.spawnMirror`, `Transport.ofChild` | ✅ |
| Plain TCP transport | `Transport.connectMirror host port` | ✅ |
| Pluggable transport | `structure Transport` (`send`/`recv`/`close`) + `Target.transport` | ✅ |
| Full session client | `Client.runClient*`, `runClientExplore`, `runClientValidate`, `ExploreSession` | ✅ |
| Existing ModelMirrors modes | stdio and legacy `--serve <port>` | ✅ |

Missing for current server mode:

| Requirement | Status |
|---|---|
| TLS 1.3 mutual-auth client (CA + client cert/key + hostname/SAN) | ❌ |
| Peer-certificate SHA-256 fingerprint | ❌ |
| Consul `/v1/health/service/modelmirrors?passing=true` discovery | ❌ |
| Registry `cert-sha256` pinning with fail-closed candidate fallback | ❌ |
| Server-mode docs, examples, tests, CI | ❌ |

Known constraints:

- Lean 4.33.0 / Lake 5.0.0; current project is Std-only, no third-party Lean packages.
- Lean stdlib has **no TLS stack** and no general HTTP client.
- `MirrorLean.lean` re-exports the base modules; linking the base library currently needs no native libraries.
- `docs/design.md` already records that mTLS + Consul discovery were deferred pending an FFI decision.

## 3. Upstream requirements (client side only)

From `docs/server-mode-design.md`:

1. **Direct mTLS connect**
   - TLS 1.3 only.
   - Client authenticates server against a pinned CA and validates hostname (SAN).
   - Client presents its own certificate/key; server requires it.
   - No extra protocol messages: after handshake, first client message is a normal `Register*`.
2. **Discovery**
   - `GET /v1/health/service/modelmirrors?passing=true`.
   - Extract each entry's `Service.Address`, `Service.Port`, and `Service.Meta.cert-sha256`.
   - Malformed registry JSON fails closed (`[]`).
   - Registry unreachable / unavailable: direct connection remains possible.
3. **Fingerprint pinning**
   - If a candidate carries `cert-sha256`, compare against the peer cert SHA-256 **after** the TLS handshake.
   - Mismatch closes the connection and tries the next candidate.
   - A compromised registry can cause denial of service, but never authentication bypass.
4. **Operational parity with ModelMirrors TLS client**
   - Key file must not be group/other readable (`0600`) on POSIX.
   - Warn when the client certificate is expired or expires within 7 days.
   - Clean shutdown: best-effort TLS `close_notify`, ignore peer-already-closed errors.
   - Debug switch `MIRRORLEAN_DEBUG_TLS=1` (no secret material; line counts/plaintext can optionally mirror upstream `TXPLAIN`/`RXPLAIN` behavior behind the flag).

## 4. Architecture decisions

### D1 — Native OpenSSL shim for TLS (not a subprocess wrapper)

Use **OpenSSL (`libssl` + `libcrypto`) through a small C shim**, exposed to Lean with `@[extern]`.

Reasons:

- TLS 1.3 with mutual auth, hostname verification, SNI, peer-certificate digest, and graceful close are all available in one vetted library.
- Fingerprint pinning needs the actual peer certificate after the handshake; this is natural with `SSL_get_peer_certificate` + `X509_digest`, but awkward with `openssl s_client` subprocess parsing.
- The resulting `Transport` can stream JSON lines directly, reusing MirrorLean's buffered line-reader logic.

Rejected alternative: wrapping `openssl s_client` as a child process. It would work for a demo, but handshake-failure reporting, fingerprint extraction, process lifecycle, and EOF behavior are all fragile; it does not make a credible library API.

Rejected alternative: pure-Lean TLS. Implementing TLS 1.3 correctly is not a realistic project task and would be an unvetted cryptographic implementation.

### D2 — Optional, separately linked server-mode module

- New `MirrorLean/ServerMode.lean` (namespace `MirrorLean.ServerMode`) contains TLS + discovery APIs.
- The C shim lives in `native/`.
- `MirrorLean.lean` **does not** re-export `ServerMode` in v1. Baseline `lake build`, `test`, and `smoke` remain buildable on machines without `libssl-dev`.
- A new Lake target/library (`mirrorlean-server-mode`) and executables link OpenSSL explicitly.
- Users import `MirrorLean.ServerMode` directly; the base session modules remain unchanged.

This keeps the current "baseline has no C dependencies" property and makes server-mode support opt-in at build time.

> Spike must validate the exact Lake 5 mechanics for `@[extern]` + a C target. If Lake cannot keep the C target optional cleanly, the fallback is a separate top-level package/target `server-mode/` (same decision, coarser split).

### D3 — Consul discovery over a minimal HTTP/1.1 client in Lean

- Registry API in the upstream design is plain HTTP (`http://`).
- Implement a small HTTP GET client over the existing `Std.Async.TCP` socket layer:
  - request path `/v1/health/service/modelmirrors?passing=true`,
  - parse status line and headers,
  - support `Content-Length` and read-to-EOF bodies; add chunked decoding if the spike shows Consul uses it,
  - bounded timeouts where Lean `IO`/`Async` facilities allow.
- Decode the Consul JSON response with `Lean.Json` (already used throughout MirrorLean).
- Malformed JSON or unexpected shape returns `#[]` (fail closed), exactly as the upstream design requires.
- Registry network/HTTP errors are reported distinctly from "no candidates".

Fallback if Lean timeout/cancellation proves impractical: call `curl -fsS --max-time 5 ...` as a subprocess. `curl` is present on Ubuntu CI and macOS; this is an implementation detail behind `discoverMirrors`.

### D4 — No changes above `Transport`

All `Client` entry points, `ExploreSession`, message codecs, and `Target.transport` remain unchanged. Server mode is purely a new `Transport` producer, plus discovery helpers that choose one.

### D5 — Error surface

- Add `MirrorError.tls (msg : String)` for TLS setup/handshake failures surfaced through existing `Except MirrorError` paths where appropriate.
- Direct constructor helpers (`connectMirrorTls`, `connectMirrorDiscovered`) follow existing `spawnMirror`/`connectMirror` style: return `IO Transport` and throw `IO.userError` with a clear message on setup failure. A spike decides whether this is ergonomic enough or whether typed `IO (Except MirrorError Transport)` is better for all new constructors.
- Registry malformed responses never throw; they return `#[]`.

## 5. Proposed public API

```lean
import MirrorLean.ServerMode

namespace MirrorLean.ServerMode

structure TlsClientConfig where
  caFile             : System.FilePath
  certFile           : System.FilePath
  keyFile            : System.FilePath
  serverName         : Option String := none   -- defaults to connection host
  expectedCertSha256 : Option String := none   -- direct-connect pinning

structure ServiceInfo where
  host       : String
  port       : UInt16
  certSha256 : Option String

-- TLS 1.3 mTLS connection; returns a normal Transport after handshake.
def connectMirrorTls (cfg : TlsClientConfig) (host : String) (port : UInt16) : IO Transport

-- Consul health lookup; malformed JSON/unexpected shape => #[]
def discoverMirrors (registryUrl : String) : IO (Array ServiceInfo)

-- Discover candidates, then try each in order with cert-sha256 pinning.
-- No candidates or all-candidates-failed throws the aggregated error.
def connectMirrorDiscovered (cfg : TlsClientConfig) (registryUrl : String) : IO Transport
```

Usage stays transport-agnostic:

```lean
let tls := { caFile := "ca.crt", certFile := "client.crt", keyFile := "client.key" }
let tr ← ServerMode.connectMirrorTls tls "mirror.example" 8443
runClient (.transport tr) cfg tc compute
```

Optional env-driven example:

- `MIRROR_CA`, `MIRROR_CERT`, `MIRROR_KEY`
- `MIRROR_HOST`, `MIRROR_PORT`
- `MODELMIRRORS_REGISTRY` (optional; if set, use discovery)
- `MIRROR_CERT_SHA256` (optional direct pin)

## 6. Work breakdown

### Phase 0 — Spike: Lean FFI + Lake native linking

**Goal:** prove the build mechanics before writing the real TLS code.

Tasks:

1. Add a throwaway `@[extern]` Lean declaration and a tiny C function under `native/`.
2. Make a non-default Lake target link it with `-lssl -lcrypto`.
3. Confirm:
   - baseline `lake build` / `lake build test` still succeed with no OpenSSL dev files installed;
   - the new target builds after `apt install libssl-dev`;
   - Lean `String`/`ByteArray` ↔ C ABI is understood and error-buffer marshalling works.
4. Decide the exact Lake structure from D2 (optional root-module vs separate package).

Deliverable: a committed spike executable and a short note in `plans/` or `docs/design.md`.

**Gate:** baseline green without `libssl-dev`; spike target green with it.

### Phase 1 — TLS transport (`connectMirrorTls`)

**Goal:** direct mTLS connection to `ModelMirrors --server --tls` works.

Tasks:

1. `native/mirrorlean_tls.c` / `.h`:
   - create TLS 1.3-only client context (`TLS_client_method`, min/max = `TLS1_3_VERSION`);
   - load CA file, client certificate and private key;
   - verify peer against CA and hostname (`SSL_set1_host` / `X509_VERIFY_PARAM_set1_host`), set SNI;
   - POSIX socket connect (DNS via `getaddrinfo`), `SSL_set_fd`, handshake;
   - expose `read`, `write`, `close`, and `peer_cert_sha256` over a stable C ABI;
   - return human-readable errors in a caller-provided buffer;
   - POSIX: reject key files readable by group/other (0600); Windows: skip permission check.
2. Lean side:
   - `MirrorLean/ServerMode.lean`: `TlsClientConfig`, `connectMirrorTls`;
   - reuse/extract the newline-buffering helper from `Transport.lean` for TLS `recv`;
   - `close` does best-effort `SSL_shutdown` and returns `0` (daemon exit code is not meaningful for TCP).
3. `MirrorLean/Error.lean`: add `MirrorError.tls`.
4. Cert expiry warning (`< 7 days`) if the C shim can report leaf validity cheaply; otherwise parse from OpenSSL CLI in tests and defer to a follow-up.
5. Debug logging behind `MIRRORLEAN_DEBUG_TLS=1` (off by default; log line lengths by default, full plaintext only when explicitly requested by a second flag).

Deliverable: `connectMirrorTls` + native shim + unit-level loopback test.

**Gate:** direct `register` replay succeeds against a real `ModelMirrors --server --tls` with generated certs.

### Phase 2 — Consul registry discovery (`discoverMirrors`)

**Goal:** parse the Consul health endpoint fail-closed.

Tasks:

1. Minimal registry URL parser (`http://host[:port][/prefix]`, no `https://` in v1).
2. HTTP/1.1 GET client over `Std.Async.TCP`:
   - `GET <prefix>/v1/health/service/modelmirrors?passing=true HTTP/1.1`,
   - `Host`, `Connection: close`, `Accept: application/json`;
   - status-line/header parsing; body via `Content-Length` and read-to-EOF; chunked decoding if needed.
3. JSON decode:
   - expected Consul shape: array of `{ "Service": { "Address": ..., "Port": ..., "Meta": { "cert-sha256": ... } } }`;
   - missing/unexpected fields are ignored or the whole response fails closed to `#[]` per upstream semantics.
4. `ServiceInfo`, `discoverMirrors`.

Deliverable: registry client + in-process stub-server tests.

**Gate:** valid stub response returns candidates; malformed/non-200 responses return `#[]`; existing tests stay green.

### Phase 3 — Pinned discovery (`connectMirrorDiscovered`)

**Goal:** registry + mTLS + fingerprint pinning compose safely.

Tasks:

1. `connectMirrorDiscovered`:
   - `discoverMirrors` → candidates;
   - for each candidate: `connectMirrorTls` with `expectedCertSha256 := candidate.certSha256`;
   - on failure close and continue to next candidate;
   - aggregate failures if all candidates fail; empty registry is an error with a clear message.
2. Direct `TlsClientConfig.expectedCertSha256` pinning for known-host setups without a registry.
3. `examples/ServerMode.lean`: env-driven direct and discovered modes using the existing Counter computer.
4. README + `docs/design.md` transport section update.

Deliverable: pinned discovery path + example.

**Gate:** stub registry with a bad fingerprint then a good candidate connects to the good candidate; direct pin mismatch fails before any JSON-lines traffic.

### Phase 4 — Tests and CI

**Goal:** make server mode continuously verified.

Tasks:

1. `test/gen-test-certs.sh`: generate an ephemeral test CA, server cert (SAN `127.0.0.1`/`localhost`), and client cert into a temp dir; never commit private keys.
2. New `lean_exe` targets (not part of baseline default targets):
   - `server-mode-test` (unit/integration tests)
   - `server-mode-example` or reuse `examples/ServerMode.lean`.
3. Test TLS peer for fast tests without apalache:
   - preferred: `openssl s_server -Verify 1 -tls1_3 ...` scripted with a JSON-lines stub, or
   - test-only server helper added to the C shim.
4. Registry stub tests reuse the in-process `Std.Async.TCP` server pattern already used for the TCP loopback test.
5. Real E2E smoke, gated by `MIRROR_BIN` exactly like `test/Smoke.lean`:
   - start `ModelMirrors --server <port> --tls --cert ... --key ... --ca ...` with apalache on `PATH`;
   - run flows (a) trace replay, (b) generate+replay, (c) validate, (d) register_explore, (e) explore-session walk over mTLS.
6. Optional real-Consul test, gated by `CONSUL_BIN`; CI uses the stub registry.
7. `.github/workflows/ci.yml`: new `server-mode` job installs `libssl-dev openssl`; baseline job remains unchanged and explicitly exercises no-server-mode build.

Deliverable: CI job + test matrix below.

**Gate:** full suite green locally and in CI.

### Phase 5 — Hardening and documentation (final pass)

Tasks:

1. Documentation:
   - README transport table gains mTLS + registry rows;
   - quick start: generate certs, start `--server --tls`, connect with `MirrorLean.ServerMode`;
   - security notes: never commit keys, `0600`, cert expiry, registry is location-only (mTLS is the trust boundary).
2. Update `plans/status.md`, `plans/remaining.md`, and remove server mode from the v1 deferred list in `docs/design.md`.
3. Hardening if cheap:
   - connection timeout for TLS handshake and registry requests;
   - IPv6 support through existing `resolveAddress`;
   - `https://` registry behind `curl` or native TLS as a follow-up decision;
   - clearer aggregate errors when all discovery candidates fail.
4. Final self-review against upstream `docs/server-mode-design.md` sections 2–3.

**Gate:** a fresh checkout can follow README from `gen-test-certs` to a working mTLS session; all acceptance criteria hold.

## 7. Test matrix

| # | Scenario | Method | Expected |
|---|---|---|---|
| T1 | Baseline build with no system `libssl-dev` | CI baseline job | green; server-mode code not linked; no `libssl`/`libcrypto` in `ldd`/`nm` (the Lean 4.33 toolchain bundles those libs in its sysroot, so the baseline needs no system OpenSSL dev files/headers — the opt-in `server-mode/` shim alone needs `libssl-dev`) |
| T2 | Direct mTLS happy path | real ModelMirrors `--server --tls` | handshake + full replay flows pass |
| T3 | Wrong CA | loopback TLS peer | handshake fails with clear TLS error |
| T4 | Missing/invalid client cert | loopback TLS peer requiring client cert | server rejects; client reports failure |
| T5 | Hostname mismatch | cert SAN without target host | verification fails |
| T6 | TLS 1.2 peer | test server capped at 1.2 | TLS 1.3-only client fails |
| T7 | Fingerprint mismatch (direct) | `expectedCertSha256` wrong | close before JSON-lines traffic |
| T8 | Key file mode `0644` | POSIX permission check | setup error before connect |
| T9 | Registry valid response | stub Consul | candidate list parsed |
| T10 | Registry malformed/non-200/empty | stub Consul | `#[]` |
| T11 | Registry candidate bad pin then good | two stub entries + two loopback peers | first closed, second used |
| T12 | Registry unreachable | no listener | clear error, direct connect still possible |
| T13 | EOF / mirror closes mid-session | loopback TLS peer | `transportClosed`, same as TCP |
| T14 | Real Consul (optional) | `CONSUL_BIN` gated | discover + pinned connect |
| T15 | All five smoke flows over mTLS | `MIRROR_BIN` gated | (a)–(e) PASS |

## 8. Files and build changes

New:

- `MirrorLean/ServerMode.lean`
- `native/mirrorlean_tls.c`
- `native/mirrorlean_tls.h`
- `examples/ServerMode.lean`
- `test/ServerMode.lean`
- `test/gen-test-certs.sh`
- registry stub fixtures/scripts as needed

Modified:

- `lakefile.toml` — optional server-mode library/exe targets + OpenSSL link flags
- `MirrorLean/Error.lean` — `MirrorError.tls`
- `MirrorLean/Transport.lean` — only to expose shared newline-framing helpers (no behavior change)
- `.github/workflows/ci.yml` — server-mode job with `libssl-dev openssl`
- `README.md`, `docs/design.md`, `plans/status.md`, `plans/remaining.md`

Unchanged:

- `MirrorLean/Protocol.lean`, `MirrorLean/Client.lean`, `MirrorLean/Value.lean`, `MirrorLean/Spec.lean`
- Wire protocol and session state machine

## 9. Acceptance criteria

1. `import MirrorLean.ServerMode; connectMirrorTls cfg host port` completes a TLS 1.3 mutual-auth handshake against current `ModelMirrors --server --tls` and returns a normal `Transport`.
2. Every existing `runClient*` / `ExploreSession` flow works unchanged over that transport (real smoke (a)–(e)).
3. `discoverMirrors` returns Consul candidates and fails closed (`#[]`) on malformed data.
4. `cert-sha256` is verified after the handshake; mismatch closes and tries the next candidate; all candidates fail → clear aggregated error.
5. Baseline `lake build`, `lake build test`, and stdio/TCP smoke remain green on machines without system OpenSSL development files, and the baseline binaries show no `libssl`/`libcrypto` linkage (Lean 4.33 bundles those libs in its sysroot; only the opt-in C shim needs system `libssl-dev` headers).
6. CI has a server-mode job covering T2–T13, with real ModelMirrors E2E gated by `MIRROR_BIN` and optional real Consul gated by `CONSUL_BIN`.
7. README and design docs describe key generation, direct connect, and registry discovery; no private keys are committed.

## 10. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Lean FFI / Lake native target is unfamiliar | blocks all phases | Phase 0 spike before real TLS code; fallback separate package |
| OpenSSL version drift (1.1.1 vs 3.x, macOS LibreSSL) | build/runtime failures | CI pins Ubuntu OpenSSL 3; document Linux-first; macOS via Homebrew OpenSSL if supported |
| Optional linking turns out not to be optional | baseline gains a hard libssl dependency | separate package/target fallback; document as opt-in build |
| Registry HTTP response uses chunked encoding | decoder incomplete | Phase 2 spike checks real Consul; implement chunked or fall back to curl |
| Fast TLS loopback test peer instability | flaky CI | use `openssl s_server` scripted peer or test-only C server helper; keep cert generation deterministic |
| Secret material in logs/repo | credential leak | never log key/cert content; debug off by default; generated certs are per-run temp files |
| Fingerprint pinning skipped accidentally | security downgrade | tests T7/T11 assert mismatch fails closed |
| Registry plain HTTP is spoofable | redirection | this is upstream-by-design; mTLS + pinning remain the trust boundary; document clearly |

## 11. Delivery order

1. Phase 0 — build spike (short, must pass first)
2. Phase 1 — direct mTLS transport
3. Phase 2 — Consul discovery
4. Phase 3 — pinning + example + docs
5. Phase 4 — test/CI matrix
6. Phase 5 — hardening + final docs

Phases 1 and 2 can proceed in parallel after Phase 0; Phase 3 depends on both.
