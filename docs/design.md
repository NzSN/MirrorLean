# MirrorLean — Design

**A Lean 4 client for the ModelMirrors protocol**

Date: 2026-08-18
Status: Historical design baseline. The client is implemented and now includes
native mTLS and typed async jobs. The [README](../README.md) and
[Async API](../MirrorLean/Async.lean) describe current behavior; older sketches
and milestone counts below are not a current support inventory.

MirrorLean is a faithful, idiomatic Lean 4 port of the
[ModelMirrors](https://github.com/NzSN/ModelMirrors) client, on parity with
[MirrorECMA](https://github.com/NzSN/MirrorECMA) (TypeScript) and
[MirrorRust](https://github.com/NzSN/MirrorRust) (Rust): it lets you write the
*system under test* as a Lean program and conformance-check it, state by state,
against a TLA+ spec whose oracle is Apalache, with the mirror doing exact
variable-by-variable state comparison.

---

## 1. Goal

A Lake package `mirrorlean` that speaks the newline-delimited JSON mirror
protocol over **stdio** (primary) and **TCP** (secondary), and exposes the full
oracle-mode surface of the protocol:

1. **Trace replay** — `register` (generate + replay) and `register_traces`
   (replay mirror-local ITF traces).
2. **Trace generation only** — `register_trace_gen`.
3. **Mirror-driven symbolic MBT** — `register_explore`.
4. **Client-driven symbolic MBT** — `register_explore_session` with the
   raw explorer command set.
5. **Validate only** — `register_validate` (present in the protocol spec but
   absent from both reference clients; we add it as a small, safe extension).

### Non-goals (v1)

- The mirror side itself (ModelMirrors stays in Haskell).
- mTLS/TLS 1.3 transports and Consul service discovery in the v1 *baseline*:
  these are **shipped**, not deferred, as the opt-in server-mode add-on
  (`MirrorLean.ServerMode` + the `server-mode/` package, phases 0–5 of
  `plans/server-mode.md`) so the baseline core library keeps zero native
  dependencies — see the transport section below.
- TLA+ parsing beyond the `EXTENDS`/`INSTANCE` closure walk needed for inline
  spec sources.

---

## 2. Protocol background (summary of what we must interoperate with)

Transport is newline-delimited UTF-8 JSON, one object per line. No greeting:
the first client message **must** be a `Register*` message, otherwise the
mirror replies `protocol_error` and closes. Client and mirror messages strictly
alternate in a lock-step loop (session modes), or alternate command/reply
(explore-session mode). Every message carries a discriminant `proto_step`.

State values use the Apalache ITF encoding
([ADR-015](https://apalache-mc.org/docs/adr/015adr-trace.html)):

| TLA+ value      | Wire JSON                                          |
|-----------------|----------------------------------------------------|
| `Int`           | `{"#bigint": "42"}` (arbitrary precision; `""` means null) |
| `Bool`          | `true` / `false`                                   |
| `Str`           | `"hello"`                                          |
| `Set`           | `{"#set": [...]}`                                  |
| `Seq`           | `[...]` (bare array)                               |
| `<<a, b>>`      | `{"#tup": [...]}`                                  |
| record/function | `{"k1": v1, ...}` (bare object)                    |
| `Map`           | `{"#map": [[k, v], ...]}`                          |
| variant         | `{"tag": t, "value": v}`                           |
| opaque          | `{"#unserializable": "..."}`                       |
| null            | `null` or `{"#bigint": ""}`                       |

This mapping is taken directly from `Apalache/Types.hs` in ModelMirrors and is
the exact interop contract for MirrorLean. Message field names and shapes follow
`Protocol/Format/Json.hs`; the full client/mirror message tables are in §5.

---

## 3. Key design decisions

1. **Lean 4.33, Lake, Std only.** No third-party Lean packages. JSON comes from
   core `Lean.Json` (`parse`/`compress`/`mkObj`/`getObj?`/`getNat?`/`getInt?`…,
   verified present in 4.33.0); ordered maps from `Std.Data.TreeMap`; process
   spawning from `IO.Process`; TCP from `Std.Async.TCP` (libuv-based, ships with
   the Lean runtime). `lean-toolchain` pins `leanprover/lean4:v4.33.0`.
2. **Blocking, single-threaded I/O.** The protocol is strict lock-step
   (send → recv → send → …), so a synchronous `IO`-based transport is simpler
   and cheaper than a task-per-message design — the same rationale MirrorRust
   documented. The only async machinery is `Std.Async.TCP` internally; we bridge
   it to `IO` with `Async.block` at the transport boundary.
3. **Hand-rolled JSON codecs on the `Lean.Json` AST.** We deliberately do **not**
   derive `ToJson`/`FromJson` for messages. The ITF encoding is asymmetric
   (encode `Set` → `{"#set":…}`, decode bare array → `Seq`; `#bigint` strings;
   `#map` key normalization) and `proto_step`-tagged sums don't map onto derived
   instances cleanly. A hand-written `encode*`/`decode*` layer is exactly what
   both reference clients do, and it gives precise, testable error messages.
4. **`State` is a sorted map.** `abbrev State := Std.TreeMap String Value compare`
   (the modern name of `RBMap`). Deterministic key order ⇒ deterministic
   `report_state` JSON and reproducible tests/error output (MirrorRust's
   `BTreeMap` decision, adopted verbatim). Record equality is key-order-free,
   and the mirror does not depend on key order.
5. **`Int` is the big-integer type.** Lean's native `Int` matches ITF
   `#bigint` semantics exactly — no external bignum library.
6. **Errors are explicit, not thrown.** Entry points return
   `IO (Except MirrorError α)`, mirroring MirrorRust's `Result`. One inductive
   `MirrorError` (§8) covers I/O, JSON, protocol, register, spec-invalid, and
   step-mismatch (carrying the full `StepMismatch` payload for reporting).
7. **`StateComputer` is an `IO`-based function.** MirrorECMA's compute is a pure
   closure with captured mutable JS state; MirrorRust's is a `&mut self` trait.
   The Lean analogue of "callback with captured mutable state" is a function
   that closes over an `IO.Ref`: `abbrev StateComputer := String → State → State → IO State`.
   Simple and faithful; pure computers lift with `pureComputer`.
8. **No regex.** Lean 4.33's stdlib ships no regex module (verified), and the
   spec-closure walk only needs to find `EXTENDS`/`INSTANCE` module names, so we
   write a small hand-rolled TLA+ comment-aware scanner (§7) instead of adding a
   C dependency.
9. **Parity-by-construction with the TS reference.** Module layout and behavior
   mirror `MirrorECMA/src` 1:1 (protocol.ts, transport.ts, spec.ts, client.ts),
   with the deliberate improvements MirrorRust already made (flush-after-send,
   `#bigint ""` → null per the protocol spec, deterministic state ordering).
   MirrorRust's explicit decisions are adopted where Lean allows.

---

## 4. Package layout

```text
MirrorLean/
├── lean-toolchain            # leanprover/lean4:v4.33.0
├── lakefile.toml             # package mirrorlean, lean_lib + lean_exe test targets
├── MirrorLean.lean           # umbrella: imports + public re-exports
├── MirrorLean/
│   ├── Value.lean            # Value, State, ITF encode/decode, helpers
│   ├── Protocol.lean         # configs, ClientMessage/MirrorMessage, DiffHint,
│   │                         #   encode/decode, prettify, render helpers
│   ├── Transport.lean        # Transport, spawnMirror, connectMirror, Target
│   ├── Spec.lean             # specFromFile / specFromFiles (EXTENDS closure)
│   └── Client.lean           # StateComputer, mainLoop, genTracesLoop,
│                             #   validateLoop, ExploreSession, entry points
├── examples/
│   └── Counter.lean          # port of the MirrorRust/TS quickstart
├── test/
│   ├── ProtocolSpec.lean     # pure codec tests (always run)
│   ├── TransportSpec.lean    # line framing / EOF against a stub peer
│   └── Smoke.lean            # end-to-end, gated on MIRROR_BIN env
└── specs/
    ├── Counter.tla           # copied fixtures from ModelMirrors
    └── traces/*.itf.json     # replay fixtures
```

```toml
# lakefile.toml (sketch)
name = "mirrorlean"
defaultTargets = ["MirrorLean"]
[[lean_lib]]
name = "MirrorLean"
root = "MirrorLean.lean"
[[lean_exe]]
name = "counter-example"
root = "examples/Counter.lean"
```

Consumers add `require mirrorlean from git "https://github.com/NzSN/MirrorLean"`.

---

## 5. Data model and wire format

### 5.1 `Value` and `State`

```lean
inductive Value where
  | int            : Int → Value
  | bool           : Bool → Value
  | str            : String → Value
  | set            : Array Value → Value        -- order-insensitive at the model level
  | seq            : Array Value → Value
  | tuple          : Array Value → Value
  | map            : Array (Value × Value) → Value
  | record         : State → Value
  | variant        : String → Value → Value
  | unserializable : String → Value
  | null           : Value
deriving Inhabited, Repr, BEq

abbrev State := Std.TreeMap String Value compare
```

Notes:

- `set` is kept as the `Array` in the order received. Client-side we never diff
  states (the mirror does `diffState`), so we don't need canonical set ordering;
  tests use structural `BEq` on encode→decode round-trips, where order is
  preserved. A semantic multiset equality helper can be added if needed.
- `map` keys are `Value` on the wire (ITF allows int/str keys; the Haskell
  mirror normalizes them to strings — `valueToText`). We keep `Array (Value × Value)`
  to preserve the wire order exactly, mirroring the TS client.

### 5.2 ITF encode/decode (`MirrorLean/Value.lean`)

```lean
def Value.toJson (v : Value) : Lean.Json
def Value.ofJson? (j : Lean.Json) : Except String Value

def State.toJson (s : State) : Lean.Json          -- {"k": enc(v), ...}, sorted keys
def State.ofJson? (j : Lean.Json) : Except String State
```

Encoding rules (exactly the Haskell `ToJSON Value` instance):

- `int n` → `{"#bigint": toString n}`; `null` → `null`
- `set` → `{"#set": [enc…]}`; `seq` → `[enc…]`; `tuple` → `{"#tup": [enc…]}`
- `map` → `{"#map": [[enc k, enc v]…]}`; `record` → bare object
- `variant t v` → `{"tag": t, "value": enc v}`; `unserializable s` → `{"#unserializable": s}`

Decoding rules (exactly the Haskell `FromJSON Value` instance, with the two
robustness fixes the TS client misses):

- object with `"#bigint"`: digits → `int`; `""` → `null` (protocol spec says
  `{"#bigint": ""}` means null; TS throws here — we follow the spec, not the bug)
- `"#tup"` → `tuple`, `"#set"` → `set`, `"#map"` → `map`, `"#unserializable"` → `unserializable`
- object whose **only** keys are `tag`+`value` with `tag : String` → `variant`
- other object → `record`; array → `seq`; bool → `bool`; string → `str`;
  number → `int` (mirror may emit bare numbers); `null` → `null`
- malformed shapes → `Except` error naming the path (`State.ofJson? "state.x[3]"`)

This asymmetry (encode `Set` boxed, decode bare array as `Seq`) is intentional
and matches the reference implementations.

### 5.3 Helpers (port of the TS/Rust helper surface)

```lean
def Value.asInt?   : Value → Option Int
def Value.asStr?   : Value → Option String
def Value.asRecord? : Value → Option State
def State.getParam? (s : State) (varName : String) : Option State      -- param var record
def State.getParamInt (s : State) (varName field : String) : Int       -- default 0
def Value.prettify : Value → Lean.Json                                 -- for error messages
def State.prettify : State → Lean.Json
```

### 5.4 Configurations

```lean
structure ApalacheConfig where
  specPath      : System.FilePath
  initPredicate : Option String := none
  nextPredicate : Option String := none
  constInit     : Option String := none
  invariant     : String
  lengthBound   : Nat          -- JSON number
  paramVars     : Option String := none

structure TraceGenerationConfig where
  numTraces : Nat
  view      : Option String := none

structure ApalacheSpec where
  sources : Array String      -- root module first, then EXTENDS/INSTANCE closure
```

Optional fields are omitted from the JSON when `none` (mirroring
`skip_serializing_if`/`JSON.stringify` semantics); the mirror's `FromJSON`
defaults `initPredicate/nextPredicate/constInit/paramVars/view` to nothing and
`lengthBound` to 10 when absent.

### 5.5 Client messages

| Lean constructor                | `proto_step`              | Fields (exact wire names) |
|--------------------------------|---------------------------|--------------------------|
| `register cfg tc spec?`         | `register`                | `apalacheConfig`, `traceConfig`, `spec?` |
| `registerTraces cfg paths`     | `register_traces`         | `apalacheConfig`, `itfTracePaths` |
| `registerTraceGen cfg tc dest spec?` | `register_trace_gen` | `apalacheConfig`, `traceConfig`, `destPath`, `spec?` |
| `registerExplore spec invs exps max` | `register_explore`   | `spec`, `invariants`, `exports`, `maxSteps` |
| `registerExploreSession spec invs exps` | `register_explore_session` | `spec`, `invariants`, `exports` |
| `registerValidate cfg bound spec?` | `register_validate`   | `apalacheConfig`, `bound`, `spec?` |
| `exploreAssumeTransition tid`  | `explore_assume_transition` | `transitionId` |
| `exploreNextStep`              | `explore_next_step`      | — |
| `exploreQueryState`            | `explore_query_state`    | — |
| `exploreCheckInvariant iid`    | `explore_check_invariant` | `invariantId` |
| `exploreAssumeState s`         | `explore_assume_state`   | `state` |
| `exploreRollback sid`          | `explore_rollback`       | `snapshotId` |
| `exploreDone`                  | `explore_done`           | — |
| `reportState s`                | `report_state`           | `state` |

```lean
def ClientMessage.toJson (m : ClientMessage) : Lean.Json
def ClientMessage.encode (m : ClientMessage) : String       -- single line, no raw newlines
```

`encode` = `Lean.Json.compress`, which escapes embedded newlines inside string
values (`
` → `\n`) — the framing constraint from the protocol spec is
automatically satisfied.

### 5.6 Mirror messages

| Lean constructor | `proto_step` | Fields |
|---|---|---|
| `specValidated result` | `spec_validated` | `result` = `"valid"` | `{"invalid": s}` |
| `initialState action state` | `initial_state` | `action`, `state` |
| `nextStep action parameters` | `next_step` | `action`, `parameters` |
| `stepOk` | `step_ok` | — |
| `stepMismatch expected actual hints` | `step_mismatch` | `expected`, `actual`, `hints` |
| `allStepsDone` | `all_steps_done` | — |
| `genTracesDone paths traces?` | `gen_traces_done` | `itfTracePaths`, `itfTraces?` (inline contents on newer mirrors) |
| `registerError err` | `register_error` | `error` |
| `protocolError err` | `protocol_error` | `error` |
| `explorerReady ni nn nv` | `explorer_ready` | `initTransitions`, `nextTransitions`, `stateInvariants` |
| `exploreTransitionStatus st` | `explore_transition_status` | `status` ∈ ENABLED/DISABLED/UNKNOWN |
| `exploreStepDone n` | `explore_step_done` | `stepNo` |
| `exploreState s` | `explore_state` | `state` |
| `exploreInvariantStatus st` | `explore_invariant_status` | `status` ∈ SATISFIED/VIOLATED/UNKNOWN |
| `exploreAssumeStatus st` | `explore_assume_status` | `status` |
| `exploreRollbackDone sid` | `explore_rollback_done` | `snapshotId` |
| `exploreSessionDone` | `explore_session_done` | — |

```lean
def MirrorMessage.ofJson? (j : Lean.Json) : Except String MirrorMessage
def MirrorMessage.decode (line : String) : Except MirrorError MirrorMessage
```

Faithful port of `walkMessage`: a **known-format but unknown `proto_step`**
decodes to `MirrorMessage.protocolError { error := "unknown proto_step: …" }`
(as the TS client does) — the session treats it as fatal, while malformed JSON
is a `MirrorError.json` with the parse message.

### 5.7 Diff hints

```lean
inductive PathSeg | field (s : String) | index (i : Nat)
inductive DiffHint
  | valueMismatch (path : Array PathSeg) (expected actual : Value)
  | missing  (path : Array PathSeg) (expected : Value)
  | extra    (path : Array PathSeg) (actual : Value)
  | missingElem (path : Array PathSeg) (expected : Value)
  | extraElem   (path : Array PathSeg) (actual : Value)
  | typeMismatch (path : Array PathSeg) (expected actual : Value)
  | truncated    (path : Array PathSeg)

def DiffHint.render (h : DiffHint) : String
def renderDiffHints (hints : Array DiffHint) : String   -- "; "-joined, "states differ" when empty
```

Wire shape (from `Format.Json`): `{"kind": …, "path": [{"field": s} | {"index": n}], "expected"/"actual" per kind}`.
`render` reproduces the Haskell `renderDiffHint` text (`at x.y[3]: expected …, got …`),
with the `truncated` fallback for unknown kinds, exactly like the TS decoder.

---

## 6. Transport layer (`MirrorLean/Transport.lean`)

```lean
structure Transport where
  send  : String → IO Unit            -- appends '
', flushes
  recv  : IO (Option String)          -- one line, or none at EOF
  close : IO UInt32                   -- mirror exit code
  asyncCapable : Bool := false        -- concrete TCP/mTLS transports set true

def spawnMirror (binPath : System.FilePath) : IO Transport
def connectMirror (host : String) (port : UInt16) : IO Transport

inductive Target
  | binary    (path : System.FilePath)
  | transport (t : Transport)
```

- **Stdio transport:** `IO.Process.spawn` with piped stdin/stdout and inherited
  stderr. `send` writes one line plus `\n` and flushes. The bounded
  `readHandleFrame` reader returns `none` only on clean EOF; malformed UTF-8,
  empty/oversized frames and partial final frames raise an error. Close drops
  stdin and waits for the child exit code.
- **TCP transport:** resolve the endpoint and connect using `Std.Async.TCP`.
  `send` writes `line ++ "\n"`. The shared TCP/TLS `recvLine` buffers chunks,
  enforces the 65,535-byte payload limit and strict UTF-8, and rejects a partial
  final frame. `asyncCapable` is true for concrete TCP/mTLS transports and false
  by default for stdio/custom transports. Close shuts down the connection.
- **TLS 1.3 transport + registry discovery (implemented, opt-in):**
  `MirrorLean.ServerMode` (in the root library; native shim + executables in
  the separate `server-mode/` package) provides `connectMirrorTls`
  (`TlsClientConfig`: CA, client cert/key, optional server name and
  `cert-sha256` pin) and `connectMirrorDiscovered` (`discoverMirrors` from a
  Consul-compatible registry, per-candidate pinning, aggregated errors).
  These are separate `Transport` producers layered on the same `Transport`
  interface; the session protocol and all client code above `Transport` are
  unchanged. The TLS engine is a small OpenSSL shim (`native/mirrorlean_tls.c`,
  TLS 1.3 only, hostname/SAN verification, 0600 key check, peer-cert SHA-256)
  linked only into server-mode targets — the baseline keeps zero OpenSSL
  dependencies (the Lean 4.33 toolchain even bundles `libssl.a`/`libcrypto.a`,
  so only the opt-in C shim needs system OpenSSL headers). Hardening (Phase 5):
  the TLS handshake is bounded by a 10 s socket timeout
  (`MIRRORLEAN_TLS_HANDSHAKE_TIMEOUT_MS`, 1–600000; cleared after the
  handshake so session traffic stays blocking); IPv6 hosts work through
  `getaddrinfo`/`AF_UNSPEC`; `Transport.close` is **idempotent** (a second
  close is a no-op — the native handle is freed once) and each transport is
  single-owner (the `runClient*`/`ExploreSession` helpers close it exactly
  once; sharing one transport across two sessions is unsupported);
  `https://` registry URLs are a documented follow-up (v1 is plain HTTP,
  and mTLS + pinning remain the trust boundary).
- Frames must contain no raw newlines — guaranteed by `Lean.Json.compress`
  escaping. The reader must never split on embedded `
`; lines are `
`-terminated
  per spec, with a trailing `
` tolerated and stripped defensively.

---

## 7. Spec source closure (`MirrorLean/Spec.lean`)

Port of `MirrorECMA/src/spec.ts`: a remote mirror has no filesystem access to
client files, so spec sources (root + transitive `EXTENDS`/`INSTANCE` closure)
travel inline in `register`/`register_trace_gen`/`register_validate`.

```lean
structure SpecError where
  msg      : String
  contexts : Array String     -- human-readable resolution trail

def specFromFile (root : System.FilePath) : IO (Except SpecError ApalacheSpec)
def specFromFiles (root : System.FilePath) (searchDirs : Array System.FilePath := #[])
  : IO (Except SpecError ApalacheSpec)
```

Behavior (identical to spec.ts):

1. Read the root file; collect `EXTENDS`/`INSTANCE` module names from each source.
2. Builtin set (`Naturals`, `Integers`, `Reals`, `Sequences`, `FiniteSets`, `TLC`,
   `Bags`, `Apalache`) is never resolved as a file.
3. Lookup order for `<Name>.tla`: importing file's directory, then `searchDirs`
   (default: `TLA_LIBRARY_PATH`, colon-separated).
4. **Ambiguity is an error:** if a module name resolves to different files in
   more than one directory, fail loudly rather than shipping the wrong module.
5. Output is `{ sources := [root, deps…] }`, root first (Apalache's
   `loadSpec` contract: `sources[0]` is the root module).

Since Lean 4.33 has no regex module, `EXTENDS`/`INSTANCE` detection is a small
hand-written scanner: strip `\*` line comments and `(* … *)` block comments
(with nesting), then match the keywords at line start (possibly indented),
splitting the module list on commas and taking the first whitespace-delimited
token of each entry (dropping `WITH …` substitutions). This is ~60 lines and
gets its own fixture tests.

---

## 8. Client layer (`MirrorLean/Client.lean`)

### 8.1 Errors

```lean
inductive MirrorError where
  | io               (e : IO.Error)
  | json             (msg : String)
  | specInvalid      (detail : String)
  | registerFailed   (detail : String)
  | protocol         (detail : String)
  | unexpectedMessage (step : String)
  | stepMismatch     (m : StepMismatchReport)
  | transportClosed
  | presetExhausted

structure StepMismatchReport where
  action : String
  params : State
  expected : State
  actual   : State
  hints    : Array DiffHint
deriving Repr

def MirrorError.toString : MirrorError → String   -- includes renderDiffHints output
```

`StepMismatchReport` carries everything the TS client uses in its error text:
action, the parameters that selected the step, expected/actual, and rendered
hints. In mirror-driven explore mode the mirror can also send
`step_mismatch` with empty states and empty hints to signal a violated state
invariant — the renderer therefore handles empty states explicitly
(`"invariant violation reported by the mirror"` instead of printing two `{}`s).

### 8.2 `StateComputer`

```lean
abbrev StateComputer := String → State → State → IO State
-- (action, params-from-mirror, previous-reported-state) → next reported state

def pureComputer (f : String → State → State → State) : StateComputer
def presetClient (states : Array State) : IO StateComputer   -- serves in order; throws presetExhausted
```

`runClient`-family functions take the computer, so stateful SUTs are written as:

```lean
def counterComputer : IO StateComputer := do
  let count ← IO.Ref.mk 0
  return fun action params prev => do
    let n := getParamInt params "parameters" "stride"
    count.modify (· + n)
    pure <| State.ofList [("count", .int (← count.get)), ("step_count", .int (← prev.step_count)) ]
```

### 8.3 Entry points (full parity surface)

```lean
def runClient (t : Target) (cfg : ApalacheConfig) (tc : TraceGenerationConfig)
    (compute : StateComputer) (spec? : Option ApalacheSpec := none)
    : IO (Except MirrorError Unit)

def runClientWithTraces (t : Target) (cfg : ApalacheConfig) (tracePaths : Array System.FilePath)
    (compute : StateComputer) : IO (Except MirrorError Unit)

structure GenTracesResult where
  itfTracePaths : Array System.FilePath   -- mirror-local (stdio mode)
  itfTraces     : Array Lean.Json         -- inline contents (newer mirrors)

def runClientGenTraces (t : Target) (cfg : ApalacheConfig) (destPath : System.FilePath)
    (tc : TraceGenerationConfig) (spec? : Option ApalacheSpec := none)
    : IO (Except MirrorError GenTracesResult)

def runClientExplore (t : Target) (spec : ApalacheSpec) (invariants exports : Array String)
    (maxSteps : Nat) (compute : StateComputer) : IO (Except MirrorError Unit)

def runClientValidate (t : Target) (cfg : ApalacheConfig) (bound : Nat)
    (spec? : Option ApalacheSpec := none) : IO (Except MirrorError Unit)

def startExploreSession (t : Target) (spec : ApalacheSpec) (invariants exports : Array String)
    : IO (Except MirrorError ExploreSession)
```

### 8.4 Replay main loop (register / register_traces / register_explore)

Identical state machine to TS `mainLoop`/Rust `main_loop`; all three register
flavors converge on it.

1. Send the `Register*` message.
2. Expect `spec_validated` (both `register` and `register_explore` send it first).
   `protocol_error`/`register_error`/anything else → close + error;
   `result := {invalid := d}` → `MirrorError.specInvalid d`.
3. Loop:
   - `initial_state {action, state}` → `s ← compute action state ∅`, send
     `report_state {state := s}`; remember `lastAction := action`.
   - `next_step {action, parameters}` → `s ← compute action parameters prev`, send
     `report_state`; remember `lastAction`, `lastParams := parameters`.
   - `step_ok` → continue.
   - `all_steps_done` → close, return `.ok ()`.
   - `step_mismatch` → close, return
     `StepMismatchReport { action := m.action | lastAction, params := lastParams, … }`
     with hints decoded.
   - `protocol_error` / `register_error` / anything else → close + corresponding error.

Note the explore-mode subtlety: in `register_explore`, `parameters` carries the
**full expected state** (including `action_taken`), not just `paramVars`-extracted
parameters — the loop is the same because the client simply passes through
whatever the mirror sends, exactly as in the reference clients. `report_state` is
always sent as `{"proto_step":"report_state","state": enc(s)}` via the
`State.toJson` encoder (not the generic message encoder), matching the TS main loop.

### 8.5 `gen_traces` loop

Expect exactly `gen_traces_done` (paths + optional inline `itfTraces`);
`protocol_error`/`register_error` → error; anything else → `unexpectedMessage`.
Close and return both path list and inline contents.

### 8.6 `validate` loop

Send `register_validate`; expect exactly one reply, then the session ends:
`spec_validated {result := "valid"}` → `.ok ()`; `{invalid := d}` → `specInvalid d`;
`register_error` → `registerFailed`; `protocol_error` → `protocol`.

### 8.7 Client-driven explore session

```lean
structure ExploreReady where
  initTransitions nextTransitions stateInvariants : Nat

structure ExploreSession where
  transport : Transport
  ready     : ExploreReady
  closed    : IO.Ref Bool

namespace ExploreSession
  def open (t : Target) (spec : ApalacheSpec) (invariants exports : Array String)
      : IO (Except MirrorError ExploreSession)
  def assumeTransition (s : ExploreSession) (tid : Nat) : IO (Except MirrorError TransitionStatus)
  def nextStep        (s : ExploreSession) : IO (Except MirrorError Nat)
  def queryState      (s : ExploreSession) : IO (Except MirrorError State)
  def checkInvariant  (s : ExploreSession) (iid : Nat) : IO (Except MirrorError InvariantStatus)
  def assumeState     (s : ExploreSession) (eqs : State) : IO (Except MirrorError TransitionStatus)
  def rollback        (s : ExploreSession) (sid : Nat) : IO (Except MirrorError Nat)
  def done            (s : ExploreSession) : IO (Except MirrorError Unit)
end ExploreSession
```

- `open` sends `register_explore_session`, requires `explorer_ready`;
  `register_error`/`protocol_error` close and fail.
- Every command is strict request/reply. A `protocol_error`, malformed reply,
  or impossible reply closes and poisons the session. The failing call returns
  its error; later calls return `transportClosed`.
- `done` requires `explore_session_done`, then closes the transport.

---

## 9. Example (the Counter port)

```lean
import MirrorLean

def counterComputer : IO StateComputer := do
  let count ← IO.Ref.mk 0
  return fun action params prev => do
    if action == "Init" || prev.isEmpty then
      count.set 0
      pure <| State.ofList [("count", .int 0), ("step_count", .int 0)]
    else
      let stride := getParamInt params "parameters" "stride"
      count.modify (· + stride)
      pure <| State.ofList [("count", .int (← count.get)),
                            ("step_count", .int (getParamInt prev "step_count" "unused") + 1))]

def main : IO Unit := do
  match ← runClient
    (Target.binary "/path/to/ModelMirrors")
    { specPath := "specs/Counter.tla", invariant := "TraceComplete",
      lengthBound := 6, constInit := some "CInit", paramVars := some "parameters" }
    { numTraces := 100 }
    (← counterComputer)
  with
  | .ok ()   => IO.println "all traces replayed: implementation matches the model"
  | .error e => IO.eprintln s!"conformance failed: {e}"
```

(The exact `step_count` plumbing is tightened at implementation time; the shape
is the contract.)

---

## 10. Testing strategy

Four layers, mirroring the sibling repos:

1. **Protocol unit tests (pure, always run via `lake test` / `lean_exe test`):**
   - ITF round-trips for every `Value` constructor, including the asymmetries
     (bare array ↔ `seq`, `#set` ↔ `set`, `#tup` ↔ `tuple`, `#map` ↔ `map`,
     variant ↔ 2-key object).
   - `#bigint` edge cases: `"0"`, negative, huge (> 2^64), `""` → `null`.
   - Decoding every `MirrorMessage` shape from fixtures; unknown `proto_step` →
     `protocolError`; malformed JSON → `MirrorError.json`.
   - `DiffHint` decode + `render` parity with the Haskell renderer.
   - `State.toJson` key ordering is deterministic (sorted).
   - `getParam`/`getParamInt`/`asInt?` helpers.
2. **Transport tests:** spawn a stub peer (`IO.Process.spawn` of a tiny script, or
   an in-process `Std.Async.TCP` server) that echoes canned lines; assert framing,
   flush-before-recv behavior, EOF → `none`, and exit-code propagation. A TCP
   loopback test covers `connectMirror`.
3. **Spec closure tests:** fixture spec forest — root + `EXTENDS` chain +
   `INSTANCE … WITH` + builtin references + `TLA_LIBRARY_PATH` lookup +
   ambiguity case (two dirs defining the same module) → error.
4. **End-to-end smoke (`test/Smoke.lean`, gated on `MIRROR_BIN` like MirrorRust):**
   - `runClient` against `specs/Counter.tla` with `presetClient` over precomputed
     traces (deterministic).
   - `runClientGenTraces` to a temp dir, then `runClientWithTraces` replays them.
   - `runClientExplore` and a scripted `startExploreSession` walk
     (assumeTransition → nextStep → queryState → checkInvariant → rollback → done).
   - `runClientValidate` valid + invalid (bad invariant) cases.
   - Fixtures: `specs/Counter.tla` + `specs/traces/*.itf.json` copied from
     ModelMirrors (as MirrorRust ships them).

**Stretch goal (optional):** model-check the harness itself the way MirrorECMA
does — replay ModelMirrors' `MirrorProtocol.tla` traces against MirrorLean's
message layer via a scripted fake SUT, proving our encode/decode layer conforms
to the protocol state machine. Parked behind the core milestones.

---

## 11. Milestones

- **M1 — Protocol core.** Lake skeleton, `Value.lean`, `Protocol.lean`,
  codecs + all pure unit tests. No I/O yet.
- **M2 — Replay path.** `Transport.lean` (stdio), `Client.lean` main loop,
  `runClient`/`runClientWithTraces`/`runClientGenTraces`, `presetClient`,
  Counter example, gated smoke test. This is already MirrorRust parity.
- **M3 — Symbolic modes + extras.** `register_explore`, `ExploreSession`,
  `runClientValidate`, `Spec.lean` closure walk, TCP transport, transport tests.
- **M4 — Polish.** Error rendering parity, docs/README, CI (GitHub Actions with
  lean toolchain + apalache), optional protocol-MBT stretch.

---

## 12. Open questions for the user

1. **Scope of v1:** include TCP now (lean stdlib `Std.Async.TCP`, no C deps), or
   stdio-only first with TCP in M3 as planned? Defer mTLS + Consul discovery?
   → **Resolved:** TCP included (M3); mTLS + Consul discovery shipped as the
   opt-in server-mode add-on (phases 0–5, `plans/server-mode.md`).
2. **`runClientValidate`:** include it (protocol parity beyond the two reference
   clients), or keep strict sibling parity?
3. **Error style:** `IO (Except MirrorError α)` (proposed) vs throwing exceptions
   with a `runClient!` wrapper for ergonomics?
4. **License:** ISC to match MirrorECMA/MirrorRust (ModelMirrors itself is AGPL-3.0;
   a client that merely talks the protocol need not inherit it — recommend ISC).
5. **Lean version pin:** `v4.33.0` (current installed here); acceptable?
