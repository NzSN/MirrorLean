import MirrorLean.Value
import MirrorLean.Error
import MirrorLean.Protocol
import MirrorLean.Transport

/-!
# MirrorLean.Client

The replay client (design §8, milestone M2): the `StateComputer` abstraction,
the register/trace entry points, and the `mainLoop` / `genTracesLoop` state
machines. Port of MirrorECMA `src/client.ts` (mainLoop, genTracesLoop,
runClient*, presetClient).

* `StateComputer` — (action, params-from-mirror, previous-reported-state) → next state
* `pureComputer` / `presetClient` — basic computers
* `runClient` / `runClientWithTraces` / `runClientGenTraces` — entry points
* `GenTracesResult` — what `runClientGenTraces` returns
-/

namespace MirrorLean

/-- (action, params-from-mirror, previous-reported-state) → next reported state. -/
abbrev StateComputer := String → State → State → IO State

/-- Lift a pure `String → State → State → State` function into a `StateComputer`. -/
def pureComputer (f : String → State → State → State) : StateComputer :=
  fun action params prev => pure (f action params prev)

/--
Serve a fixed array of states in order (a "preset client" for replaying known
traces). Once the states run out it throws `IO.userError "preset_client
exhausted"`, mirroring the TS `presetClient` which throws when exhausted.
-/
def presetClient (states : Array State) : IO StateComputer := do
  let idx ← IO.mkRef 0
  return fun _ _ _ => do
    let i ← idx.get
    if h : i < states.size then
      idx.set (i + 1)
      pure (states[i])
    else
      throw <| IO.userError "preset_client exhausted"

/-- The result of a `register_trace_gen` session. -/
structure GenTracesResult where
  /-- Mirror-local paths of the generated trace files (stdio mode). -/
  itfTracePaths : Array System.FilePath
  /-- Inline ITF JSON trace contents, one per path (newer mirrors). -/
  itfTraces : Array Lean.Json

/-- The `proto_step` discriminant of a mirror message, for error reporting. -/
private def stepName : MirrorMessage → String
  | .specValidated _           => "spec_validated"
  | .initialState _ _          => "initial_state"
  | .nextStep _ _              => "next_step"
  | .stepOk                    => "step_ok"
  | .stepMismatch _ _ _ _      => "step_mismatch"
  | .allStepsDone              => "all_steps_done"
  | .genTracesDone _ _         => "gen_traces_done"
  | .registerError _           => "register_error"
  | .protocolError _           => "protocol_error"
  | .explorerReady _ _ _       => "explorer_ready"
  | .exploreTransitionStatus _ => "explore_transition_status"
  | .exploreStepDone _         => "explore_step_done"
  | .exploreState _            => "explore_state"
  | .exploreInvariantStatus _  => "explore_invariant_status"
  | .exploreAssumeStatus _     => "explore_assume_status"
  | .exploreRollbackDone _     => "explore_rollback_done"
  | .exploreSessionDone        => "explore_session_done"

/-- Receive and decode one mirror message; EOF → `transportClosed`. -/
private def recvMsg (t : Transport) : IO (Except MirrorError MirrorMessage) := do
  match ← t.recv with
  | none      => pure (.error .transportClosed)
  | some line => pure (MirrorMessage.decode line)

/-- Close the transport and return an error (used on every exit path). -/
private def closeErr {α : Type} (t : Transport) (e : MirrorError) : IO (Except MirrorError α) := do
  try let _ ← t.close catch _ => pure ()
  pure (.error e)

