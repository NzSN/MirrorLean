import MirrorLean.Value
import MirrorLean.Error

/-!
# MirrorLean.Protocol

The client/mirror message layer of the ModelMirrors protocol (design §5).

* Configurations: `ApalacheConfig`, `TraceGenerationConfig`, `ApalacheSpec`.
* `ClientMessage` — what the client sends (encode is exact: optional fields
  are omitted when none, matching the TS `JSON.stringify` semantics).
* `MirrorMessage` — what the mirror sends (decode; a known-format but unknown
  proto_step decodes to a `protocol_error` message, exactly like the TS
  walkMessage).
* Codecs are hand-written on the Lean.Json AST — we deliberately do not
  derive ToJson/FromJson, since the ITF encoding is asymmetric and the
  proto_step-tagged sums don't map onto derived instances.
-/

namespace MirrorLean

private def getStrD (j : Lean.Json) (k : String) (d : String) : Except String String := 
  match j.getObjVal? k with
  | .ok jv => jv.getStr?
  | .error _ => .ok d

private def getNatD (j : Lean.Json) (k : String) (d : Nat) : Except String Nat := 
  match j.getObjVal? k with
  | .ok jv => jv.getNat?
  | .error _ => .ok d

/-- Required string field. -/
private def getStrField (j : Lean.Json) (k : String) : Except String String := do
  let jv ← j.getObjVal? k
  Lean.Json.getStr? jv

/-- Required natural field. -/
private def getNatField (j : Lean.Json) (k : String) : Except String Nat := do
  let jv ← j.getObjVal? k
  Lean.Json.getNat? jv

/-- Required JSON array field. -/
private def getArrField (j : Lean.Json) (k : String) : Except String (Array Lean.Json) := do
  let jv ← j.getObjVal? k
  Lean.Json.getArr? jv

private def getStrOpt (j : Lean.Json) (k : String) : Except String (Option String) := 
  match j.getObjVal? k with
  | .ok jv => (some <$> jv.getStr?)
  | .error _ => .ok none

private def getOpt (j : Lean.Json) (k : String) : Except String (Option Lean.Json) := 
  match j.getObjVal? k with
  | .ok jv => .ok (some jv)
  | .error _ => .ok none

private def getStrArr (j : Lean.Json) (k : String) : Except String (Array String) := do
  let jv ← j.getObjVal? k
  let xs ← jv.getArr?
  xs.mapM (·.getStr?)

private def getStrArrD (j : Lean.Json) (k : String) : Except String (Array String) := 
  match j.getObjVal? k with
  | .ok jv => jv.getArr? >>= fun xs => xs.mapM (·.getStr?)
  | .error _ => .ok #[]

private def getArrD (j : Lean.Json) (k : String) : Except String (Array Lean.Json) := 
  match j.getObjVal? k with
  | .ok jv => jv.getArr?
  | .error _ => .ok #[]

/-- Omit an optional string field when none, else include it (TS semantics). -/
private def optJsonStr (k : String) (v : Option String) : List (String × Lean.Json) := 
  match v with
  | none   => []
  | some s => [(k, s)]

/-- Omit an optional JSON field when none, else include it. -/
private def optJson (k : String) (v : Option Lean.Json) : List (String × Lean.Json) := 
  match v with
  | none   => []
  | some j => [(k, j)]

/-- Build a message object with the proto_step discriminant. The explicit
`String × Lean.Json` annotation forces the String-to-Json coercion for the
step name so list literals unify. -/
private def mkMsg (step : String) (fields : List (String × Lean.Json)) : Lean.Json :=
  Lean.Json.mkObj ((("proto_step", step) : String × Lean.Json) :: fields)

/-- Encode an array of strings as a JSON array (there is no implicit Coerce
from Array String to Json). -/
private def jarrStr (xs : Array String) : Lean.Json :=
  Lean.toJson xs

/-- The Apalache configuration block sent with register messages.

Optional fields are omitted from the JSON when `none`; the mirror's FromJSON
defaults them (initPredicate/nextPredicate/constInit/paramVars to nothing,
lengthBound to 10).
-/
structure ApalacheConfig where
  specPath      : String
  initPredicate : Option String := none
  nextPredicate : Option String := none
  constInit     : Option String := none
  invariant     : String
  lengthBound   : Nat
  paramVars     : Option String := none
