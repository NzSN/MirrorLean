# MirrorLean — current state

Recorded: 2026-08-18 (session, updated after t1). Authoritative design: docs/design.md.

## Done and verified

### M1 — protocol core (t1, completed)
- lean-toolchain: leanprover/lean4:v4.33.0
- lakefile.toml: lean_lib MirrorLean; lean_exe test (root test.Main), counter-example (root examples.Counter), smoke (root test.Smoke)
- MirrorLean.lean: umbrella imports (Value, Error, Protocol, Transport, Client)
- MirrorLean/Value.lean: ITF Value (int/bool/str/set/seq/tuple/map/record/variant/unserializable/null), State = Std.TreeMap String Value compare, toJson/ofJson?/prettify, #bigint boxing, empty-string bigint -> null, bare-array -> seq asymmetry, helpers asInt?/asStr?/asRecord?/getParam?/getParamInt
- MirrorLean/Error.lean: PathSeg, DiffHint (7 kinds), renderPath/renderDiffHint/renderDiffHints, StepMismatchReport, MirrorError (io/json/specInvalid/registerFailed/protocol/unexpectedMessage/stepMismatch/transportClosed/presetExhausted) + toString
- MirrorLean/Protocol.lean: ApalacheConfig (specPath is String), TraceGenerationConfig, ApalacheSpec, ValidateResult, ClientMessage (14 variants, exact wire names), MirrorMessage (18 variants), codecs; unknown proto_step -> protocol_error; malformed JSON -> MirrorError.json
- test/Main.lean: 96 unit tests (initial)

### M2 — replay path (complete)
- MirrorLean/Transport.lean: Transport (send/recv/close), spawnMirror (stdio piped, stderr inherited, flush-after-send), Transport.ofChild, stripLineEnding, Target (binary/transport)
- MirrorLean/Client.lean: StateComputer = String -> State -> State -> IO State; pureComputer; presetClient (IO.mkRef index, throws preset_client exhausted); mainLoop/replayLoop/genTracesLoop; withClose (exception safety: closes transport, maps to MirrorError.io); runClient / runClientWithTraces / runClientGenTraces; GenTracesResult
- examples/Counter.lean: counterComputer (count/parameters/action_taken; init/tick), main with MIRROR_BIN env + default mirror path
- test/Smoke.lean: MIRROR_BIN-gated; (a) trace replay of specs/traces/violation.itf.json via presetClient (ITF parser projects the vars array); (b) generate+replay, numTraces 10, view View
- specs/: Counter.tla, HourClock.tla, traces/violation.itf.json, traces/violation1.itf.json
- Verification: lake build green; lake build test green; .lake/build/bin/test = 102 tests, 0 failures
- REAL end-to-end (mirror binary + apalache 0.57):
  - .lake/build/bin/counter-example -> all traces replayed: implementation matches the model
  - .lake/build/bin/smoke -> (a) trace replay: PASS; (b) generate+replay: PASS; all checks passed

### M3 — closure + explore + validate + TCP (t1, COMPLETE)
- MirrorLean/Spec.lean: specFromFile / specFromFiles per design section 7; hand-written TLA+ scanner (line/block comments, EXTENDS/INSTANCE at line start, module list split, WITH substitutions dropped); builtin modules never resolved as files (Naturals, Integers, Reals, Sequences, FiniteSets, TLC, Bags, Apalache); lookup order: importing dir then searchDirs (TLA_LIBRARY_PATH); ambiguity is an error; SpecError { msg, contexts }
- MirrorLean/Transport.lean: connectMirror (host port) via Std.Async.TCP.Socket.Client (.block bridge), buffered line reader (recv? 4096, split \n, strip \r, EOF/zero-byte -> none)
- MirrorLean/Client.lean: runClientExplore (register_explore + same mainLoop), runClientValidate (register_validate, exactly one reply, session ends), TransitionStatus + InvariantStatus + ofString? decoders, ExploreSession namespace (start — design said open, a Lean keyword; private cmd keeps session OPEN on protocol_error; private expect; assumeTransition, nextStep, queryState, checkInvariant, assumeState, rollback, done), startExploreSession alias
- test/Main.lean: extended to 115 tests, 0 failures (spec closure fixtures, explore reply decoders, TCP loopback, MirrorError.toString formats)
- specs/CounterExplore.tla: constant-free twin of Counter.tla (STRIDES = {2,3} inlined into TICK/Next, no CONSTANTS/CInit) for the explorer smoke — apalache's explorer JSON-RPC has no cinit parameter, so specs with CONSTANTS fail inside the explorer ("SubstRule: Variable STRIDES is not assigned a value"; mirror docs/apalache/interactive.md "CONSTANTS and CInit"). Generate/replay/validate paths keep canonical Counter.tla with CInit.
- REAL end-to-end smoke (real MIRROR_BIN + apalache 0.57.0), .lake/build/bin/smoke:
  - (a) trace replay: PASS
  - (b) generate+replay: PASS
  - (c) validate: PASS (valid config ok; NoSuchInvariant -> register_error -> registerFailed)
  - (d) register_explore: PASS (3 steps; assumeState ENABLED + TraceComplete SATISFIED each step)
  - (e) explore-session walk: PASS (explorer_ready 1 init / 1 next / 1 invariant; assumeTransition 0 ENABLED; nextStep 1; queryState non-empty; checkInvariant 0 SATISFIED; rollback 0 -> 0; done)
  - skip path (MIRROR_BIN unset): prints "MIRROR_BIN not set; skipping smoke", exit 0