/-- The replay loop after `spec_validated {result := valid}`. -/
private partial def replayLoop (t : Transport) (compute : StateComputer)
    (lastAction : String) (lastParams prevState : State) : IO (Except MirrorError Unit) := do
  match ← recvMsg t with
  | .error e => closeErr t e
  | .ok msg =>
      match msg with
      | .initialState action state => do
          let s ← compute action state (State.ofList [])
          t.send (ClientMessage.encode (.reportState s))
          replayLoop t compute action lastParams s
      | .nextStep action parameters => do
          let s ← compute action parameters prevState
          t.send (ClientMessage.encode (.reportState s))
          replayLoop t compute action parameters s
      | .stepOk =>
          replayLoop t compute lastAction lastParams prevState
      | .allStepsDone => do
          let _ ← t.close
          pure (.ok ())
      | .stepMismatch action? expected actual hints => do
          closeErr t (.stepMismatch
            { action := action?.getD lastAction, params := lastParams, expected, actual, hints })
      | .protocolError d => closeErr t (.protocol d)
      | .registerError d => closeErr t (.registerFailed d)
      | other => closeErr t (.unexpectedMessage (stepName other))

/-- The replay main loop (register / register_traces / register_explore). -/
private def mainLoop (t : Transport) (compute : StateComputer) : IO (Except MirrorError Unit) := do
  match ← recvMsg t with
  | .error e => closeErr t e
  | .ok msg0 =>
      match msg0 with
      | .protocolError d => closeErr t (.protocol d)
      | .registerError d => closeErr t (.registerFailed d)
      | .specValidated (.invalid d) => closeErr t (.specInvalid d)
      | .specValidated .valid =>
          replayLoop t compute "" (State.ofList []) (State.ofList [])
      | other => closeErr t (.unexpectedMessage (stepName other))

/-- The `register_trace_gen` loop: expect exactly `gen_traces_done`. -/
private def genTracesLoop (t : Transport) : IO (Except MirrorError GenTracesResult) := do
  match ← recvMsg t with
  | .error e => closeErr t e
  | .ok msg =>
      match msg with
      | .genTracesDone paths traces => do
          let _ ← t.close
          pure (.ok { itfTracePaths := paths.map System.FilePath.mk, itfTraces := traces })
      | .protocolError d => closeErr t (.protocol d)
      | .registerError d => closeErr t (.registerFailed d)
      | other => closeErr t (.unexpectedMessage (stepName other))

/-- Resolve a `Target` to a concrete `Transport`, spawning the binary if needed. -/
private def resolveTarget (t : Target) : IO Transport :=
  match t with
  | .binary path  => spawnMirror path
  | .transport tr => pure tr

/--
Run `body`, and on any IO exception close the transport and report the I/O
error (design §8.1 exception safety: the transport is closed on every exit
path, including when `compute`/`send`/`recv` throw).
-/
private def withClose (tr : Transport) {α : Type} (body : IO (Except MirrorError α))
    : IO (Except MirrorError α) :=
  try
    body
  catch e =>
    try let _ ← tr.close catch _ => pure ()
    pure (.error (.io e))

/-- Replay: `register`, then the main loop. -/
def runClient (t : Target) (cfg : ApalacheConfig) (tc : TraceGenerationConfig)
    (compute : StateComputer) (spec? : Option ApalacheSpec := none)
    : IO (Except MirrorError Unit) := do
  let tr ← resolveTarget t
  withClose tr do
    tr.send (ClientMessage.encode (.register cfg tc spec?))
    mainLoop tr compute

/-- Replay: `register_traces` with pre-existing trace files, then the main loop. -/
def runClientWithTraces (t : Target) (cfg : ApalacheConfig) (tracePaths : Array System.FilePath)
    (compute : StateComputer) : IO (Except MirrorError Unit) := do
  let tr ← resolveTarget t
  withClose tr do
    tr.send (ClientMessage.encode (.registerTraces cfg (tracePaths.map (·.toString))))
    mainLoop tr compute

/-- Generate traces only: `register_trace_gen`, then the gen-traces loop. -/
def runClientGenTraces (t : Target) (cfg : ApalacheConfig) (destPath : System.FilePath)
    (tc : TraceGenerationConfig) (spec? : Option ApalacheSpec := none)
    : IO (Except MirrorError GenTracesResult) := do
  let tr ← resolveTarget t
  withClose tr do
    tr.send (ClientMessage.encode (.registerTraceGen cfg tc destPath.toString spec?))
    genTracesLoop tr



