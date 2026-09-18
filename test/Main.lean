import MirrorLean

/-!
# MirrorLean.test

Pure unit tests for the M1 protocol core (Value, State, Protocol, Error).

Coverage:
* Value encode/decode round-trips for every constructor.
* ITF edge cases: #bigint boxing, empty-string bigint -> null, bare array -> seq,
  #tup/#set/#map unboxing, variants, unserializable, records (sorted keys).
* State round-trips and sorted-key determinism.
* ClientMessage encode -> decode -> re-encode stability for every constructor.
* MirrorMessage.decode on wire samples: initial_state, spec_validated,
  step_mismatch with diff hints, gen_traces_done, explorer_ready, unknown
  proto_step -> protocol_error, malformed JSON -> MirrorError.json.
* DiffHint rendering (renderPath/renderDiffHint/renderDiffHints).
* MirrorError.toString for the step-mismatch and invariant-violation cases.
-/

open MirrorLean

namespace MirrorLeanTest

-- --------------------------------------------------------------------------
-- Tiny test framework: a list of named IO Bool actions; main() aggregates
-- failures and throws if any test failed (no IO.Process.exit in Lean 4).
-- --------------------------------------------------------------------------

def decodeValue (s : String) : Except String Value :=
  match Lean.Json.parse s with
  | .error e => .error e
  | .ok jv => Value.ofJson? jv

-- Encode a Value to its canonical compressed JSON string.
def encValue (v : Value) : String := Lean.Json.compress (Value.toJson v)

-- Decode a JSON string, re-encode, return the canonical string (round-trip).
def valueRoundTrip (s : String) : Except String String := do
  let v ← decodeValue s
  return encValue v

-- Decode a JSON string into a Value (for equality assertions; Value has BEq).
def valueOf (s : String) : Except String Value := decodeValue s

-- Round-trip a JSON string through Value decode/encode; ERR on failure.
def rtStr (s : String) : String := (valueRoundTrip s).toOption.getD "ERR"

def check (name : String) (cond : Bool) : IO Bool := do
  if cond then
    IO.println s!"  ok   - {name}"
    pure true
  else
    IO.println s!"  FAIL - {name}"
    pure false

def checkEq (name : String) (got expected : String) : IO Bool := do
  if got == expected then
    IO.println s!"  ok   - {name}"
    pure true
  else
    IO.println s!"  FAIL - {name}"
    IO.println s!"         got:      {got}"
    IO.println s!"         expected: {expected}"
    pure false

def checkErr (name : String) (r : Except String α) : IO Bool := do
  match r with
  | .error e =>
      IO.println s!"  ok   - {name} (error: {e})"
      pure true
  | .ok _ =>
      IO.println s!"  FAIL - {name} (expected error, got ok)"
      pure false

def checkOk (name : String) (r : Except String α) : IO Bool := do
  match r with
  | .ok _ =>
      IO.println s!"  ok   - {name}"
      pure true
  | .error e =>
      IO.println s!"  FAIL - {name} (error: {e})"
      pure false

-- --------------------------------------------------------------------------
-- 1. Value encoding round-trips
-- --------------------------------------------------------------------------

def testValueRoundTrips : List (String × IO Bool) :=
  [
    ("bigint positive", checkEq "bigint positive" (rtStr "{\"#bigint\":\"42\"}") "{\"#bigint\":\"42\"}"),
    ("bigint negative", checkEq "bigint negative" (rtStr "{\"#bigint\":\"-7\"}") "{\"#bigint\":\"-7\"}"),
    ("bigint empty -> null", checkEq "bigint empty" (rtStr "{\"#bigint\":\"\"}") "null"),
    ("bigint huge", checkEq "bigint huge" (rtStr "{\"#bigint\":\"123456789012345678901234567890\"}") "{\"#bigint\":\"123456789012345678901234567890\"}"),
    ("bigint invalid", checkErr "bigint invalid" (decodeValue "{\"#bigint\":\"abc\"}")),
    ("bool true", checkEq "bool true" (rtStr "true") "true"),
    ("bool false", checkEq "bool false" (rtStr "false") "false"),
    ("string", checkEq "string" (rtStr "\"hello\"") "\"hello\""),
    ("null", checkEq "null" (rtStr "null") "null"),
    ("bare number -> int (asymmetry)", checkEq "bare number" (rtStr "42") "{\"#bigint\":\"42\"}"),
    ("bare array -> seq", checkEq "bare array" (rtStr "[1,2]") "[{\"#bigint\":\"1\"},{\"#bigint\":\"2\"}]"),
    ("set", checkEq "set" (rtStr "{\"#set\":[1,2]}") "{\"#set\":[{\"#bigint\":\"1\"},{\"#bigint\":\"2\"}]}"),
    ("tuple", checkEq "tuple" (rtStr "{\"#tup\":[1,2]}") "{\"#tup\":[{\"#bigint\":\"1\"},{\"#bigint\":\"2\"}]}"),
    ("map", checkEq "map" (rtStr "{\"#map\":[[1,\"x\"],[2,\"y\"]]}") "{\"#map\":[[{\"#bigint\":\"1\"},\"x\"],[{\"#bigint\":\"2\"},\"y\"]]}"),
    ("variant", checkEq "variant" (rtStr "{\"tag\":\"Some\",\"value\":42}") "{\"tag\":\"Some\",\"value\":{\"#bigint\":\"42\"}}"),
    ("unserializable", checkEq "unserializable" (rtStr "{\"#unserializable\":\"oops\"}") "{\"#unserializable\":\"oops\"}"),
    ("record sorted keys", checkEq "record sorted" (rtStr "{\"b\":1,\"a\":2,\"c\":3}") "{\"a\":{\"#bigint\":\"2\"},\"b\":{\"#bigint\":\"1\"},\"c\":{\"#bigint\":\"3\"}}"),
    ("nested record", checkEq "nested record" (rtStr "{\"x\":{\"y\":1}}") "{\"x\":{\"y\":{\"#bigint\":\"1\"}}}"),
    ("empty record", checkEq "empty record" (rtStr "{}") "{}"),
    ("empty seq", checkEq "empty seq" (rtStr "[]") "[]"),
  ]