### Design §12 open questions — resolved
1. Scope of v1: TCP included now (Std.Async.TCP, no C deps); mTLS + Consul discovery deferred.
2. runClientValidate: included (protocol parity beyond the reference clients).
3. Error style: IO (Except MirrorError α), no throwing runClient! wrapper.
4. License: ISC (matches MirrorECMA/MirrorRust; talking the AGPL-3.0 protocol does not inherit it).
5. Lean version pin: v4.33.0.


### M4 — polish (t2, COMPLETE)
- README.md: full rewrite modeled on the MirrorECMA README — architecture diagram, three oracle modes, Counter quick start, full API listing (runClient family, runClientExplore, startExploreSession/ExploreSession, specFromFile/specFromFiles, connectMirror, configs, Value helpers), protocol message catalog + flows, ITF value format, build/test instructions, MIRROR_BIN gating, ExploreSession.start naming note, known issues (explorer cinit)
- LICENSE: ISC (copyright 2026 NzSN), matching MirrorECMA/MirrorRust
- .gitignore: .lake/, build/, *.olean, *.ilean, leanpkg.path, *.c, *.o, .agent-teams/, _apalache-out/
- .github/workflows/ci.yml: elan pinned v4.33.0, lake build, test exe, smoke exe (self-skips without MIRROR_BIN)
- Final self-review vs design sections 5-9: public surface re-exported via MirrorLean.lean umbrella; wire tables 5.5 (14 client messages) and 5.6 (18 mirror messages) match the implementation; §6 transport, §7 spec closure, §8 client layer, §9 example all in place
- Final clean build: rm -rf .lake/build && lake build && lake build test -> 115 tests, 0 failures; smoke rebuilt from clean -> (a)-(e) PASS; skip path exit 0

## Server-mode (plans/server-mode.md) — phases 0–5, COMPLETE

### Phase 0 — build spike (t1, engineer; commit 686c82e)
- Separate top-level package `server-mode/` (Lake decision D2): Lake 5.0.0 TOML cannot declare native/C targets, so the plan's "optional root module" is not expressible; the documented fallback (separate package) is used.
- `native/spike.c` + `Spike.lean` + custom `target native_spike` (compileO with system cc + `-I` Lean include dir, `-lssl -lcrypto`).
- Baseline `lake build` stays byte-identical (no OpenSSL dependency); server mode is opt-in at build time (`cd server-mode && lake build`).
- Structural finding (Phase 1): Lake 5 root-prefix module ownership means `MirrorLean.ServerMode`/`Discovery` (pure Lean) live in the ROOT package (compiled by `lake build`, never linked into baseline exes); this package holds the C shim + test/example exes.

### Phase 1 — TLS transport (t2, engineer; commit 3aa48de)
- `native/mirrorlean_tls.c/.h`: TLS 1.3-only client (min==max), CA + hostname/SAN verification (SSL_set1_host/SNI), 0600 key check, peer-cert SHA-256, best-effort close_notify; stable C ABI + Lean externs (`mirrorlean_tls_lean_*`).
- `MirrorLean/ServerMode.lean`: `TlsClientConfig` (caFile/certFile/keyFile/serverName?/expectedCertSha256?), `connectMirrorTls` returning a normal `Transport`; expiry warning (< 7 days); `MIRRORLEAN_DEBUG_TLS[=_PLAIN]` debug logging (off by default).
- `MirrorLean/Error.lean`: `MirrorError.tls`.
- Gate: direct register replay works against real `ModelMirrors --server --tls`.

### Phase 2 — Consul discovery (t3, discovery; commit 0223586)
- `MirrorLean/ServerMode/Discovery.lean`: `parseRegistryUrl` (http only, rejects https/IPv6 literals in v1), minimal HTTP/1.1 GET over `Std.Async.TCP` (status/headers, Content-Length + read-to-EOF + chunked), fail-closed JSON decode → `ServiceInfo { host, port, certSha256 }`, distinct "registry unavailable" errors, `timeoutMs` parameter.
- Gate: valid stub response → candidates; malformed/non-200/empty → `#[]`; tests green.

