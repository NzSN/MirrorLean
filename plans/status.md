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
