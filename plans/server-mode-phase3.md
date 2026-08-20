# MirrorLean server-mode — Phase 3 results (pinned discovery)

- Status: **done** (Phase 3 of `plans/server-mode.md`)
- Date: 2026-08-20
- Deliverables: `connectMirrorDiscovered` in `MirrorLean/ServerMode.lean`,
  `server-mode/examples/ServerMode.lean` + `server-mode-example` target,
  Phase 3 tests in `server-mode/Test/ServerMode.lean`, README +
  `docs/design.md` transport sections.

## What was built

- `connectMirrorDiscovered (cfg : TlsClientConfig) (registryUrl : String)
  : IO Transport`:
  - `discoverMirrors` → candidates (discovery's module; unreachable registry
    throws a clear error — a direct `connectMirrorTls` remains possible);
  - empty candidate list → `IO.userError` "returned no candidates";
  - for each candidate: `connectMirrorTls` with
    `expectedCertSha256 := candidate.certSha256` (candidates without a pin
    are attempted unpinned); failure closes the connection and continues;
  - all candidates failing → aggregated `IO.userError` with one line per
    candidate (`host:port: error`).
- Direct pinning (`TlsClientConfig.expectedCertSha256`) was already in place
  from Phase 1 and closes the connection before any protocol traffic on
  mismatch.
- `server-mode/examples/ServerMode.lean` (env-driven; Counter replay over
  the chosen transport): `MIRROR_CA`, `MIRROR_CERT`, `MIRROR_KEY`,
  `MIRROR_HOST`, `MIRROR_PORT`, `MODELMIRRORS_REGISTRY` (switches to
  discovery), `MIRROR_CERT_SHA256` (optional direct pin). The Counter
  computer is inlined (the root's `examples/Counter.lean` is an executable
  root, not an importable module).
- README: new "TLS 1.3 transport (server mode, opt-in)" section + two new
  transport-table rows (TLS mTLS, TLS + registry). `docs/design.md`: the
  deferred mTLS/discovery design note now documents the implemented opt-in
  server-mode transport; the v1 non-goals list updated accordingly.

## Gate verification (all green)

- **Bad pin then good candidate**: stub Consul registry listing
  `127.0.0.1:portA` with a wrong `cert-sha256` and `127.0.0.1:portB` with
  the correct one; `connectMirrorDiscovered` skips A (fingerprint mismatch
  closes it) and connects to B — palindrome echoed back. **PASS**.
- **Direct pin mismatch fails before traffic**: `connectMirrorTls` with a
  wrong `expectedCertSha256` throws "peer certificate fingerprint mismatch"
  and never returns a `Transport`. **PASS** (Phase 1 test, re-run).
- Empty registry → "no candidates" error. **PASS**.
- All candidates failing → aggregated error (contains "all 1 candidate(s)
  failed" + the per-candidate reason). **PASS**.

Commands:

```
cd server-mode && lake build
.lake/build/bin/server-mode-test     # SERVER-MODE TESTS: ALL PASS (10 checks)
# baseline (root): lake build / test / smoke green; 115/115 tests;
# no libssl and no mirrorlean_tls symbols in baseline binaries.
```

## Notes

- The real `ModelMirrors --server --tls` + registry E2E remains
  `MIRROR_BIN`-gated (Phase 4).
- Test infrastructure: `s_server -naccept 1` means each test server serves
  one connection; readiness is probed with a bind attempt (a connect probe
  would consume the single accept). `gen-test-certs.sh` now also emits
  `server2.crt/key` (same CA, different fingerprint) for the two-candidate
  test.
