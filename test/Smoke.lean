import MirrorLean

/-!
# MirrorLean smoke test (gated on MIRROR_BIN)

End-to-end conformance runs against a real ModelMirrors binary:

* (a) trace replay - replay specs/traces/violation.itf.json with a preset
  client serving the exact trace states (diffState must match every step);
* (b) generate + replay - let the mirror generate counterexample traces of
  specs/Counter.tla via apalache and replay them with the Counter computer;
* (c) validate - register_validate with a valid spec (ok) and with an
  unknown invariant (register_error -> registerFailed);
* (d) explore - register_explore against CounterExplore.tla;
* (e) explore session - a scripted startExploreSession walk over
  CounterExplore.tla (assumeTransition 0 -> nextStep -> queryState ->
  checkInvariant 0 -> rollback 0 -> done).

(d)/(e) use specs/CounterExplore.tla, the constant-free twin of Counter.tla
(STRIDES = {2, 3} inlined into TICK/Next, no CONSTANTS/CInit): apalache's
explorer JSON-RPC has no cinit parameter, so a spec with CONSTANTS fails
inside the explorer with "SubstRule: Variable STRIDES is not assigned a
value" (mirror docs/apalache/interactive.md, "CONSTANTS and CInit"). The
generate/replay paths (a)-(c) keep the canonical Counter.tla with CInit.

When MIRROR_BIN is unset the test prints a skip message and exits 0, like the
MirrorRust smoke suite. apalache-mc must be on PATH when MIRROR_BIN is set.
-/

open MirrorLean

/-- Parse one ITF trace file into its sequence of variable valuations.

The ITF vars array names the state variables; every states entry carries
those variables (plus constants and metadata), and the variable values are
already ITF-encoded JSON, so Value.ofJson? decodes them directly. -/
def parseItfStates (content : String) : Except String (Array State) := do
  let j ← Lean.Json.parse content
  let o ← j.getObj?
  let varsArr ← match o.get? "vars" with
    | some v => v.getArr?
    | none   => throw "trace has no vars array"
  let vars ← varsArr.mapM (fun v => v.getStr?)
  let statesArr ← match o.get? "states" with
    | some v => v.getArr?
    | none   => throw "trace has no states array"
  statesArr.mapM fun sj => do
    let so ← sj.getObj?
    let mut st : State := ∅
    for v in vars do
      match so.get? v with
      | some jv => st := st.insert v (← Value.ofJson? jv)
      | none    => throw s!"trace state is missing variable {v}"
    return st

/-- The Counter machine (same as examples/Counter.lean, kept local so the
smoke binary is self-contained). -/
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

def counterCfg : ApalacheConfig :=
  { specPath := "specs/Counter.tla", invariant := "TraceComplete",
    lengthBound := 6, constInit := some "CInit", paramVars := some "parameters" }

/-- (a) replay the checked-in violation trace through the mirror. -/
def replayTrace (bin : String) : IO (Except MirrorError Unit) := do
  let traceText ← IO.FS.readFile (System.FilePath.mk "specs/traces/violation.itf.json")
  match parseItfStates traceText with
  | .error e => pure (.error (.json e))
  | .ok states => do
      let compute ← presetClient states
      runClientWithTraces
        (.binary (System.FilePath.mk bin))
        counterCfg
        #[System.FilePath.mk "specs/traces/violation.itf.json"]
        compute

/-- (b) generate fresh counterexample traces and replay them. -/
def generateAndReplay (bin : String) : IO (Except MirrorError Unit) := do
  runClient (.binary (System.FilePath.mk bin)) counterCfg
    { numTraces := 10, view := some "View" } (← counterComputer)

/-- (c) validate-only session: a valid config reports ok; an invariant
that does not exist in the spec is an apalache config error (exit 255), which
the mirror reports as register_error (MirrorError.registerFailed). A genuine
spec defect (type error or violated invariant) is the specInvalid path; see
the fake-transport unit tests in test/Main.lean. -/
def validateCases (bin : String) : IO (Except MirrorError Unit) := do
  match ← runClientValidate (.binary (System.FilePath.mk bin)) counterCfg 3 with
  | .error e =>
      pure (.error e)
  | .ok () =>
      -- an invariant that does not exist in the spec => apalache config
      -- error (exit 255) => register_error on the wire => registerFailed
      let badCfg : ApalacheConfig := { counterCfg with invariant := "NoSuchInvariant" }
      match ← runClientValidate (.binary (System.FilePath.mk bin)) badCfg 3 with
      | .ok ()        => pure (.error (.unexpectedMessage "validate expected registerFailed"))
      | .error (.registerFailed _) => pure (.ok ())
      | .error e      => pure (.error e)