/-! M3 additions: mirror-driven exploration, validate-only sessions, and
client-driven explorer sessions (design 8.4/8.6/8.7). -/

/-- A transition status as reported by the explorer. -/
inductive TransitionStatus where
  | enabled
  | disabled
  | unknown
deriving Repr, BEq, Inhabited

namespace TransitionStatus

/-- Decode the wire status string (ENABLED/DISABLED/UNKNOWN). -/
def ofString? : String → Option TransitionStatus
  | "ENABLED"  => some .enabled
  | "DISABLED" => some .disabled
  | "UNKNOWN"  => some .unknown
  | _          => none

end TransitionStatus

/-- An invariant status as reported by the explorer. -/
inductive InvariantStatus where
  | satisfied
  | violated
  | unknown
deriving Repr, BEq, Inhabited

namespace InvariantStatus

/-- Decode the wire status string (SATISFIED/VIOLATED/UNKNOWN). -/
def ofString? : String → Option InvariantStatus
  | "SATISFIED" => some .satisfied
  | "VIOLATED"  => some .violated
  | "UNKNOWN"   => some .unknown
  | _           => none

end InvariantStatus

/-- Mirror-driven symbolic exploration: register_explore, then the same
replay main loop (in explore mode the parameters carry the full expected
state including action_taken; the client just passes them through). -/
def runClientExplore (t : Target) (spec : ApalacheSpec) (invariants exports : Array String)
    (maxSteps : Nat) (compute : StateComputer) : IO (Except MirrorError Unit) := do
  let tr ← resolveTarget t
  withClose tr do
    tr.send (ClientMessage.encode (.registerExplore spec invariants exports maxSteps))
    mainLoop tr compute

/-- Validate-only session: register_validate, exactly one reply, then the
session ends (design 8.6). -/
def runClientValidate (t : Target) (cfg : ApalacheConfig) (bound : Nat)
    (spec? : Option ApalacheSpec := none) : IO (Except MirrorError Unit) := do
  if bound < 1 || bound > 100 then
    return .error (.protocol "validate bound must be in [1, 100]")
  let tr ← resolveTarget t
  withClose tr do
    tr.send (ClientMessage.encode (.registerValidate cfg bound spec?))
    match ← recvMsg tr with
    | .error e => closeErr tr e
    | .ok msg => match msg with
        | .specValidated .valid        => do let _ ← tr.close; pure (.ok ())
        | .specValidated (.invalid d)  => closeErr tr (.specInvalid d)
        | .protocolError d            => closeErr tr (.protocol d)
        | .registerError d            => closeErr tr (.registerFailed d)
        | other                       => closeErr tr (.unexpectedMessage (stepName other))

/-- The explorer readiness counts carried by explorer_ready. -/
structure ExploreReady where
  initTransitions : Nat
  nextTransitions : Nat
  stateInvariants : Nat
deriving Repr, Inhabited

/-- A client-driven explorer session (design 8.7): strict command/reply
alternation; the explorer state lives in the mirror. -/
structure ExploreSession where
  transport : Transport
  ready : ExploreReady
  closed : IO.Ref Bool

namespace ExploreSession

/-- Start a session: register_explore_session, then require explorer_ready.
(Lesson: open is a Lean keyword, so the design has ExploreSession.start as
the public name; startExploreSession is the alias.) -/
def start (t : Target) (spec : ApalacheSpec) (invariants exports : Array String)
    : IO (Except MirrorError ExploreSession) := do
  let tr ← resolveTarget t
  try
    tr.send (ClientMessage.encode (.registerExploreSession spec invariants exports))
    match ← recvMsg tr with
    | .error e => closeErr tr e
    | .ok msg => match msg with
        | .explorerReady ni nn nv => do
            let closed ← IO.mkRef false
            pure (.ok { transport := tr, closed, ready :=
              { initTransitions := ni, nextTransitions := nn, stateInvariants := nv } })
        | .protocolError d        => closeErr tr (.protocol d)
        | .registerError d        => closeErr tr (.registerFailed d)
        | other                   => closeErr tr (.unexpectedMessage (stepName other))
  catch e =>
    closeErr tr (.io e)