deriving Repr

namespace ApalacheConfig

/-- Encode an ApalacheConfig to its JSON object. -/
def toJson (c : ApalacheConfig) : Lean.Json := 
  Lean.Json.mkObj (
    ([("specPath", c.specPath),
     ("invariant", c.invariant),
     ("lengthBound", c.lengthBound)] : List (String × Lean.Json))
    ++ optJsonStr "initPredicate" c.initPredicate
    ++ optJsonStr "nextPredicate" c.nextPredicate
    ++ optJsonStr "constInit" c.constInit
    ++ optJsonStr "paramVars" c.paramVars)

instance : Lean.ToJson ApalacheConfig := ⟨toJson⟩

/-- Decode an ApalacheConfig from its JSON object, applying the mirror's
defaults for absent optional fields. -/
def ofJson? (j : Lean.Json) : Except String ApalacheConfig := do
  let specPathJ ← j.getObjVal? "specPath"
  let specPath ← Lean.Json.getStr? specPathJ
  let invariant ← getStrD j "invariant" ""
  let lengthBound ← getNatD j "lengthBound" 10
  let initPredicate ← getStrOpt j "initPredicate"
  let nextPredicate ← getStrOpt j "nextPredicate"
  let constInit ← getStrOpt j "constInit"
  let paramVars ← getStrOpt j "paramVars"
  return { specPath, initPredicate, nextPredicate, constInit, invariant, lengthBound, paramVars }

end ApalacheConfig

/-- The trace generation configuration block sent with register /
register_trace_gen messages. -/
structure TraceGenerationConfig where
  numTraces : Nat
  view      : Option String := none
deriving Repr

namespace TraceGenerationConfig

/-- Encode a TraceGenerationConfig to its JSON object. -/
def toJson (c : TraceGenerationConfig) : Lean.Json := 
  Lean.Json.mkObj (([("numTraces", c.numTraces)] : List (String × Lean.Json)) ++ optJsonStr "view" c.view)

instance : Lean.ToJson TraceGenerationConfig := ⟨toJson⟩

/-- Decode a TraceGenerationConfig, defaulting numTraces to 1. -/
def ofJson? (j : Lean.Json) : Except String TraceGenerationConfig := do
  let numTraces ← getNatD j "numTraces" 1
  let view ← getStrOpt j "view"
  return { numTraces, view }

end TraceGenerationConfig

/-- Inline spec sources: the root module first, then the EXTENDS/INSTANCE
closure. The mirror materializes these and ignores apalacheConfig.specPath. -/
structure ApalacheSpec where
  sources : Array String
deriving Repr

namespace ApalacheSpec

/-- Encode a spec to its JSON object. -/
def toJson (s : ApalacheSpec) : Lean.Json := 
  Lean.Json.mkObj [("sources", jarrStr s.sources)]

instance : Lean.ToJson ApalacheSpec := ⟨toJson⟩

/-- Decode a spec from its JSON object. -/
def ofJson? (j : Lean.Json) : Except String ApalacheSpec := do
  let sourcesJ ← j.getObjVal? "sources"
  let sourcesArr ← Lean.Json.getArr? sourcesJ
  let sources ← sourcesArr.mapM Lean.Json.getStr?
  return { sources }

end ApalacheSpec

/-- The result of the mirror's spec-validation step: `"valid"` or
`{"invalid": detail}`. -/
inductive ValidateResult where
  | valid
  | invalid (detail : String)
deriving Repr, BEq

namespace ValidateResult

def toJson : ValidateResult → Lean.Json
  | .valid => "valid"
  | .invalid d => Lean.Json.mkObj [("invalid", d)]

instance : Lean.ToJson ValidateResult := ⟨toJson⟩

def ofJson? (j : Lean.Json) : Except String ValidateResult := 
  match j.getStr? with
  | .ok s => if s == "valid" then .ok .valid else .error s!"invalid spec validation result: {s}"
  | .error _ => do
      let d ← j.getObjVal? "invalid"
      .ok (.invalid (← d.getStr?))