/-- (d1) mirror-driven explore: register_explore against CounterExplore.tla
(the constant-free twin of Counter.tla, see the header) with the
TraceComplete invariant; maxSteps 3 keeps count < 12 so the invariant holds
on every explored prefix (strides are 2 and 3). -/
def exploreMode (bin : String) : IO (Except MirrorError Unit) := do
  match ← specFromFile (System.FilePath.mk "specs/CounterExplore.tla") with
  | .error e   => pure (.error (.specInvalid (e.msg)))
  | .ok spec =>
      runClientExplore (.binary (System.FilePath.mk bin)) spec #["TraceComplete"] #[] 3
        (← counterComputer)

/-- (d2) client-driven explore session: a scripted walk over CounterExplore.tla.
start -> assumeTransition 0 -> nextStep -> queryState -> checkInvariant 0
-> rollback 0 -> done. -/
def exploreSessionWalk (bin : String) : IO (Except MirrorError Unit) := do
  match ← specFromFile (System.FilePath.mk "specs/CounterExplore.tla") with
  | .error e => pure (.error (.specInvalid (e.msg)))
  | .ok spec =>
      match ← startExploreSession (.binary (System.FilePath.mk bin)) spec #["TraceComplete"] #[] with
      | .error e => pure (.error e)
      | .ok s =>
          -- ready counts: one init transition (Counter's Spec), one invariant
          if s.ready.initTransitions != 1 then
            pure (.error (.unexpectedMessage s!"initTransitions {s.ready.initTransitions}"))
          else if s.ready.stateInvariants != 1 then
            pure (.error (.unexpectedMessage s!"stateInvariants {s.ready.stateInvariants}"))
          else if s.ready.nextTransitions == 0 then
            pure (.error (.unexpectedMessage "no next transitions"))
          else do
            match ← ExploreSession.assumeTransition s 0 with
            | .error e => pure (.error e)
            | .ok .enabled =>
                match ← ExploreSession.nextStep s with
                | .error e => pure (.error e)
                | .ok 1 =>
                    match ← ExploreSession.queryState s with
                    | .error e => pure (.error e)
                    | .ok st =>
                        if st.toList.isEmpty then
                          pure (.error (.unexpectedMessage "queryState empty"))
                        else
                          match ← ExploreSession.checkInvariant s 0 with
                          | .error e => pure (.error e)
                          | .ok .satisfied =>
                              match ← ExploreSession.rollback s 0 with
                              | .error e => pure (.error e)
                              | .ok 0 => ExploreSession.done s
                              | .ok n  => pure (.error (.unexpectedMessage s!"rollback -> {n}"))
                          | .ok _ => pure (.error (.unexpectedMessage "checkInvariant not satisfied"))
                | .ok n => pure (.error (.unexpectedMessage s!"nextStep -> {n}"))
            | .ok _ => pure (.error (.unexpectedMessage "assumeTransition not enabled"))

def main : IO Unit := do
  let some bin ← IO.getEnv "MIRROR_BIN" | do
    IO.println "MIRROR_BIN not set; skipping smoke"
    return
  match ← replayTrace bin with
  | .error e => IO.eprintln s!"smoke (a) trace replay FAILED: {MirrorError.toString e}"
                IO.Process.exit 1
  | .ok ()   => IO.println "smoke (a) trace replay: PASS"
  match ← generateAndReplay bin with
  | .error e => IO.eprintln s!"smoke (b) generate+replay FAILED: {MirrorError.toString e}"
                IO.Process.exit 1
  | .ok ()   => IO.println "smoke (b) generate+replay: PASS"
  match ← validateCases bin with
  | .error e => IO.eprintln s!"smoke (c) validate FAILED: {MirrorError.toString e}"
                IO.Process.exit 1
  | .ok ()   => IO.println "smoke (c) validate: PASS"
  match ← exploreMode bin with
  | .error e => IO.eprintln s!"smoke (d) explore FAILED: {MirrorError.toString e}"
                IO.Process.exit 1
  | .ok ()   => IO.println "smoke (d) register_explore: PASS"
  match ← exploreSessionWalk bin with
  | .error e => IO.eprintln s!"smoke (e) explore-session FAILED: {MirrorError.toString e}"
                IO.Process.exit 1
  | .ok ()   => IO.println "smoke (e) explore-session walk: PASS"
  IO.println "smoke: all checks passed"