### Phase 3 — pinned discovery (t4, engineer; commit 68ee784)
- `connectMirrorDiscovered`: candidates in order with per-candidate `certSha256` pinning; failure closes and continues; empty/all-fail → clear aggregate error; direct `expectedCertSha256` pin for known hosts.
- `server-mode/examples/ServerMode.lean` (env-driven: MIRROR_CA/CERT/KEY/HOST/PORT/CERT_SHA256, MODELMIRRORS_REGISTRY) + README/design transport rows.
- Gate: stub registry bad-pin-then-good connects to the good candidate; direct pin mismatch closes before any JSON-lines traffic.

### Phase 4 — tests + CI (t5, qa-docs)
- `server-mode/test/gen-test-certs.sh`: ephemeral CA + server (SAN localhost/127.0.0.1) + client + second server (server2, different fingerprint) + unrelated CA (ca2) + ca2-signed client-bad cert; all keys 0600; **no private keys committed**. Certificates are X509v3 with serverAuth/clientAuth EKU — ModelMirrors' Haskell `tls` stack rejects X509v1 leaves ("LeafNotV3").
- New non-default exes in `server-mode/lakefile.lean`: `server-mode-test` (loopback, 15 checks: happy path, wrong CA, missing/invalid client cert via `-verify_return_error`, hostname mismatch, TLS 1.2-only peer, fingerprint pin ok/mismatch, key-file 0644, EOF mid-session, idempotent close, pinned discovery bad-pin-then-good/empty/all-fail), `server-mode-test-discovery` (13 stub-registry tests), `server-mode-smoke` (MIRROR_BIN-gated real E2E over mTLS, flows (a)–(e)), `server-mode-test-consul` (CONSUL_BIN-gated real-Consul, T14).
- `.github/workflows/ci.yml`: new `server-mode` job (installs libssl-dev+openssl, builds all server-mode exes, runs all four suites; real E2E + Consul self-skip); baseline job unchanged + explicit no-server-mode verification (`ldd` must show no libssl/libcrypto).
- Verified locally: baseline 115 tests; loopback 15/15 ALL PASS; discovery 13/13; real E2E (a)–(e) PASS over mTLS twice.

### Phase 5 — hardening + docs (t6, qa-docs)
- Idempotent `Transport.close` (TLS handle freed once; extra closes are no-ops) + single-owner transport rule documented.
- TLS handshake timeout: SO_RCVTIMEO/SO_SNDTIMEO during `SSL_connect` only (10 s default, `MIRRORLEAN_TLS_HANDSHAKE_TIMEOUT_MS` 1–600000), cleared after the handshake so long apalache sessions are unaffected; timeout failure reports "handshake timed out".
- IPv6 verified (getaddrinfo AF_UNSPEC; `::1` loopback connect works). `https://` registry = documented follow-up (v1 plain HTTP; mTLS+pin remain the trust boundary).
- Aggregate discovery error now names the registry URL; unused-variable linter warning removed.
- README: server-mode quick start (build → gen certs → `--server --tls` → connect) + security notes (never commit keys, 0600, expiry, registry is location-only, one owner per transport); docs/design.md moved server mode out of the v1 deferred list and annotated the open question; plans updated.

## Environment facts
- Lean 4.33.0 / Lake 5.0.0 via elan: export PATH="$HOME/.elan/bin:$PATH"
- Mirror binary (GHC 9.14.1 build): /home/nzsn/Repos/ModelMirros/dist-newstyle/build/x86_64-linux/ghc-9.14.1/ModelMirrors-0.1.0.0/x/ModelMirrors/build/ModelMirrors/ModelMirrors
- apalache-mc 0.57.0: ~/.local/bin/apalache/bin/apalache-mc (must be on PATH when the mirror runs)
- apalache 0.57 requires a view when maxError is used: TraceGenerationConfig view := some "View" for Counter
- apalache 0.57 explorer JSON-RPC has NO cinit: specs with CONSTANTS fail in the explorer; use a constant-free variant (CounterExplore.tla)
- Diff semantics (Engine/Core.hs): diffState ignores meta keys (#..., action_taken, parameters); reported states may include them

## AgentTeams state
- Team mirrorlean3: single member engineer; t1 (M3 remainder + real smoke) COMPLETED; t2 (M4 polish: README/LICENSE/.gitignore/CI + final self-review + clean build) COMPLETED — MirrorLean is DONE per design
- Active goal: goal-8c9a9917-209b-4cf6-afda-3ead64594bc6 (complete MirrorLean per design)