/-- Close and poison a session, returning the supplied error. -/
private def poison {α : Type} (s : ExploreSession) (e : MirrorError)
    : IO (Except MirrorError α) := do
  s.closed.set true
  let _ ← s.transport.close
  pure (.error e)

/-- Send one command and receive its reply. Transport errors, malformed input,
and protocol_error close and poison the persistent session. -/
private def cmd (s : ExploreSession) (m : ClientMessage)
    : IO (Except MirrorError MirrorMessage) := do
  if ← s.closed.get then
    pure (.error .transportClosed)
  else try
    s.transport.send (ClientMessage.encode m)
    match ← recvMsg s.transport with
    | .error e => poison s e
    | .ok (.protocolError d) => poison s (.protocol d)
    | .ok msg => pure (.ok msg)
  catch e =>
    poison s (.io e)

/-- Require a specific reply, mapping anything else to unexpectedMessage. -/
private def expect (s : ExploreSession) (m : ClientMessage)
    (f : MirrorMessage → Option α) : IO (Except MirrorError α) := do
  match ← cmd s m with
  | .error e => pure (.error e)
  | .ok msg => match f msg with
      | some a => pure (.ok a)
      | none   => poison s (.unexpectedMessage (stepName msg))

/-- Assume an init/next transition by id; the explorer returns its status
and records a snapshot. -/
def assumeTransition (s : ExploreSession) (transitionId : Nat)
    : IO (Except MirrorError TransitionStatus) :=
  expect s (.exploreAssumeTransition transitionId) (fun
    | .exploreTransitionStatus st => TransitionStatus.ofString? st
    | _ => none)

/-- Take one exploration step; returns the new step number. -/
def nextStep (s : ExploreSession) : IO (Except MirrorError Nat) :=
  expect s .exploreNextStep (fun
    | .exploreStepDone n => some n
    | _ => none)

/-- Query the explorer for the current symbolic state. -/
def queryState (s : ExploreSession) : IO (Except MirrorError State) :=
  expect s .exploreQueryState (fun
    | .exploreState st => some st
    | _ => none)

/-- Check a state invariant by id; returns SATISFIED/VIOLATED/UNKNOWN. -/
def checkInvariant (s : ExploreSession) (invariantId : Nat)
    : IO (Except MirrorError InvariantStatus) :=
  expect s (.exploreCheckInvariant invariantId) (fun
    | .exploreInvariantStatus st => InvariantStatus.ofString? st
    | _ => none)

/-- Force the explorer into a concrete state; returns the assumption status. -/
def assumeState (s : ExploreSession) (eqs : State)
    : IO (Except MirrorError TransitionStatus) :=
  expect s (.exploreAssumeState eqs) (fun
    | .exploreAssumeStatus st => TransitionStatus.ofString? st
    | _ => none)

/-- Roll back to a snapshot taken by an earlier command. -/
def rollback (s : ExploreSession) (snapshotId : Nat) : IO (Except MirrorError Nat) :=
  expect s (.exploreRollback snapshotId) (fun
    | .exploreRollbackDone sid => some sid
    | _ => none)

/-- End the session: explore_done, require explore_session_done, close. -/
def done (s : ExploreSession) : IO (Except MirrorError Unit) := do
  match ← cmd s .exploreDone with
  | .error e => pure (.error e)
  | .ok msg => match msg with
      | .exploreSessionDone => do
          s.closed.set true
          let _ ← s.transport.close
          pure (.ok ())
      | other => poison s (.unexpectedMessage (stepName other))

end ExploreSession

/-- Alias of ExploreSession.open, matching the reference client API. -/
def startExploreSession (t : Target) (spec : ApalacheSpec) (invariants exports : Array String)
    : IO (Except MirrorError ExploreSession) :=
  ExploreSession.start t spec invariants exports
end MirrorLean
