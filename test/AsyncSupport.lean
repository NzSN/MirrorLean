import MirrorLean

open MirrorLean

namespace AsyncTests

def require (ok : Bool) (message : String) : IO Unit :=
  unless ok do throw (IO.userError message)

def unwrap {α : Type} (value : Except MirrorError α) : IO α :=
  match value with
  | .ok a => pure a
  | .error e => throw (IO.userError (MirrorError.toString e))

def config : ApalacheConfig :=
  { specPath := "AsyncProbe.tla", invariant := "Safe", lengthBound := 3,
    initPredicate := some "Init", nextPredicate := some "Next" }

def spec : ApalacheSpec :=
  { sources := #["---- MODULE AsyncProbe ----\nEXTENDS Naturals\nVARIABLE\n  \\* @type: Int;\n  x\nInit == x = 0\nNext == x' = x + 1\nSafe == x >= 0\n====\n"] }

def vectors : IO Unit := do
  let file := (← IO.getEnv "MIRRORS_CLIENT_CONFORMANCE").getD "test/fixtures/client-conformance/async-replies.json"
  let data ← IO.FS.readFile file
  let .ok corpus := Lean.Json.parse data | throw (IO.userError "invalid corpus")
  let .ok cases := (corpus.getObjVal? "cases").bind Lean.Json.getArr? | throw (IO.userError "missing cases")
  for entry in cases do
    let .ok request := entry.getObjVal? "request" | throw (IO.userError "missing request")
    let .ok tag := (request.getObjVal? "proto_step").bind Lean.Json.getStr? | throw (IO.userError "missing tag")
    let id := ((request.getObjVal? "jobId").bind Lean.Json.getStr?).toOption.getD "job-1"
    let request : JobRequest := match tag with
      | "query_job" => .query id
      | "await_job" => .await id (some 1)
      | _ => .validate config 3 none
    let .ok reply := entry.getObjVal? "reply" | throw (IO.userError "missing reply")
    let .ok accept := (entry.getObjVal? "accept").bind Lean.Json.getBool? | throw (IO.userError "missing expected")
    let closed ← IO.mkRef 0
    let transport : Transport := {
      asyncCapable := true
      send := fun _ => pure ()
      recv := pure (some reply.compress)
      close := do closed.modify (· + 1); pure 0 }
    let connection ← Connection.ofTransport transport
    let result ← match request with
      | .query id => connection.queryJob id
      | .await id t => connection.awaitJob id t
      | _ => connection.submitValidateAsync config 3
    require (result.isOk == accept) s!"vector failed: {entry.compress}"
    if !accept then
      require ((← closed.get) == 1) "failed exchange did not close"
      require (!(← connection.queryJob id).isOk) "poisoned connection reused"
    connection.close
    connection.close
    require ((← closed.get) == 1) "close was not once-only"

def frames : IO Unit := do
  for size in [65535, 65536] do
    let bytes := (String.ofList (List.replicate size 'x') ++ "\n").toUTF8
    let buffer ← IO.mkRef bytes
    let accepted ← try let _ ← recvLine (pure none) buffer; pure true catch _ => pure false
    require (accepted == (size == 65535)) "frame size boundary"
  for bytes in [ByteArray.mk #[255, 10], "unterminated".toUTF8, "\n".toUTF8] do
    let buffer ← IO.mkRef bytes
    let accepted ← try let _ ← recvLine (pure none) buffer; pure true catch _ => pure false
    require (!accepted) "malformed frame accepted"
  let overflow ← IO.mkRef ((String.ofList (List.replicate 65536 'x')).toUTF8)
  let reads ← IO.mkRef 0
  let rejected ← try
    let _ ← recvLine (do reads.modify (· + 1); pure none) overflow
    pure false
  catch _ => pure true
  require (rejected && (← reads.get) == 0) "oversize frame requested another read"
  let writes ← IO.mkRef 0
  let t : Transport := { send := fun _ => writes.modify (· + 1), recv := pure none, close := pure 0 }
  let accepted ← try let _ ← Connection.ofTransport t; pure true catch _ => pure false
  require (!accepted) "stdio accepted for jobs"
  let result ← runClientValidate (.transport t) config 0
  require (!result.isOk && (← writes.get) == 0) "invalid bound wrote bytes"
  let bad : Transport := {
    asyncCapable := true
    send := fun _ => throw (IO.userError "primary send failure")
    recv := pure none
    close := throw (IO.userError "secondary close failure") }
  let connection ← Connection.ofTransport bad
  match ← connection.queryJob "job-1" with
  | .error e => require ((MirrorError.toString e).contains "primary send failure") "cleanup hid primary failure"
  | .ok _ => throw (IO.userError "failed send succeeded")
  connection.close


/-- Shared live test for TCP and mTLS; independent owners and cross-connection awaits. -/
def live (fresh : IO Transport) : IO Unit := do
  let owner ← Connection.ofTransport (← fresh)
  let reader ← Connection.ofTransport (← fresh)
  try
    let mut ids : Array String := #[]
    for _ in [0:2] do
      let result ← unwrap (← owner.submitValidateAsync config 3 (some spec))
      let .accepted id .validate := result | throw (IO.userError "expected validation acceptance")
      ids := ids.push id
    require (ids[0]! != ids[1]!) "job IDs collided"
    for id in ids.reverse do
      let mut done := false
      for _ in [0:12] do
        if !done then
          let reply ← unwrap (← reader.awaitJob id (some 10))
          match reply with
          | .result _ (.validate .valid) => done := true
          | .status _ .pending | .status _ .running => pure ()
          | _ => throw (IO.userError "unexpected await outcome")
      require done "await deadline exceeded"
      let result ← unwrap (← reader.queryJob id)
      match result with
      | .result actual (.validate .valid) => require (actual == id) "query correlation"
      | _ => throw (IO.userError "terminal query lost result")
    owner.close
    for id in ids do
      let mut evicted := false
      for _ in [0:100] do
        if !evicted then
          match ← unwrap (← reader.queryJob id) with
          | .status _ .unknown => evicted := true
          | _ => IO.sleep 20
      require evicted "owner disconnect did not evict"
    let cancelled ← unwrap (← reader.submitValidateAsync config 100 (some spec))
    let .accepted id _ := cancelled | throw (IO.userError "expected accepted")
    match ← unwrap (← reader.cancelJob id) with
    | .status _ .cancelled => pure ()
    | .result _ _ => pure () -- completion may win cancellation
    | _ => throw (IO.userError "invalid cancellation result")
  finally
    owner.close
    reader.close
end AsyncTests