end ValidateResult

/-- Messages the client sends to the mirror. Constructor names match the
design; wire `proto_step` names differ (register, register_traces, ...). -/
inductive ClientMessage where
  | register               (cfg : ApalacheConfig) (tc : TraceGenerationConfig) (spec? : Option ApalacheSpec)
  | registerTraces         (cfg : ApalacheConfig) (paths : Array String)
  | registerTraceGen       (cfg : ApalacheConfig) (tc : TraceGenerationConfig) (destPath : String) (spec? : Option ApalacheSpec)
  | registerExplore        (spec : ApalacheSpec) (invariants exports : Array String) (maxSteps : Nat)
  | registerExploreSession (spec : ApalacheSpec) (invariants exports : Array String)
  | registerValidate       (cfg : ApalacheConfig) (bound : Nat) (spec? : Option ApalacheSpec)
  | exploreAssumeTransition (transitionId : Nat)
  | exploreNextStep
  | exploreQueryState
  | exploreCheckInvariant  (invariantId : Nat)
  | exploreAssumeState     (state : State)
  | exploreRollback        (snapshotId : Nat)
  | exploreDone
  | reportState            (state : State)
deriving Repr

namespace ClientMessage

/-- Encode a client message to its JSON object (exact wire field names). -/
def toJson : ClientMessage → Lean.Json
  | .register cfg tc spec? =>
      mkMsg "register" ([("apalacheConfig", cfg.toJson), ("traceConfig", tc.toJson)]
        ++ optJson "spec" (spec?.map ApalacheSpec.toJson))
  | .registerTraces cfg paths =>
      mkMsg "register_traces" [("apalacheConfig", cfg.toJson), ("itfTracePaths", jarrStr paths)]
  | .registerTraceGen cfg tc destPath spec? =>
      mkMsg "register_trace_gen" ([("apalacheConfig", cfg.toJson), ("traceConfig", tc.toJson),
        ("destPath", destPath)] ++ optJson "spec" (spec?.map ApalacheSpec.toJson))
  | .registerExplore spec invariants exports maxSteps =>
      mkMsg "register_explore" [("spec", spec.toJson), ("invariants", jarrStr invariants),
        ("exports", jarrStr exports), ("maxSteps", maxSteps)]
  | .registerExploreSession spec invariants exports =>
      mkMsg "register_explore_session" [("spec", spec.toJson), ("invariants", jarrStr invariants),
        ("exports", jarrStr exports)]
  | .registerValidate cfg bound spec? =>
      mkMsg "register_validate" ([("apalacheConfig", cfg.toJson), ("bound", bound)]
        ++ optJson "spec" (spec?.map ApalacheSpec.toJson))
  | .exploreAssumeTransition tid =>
      mkMsg "explore_assume_transition" [("transitionId", tid)]
  | .exploreNextStep => mkMsg "explore_next_step" []
  | .exploreQueryState => mkMsg "explore_query_state" []
  | .exploreCheckInvariant iid =>
      mkMsg "explore_check_invariant" [("invariantId", iid)]
  | .exploreAssumeState st =>
      mkMsg "explore_assume_state" [("state", State.toJson st)]
  | .exploreRollback sid =>
      mkMsg "explore_rollback" [("snapshotId", sid)]
  | .exploreDone => mkMsg "explore_done" []
  | .reportState st =>
      mkMsg "report_state" [("state", State.toJson st)]

/-- Encode a client message as a single-line JSON string (no raw newlines;
Lean.Json.compress escapes embedded newlines, satisfying the framing
constraint). -/
def encode (m : ClientMessage) : String := Lean.Json.compress (toJson m)

