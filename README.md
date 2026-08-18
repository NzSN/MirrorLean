# MirrorLean

Lean 4 client for the [ModelMirrors](https://github.com/NzSN/ModelMirrors) protocol — model-based testing of state machines against TLA+ specs: replay model-generated traces or drive interactive symbolic exploration, over stdio or TCP.

## Architecture

The **TLA+ spec is the test oracle**; your Lean state machine is the system
under test (SUT). The mirror (ModelMirrors) sits between the model checker
and your code: it obtains expected states from the model via apalache-mc and
conformance-checks every state the SUT reports (variable-by-variable
equality, `diffState`).

```
               model side                        SUT side
┌──────────────┐  JSON-RPC  ┌─────────┐ JSON-lines ┌──────────┐
│ apalache-mc  │◄──────────►│ mirror  │◄══════════►│ your SUT │
│ (CLI/server) │            │ (daemon)│ stdio | TCP│(this lib)│
└──────────────┘            └─────────┘            └──────────┘
     produces expected states        checks reported states
```

Three oracle modes, all transport-agnostic:

1. **Trace replay** (`runClient`, `runClientWithTraces`,
   `runClientGenTraces`) — apalache generates counterexample traces (an
   "invariant" like `count < 12` is violated on purpose); the mirror replays
   them step-by-step and the SUT must reproduce every state.
2. **Mirror-driven symbolic MBT** (`runClientExplore`) — the mirror drives a
   live apalache explorer server, computing each successor state
   *symbolically* (no pregenerated trace), and checks state invariants after
   every step.
3. **Client-driven symbolic MBT** (`startExploreSession`) — the mirror
   proxies raw explorer commands; your test script controls the exploration:
   `assumeTransition`/`nextStep` to walk, `queryState` to read the oracle,
   `assumeState` to force concrete scenarios, `checkInvariant` to probe,
   `rollback` to backtrack.

**Physical separation:** spec sources (with their `EXTENDS` dependency
closure) travel inline inside `register`/`register_trace_gen`
(`specFromFiles`), and the mirror can run as a TCP daemon (`--serve
<port>`) — a remote mirror needs nothing but the apalache toolchain.
`register_traces` is the exception: its trace paths are mirror-local.

## Install & Build

Requires Lean 4.33.0 and Lake via [elan](https://github.com/leanprover/elan):

```bash
export PATH="$HOME/.elan/bin:$PATH"
lake build                # build the MirrorLean library
lake build test           # build the unit-test binary
lake build smoke          # build the end-to-end smoke binary
.lake/build/bin/test      # 115 tests, 0 failures
```

The smoke binary additionally needs a ModelMirrors binary and apalache-mc on
`PATH` (see [Testing](#testing)); without `MIRROR_BIN` it prints a skip
message and exits 0, like the MirrorRust smoke suite.

## Quick Start

```lean
import MirrorLean

open MirrorLean

/-- The Counter machine: count accumulates the stride the model chooses. -/
def counterComputer : IO StateComputer := do
  let count ← IO.mkRef 0
  return fun action params prev => do
    if action == "init" || prev.toList.isEmpty then
      count.set 0
      pure <| State.ofList
        [ ("count", .int 0)
        , ("parameters", .record #[("stride", .int 0)])
        , ("action_taken", .str "init") ]
    else
      let stride := State.getParamInt params "parameters" "stride"
      count.modify (fun n => n + stride)
      pure <| State.ofList
        [ ("count", .int (← count.get))
        , ("parameters", .record #[("stride", .int stride)])
        , ("action_taken", .str "tick") ]

def main : IO Unit := do
  let some bin ← IO.getEnv "MIRROR_BIN" | IO.throw "set MIRROR_BIN"
  match ← runClient
    (.binary (System.FilePath.mk bin))
    { specPath := "specs/Counter.tla", invariant := "TraceComplete",
      lengthBound := 6, constInit := some "CInit", paramVars := some "parameters" }
    { numTraces := 10, view := some "View" }
    (← counterComputer)
  with
  | .ok ()   => IO.println "all traces replayed: implementation matches the model"
  | .error e => IO.eprintln s!"conformance failed: {MirrorError.toString e}"
```

Run from the repository root with apalache on `PATH` and `MIRROR_BIN`
pointing at a ModelMirrors binary:

```bash
export PATH="$HOME/.elan/bin:$HOME/.local/bin/apalache/bin:$PATH"
export MIRROR_BIN=/path/to/ModelMirrors
lake build counter-example && .lake/build/bin/counter-example
# → all traces replayed: implementation matches the model
```

## API

Errors are values: every entry point returns `IO (Except MirrorError α)`
(`MirrorError` covers io, json, specInvalid, registerFailed, protocol,
unexpectedMessage, stepMismatch, transportClosed, presetExhausted; use
`MirrorError.toString e` — there is no `ToString` instance).

### `runClient (t : Target) (cfg : ApalacheConfig) (tc : TraceGenerationConfig) (compute : StateComputer)`

Connects to a ModelMirrors binary, registers a spec, generates
counterexample traces with apalache, and replays them all against `compute`.
Returns `.ok ()` when `all_steps_done` is received; `.error` on step
mismatch or protocol error.

`t` is a `Target`: `.binary path` spawns the mirror over stdio, or pass a
`Transport` (e.g. `connectMirror host port`) for TCP.

The `compute` function is called with:

| Event | Args | Expected return |
|---|---|---|
| `initial_state` | `(action, stateFromMirror, {})` | The initial state the client wants to report |
| `next_step` | `(action, params, prevState)` | The next state after applying the action |

### `runClientWithTraces (t : Target) (cfg : ApalacheConfig) (tracePaths : Array System.FilePath)`

Replays precomputed ITF trace files (`register_traces`). The trace paths are
**mirror-local** — for remote mirrors use `runClient`, `runClientGenTraces`,
or the explore flows.

### `runClientGenTraces (t : Target) (cfg : ApalacheConfig) (destPath : System.FilePath)`

Generates trace files only (`register_trace_gen`), no replay; returns a
`GenTracesResult` with the paths.

### `presetClient (states : Array State) : IO StateComputer`

A `StateComputer` that serves states from a pre-defined array in order;
useful for deterministic specs and for replaying a trace whose states you
already know. (`pureComputer` wraps a pure function of the same shape.)

### `runClientValidate (t : Target) (cfg : ApalacheConfig) (bound : Nat) (spec? : Option ApalacheSpec := none)`

Validate-only session (`register_validate`): exactly one `spec_validated`
reply, then the session ends. A genuine spec defect (type error or violated
invariant) is `specInvalid`; an apalache config error (e.g. an invariant
that does not exist in the spec) comes back as `registerFailed`.

### `runClientExplore (t : Target) (spec : ApalacheSpec) (invariants exports : Array String) (maxSteps : Nat) (compute : StateComputer)`

Mirror-driven **interactive symbolic model checking**. The mirror starts a
live apalache explorer server and computes each successor state
symbolically; your `compute` is conformance-checked against those states.
The message flow is identical to `runClient` (`spec_validated` →
`initial_state`/`next_step` → … → `all_steps_done`).

| Arg | Description |
|---|---|
| `spec` | `ApalacheSpec` (`{ sources : Array String }`) — TLA+ source text; use `specFromFile` / `specFromFiles` |
| `invariants` | Names of state-invariant operators, checked after every step |
| `exports` | Operator names declared for later `OPERATOR`-kind RPC queries. Unused by the mirror's current session commands — pass `#[]` |
| `maxSteps` | Exploration depth; `all_steps_done` is sent when it is reached |

Differences from the trace flows:

- `next_step.parameters` carries the **full expected state** (not
  paramVars-extracted params), so a computer may echo it — but an independent
  implementation makes the check non-vacuous.
- The reported state must contain **every** state variable, including
  `action_taken` if the spec has one (the mirror derives action names from
  it). The `paramVars` omit-from-report rule does not apply.
- The explorer JSON-RPC has **no constant initialization** (`cinit`): specs
  with `CONSTANTS` fail inside the explorer with `SubstRule: Variable …
  is not assigned a value`. Use a constant-free spec variant — see
  [Known issues](#known-issues).

### `startExploreSession (t : Target) (spec : ApalacheSpec) (invariants exports : Array String) : IO (Except MirrorError ExploreSession)`

Client-driven symbolic checking: opens an explorer session
(`register_explore_session` → `explorer_ready`) and lets you issue
explorer commands yourself; the mirror proxies each one to the apalache
server.

```lean
let s ← startExploreSession t spec #["TraceComplete"] #[]
-- s.ready : { initTransitions, nextTransitions, stateInvariants }
ExploreSession.assumeTransition s 0      -- → .enabled | .disabled | .unknown
ExploreSession.nextStep s                -- → step number
let st ← ExploreSession.queryState s     -- → State
ExploreSession.checkInvariant s 0        -- → .satisfied | .violated | .unknown
ExploreSession.assumeState s st          -- → .enabled | .disabled | .unknown
ExploreSession.rollback s 0              -- → snapshot id
ExploreSession.done s                    -- ends the session and closes the mirror
```

Commands and replies strictly alternate. A rejected command returns
`MirrorError.protocol` but the **session stays open** — you may keep issuing
commands. `invariantId` indexes into the `invariants` list passed at open.

**Naming note:** the design called this `ExploreSession.open`, but `open`
is a Lean keyword; the public name is `ExploreSession.start`, with
`startExploreSession` as the alias.

### `specFromFile (root : System.FilePath) : IO (Except SpecError ApalacheSpec)`

Reads a TLA+ file into the `{ sources := #[text] }` shape expected by the
explore and inline-spec messages.

### `specFromFiles (root : System.FilePath) (searchDirs : Array System.FilePath := #[])`

Reads a root TLA+ file **and its dependency closure** (`EXTENDS` /
`INSTANCE` clauses, resolved transitively as `<Name>.tla` next to the
importing file, then in `searchDirs`). When `searchDirs` is empty it
defaults to the `TLA_LIBRARY_PATH` environment variable (colon-separated).
Builtin modules (`Naturals`, `Integers`, `Sequences`, …) are skipped. A
module name found in more than one directory is an **ambiguity error** (the
wrong file would otherwise be shipped silently). The result is
`{ sources := #[root, ...deps] }` — root first, as apalache requires.

### TCP transport

All entry points accept a `Target` — a binary path (spawns the mirror over
stdio) or a `Transport`. `connectMirror` provides a TCP transport; run the
mirror as a daemon with `--serve <port>` (one protocol session per
connection, sequential accept loop):

```lean
-- mirror side:  ModelMirrors --serve 8823
let t : Target := .transport (← connectMirror "192.168.1.10" 8823)
-- or .binary path for stdio
```

The wire format is the same JSON-lines as stdio. Plain TCP, no TLS — use
SSH/stunnel for untrusted networks.

### `ApalacheConfig`

| Field | Type | Description |
|---|---|---|
| `specPath` | `String` | Path to the .tla file **on the mirror's filesystem** (ignored when inline `spec` is given) |
| `initPredicate?` | `Option String` | Init operator override (`--init`) |
| `nextPredicate?` | `Option String` | Next operator override (`--next`) |
| `constInit?` | `Option String` | Constant initialization operator (`--cinit`) |
| `invariant` | `String` | Invariant to violate (Apalache `--inv`) |
| `lengthBound` | `Nat` | Max Next steps (Apalache `--length`; default 10) |
| `paramVars?` | `Option String` | Variable to treat as action parameters |

### `TraceGenerationConfig`

| Field | Type | Description |
|---|---|---|
| `numTraces` | `Nat` | Number of counterexample traces (`--max-error`; default 1) |
| `view?` | `Option String` | State-view operator (`--view`; apalache 0.57 **requires** a view when `maxError` is used) |

### `StateComputer`

```lean
abbrev StateComputer := String → State → State → IO State
```

Called on each step with the action name, the mirror's parameters (or initial
state), and the previous computed state; returns the next state.

### Value helpers

```lean
State.getParam?  (s : State) (varName : String) : Option State      -- extract nested record
State.getParamInt (s : State) (varName field : String) : Int        -- extract int field
Value.asInt?  : Value → Option Int
Value.asStr?  : Value → Option String
Value.asRecord? : Value → Option State
```

## Protocol

Client and mirror exchange newline-delimited JSON, one message per line,
tagged by `proto_step`. The same framing runs over stdio (spawned child) or
TCP (`--serve <port>` daemon + `connectMirror`).

### Client → Mirror

| `proto_step` | Fields | Purpose |
|---|---|---|
| `register` | `apalacheConfig`, `traceConfig`, `spec?` | Generate traces, then replay them against the SUT |
| `register_traces` | `apalacheConfig`, `itfTracePaths` | Replay precomputed ITF traces (paths are mirror-local) |
| `register_trace_gen` | `apalacheConfig`, `traceConfig`, `destPath`, `spec?` | Generate trace files only (no replay) |
| `register_explore` | `spec`, `invariants`, `exports`, `maxSteps` | Mirror-driven symbolic exploration + conformance |
| `register_explore_session` | `spec`, `invariants`, `exports` | Open a client-driven explorer session |
| `register_validate` | `apalacheConfig`, `bound`, `spec?` | Validate a spec only (no replay) |
| `report_state` | `state` | SUT's state in response to `initial_state`/`next_step` |
| `explore_assume_transition` | `transitionId` | Session command: prepare transition |
| `explore_next_step` | — | Session command: advance one step |
| `explore_query_state` | — | Session command: read current state |
| `explore_check_invariant` | `invariantId` | Session command: check state invariant |
| `explore_assume_state` | `state` | Session command: constrain current state |
| `explore_rollback` | `snapshotId` | Session command: revert to a snapshot |
| `explore_done` | — | Close the session |

### Mirror → Client

| `proto_step` | Fields | Purpose |
|---|---|---|
| `spec_validated` | `result`: `"valid"` | `{"invalid": …}` | Spec accepted; replay/exploration begins |
| `initial_state` | `action`, `state` | First expected state |
| `next_step` | `action`, `parameters` | Next expected step (explore: full state in `parameters`) |
| `step_ok` | — | Reported state matched |
| `step_mismatch` | `expected`, `actual` (+ `hints`) | Conformance failure; run aborts |
| `all_steps_done` | — | All traces/steps verified |
| `gen_traces_done` | `itfTracePaths`, `traces` | Trace files written (paths on the mirror) |
| `explorer_ready` | `initTransitions`, `nextTransitions`, `stateInvariants` | Session opened |
| `explore_transition_status` / `explore_assume_status` | `status`: `ENABLED` | `DISABLED` | `UNKNOWN` | Command result |
| `explore_step_done` | `stepNo` | Step advanced |
| `explore_state` | `state` | Current symbolic state |
| `explore_invariant_status` | `status`: `SATISFIED` | `VIOLATED` | `UNKNOWN` | Invariant result |
| `explore_rollback_done` | `snapshotId` | Reverted |
| `explore_session_done` | — | Session closed cleanly |
| `register_error` | `error` | Registration failed (bad spec/sources); run ends |
| `protocol_error` | `error` | Protocol violation; in a session, the session **survives** |

`spec` fields have the shape `{ sources: [root, ...deps] }` (TLA+ source
text, root module first — apalache resolves `EXTENDS` across them).

### Flows

Trace replay (`register`, `register_traces`) and mirror-driven explore
(`register_explore`) share the same stepping loop:

```
client                        mirror
  |-- register(...) ------------>|
  |<-- spec_validated -----------|
  |<-- initial_state(action, s) -|
  |-- report_state(s) ---------->|
  |<-- step_ok ------------------|
  |<-- next_step(action, p) -----|
  |-- report_state(s') --------->|
  |          ... repeat ...      |
  |<-- all_steps_done -----------|
```

Generation only (`register_trace_gen`):

```
  |-- register_trace_gen(...) --->|
  |<-- gen_traces_done(paths) ----|
```

Validate only (`register_validate`):

```
  |-- register_validate(...) ---->|
  |<-- spec_validated ------------|
```

Explorer session (`register_explore_session`) — commands and replies
strictly alternate until done:

```
  |-- register_explore_session -->|
  |<-- explorer_ready ------------|
  |-- explore_assume_transition ->|
  |<-- explore_transition_status -|
  |-- explore_next_step --------->|
  |<-- explore_step_done ---------|
  |-- explore_query_state ------->|
  |<-- explore_state -------------|
  |          ... any order ...    |
  |-- explore_done -------------->|
  |<-- explore_session_done ------|
```

### Transports

| Mode | Client side | Mirror side | Notes |
|---|---|---|---|
| stdio | `Target.binary` / `spawnMirror binPath` (implicit for `.binary`) | default (no args) | Local child process |
| TCP | `connectMirror host port` | `ModelMirrors --serve <port>` | One session per connection, sequential accept loop; plain TCP, no TLS |

## Value Format

State maps use the Apalache ITF value encoding:

| Type | JSON |
|---|---|
| Int | `{"#bigint": "42"}` |
| Bool | `true` / `false` |
| Str | `"hello"` |
| Set | `[{"#bigint": "1"}, {"#bigint": "2"}]` |
| Tuple | `{"#tup": [...]}` |
| Record | `{"field": value, ...}` |

In the tagged `Value` representation these become `.int 42`,
`.record #[("field", …)]`, etc. (`Value`: int, bool, str, set, seq,
tuple, map, record, variant, unserializable, null.)

## Testing

```bash
export PATH="$HOME/.elan/bin:$PATH"
lake build test
.lake/build/bin/test      # 115 tests, 0 failures
```

The unit suite covers ITF value round-trips, error rendering
(`MirrorError.toString`), protocol codecs (unknown `proto_step` →
`protocol_error`), spec-closure walking (fixtures under `test/fixtures/`),
explore reply decoding, and a TCP loopback test against an in-process
`Std.Async.TCP` server.

The end-to-end smoke (`test/Smoke.lean`, gated on `MIRROR_BIN`) exercises a
real ModelMirrors binary + apalache:

```bash
export PATH="$HOME/.elan/bin:$HOME/.local/bin/apalache/bin:$PATH"
export MIRROR_BIN=/path/to/ModelMirrors
lake build smoke
.lake/build/bin/smoke
# smoke (a) trace replay: PASS
# smoke (b) generate+replay: PASS
# smoke (c) validate: PASS
# smoke (d) register_explore: PASS
# smoke (e) explore-session walk: PASS
# smoke: all checks passed
```

Without `MIRROR_BIN` the smoke prints `MIRROR_BIN not set; skipping smoke`
and exits 0.

## Known issues

### apalache explorer: no constant initialization (`cinit`)

apalache 0.57's explorer JSON-RPC `loadSpec` has no `cinit` parameter
(mirror docs/apalache/interactive.md, "CONSTANTS and CInit"). A spec with
`CONSTANTS` therefore fails inside the explorer with `Internal error:
SubstRule: Variable <NAME> is not assigned a value`. The smoke's explore
tests use `specs/CounterExplore.tla`, the constant-free twin of
`Counter.tla` (`STRIDES = {2, 3}` inlined into `TICK`/`Next`); the
generate/replay/validate paths keep the canonical `Counter.tla` with
`CInit`.

### `open` is a Lean keyword

The design's `ExploreSession.open` is spelled `ExploreSession.start`
(`startExploreSession` alias).