-- --------------------------------------------------------------------------
-- 2. Value decode correctness (structural, using BEq on Value)
-- --------------------------------------------------------------------------

def testValueDecode : List (String × IO Bool) :=
  [
    ("decode bigint", check "decode bigint" ((valueOf "{\"#bigint\":\"42\"}").toOption == some (Value.int 42))),
    ("decode bool", check "decode bool" ((valueOf "true").toOption == some (Value.bool true))),
    ("decode str", check "decode str" ((valueOf "\"hi\"").toOption == some (Value.str "hi"))),
    ("decode seq", check "decode seq" ((valueOf "[1,2]").toOption == some (Value.seq #[Value.int 1, Value.int 2]))),
    ("decode tuple", check "decode tuple" ((valueOf "{\"#tup\":[1]}").toOption == some (Value.tuple #[Value.int 1]))),
    ("decode set", check "decode set" ((valueOf "{\"#set\":[1]}").toOption == some (Value.set #[Value.int 1]))),
    ("decode map", check "decode map" ((valueOf "{\"#map\":[[1,2]]}").toOption == some (Value.map #[(Value.int 1, Value.int 2)]))),
    ("decode variant", check "decode variant" ((valueOf "{\"tag\":\"T\",\"value\":null}").toOption == some (Value.variant "T" Value.null))),
    ("decode unserializable", check "decode unserializable" ((valueOf "{\"#unserializable\":\"x\"}").toOption == some (Value.unserializable "x"))),
    ("decode null", check "decode null" ((valueOf "null").toOption == some Value.null)),
    ("decode empty bigint -> null", check "empty bigint null" ((valueOf "{\"#bigint\":\"\"}").toOption == some Value.null)),
    ("decode record", check "decode record" ((valueOf "{\"a\":1}").toOption == some (Value.record #[("a", Value.int 1)]))),
    ("decode bigint empty not error", checkOk "empty bigint ok" (decodeValue "{\"#bigint\":\"\"}")),
  ]

-- --------------------------------------------------------------------------
-- 3. State round-trips and determinism
-- --------------------------------------------------------------------------

def testState : List (String × IO Bool) :=
  [
    ("state encode", checkEq "state encode" (Lean.Json.compress (State.toJson (State.ofList [("x", Value.int 1), ("y", Value.int 2)]))) "{\"x\":{\"#bigint\":\"1\"},\"y\":{\"#bigint\":\"2\"}}"),
    ("state sorted keys", checkEq "state sorted" (Lean.Json.compress (State.toJson (State.ofList [("b", Value.int 1), ("a", Value.int 2)]))) "{\"a\":{\"#bigint\":\"2\"},\"b\":{\"#bigint\":\"1\"}}"),
    ("state round trip", check "state roundtrip" (match State.ofJson? ((Lean.Json.parse "{\"x\":1,\"y\":2}").toOption.getD Lean.Json.null) with
        | Except.ok s => s == State.ofList [("x", Value.int 1), ("y", Value.int 2)]
        | Except.error _ => false)),
    ("state empty", checkEq "state empty" (Lean.Json.compress (State.toJson (State.ofList []))) "{}"),
    ("getParamInt basic", check "getParamInt" (State.getParamInt (State.ofList [("x", Value.record #[("n", Value.int 5)])]) "x" "n" == 5)),
    ("getParamInt missing var -> 0", check "getParamInt missing" (State.getParamInt (State.ofList []) "x" "n" == 0)),
    ("getParam? present", check "getParam?" (match State.getParam? (State.ofList [("x", Value.record #[("n", Value.int 5)])]) "x" with
        | some s => s == State.ofList [("n", Value.int 5)]
        | none => false)),
    ("getParam? missing -> none", check "getParam? none" (State.getParam? (State.ofList []) "x" == none)),
  ]

-- --------------------------------------------------------------------------
-- 4. ClientMessage encode/decode stability
-- --------------------------------------------------------------------------

def clientRoundTrip (m : ClientMessage) : String :=
  -- encode -> parse -> decode -> re-encode; must equal the original encoding
  let enc := ClientMessage.encode m
  match Lean.Json.parse enc with
  | .error _ => "PARSE-ERR"
  | .ok jv => match ClientMessage.ofJson? jv with
      | .error e => "DECODE-ERR: " ++ e
      | .ok m' => ClientMessage.encode m'

def sampleCfg : ApalacheConfig :=
  { specPath := "spec.tla", initPredicate := some "Init", nextPredicate := none,
    constInit := none, invariant := "Inv", lengthBound := 10, paramVars := some "x" }

def sampleTC : TraceGenerationConfig := { numTraces := 3, view := some "stats" }

def sampleSpec : ApalacheSpec := { sources := #["Spec.tla", "Spec_Ext.tla"] }

def cfgNone : ApalacheConfig :=
  { specPath := "spec.tla", initPredicate := none, nextPredicate := none,
    constInit := none, invariant := "Inv", lengthBound := 10, paramVars := none }

def cfgInit : ApalacheConfig :=
  { specPath := "spec.tla", initPredicate := some "Init", nextPredicate := none,
    constInit := none, invariant := "Inv", lengthBound := 10, paramVars := none }

def tcNone : TraceGenerationConfig := { numTraces := 1, view := none }

def sampleState : State := State.ofList [("x", Value.int 1), ("s", Value.str "hi")]

def testClientMessages : List (String × IO Bool) :=
  [
    ("register no spec", checkEq "register" (clientRoundTrip (.register sampleCfg sampleTC none))
        (ClientMessage.encode (.register sampleCfg sampleTC none))),
    ("register with spec", checkEq "register+spec" (clientRoundTrip (.register sampleCfg sampleTC (some sampleSpec)))
        (ClientMessage.encode (.register sampleCfg sampleTC (some sampleSpec)))),
    ("register_traces", checkEq "register_traces" (clientRoundTrip (.registerTraces sampleCfg #["a.itf.json"]))
        (ClientMessage.encode (.registerTraces sampleCfg #["a.itf.json"]))),
    ("register_trace_gen no spec", checkEq "register_trace_gen" (clientRoundTrip (.registerTraceGen sampleCfg sampleTC "out/" none))
        (ClientMessage.encode (.registerTraceGen sampleCfg sampleTC "out/" none))),
    ("register_trace_gen with spec", checkEq "register_trace_gen+spec" (clientRoundTrip (.registerTraceGen sampleCfg sampleTC "out/" (some sampleSpec)))
        (ClientMessage.encode (.registerTraceGen sampleCfg sampleTC "out/" (some sampleSpec)))),
    ("register_explore", checkEq "register_explore" (clientRoundTrip (.registerExplore sampleSpec #["Inv1"] #["states.itf.json"] 20))
        (ClientMessage.encode (.registerExplore sampleSpec #["Inv1"] #["states.itf.json"] 20))),
    ("register_explore_session", checkEq "register_explore_session" (clientRoundTrip (.registerExploreSession sampleSpec #["Inv1"] #["states.itf.json"]))
        (ClientMessage.encode (.registerExploreSession sampleSpec #["Inv1"] #["states.itf.json"]))),
    ("register_validate", checkEq "register_validate" (clientRoundTrip (.registerValidate sampleCfg 5 none))
        (ClientMessage.encode (.registerValidate sampleCfg 5 none))),
    ("explore_assume_transition", checkEq "explore_assume_transition" (clientRoundTrip (.exploreAssumeTransition 3))
        (ClientMessage.encode (.exploreAssumeTransition 3))),
    ("explore_next_step", checkEq "explore_next_step" (clientRoundTrip .exploreNextStep) (ClientMessage.encode .exploreNextStep)),
    ("explore_query_state", checkEq "explore_query_state" (clientRoundTrip .exploreQueryState) (ClientMessage.encode .exploreQueryState)),
    ("explore_check_invariant", checkEq "explore_check_invariant" (clientRoundTrip (.exploreCheckInvariant 2))
        (ClientMessage.encode (.exploreCheckInvariant 2))),
    ("explore_assume_state", checkEq "explore_assume_state" (clientRoundTrip (.exploreAssumeState sampleState))
        (ClientMessage.encode (.exploreAssumeState sampleState))),
    ("explore_rollback", checkEq "explore_rollback" (clientRoundTrip (.exploreRollback 7))
        (ClientMessage.encode (.exploreRollback 7))),
    ("explore_done", checkEq "explore_done" (clientRoundTrip .exploreDone) (ClientMessage.encode .exploreDone)),
    ("report_state", checkEq "report_state" (clientRoundTrip (.reportState sampleState))
        (ClientMessage.encode (.reportState sampleState))),
    ("register omits absent optional fields", check "register omits optionals"
        (not ((ClientMessage.encode (.register cfgNone tcNone none)).contains "initPredicate"))),
    ("register includes present optional fields", check "register includes optionals"
        ((ClientMessage.encode (.register cfgInit tcNone none)).contains "initPredicate")),
  ]

-- --------------------------------------------------------------------------
-- 5. MirrorMessage.decode on wire samples
-- --------------------------------------------------------------------------

def decodeMM (s : String) : Except MirrorError MirrorMessage := MirrorMessage.decode s

def testMirrorDecode : List (String × IO Bool) :=
  [
    ("initial_state", check "initial_state" (match decodeMM "{\"proto_step\":\"initial_state\",\"action\":\"Init\",\"state\":{\"x\":1}}" with
        | .ok (.initialState "Init" st) => st == State.ofList [("x", Value.int 1)]
        | _ => false)),
    ("spec_validated valid", check "spec_validated" (match decodeMM "{\"proto_step\":\"spec_validated\",\"result\":\"valid\"}" with
        | .ok (.specValidated .valid) => true
        | _ => false)),
    ("spec_validated invalid", check "spec_validated invalid" (match decodeMM "{\"proto_step\":\"spec_validated\",\"result\":{\"invalid\":\"boom\"}}" with
        | .ok (.specValidated (.invalid "boom")) => true
        | _ => false)),
    ("next_step", check "next_step" (match decodeMM "{\"proto_step\":\"next_step\",\"action\":\"N\",\"parameters\":{\"x\":1}}" with
        | .ok (.nextStep "N" params) => params == State.ofList [("x", Value.int 1)]
        | _ => false)),
    ("step_ok", check "step_ok" (match decodeMM "{\"proto_step\":\"step_ok\"}" with
        | .ok .stepOk => true
        | _ => false)),
    ("all_steps_done", check "all_steps_done" (match decodeMM "{\"proto_step\":\"all_steps_done\"}" with
        | .ok .allStepsDone => true
        | _ => false)),
    ("step_mismatch empty", check "step_mismatch empty" (match decodeMM "{\"proto_step\":\"step_mismatch\",\"expected\":{},\"actual\":{},\"hints\":[]}" with
        | .ok (.stepMismatch _ e a h) => e.isEmpty && a.isEmpty && h.isEmpty
        | _ => false)),
    ("step_mismatch hints", check "step_mismatch hints" (match decodeMM "{\"proto_step\":\"step_mismatch\",\"expected\":{\"x\":1},\"actual\":{\"x\":2},\"hints\":[{\"kind\":\"value_mismatch\",\"path\":[{\"field\":\"x\"}],\"expected\":1,\"actual\":2}]}" with
        | .ok (.stepMismatch _ e a h) => (e == State.ofList [("x", Value.int 1)]) && (a == State.ofList [("x", Value.int 2)]) && (h.size == 1)
        | _ => false)),
    ("gen_traces_done", check "gen_traces_done" (match decodeMM "{\"proto_step\":\"gen_traces_done\",\"itfTracePaths\":[\"a.itf.json\"],\"itfTraces\":[1,2]}" with
        | .ok (.genTracesDone paths traces) => paths == #["a.itf.json"] && traces.size == 2
        | _ => false)),
    ("gen_traces_done defaults", check "gen_traces_done defaults" (match decodeMM "{\"proto_step\":\"gen_traces_done\"}" with
        | .ok (.genTracesDone paths traces) => paths.isEmpty && traces.isEmpty
        | _ => false)),
    ("explorer_ready", check "explorer_ready" (match decodeMM "{\"proto_step\":\"explorer_ready\",\"initTransitions\":2,\"nextTransitions\":3,\"stateInvariants\":1}" with
        | .ok (.explorerReady a b c) => a == 2 && b == 3 && c == 1
        | _ => false)),
    ("explore_transition_status", check "explore_transition_status" (match decodeMM "{\"proto_step\":\"explore_transition_status\",\"status\":\"ok\"}" with
        | .ok (.exploreTransitionStatus s) => s == "ok"
        | _ => false)),
    ("explore_step_done", check "explore_step_done" (match decodeMM "{\"proto_step\":\"explore_step_done\",\"stepNo\":5}" with
        | .ok (.exploreStepDone n) => n == 5
        | _ => false)),
    ("explore_state", check "explore_state" (match decodeMM "{\"proto_step\":\"explore_state\",\"state\":{\"x\":1}}" with
        | .ok (.exploreState st) => st == State.ofList [("x", Value.int 1)]
        | _ => false)),
    ("explore_invariant_status", check "explore_invariant_status" (match decodeMM "{\"proto_step\":\"explore_invariant_status\",\"status\":\"violated\"}" with
        | .ok (.exploreInvariantStatus s) => s == "violated"
        | _ => false)),
    ("explore_assume_status", check "explore_assume_status" (match decodeMM "{\"proto_step\":\"explore_assume_status\",\"status\":\"ok\"}" with
        | .ok (.exploreAssumeStatus s) => s == "ok"
        | _ => false)),
    ("explore_rollback_done", check "explore_rollback_done" (match decodeMM "{\"proto_step\":\"explore_rollback_done\",\"snapshotId\":4}" with
        | .ok (.exploreRollbackDone n) => n == 4
        | _ => false)),
    ("explore_session_done", check "explore_session_done" (match decodeMM "{\"proto_step\":\"explore_session_done\"}" with
        | .ok .exploreSessionDone => true
        | _ => false)),
    ("protocol_error", check "protocol_error" (match decodeMM "{\"proto_step\":\"protocol_error\",\"error\":\"oops\"}" with
        | .ok (.protocolError e) => e == "oops"
        | _ => false)),
    ("register_error", check "register_error" (match decodeMM "{\"proto_step\":\"register_error\",\"error\":\"no\"}" with
        | .ok (.registerError e) => e == "no"
        | _ => false)),
    ("unknown proto_step -> protocol_error", check "unknown step" (match decodeMM "{\"proto_step\":\"bogus\"}" with
        | .ok (.protocolError e) => e == "unknown proto_step: bogus"
        | _ => false)),
    ("malformed json -> json error", check "malformed json" (match decodeMM "not json" with
        | .error (.json _) => true
        | _ => false)),
    ("decode empty hints default", check "decode empty hints default" (match decodeMM "{\"proto_step\":\"step_mismatch\",\"expected\":{},\"actual\":{}}" with
        | .ok (.stepMismatch _ _ _ h) => h.isEmpty
        | _ => false)),
  ]

-- --------------------------------------------------------------------------
-- 6. DiffHint rendering
-- --------------------------------------------------------------------------

def testRendering : List (String × IO Bool) :=
  [
    ("renderPath field", checkEq "renderPath field" (renderPath #[PathSeg.field "x"]) "x"),
    ("renderPath index", checkEq "renderPath index" (renderPath #[PathSeg.index 1]) "[1]"),
    ("renderPath mixed", checkEq "renderPath mixed" (renderPath #[PathSeg.field "x", PathSeg.index 1]) "x[1]"),
    ("renderPath empty", checkEq "renderPath empty" (renderPath #[]) "<state>"),
    ("renderDiffHint valueMismatch", checkEq "renderDiffHint" (renderDiffHint (.valueMismatch #[PathSeg.field "x", PathSeg.index 1] (Value.int 2) (Value.int 3))) "at x[1]: expected 2, got 3"),
    ("renderDiffHint missing", checkEq "renderDiffHint missing" (renderDiffHint (.missing #[PathSeg.field "y"] (Value.str "z"))) "at y: missing \"z\""),
    ("renderDiffHint extra", checkEq "renderDiffHint extra" (renderDiffHint (.extra #[PathSeg.field "y"] (Value.str "z"))) "at y: unexpected \"z\""),
    ("renderDiffHints empty", checkEq "renderDiffHints empty" (renderDiffHints #[]) "states differ"),
    ("renderDiffHints joined", checkEq "renderDiffHints joined" (renderDiffHints #[.valueMismatch #[PathSeg.field "x"] (Value.int 1) (Value.int 2), .missing #[PathSeg.field "y"] (Value.int 3)]) "at x: expected 1, got 2; at y: missing 3"),
  ]

-- --------------------------------------------------------------------------
-- 7. MirrorError.toString
-- --------------------------------------------------------------------------

def testErrors : List (String × IO Bool) :=
  [
    ("invariant violation", checkEq "invariant violation" (MirrorError.toString (.stepMismatch { action := "Init", params := State.ofList [], expected := State.ofList [], actual := State.ofList [], hints := #[] })) "invariant violation reported by the mirror"),
    ("step mismatch with hints", checkEq "step mismatch hints" (MirrorError.toString (.stepMismatch { action := "Next", params := State.ofList [("x", Value.int 1)], expected := State.ofList [("x", Value.int 1)], actual := State.ofList [("x", Value.int 2)], hints := #[.valueMismatch #[PathSeg.field "x"] (Value.int 1) (Value.int 2)] })) "step mismatch on action \"Next\" with parameters {\"x\":1}: at x: expected 1, got 2"),
    ("json error", check "json error" ("JSON error".isPrefixOf (MirrorError.toString (.json "parse failed")))),
    ("protocol error", checkEq "protocol error" (MirrorError.toString (.protocol "boom")) "protocol error: boom"),
    ("transport closed", checkEq "transport closed" (MirrorError.toString .transportClosed) "transport closed"),
  ]


-- --------------------------------------------------------------------------
-- 8. Transport (M2): spawn a stub peer via /bin/sh and drive it over stdio.
-- --------------------------------------------------------------------------

def testTransportRoundTrip : IO Bool := do
  let script := "read line; echo '{\"proto_step\":\"spec_validated\",\"result\":\"valid\"}'; read line; echo '{\"proto_step\":\"all_steps_done\"}'"
  let args : IO.Process.SpawnArgs :=
    { cmd := "/bin/sh", args := #["-c", script], stdin := .piped, stdout := .piped, stderr := .inherit }
  let child : StdioPipedChild ← IO.Process.spawn args
  let t := Transport.ofChild child
  t.send "{\"proto_step\":\"register\",\"position\":0}"
  let r1 ← t.recv
  let a ← checkEq "transport recv #1" (r1.getD "NONE") "{\"proto_step\":\"spec_validated\",\"result\":\"valid\"}"
  t.send "{\"proto_step\":\"validate\",\"bound\":10}"
  let r2 ← t.recv
  let b ← checkEq "transport recv #2" (r2.getD "NONE") "{\"proto_step\":\"all_steps_done\"}"
  let code ← t.close
  let c ← checkEq "transport close code" (toString code) "0"
  pure (a && b && c)

def testTransportEof : IO Bool := do
  let args : IO.Process.SpawnArgs :=
    { cmd := "/bin/sh", args := #["-c", "echo; echo done"], stdin := .piped, stdout := .piped, stderr := .inherit }
  let child : StdioPipedChild ← IO.Process.spawn args
  let t := Transport.ofChild child
  let rejected ← try let _ ← t.recv; pure false catch _ => pure true
  let a ← check "transport rejects empty frame" rejected
  let e2 ← t.recv
  let b ← checkEq "transport line #2" (e2.getD "NONE") "done"
  let e3 ← t.recv
  let c ← check "transport EOF -> none" e3.isNone
  let code ← t.close
  let d ← checkEq "transport eof close code" (toString code) "0"
  pure (a && b && c && d)

def protocolLineAccepted (line : String) : IO Bool := do
  try
    validateProtocolLine line
    pure true
  catch _ =>
    pure false

def testProtocolLineValidation : IO Bool := do
  let asciiMax := String.ofList (List.replicate 65535 'x')
  let asciiTooLarge := String.ofList (List.replicate 65536 'x')
  let utf8Max := String.ofList (List.replicate 32767 'é') ++ "a"
  let utf8TooLarge := String.ofList (List.replicate 32768 'é')
  let a ← check "framing: 65535 ASCII bytes accepted" (← protocolLineAccepted asciiMax)
  let b ← check "framing: 65536 ASCII bytes rejected" !(← protocolLineAccepted asciiTooLarge)
  let c ← check "framing: UTF-8 byte boundary accepted" (← protocolLineAccepted utf8Max)
  let d ← check "framing: UTF-8 byte overflow rejected" !(← protocolLineAccepted utf8TooLarge)
  let e ← check "framing: empty line rejected" !(← protocolLineAccepted "")
  let f ← check "framing: embedded newline rejected" !(← protocolLineAccepted "bad\nline")
  pure (a && b && c && d && e && f)

-- --------------------------------------------------------------------------
-- 9. Client (M2): drive the replay main loop over a pure in-memory transport.
-- --------------------------------------------------------------------------

/-- A pure in-memory `Transport`: `send` appends to `sent`, `recv` pops from
`inbox` (empty → EOF), `close` returns 0. -/
def fakeTransport (sent inbox : IO.Ref (Array String)) : Transport :=
  {
    send := fun line => sent.modify (·.push line),
    recv := do
      let arr ← inbox.get
      if arr.isEmpty then
        pure none
      else
        let line := arr.getD 0 ""
        inbox.set (arr.drop 1)
        pure (some line),
    close := pure 0,
  }

/-- Fake transport that counts closes, for persistent-session poison tests. -/
def trackedFakeTransport (sent inbox : IO.Ref (Array String)) (closes : IO.Ref Nat) : Transport :=
  {
    send := fun line => sent.modify (·.push line),
    recv := do
      let arr ← inbox.get
      if arr.isEmpty then pure none
      else
        inbox.set (arr.drop 1)
        pure (some (arr.getD 0 "")),
    close := do
      closes.modify (· + 1)
      pure 0,
  }

def testExploreProtocolErrorPoisons : IO Bool := do
  let inbox ← IO.mkRef #[
    "{\"proto_step\":\"explorer_ready\",\"initTransitions\":1,\"nextTransitions\":0,\"stateInvariants\":0}",
    "{\"proto_step\":\"protocol_error\",\"error\":\"bad transition\"}"
  ]
  let sent ← IO.mkRef (#[] : Array String)
  let closes ← IO.mkRef 0
  let opened ← startExploreSession
    (.transport (trackedFakeTransport sent inbox closes)) sampleSpec #[] #[]
  match opened with
  | .error _ => check "explore poison: session opened" false
  | .ok session =>
      let first ← ExploreSession.assumeTransition session 99
      let second ← ExploreSession.queryState session
      let sentLines ← sent.get
      let closeCount ← closes.get
      let a ← check "explore poison: protocol_error surfaced" (match first with
        | .error (.protocol "bad transition") => true
        | _ => false)
      let b ← check "explore poison: later command reports closed" (match second with
        | .error .transportClosed => true
        | _ => false)
      let c ← check "explore poison: no command written after poison" (sentLines.size == 2)
      let d ← check "explore poison: transport closed once" (closeCount == 1)
      pure (a && b && c && d)

def testClientHappy : IO Bool := do
  let inbox ← IO.mkRef #[
"{\"proto_step\":\"spec_validated\",\"result\":\"valid\"}",
    "{\"proto_step\":\"initial_state\",\"action\":\"Init\",\"state\":{}}",
    "{\"proto_step\":\"step_ok\"}",
    "{\"proto_step\":\"next_step\",\"action\":\"Advance\",\"parameters\":{\"x\":1}}",
    "{\"proto_step\":\"step_ok\"}",
    "{\"proto_step\":\"all_steps_done\"}"
  ]
  let sent ← IO.mkRef (#[] : Array String)
  let calls ← IO.mkRef (#[] : Array String)
  let compute : StateComputer := fun action _params prev => do
    calls.modify (·.push action)
    match action with
    | "Init" => pure (State.ofList [("count", Value.int 1)])
    | "Advance" => pure (State.ofList [("count", Value.int 2)])
    | _ => pure prev
  let r ← runClient (Target.transport (fakeTransport sent inbox)) sampleCfg sampleTC compute
  let a ← check "client happy: result ok" r.isOk
  let gotSent ← sent.get
  let b ← check "client happy: sent messages" (gotSent == #[
      ClientMessage.encode (.register sampleCfg sampleTC none),
      ClientMessage.encode (.reportState (State.ofList [("count", Value.int 1)])),
      ClientMessage.encode (.reportState (State.ofList [("count", Value.int 2)]))
    ])
  let gotCalls ← calls.get
  let c ← check "client happy: compute calls" (gotCalls == #["Init", "Advance"])
  pure (a && b && c)

def testClientMismatch : IO Bool := do
  let inbox ← IO.mkRef #[
"{\"proto_step\":\"spec_validated\",\"result\":\"valid\"}",
    "{\"proto_step\":\"initial_state\",\"action\":\"Init\",\"state\":{}}",
    "{\"proto_step\":\"step_ok\"}",
    "{\"proto_step\":\"next_step\",\"action\":\"Advance\",\"parameters\":{\"x\":1}}",
    "{\"proto_step\":\"step_ok\"}",
    "{\"proto_step\":\"step_mismatch\",\"expected\":{\"x\":1},\"actual\":{\"x\":2},\"hints\":[{\"kind\":\"value_mismatch\",\"path\":[{\"field\":\"x\"}],\"expected\":1,\"actual\":2}]}"
  ]
  let sent ← IO.mkRef (#[] : Array String)
  let compute : StateComputer := fun _ _ _ => pure (State.ofList [])
  let r ← runClient (Target.transport (fakeTransport sent inbox)) sampleCfg sampleTC compute
  match r with
  | .error (.stepMismatch rep) =>
      let a ← checkEq "client mismatch: action" rep.action "Advance"
      let b ← check "client mismatch: params" (rep.params == State.ofList [("x", Value.int 1)])
      let c ← check "client mismatch: expected" (rep.expected == State.ofList [("x", Value.int 1)])
      let d ← check "client mismatch: actual" (rep.actual == State.ofList [("x", Value.int 2)])
      let e ← check "client mismatch: hints" (rep.hints.size == 1)
      let f ← checkEq "client mismatch: renders" (MirrorError.toString (.stepMismatch rep))
          "step mismatch on action \"Advance\" with parameters {\"x\":1}: at x: expected 1, got 2"
      pure (a && b && c && d && e && f)
  | _ =>
      check "client mismatch: got stepMismatch error" false

def testClientGenTraces : IO Bool := do
  let inbox ← IO.mkRef #[
"{\"proto_step\":\"gen_traces_done\",\"itfTracePaths\":[\"/tmp/t0.itf.json\",\"/tmp/t1.itf.json\"],\"itfTraces\":[{\"states\":[]},{\"states\":[]}]}"
  ]
  let sent ← IO.mkRef (#[] : Array String)
  let r ← runClientGenTraces (Target.transport (fakeTransport sent inbox)) sampleCfg
      (System.FilePath.mk "/tmp/gen") sampleTC
  match r with
  | .ok res =>
      let a ← check "client gen: paths"
          (res.itfTracePaths == #[System.FilePath.mk "/tmp/t0.itf.json", System.FilePath.mk "/tmp/t1.itf.json"])
      let b ← check "client gen: inline traces" (res.itfTraces.size == 2)
      let gotSent ← sent.get
      let c ← check "client gen: register_trace_gen sent"
          (gotSent == #[ClientMessage.encode (.registerTraceGen sampleCfg sampleTC "/tmp/gen" none)])
      pure (a && b && c)
  | .error _ =>
      check "client gen: expected ok" false


def testClientPresetExhausted : IO Bool := do
  let inbox ← IO.mkRef #[
    "{\"proto_step\":\"spec_validated\",\"result\":\"valid\"}",
    "{\"proto_step\":\"initial_state\",\"action\":\"Init\",\"state\":{}}"
  ]
  let sent ← IO.mkRef (#[] : Array String)
  let compute ← presetClient (#[] : Array State)
  let r ← runClient (Target.transport (fakeTransport sent inbox)) sampleCfg sampleTC compute
  match r with
  | .error (.io _) => check "client preset exhausted -> io error" true
  | _ => check "client preset exhausted -> io error" false

/-- Validate-only session, design 8.6: spec_validated {result: "valid"} -> ok;
{result: {invalid: d}} -> MirrorError.specInvalid; register_error ->
MirrorError.registerFailed. Each case uses a fake transport so the wire
replies exercise the client mapping without a mirror binary. -/
def testClientValidateSpecInvalid : IO Bool := do
  let inbox ← IO.mkRef #[
    "{\"proto_step\":\"spec_validated\",\"result\":{\"invalid\":\"type error\"}}"
  ]
  let sent ← IO.mkRef (#[] : Array String)
  let r ← runClientValidate (Target.transport (fakeTransport sent inbox)) sampleCfg 3
  match r with
  | .error (.specInvalid d) =>
      let a ← checkEq "validate specInvalid: detail" d "type error"
      let gotSent ← sent.get
      let b ← check "validate specInvalid: register_validate sent"
          (gotSent == #[ClientMessage.encode (.registerValidate sampleCfg 3 none)])
      pure (a && b)
  | _ => check "validate specInvalid: got specInvalid error" false

def testClientValidateRegisterFailed : IO Bool := do
  let inbox ← IO.mkRef #[
    "{\"proto_step\":\"register_error\",\"error\":\"no such operator\"}"
  ]
  let sent ← IO.mkRef (#[] : Array String)
  let r ← runClientValidate (Target.transport (fakeTransport sent inbox)) sampleCfg 3
  match r with
  | .error (.registerFailed d) =>
      let a ← checkEq "validate registerFailed: detail" d "no such operator"
      let gotSent ← sent.get
      let b ← check "validate registerFailed: register_validate sent"
          (gotSent == #[ClientMessage.encode (.registerValidate sampleCfg 3 none)])
      pure (a && b)
  | _ => check "validate registerFailed: got registerFailed error" false

def testClientValidateValid : IO Bool := do
  let inbox ← IO.mkRef #[
    "{\"proto_step\":\"spec_validated\",\"result\":\"valid\"}"
  ]
  let sent ← IO.mkRef (#[] : Array String)
  let r ← runClientValidate (Target.transport (fakeTransport sent inbox)) sampleCfg 3
  match r with
  | .ok () =>
      let gotSent ← sent.get
      check "validate valid: register_validate sent"
          (gotSent == #[ClientMessage.encode (.registerValidate sampleCfg 3 none)])
  | _ => check "validate valid: expected ok" false

def testClient : List (String × IO Bool) :=
  [
    ("client happy replay", testClientHappy),
    ("client step mismatch", testClientMismatch),
    ("client gen traces", testClientGenTraces),
    ("client preset exhausted", testClientPresetExhausted),
    ("client validate specInvalid", testClientValidateSpecInvalid),
    ("client validate registerFailed", testClientValidateRegisterFailed),
    ("client validate valid", testClientValidateValid),
    ("explorer protocol_error poisons", testExploreProtocolErrorPoisons),
  ]

-- --------------------------------------------------------------------------
-- 10. Spec closure (M3): specFromFile / specFromFiles over test/fixtures/.
-- --------------------------------------------------------------------------

/-- Check that source[i] declares the expected module (by its MODULE line). -/
def srcHasModule (spec : ApalacheSpec) (i : Nat) (mod : String) : Bool :=
  (spec.sources.getD i "").contains s!"MODULE {mod}"

def testSpecRootClosure : IO Bool := do
  let r ← specFromFile (System.FilePath.mk "test/fixtures/root/Root.tla")
  match r with
  | .error _ =>
      check "spec root closure: error" false
  | .ok spec =>
      let a ← checkEq "spec root: 3 sources" (toString spec.sources.size) "3"
      let b ← check "spec root: root first" (srcHasModule spec 0 "Root")
      let c ← check "spec root: DepA second" (srcHasModule spec 1 "DepA")
      let d ← check "spec root: DepB third" (srcHasModule spec 2 "DepB")
      pure (a && b && c && d)

def testSpecCommented : IO Bool := do
  let r ← specFromFile (System.FilePath.mk "test/fixtures/root/Commented.tla")
  match r with
  | .error _ => check "spec commented: error" false
  | .ok spec =>
      -- \* EXTENDS DepA and (* EXTENDS DepB ... *) are stripped by the
      -- comment scanner, so no dependencies are resolved.
      check "spec commented: only root" (spec.sources.size == 1)

def testSpecBuiltinOnly : IO Bool := do
  let r ← specFromFile (System.FilePath.mk "test/fixtures/root/BuiltinOnly.tla")
  match r with
  | .error _ => check "spec builtin: error" false
  | .ok spec =>
      -- Naturals / Sequences / FiniteSets are builtins: never resolved as files.
      check "spec builtin: only root" (spec.sources.size == 1)

def testSpecWithInst : IO Bool := do
  let r ← specFromFile (System.FilePath.mk "test/fixtures/root/WithInst.tla")
  match r with
  | .error _ => check "spec inst: error" false
  | .ok spec =>
      -- INSTANCE DepA WITH x <- y resolves DepA (WITH dropped); DepA itself
      -- extends DepB, so the closure is [WithInst, DepA, DepB].
      let a ← checkEq "spec inst: 3 sources" (toString spec.sources.size) "3"
      let b ← check "spec inst: root first" (srcHasModule spec 0 "WithInst")
      let c ← check "spec inst: DepA second" (srcHasModule spec 1 "DepA")
      let d ← check "spec inst: DepB third" (srcHasModule spec 2 "DepB")
      pure (a && b && c && d)

/-- A WithInst variant whose WITH substitution carries a comma: the scanner
must still resolve only DepA (never the substitution names). -/
def testSpecWithInstComma : IO Bool := do
  -- build a temp module text in tmp/ exercising the comma case
  let text := "---- MODULE WithInstComma ----
INSTANCE DepA WITH x <- 1, y <- 2
===="
  IO.FS.writeFile (System.FilePath.mk "tmp/WithInstComma.tla") text
  let r ← specFromFiles (System.FilePath.mk "tmp/WithInstComma.tla") #[System.FilePath.mk "test/fixtures/root"]
  match r with
  | .error _ =>
      check "spec inst comma: error" false
  | .ok spec =>
      let a ← checkEq "spec inst comma: 3 sources" (toString spec.sources.size) "3"
      let b ← check "spec inst comma: root first" (srcHasModule spec 0 "WithInstComma")
      let c ← check "spec inst comma: DepA second" (srcHasModule spec 1 "DepA")
      let d ← check "spec inst comma: DepB third" (srcHasModule spec 2 "DepB")
      pure (a && b && c && d)

def testSpecAdvancedForms : IO Bool := do
  let r ← specFromFile (System.FilePath.mk "test/fixtures/root/Advanced.tla")
  match r with
  | .error _ => check "spec advanced forms: error" false
  | .ok spec =>
      let a ← checkEq "spec advanced: 4 sources" (toString spec.sources.size) "4"
      let b ← check "spec advanced: root first" (srcHasModule spec 0 "Advanced")
      let c ← check "spec advanced: multiline EXTENDS" (srcHasModule spec 1 "DepA")
      let d ← check "spec advanced: second EXTENDS module" (srcHasModule spec 2 "DepB")
      let e ← check "spec advanced: expression INSTANCE" (srcHasModule spec 3 "DepC")
      pure (a && b && c && d && e)

def testSpecLibDir : IO Bool := do
  let r ← specFromFiles (System.FilePath.mk "test/fixtures/root/UsesExtra.tla")
      #[System.FilePath.mk "test/fixtures/libdir"]
  match r with
  | .error _ => check "spec libdir: error" false
  | .ok spec =>
      -- Extra is not next to the importing file; searchDirs finds it.
      let a ← checkEq "spec libdir: 2 sources" (toString spec.sources.size) "2"
      let b ← check "spec libdir: Extra resolved" (srcHasModule spec 1 "Extra")
      pure (a && b)

/-- TLA_LIBRARY_PATH default lookup: when the env var is set (as in the real
smoke environment), the default searchDirs find lib modules. Skipped when
TLA_LIBRARY_PATH is unset (the plain unit-test environment). -/
def testSpecTlaLibraryPath : IO Bool := do
  let env ← IO.getEnv "TLA_LIBRARY_PATH"
  match env with
  | none =>
      IO.println "  skp - TLA_LIBRARY_PATH unset; skipping"
      pure true
  | some _ =>
      let r ← specFromFile (System.FilePath.mk "test/fixtures/root/UsesExtra.tla")
      match r with
      | .error _ => check "spec tla_library_path: error" false
      | .ok spec =>
          let a ← checkEq "spec tla_library_path: 2 sources" (toString spec.sources.size) "2"
          let b ← check "spec tla_library_path: Extra resolved" (srcHasModule spec 1 "Extra")
          pure (a && b)

def testSpecAmbiguity : IO Bool := do
  -- Same.tla exists in both lib1 and lib2 with different content -> ambiguity.
  let r ← specFromFiles (System.FilePath.mk "test/fixtures/root/UsesSame.tla")
      #[System.FilePath.mk "test/fixtures/lib1", System.FilePath.mk "test/fixtures/lib2"]
  match r with
  | .error e =>
      check "spec ambiguity: errors" (e.msg.contains "ambiguous")
  | .ok _ =>
      check "spec ambiguity: errors" false

def testSpecMissing : IO Bool := do
  -- Same.tla exists only in lib1 and lib2, never in libdir: with libdir as
  -- the only search dir the import must fail to resolve (deterministic even
  -- when TLA_LIBRARY_PATH is set, because explicit searchDirs win).
  let r ← specFromFiles (System.FilePath.mk "test/fixtures/root/UsesSame.tla")
      #[System.FilePath.mk "test/fixtures/libdir"]
  match r with
  | .error e =>
      check "spec missing: errors" (e.msg.contains "not found")
  | .ok _ =>
      check "spec missing: errors" false

def testSpecClosure : List (String × IO Bool) :=
  [
    ("spec root closure", testSpecRootClosure),
    ("spec commented stripped", testSpecCommented),
    ("spec builtin-only", testSpecBuiltinOnly),
    ("spec INSTANCE WITH", testSpecWithInst),
    ("spec INSTANCE WITH comma", testSpecWithInstComma),
    ("spec continued and embedded forms", testSpecAdvancedForms),
    ("spec searchDirs lookup", testSpecLibDir),
    ("spec TLA_LIBRARY_PATH lookup", testSpecTlaLibraryPath),
    ("spec ambiguity error", testSpecAmbiguity),
    ("spec missing module error", testSpecMissing),
  ]

-- --------------------------------------------------------------------------
-- 11. Transport (M3): TCP loopback via connectMirror.
-- --------------------------------------------------------------------------

/-- A TCP loopback test: an in-process server on 127.0.0.1:0 (ephemeral
port) accepts one connection, serves canned mirror lines, and asserts that
connectMirror's buffered line reader returns them in order; the client's
send is verified by reading it back on the server side. -/
def testTcpLoopback : IO Bool := do
  let server ← Std.Async.TCP.Socket.Server.mk
  server.bind (Std.Net.SocketAddress.v4 { addr := Std.Net.IPv4Addr.ofParts 127 0 0 1, port := 0 })
  server.listen 5
  let sockName ← server.getSockName
  let port := sockName.port
  let acceptTask ← IO.asTask (Std.Async.Async.block server.accept)
  let t ← connectMirror "127.0.0.1" port
  let accepted ← IO.ofExcept acceptTask.get
  let serve (s : String) : IO Unit :=
    Std.Async.Async.block (Std.Async.TCP.Socket.Client.send accepted ((s ++ "\n").toUTF8))
  serve "{\"proto_step\":\"spec_validated\",\"result\":\"valid\"}"
  serve "{\"proto_step\":\"initial_state\",\"action\":\"Init\",\"state\":{\"count\":0}}"
  serve "{\"proto_step\":\"all_steps_done\"}"
  let r1 ← t.recv
  let a ← checkEq "tcp recv #1" (r1.getD "NONE") "{\"proto_step\":\"spec_validated\",\"result\":\"valid\"}"
  let r2 ← t.recv
  let b ← checkEq "tcp recv #2" (r2.getD "NONE") "{\"proto_step\":\"initial_state\",\"action\":\"Init\",\"state\":{\"count\":0}}"
  let r3 ← t.recv
  let c ← checkEq "tcp recv #3" (r3.getD "NONE") "{\"proto_step\":\"all_steps_done\"}"
  let recvTask ← IO.asTask (Std.Async.Async.block (Std.Async.TCP.Socket.Client.recv? accepted 4096))
  t.send "hello from client"
  let got ← IO.ofExcept recvTask.get
  let d ← check "tcp send received" (match got with
      | some bs => (String.fromUTF8? bs).getD "" == "hello from client\n"
      | none => false)
  let code ← t.close
  let e ← checkEq "tcp close code" (toString code) "0"
  pure (a && b && c && d && e)

def testTcp : List (String × IO Bool) :=
  [
    ("tcp loopback", testTcpLoopback),
  ]


-- --------------------------------------------------------------------------
-- main
-- --------------------------------------------------------------------------

def testTransport : List (String × IO Bool) :=
  [
    ("transport round-trip", testTransportRoundTrip),
    ("transport eof empty-line", testTransportEof),
    ("transport protocol line validation", testProtocolLineValidation),
  ]

def allTests : List (String × IO Bool) :=
  testValueRoundTrips ++ testValueDecode ++ testState ++
  testClientMessages ++ testMirrorDecode ++ testRendering ++ testErrors ++
  testTransport ++ testClient ++ testSpecClosure ++ testTcp

def main : IO Unit := do
  IO.println "MirrorLean M1 tests"
  let mut failures : Nat := 0
  let mut count : Nat := 0
  for (name, test) in allTests do
    count := count + 1
    IO.print s!"[{name}] "
    match ← test with
    | true  => IO.println "PASS"
    | false => failures := failures + 1; IO.println "FAIL"
  IO.println s!""
  IO.println s!"{count} tests, {failures} failures"
  if failures > 0 then
    throw (IO.userError s!"{failures} test(s) failed")

end MirrorLeanTest

/-- Executable entry point: run the M1 unit tests. -/
def main : IO Unit := MirrorLeanTest.main