/-- Decode a client message from its JSON object. -/
def ofJson? (j : Lean.Json) : Except String ClientMessage := do
  let step ← getStrField j "proto_step"
  match step with
  | "register" => do
      let cfg ← j.getObjVal? "apalacheConfig" >>= ApalacheConfig.ofJson?
      let tc ← j.getObjVal? "traceConfig" >>= TraceGenerationConfig.ofJson?
      let spec? ← (← getOpt j "spec").mapM ApalacheSpec.ofJson?
      return .register cfg tc spec?
  | "register_traces" => do
      let cfg ← j.getObjVal? "apalacheConfig" >>= ApalacheConfig.ofJson?
      let paths ← getStrArr j "itfTracePaths"
      return .registerTraces cfg paths
  | "register_trace_gen" => do
      let cfg ← j.getObjVal? "apalacheConfig" >>= ApalacheConfig.ofJson?
      let tc ← j.getObjVal? "traceConfig" >>= TraceGenerationConfig.ofJson?
      let destPath ← getStrD j "destPath" ""
      let spec? ← (← getOpt j "spec").mapM ApalacheSpec.ofJson?
      return .registerTraceGen cfg tc destPath spec?
  | "register_explore" => do
      let spec ← j.getObjVal? "spec" >>= ApalacheSpec.ofJson?
      let invariants ← getStrArr j "invariants"
      let exports ← getStrArr j "exports"
      let maxSteps ← getNatD j "maxSteps" 10
      return .registerExplore spec invariants exports maxSteps
  | "register_explore_session" => do
      let spec ← j.getObjVal? "spec" >>= ApalacheSpec.ofJson?
      let invariants ← getStrArr j "invariants"
      let exports ← getStrArr j "exports"
      return .registerExploreSession spec invariants exports
  | "register_validate" => do
      let cfg ← j.getObjVal? "apalacheConfig" >>= ApalacheConfig.ofJson?
      let bound ← getNatD j "bound" 0
      let spec? ← (← getOpt j "spec").mapM ApalacheSpec.ofJson?
      return .registerValidate cfg bound spec?
  | "explore_assume_transition" => do
      let tid ← getNatField j "transitionId"
      return .exploreAssumeTransition tid
  | "explore_next_step" => return .exploreNextStep
  | "explore_query_state" => return .exploreQueryState
  | "explore_check_invariant" => do
      let iid ← getNatField j "invariantId"
      return .exploreCheckInvariant iid
  | "explore_assume_state" => do
      let st ← j.getObjVal? "state" >>= State.ofJson?
      return .exploreAssumeState st
  | "explore_rollback" => do
      let sid ← getNatField j "snapshotId"
      return .exploreRollback sid
  | "explore_done" => return .exploreDone
  | "report_state" => do
      let st ← j.getObjVal? "state" >>= State.ofJson?
      return .reportState st
  | other => throw s!"Unknown ClientMessage proto_step: {other}"

end ClientMessage

/-- Messages the mirror sends to the client. -/
inductive MirrorMessage where
  | specValidated             (result : ValidateResult)
  | initialState              (action : String) (state : State)
  | nextStep                  (action : String) (parameters : State)
  | stepOk
  | stepMismatch              (action? : Option String) (expected actual : State) (hints : Array DiffHint)
  | allStepsDone
  | genTracesDone             (paths : Array String) (traces : Array Lean.Json)
  | registerError             (error : String)
  | protocolError             (error : String)
  | explorerReady             (initTransitions nextTransitions stateInvariants : Nat)
  | exploreTransitionStatus   (status : String)
  | exploreStepDone           (stepNo : Nat)
  | exploreState              (state : State)
  | exploreInvariantStatus    (status : String)
  | exploreAssumeStatus       (status : String)
  | exploreRollbackDone       (snapshotId : Nat)
  | exploreSessionDone
deriving Inhabited

namespace DiffHint

/-- Decode a single diff hint from its JSON object.

Unknown kinds decode to `truncated`, exactly like the TS decoder. -/
def ofJson? (j : Lean.Json) : Except String DiffHint := do
  let kind ← getStrField j "kind"
  let path ← decodePath j
  match kind with
  | "value_mismatch" => do
      let e ← j.getObjVal? "expected" >>= Value.ofJson?
      let a ← j.getObjVal? "actual" >>= Value.ofJson?
      return .valueMismatch path e a
  | "missing" => do
      let e ← j.getObjVal? "expected" >>= Value.ofJson?
      return .missing path e
  | "extra" => do
      let a ← j.getObjVal? "actual" >>= Value.ofJson?
      return .extra path a
  | "missing_elem" => do
      let e ← j.getObjVal? "expected" >>= Value.ofJson?
      return .missingElem path e
  | "extra_elem" => do
      let a ← j.getObjVal? "actual" >>= Value.ofJson?
      return .extraElem path a
  | "type_mismatch" => do
      let e ← j.getObjVal? "expected" >>= Value.ofJson?
      let a ← j.getObjVal? "actual" >>= Value.ofJson?
      return .typeMismatch path e a
  | "truncated" => return .truncated path
  | _ => return .truncated path
