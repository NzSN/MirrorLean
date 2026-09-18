import MirrorLean.Protocol
import MirrorLean.Transport
import Std.Sync.Mutex

/-! Network async jobs. A Connection owns its transport and serializes exchanges.
Closing the submitter cancels/evicts its jobs. Handles do not survive reconnects.
These types are separate from the synchronous replay state machine. -/
namespace MirrorLean

inductive JobKind where
  | validate | genTraces
  deriving Repr, BEq

inductive JobPhase where
  | pending | running | done | failed | cancelled | unknown
  deriving Repr, BEq

inductive JobOutcome where
  | validate (result : ValidateResult)
  | genTraces (paths : Array String) (traces : Array Lean.Json)
  | error (message : String)

inductive JobReply where
  | accepted (jobId : String) (kind : JobKind)
  | status (jobId : String) (phase : JobPhase)
  | result (jobId : String) (outcome : JobOutcome)
  | registrationError (message : String)
  | protocolError (message : String)

namespace JobReply

def decode (line : String) : Except String JobReply := do
  let j ← Lean.Json.parse line
  let tag ← (← j.getObjVal? "proto_step").getStr?
  if tag == "register_error" then return .registrationError (← (← j.getObjVal? "error").getStr?)
  if tag == "protocol_error" then return .protocolError (← (← j.getObjVal? "error").getStr?)
  let id ← (← j.getObjVal? "jobId").getStr?
  match tag with
  | "job_accepted" =>
      let kind ← (← j.getObjVal? "kind").getStr?
      match kind with
      | "validate" => return .accepted id .validate
      | "gen_traces" => return .accepted id .genTraces
      | _ => throw "unknown job kind"
  | "job_status" =>
      let phase ← (← j.getObjVal? "phase").getStr?
      let phase ← match phase with
        | "pending" => pure JobPhase.pending
        | "running" => pure .running
        | "done" => pure .done
        | "failed" => pure .failed
        | "cancelled" => pure .cancelled
        | "unknown" => pure .unknown
        | _ => throw "unknown job phase"
      return .status id phase
  | "job_result" =>
      let outcome ← j.getObjVal? "outcome"
      let fields ← outcome.getObj?
      if fields.size != 1 then throw "expected one job outcome"
      if let .ok value := outcome.getObjVal? "validate" then
        return .result id (.validate (← ValidateResult.ofJson? value))
      if let .ok value := outcome.getObjVal? "genTraces" then
        let paths ← (← value.getObjVal? "itfTracePaths").getArr?
        let traces ← (← value.getObjVal? "itfTraces").getArr?
        return .result id (.genTraces (← paths.mapM Lean.Json.getStr?) traces)
      if let .ok value := outcome.getObjVal? "error" then
        return .result id (.error (← value.getStr?))
      throw "unknown job outcome"
  | _ => throw "unexpected async reply"
end JobReply

inductive JobRequest where
  | validate (config : ApalacheConfig) (bound : Nat) (spec : Option ApalacheSpec)
  | genTraces (config : ApalacheConfig) (trace : TraceGenerationConfig)
      (dest : Option String) (spec : Option ApalacheSpec)
  | query (jobId : String)
  | await (jobId : String) (timeoutSecs : Option Nat)
  | cancel (jobId : String)

namespace JobRequest
private def optional (key : String) (value : Option Lean.Json) : List (String × Lean.Json) :=
  value.toList.map (key, ·)

def encode (request : JobRequest) : String :=
  let (tag, fields) : String × List (String × Lean.Json) := match request with
    | .validate cfg bound spec => ("register_validate_async",
        [("apalacheConfig", cfg.toJson), ("bound", Lean.toJson bound)] ++
        optional "spec" (spec.map ApalacheSpec.toJson))
    | .genTraces cfg trace dest spec => ("register_trace_gen_async",
        [("apalacheConfig", cfg.toJson), ("traceConfig", trace.toJson)] ++
        optional "destPath" (dest.map Lean.toJson) ++ optional "spec" (spec.map ApalacheSpec.toJson))
    | .query id => ("query_job", [("jobId", Lean.toJson id)])
    | .await id timeout => ("await_job", [("jobId", Lean.toJson id)] ++
        optional "timeoutSecs" (timeout.map Lean.toJson))
    | .cancel id => ("cancel_job", [("jobId", Lean.toJson id)])
  (Lean.Json.mkObj (("proto_step", Lean.toJson tag) :: fields)).compress

def acceptsReply (request : JobRequest) (reply : JobReply) : Bool :=
  match request, reply with
  | .validate .., .accepted _ kind => kind == .validate
  | .genTraces .., .accepted _ kind => kind == .genTraces
  | .query id, .status actual _ | .query id, .result actual _
  | .await id _, .status actual _ | .await id _, .result actual _
  | .cancel id, .status actual _ | .cancel id, .result actual _ => id == actual
  | _, _ => false
end JobRequest

/-- Adopt a transport once; do not share it with raw readers or another Connection. -/
structure Connection where
  private transport : Transport
  private closed : Std.Mutex Bool

namespace Connection

def ofTransport (transport : Transport) : IO Connection := do
  if !transport.asyncCapable then throw (IO.userError "async jobs require TCP or mTLS")
  return { transport, closed := ← Std.Mutex.new false }

/-- Idempotent; only closes the owned connection, not the server process. -/
def close (connection : Connection) : IO Unit := connection.closed.atomically do
  if ← get then return
  set true
  let _ ← connection.transport.close

private def exchange (connection : Connection) (request : JobRequest) : IO (Except MirrorError JobReply) :=
  connection.closed.atomically do
    if ← get then return .error .transportClosed
    try
      connection.transport.send request.encode
      let some line ← connection.transport.recv | throw (IO.userError "EOF awaiting async reply")
      let reply ← match JobReply.decode line with
        | .ok reply => pure reply
        | .error e => throw (IO.userError e)
      if let .registrationError e := reply then return .error (.registerFailed e)
      if let .protocolError e := reply then throw (IO.userError e)
      if !request.acceptsReply reply then throw (IO.userError "async reply jobId or kind mismatch")
      return .ok reply
    catch e =>
      set true
      try let _ ← connection.transport.close catch _ => pure ()
      return .error (.io e)

def submitValidateAsync (connection : Connection) (config : ApalacheConfig) (bound : Nat)
    (spec : Option ApalacheSpec := none) : IO (Except MirrorError JobReply) := do
  if bound < 1 || bound > 100 then return .error (.protocol "validate bound must be in [1, 100]")
  exchange connection (.validate config bound spec)

def submitTraceGenAsync (connection : Connection) (config : ApalacheConfig)
    (trace : TraceGenerationConfig) (dest : Option String := none)
    (spec : Option ApalacheSpec := none) : IO (Except MirrorError JobReply) :=
  exchange connection (.genTraces config trace dest spec)

def queryJob (connection : Connection) (jobId : String) : IO (Except MirrorError JobReply) :=
  exchange connection (.query jobId)

def awaitJob (connection : Connection) (jobId : String) (timeoutSecs : Option Nat := none)
    : IO (Except MirrorError JobReply) := exchange connection (.await jobId timeoutSecs)

def cancelJob (connection : Connection) (jobId : String) : IO (Except MirrorError JobReply) :=
  exchange connection (.cancel jobId)
end Connection
end MirrorLean