where
  decodePath (j : Lean.Json) : Except String (Array PathSeg) := do
    let arr ← getArrField j "path"
    arr.mapM fun seg => do
      let o ← Lean.Json.getObj? seg
      match o.get? "field" with
      | some jf => PathSeg.field <$> Lean.Json.getStr? jf
      | none =>
          match o.get? "index" with
          | some ji => PathSeg.index <$> Lean.Json.getNat? ji
          | none => throw "path segment has neither field nor index"

end DiffHint

namespace MirrorMessage

/-- Decode a mirror message from its JSON object.

A known-format message with an unknown proto_step decodes to a
`protocol_error` message (`unknown proto_step: ...`), exactly like the TS
walkMessage: the session treats it as fatal, while genuinely malformed JSON
is a `MirrorError.json` (see `decode`). -/
def ofJson? (j : Lean.Json) : Except String MirrorMessage := do
  let step ← getStrField j "proto_step"
  match step with
  | "spec_validated" => do
      let result ← j.getObjVal? "result"
      MirrorMessage.specValidated <$> ValidateResult.ofJson? result
  | "initial_state" => do
      let action ← getStrField j "action"
      let state ← j.getObjVal? "state" >>= State.ofJson?
      return .initialState action state
  | "next_step" => do
      let action ← getStrField j "action"
      let parameters ← j.getObjVal? "parameters" >>= State.ofJson?
      return .nextStep action parameters
  | "step_ok" => return .stepOk
  | "step_mismatch" => do
      let action? ← getStrOpt j "action"
      let expected ← j.getObjVal? "expected" >>= State.ofJson?
      let actual ← j.getObjVal? "actual" >>= State.ofJson?
      let hints ← (← getArrD j "hints").mapM DiffHint.ofJson?
      return .stepMismatch action? expected actual hints
  | "all_steps_done" => return .allStepsDone
  | "gen_traces_done" => do
      let paths ← getStrArrD j "itfTracePaths"
      let traces ← getArrD j "itfTraces"
      return .genTracesDone paths traces
  | "protocol_error" => do
      let error ← getStrField j "error"
      return .protocolError error
  | "register_error" => do
      let error ← getStrField j "error"
      return .registerError error
  | "explorer_ready" => do
      let nInit ← getNatField j "initTransitions"
      let nNext ← getNatField j "nextTransitions"
      let nInv ← getNatField j "stateInvariants"
      return .explorerReady nInit nNext nInv
  | "explore_transition_status" => do
      let status ← getStrField j "status"
      return .exploreTransitionStatus status
  | "explore_step_done" => do
      let stepNo ← getNatField j "stepNo"
      return .exploreStepDone stepNo
  | "explore_state" => do
      let state ← j.getObjVal? "state" >>= State.ofJson?
      return .exploreState state
  | "explore_invariant_status" => do
      let status ← getStrField j "status"
      return .exploreInvariantStatus status
  | "explore_assume_status" => do
      let status ← getStrField j "status"
      return .exploreAssumeStatus status
  | "explore_rollback_done" => do
      let snapshotId ← getNatField j "snapshotId"
      return .exploreRollbackDone snapshotId
  | "explore_session_done" => return .exploreSessionDone
  | other => return .protocolError s!"unknown proto_step: {other}"

/-- Decode a newline-delimited JSON message from the mirror.

Malformed JSON yields `MirrorError.json` with the parse message; a
known-format but unknown proto_step decodes to a `protocol_error` message. -/
def decode (line : String) : Except MirrorError MirrorMessage := 
  match Lean.Json.parse line with
  | .error e => .error (.json e)
  | .ok j =>
      match ofJson? j with
      | .error e => .error (.json e)
      | .ok m => .ok m

end MirrorMessage
end MirrorLean
