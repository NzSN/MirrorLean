import MirrorLean.ModelInterface

open Lean MirrorLean MirrorLean.ModelInterface

namespace ModelInterfaceTest

private def digestText : String := String.ofList (List.replicate 64 'a')
private def otherDigest : String := String.ofList (List.replicate 64 'b')
private def digest : SemanticDigest :=
  (SemanticDigest.fromHex digestText).toOption.get (by decide)

private def contractJson : Json := Json.mkObj [
  ("schema", "mirrors.model-interface/v1"), ("interfaceVersion", "1.0.0"),
  ("model", Json.mkObj [("module", "Counter"), ("source", "specs/Counter.tla")]),
  ("wire", Json.mkObj [("actionVariable", "action_taken"), ("parameterVariable", "parameters")]),
  ("initializers", .arr #[Json.mkObj [("id", "Initialize"), ("wireAction", "init"),
    ("wireAliases", .arr #[]), ("inputs", .arr #[])]]),
  ("actions", .arr #[]),
  ("observations", .arr #[Json.mkObj [("id", "Count"), ("wireName", "count"),
    ("provenance", "implementation")]])]

private def metadata : GeneratedMetadata := ⟨digestText, contractJson.compress⟩
private def config : ApalacheConfig := {
  specPath := "Counter.tla", invariant := "Inv", lengthBound := 3, paramVars := some "parameters" }

private def matchedFields : List (String × Json) := [
  ("schema", .str negotiationSchema), ("status", "matched"),
  ("descriptorSchema", .str descriptorSchema), ("semanticDigest", .str digest.toWire)]
private def validated (fields : List (String × Json)) : String :=
  (Json.mkObj [("proto_step", "spec_validated"), ("result", "valid"),
    ("modelInterface", Json.mkObj fields)]).compress
private def matched : String := validated matchedFields
private def change (fields : List (String × Json)) (key : String) (value : Json) :=
  fields.map fun (name, previous) => (name, if name == key then value else previous)
private def initial : String :=
  "{\"proto_step\":\"initial_state\",\"action\":\"init\",\"state\":{\"count\":{\"#bigint\":\"0\"}}}"
private def doneMessage : String := "{\"proto_step\":\"all_steps_done\"}"
private def mismatch : String :=
  "{\"proto_step\":\"step_mismatch\",\"action\":\"init\",\"expected\":{\"count\":{\"#bigint\":\"0\"}},\"actual\":{\"count\":{\"#bigint\":\"1\"}},\"hints\":[]}"

private def errorCode : Except NegotiatedError α → String
  | .ok _ => "ok"
  | .error (.modelInterface code _) => code
  | .error (.registration failure) => "server:" ++ failure.code
  | .error (.legacy (.stepMismatch _)) => "step_mismatch"
  | .error (.legacy (.io _)) => "io"
  | .error (.legacy (.json _)) => "json"
  | .error (.legacy .transportClosed) => "transport_closed"
  | .error (.legacy _) => "legacy"

private def assert (label : String) (condition : Bool) : IO Unit := do
  if !condition then throw (IO.userError s!"FAIL: {label}")
  IO.println s!"PASS: {label}"

structure Options where
  bindingDigest : String := digestText
  configFailure : Bool := false
  factoryFailure : Bool := false
  factoryThrow : Bool := false
  callbackError : Option String := none
  callbackThrow : Bool := false
  disposeFailure : Bool := false
  disposeThrow : Bool := false
  closeThrow : Bool := false
  sendThrow : Bool := false
  receiveThrow : Bool := false

structure Session where
  transport : Transport
  selection : CompiledAdapterSelection
  events : IO.Ref (Array String)
  sent : IO.Ref (Array String)

private def makeSession (replies : Array String) (options : Options := {}) : IO Session := do
  let events ← IO.mkRef #[]
  let sent ← IO.mkRef #[]
  let next ← IO.mkRef 0
  let record := fun event => events.modify (·.push event)
  let transport : Transport := {
    send := fun line => do
      record "send"
      sent.modify (·.push line)
      if options.sendThrow && (← sent.get).size > 1 then throw (IO.userError "send failed")
    recv := do
      record "recv"
      let index ← next.get
      next.set (index + 1)
      if options.receiveThrow && index > 0 then throw (IO.userError "receive failed")
      return replies[index]?
    close := do
      record "close"
      if options.closeThrow then throw (IO.userError "close failed")
      return 0 }
  let factory : AdapterFactory := fun context => do
    record "factory"
    assert "factory context has exact digest and config"
      (context.semanticDigest == digest && context.effectiveConfig.paramVars == some "parameters")
    if options.factoryThrow then throw (IO.userError "factory threw")
    if options.factoryFailure then return .error ⟨"failed", "factory failed"⟩
    return .ok {
      semanticDigest := options.bindingDigest
      assertCompatibleConfig := fun _ =>
        if options.configFailure then .error ⟨"configuration_mismatch", "wrong config"⟩ else .ok ()
      computer := fun _ _ previous => do
        record "compute"
        assert "initializer previous state is empty" previous.isEmpty
        if options.callbackThrow then throw (IO.userError "callback threw")
        if let some code := options.callbackError then return .error ⟨code, "callback failed"⟩
        return .ok (State.ofList [("count", .int 0)])
      dispose := do
        record "dispose"
        if options.disposeThrow then throw (IO.userError "dispose threw")
        if options.disposeFailure then return .error ⟨"failed", "dispose failed"⟩
        return .ok () }
  let registration : AdapterRegistration := {
    key := { semanticDigest := digest, adapterId := "counter" }
    factory }
  return {
    transport, events, sent
    selection := { metadata, adapterId := "counter", registry := #[registration] } }

private def runSession (session : Session) :=
  runClientWithTracesNegotiated (.transport session.transport) config #[] session.selection

private def occurrences (events : Array String) (name : String) : Nat :=
  (events.filter (· == name)).size

private def admissionTests : IO Unit := do
  let cases : List (String × String × String) := [
    ("missing extension", "{\"proto_step\":\"spec_validated\",\"result\":\"valid\"}", "negotiation_missing"),
    ("null extension", "{\"proto_step\":\"spec_validated\",\"result\":\"valid\",\"modelInterface\":null}", "negotiation_missing"),
    ("wrong digest", validated (change matchedFields "semanticDigest" (.str ("sha256:" ++ otherDigest))), "interface_digest_mismatch"),
    ("uppercase digest", validated (change matchedFields "semanticDigest" (.str ("sha256:" ++ digestText.toUpper))), "descriptor_digest_invalid"),
    ("missing wire prefix", validated (change matchedFields "semanticDigest" (.str digestText)), "descriptor_digest_invalid"),
    ("wrong schema", validated (change matchedFields "schema" "other"), "negotiation_status_unexpected"),
    ("wrong descriptor schema", validated (change matchedFields "descriptorSchema" "other"), "negotiation_status_unexpected"),
    ("wrong status", validated (change matchedFields "status" "resolved"), "negotiation_status_unexpected"),
    ("unsupported cannot fallback", validated (change matchedFields "status" "unsupported"), "negotiation_status_unexpected"),
    ("unknown extension field", validated (matchedFields ++ [("unknown", .bool true)]), "negotiation_status_unexpected"),
    ("descriptor forbidden", validated (matchedFields ++ [("descriptor", Json.mkObj [])]), "negotiation_status_unexpected"),
    ("descriptor bytes forbidden", validated (matchedFields ++ [("descriptorBytes", toJson (0 : Nat))]), "negotiation_status_unexpected"),
    ("duplicate reply key", "{\"proto_step\":\"spec_validated\",\"result\":\"valid\",\"result\":\"valid\"}", "negotiation_status_unexpected"),
    ("escaped duplicate reply key", "{\"proto_step\":\"spec_validated\",\"result\":\"valid\",\"resu\\u006ct\":\"valid\"}", "negotiation_status_unexpected"),
    ("premature initial state", initial, "negotiation_status_unexpected"),
    ("unbounded exponent", "{\"x\":1e99999999999}", "negotiation_status_unexpected")]
  for (label, reply, expected) in cases do
    let session ← makeSession #[reply, initial, doneMessage]
    let result ← runSession session
    let events ← session.events.get
    assert label (errorCode result == expected && occurrences events "factory" == 0 &&
      occurrences events "compute" == 0 && occurrences events "close" == 1 &&
      (← session.sent.get).size == 1)
  let nullOptional := validated (matchedFields ++ [("descriptor", .null), ("descriptorBytes", .null)])
  assert "optional nulls treated as absent" (admitMatched nullOptional digest).isOk
  let structured := (Json.mkObj [("proto_step", "register_error"), ("error", "denied"),
    ("modelInterface", Json.mkObj [("schema", .str negotiationSchema), ("status", "unavailable"),
      ("code", "interface_access_denied")])]).compress
  let session ← makeSession #[structured]
  assert "structured server failure preserved" (errorCode (← runSession session) == "server:interface_access_denied")
  assert "server denial constructs nothing" (occurrences (← session.events.get) "factory" == 0)

private def lifecycleTests : IO Unit := do
  let tooDeep := "{\"proto_step\":\"initial_state\",\"action\":\"init\",\"state\":{\"count\":" ++
    String.ofList (List.replicate 130 '[') ++ "0" ++
    String.ofList (List.replicate 130 ']') ++ "}}"
  let tooLarge := "{\"proto_step\":\"all_steps_done\",\"extra\":\"" ++
    String.ofList (List.replicate 65536 'x') ++ "\"}"
  let cases : List (String × Options × Array String × String × Nat × Nat) := [
    ("success", {}, #[matched, initial, doneMessage], "ok", 1, 1),
    ("factory failure", {factoryFailure := true}, #[matched], "adapter_factory_failed", 0, 0),
    ("factory exception", {factoryThrow := true}, #[matched], "adapter_factory_failed", 0, 0),
    ("wrong binding digest", {bindingDigest := otherDigest}, #[matched, initial], "binding_digest_mismatch", 1, 0),
    ("malformed binding digest", {bindingDigest := "wrong"}, #[matched, initial], "binding_digest_mismatch", 1, 0),
    ("binding config mismatch", {configFailure := true}, #[matched, initial], "binding_config_mismatch", 1, 0),
    ("callback typed failure", {callbackError := some "input_shape_mismatch"}, #[matched, initial], "input_shape_mismatch", 1, 1),
    ("callback exception", {callbackThrow := true}, #[matched, initial], "adapter_failure", 1, 1),
    ("observation failure", {callbackError := some "observation_shape_mismatch"}, #[matched, initial], "observation_shape_mismatch", 1, 1),
    ("step mismatch", {}, #[matched, initial, mismatch], "step_mismatch", 1, 1),
    ("decode failure", {}, #[matched, "not json"], "json", 1, 0),
    ("duplicate replay field", {}, #[matched,
      "{\"proto_step\":\"initial_state\",\"action\":\"init\",\"state\":{\"count\":0,\"count\":1}}"], "json", 1, 0),
    ("deep replay frame", {}, #[matched, tooDeep], "json", 1, 0),
    ("oversized replay frame", {}, #[matched, tooLarge], "json", 1, 0),
    ("transport EOF", {}, #[matched], "transport_closed", 1, 0),
    ("receive exception", {receiveThrow := true}, #[matched, initial], "io", 1, 0),
    ("send exception", {sendThrow := true}, #[matched, initial], "io", 1, 1),
    ("dispose failure", {disposeFailure := true}, #[matched, initial, doneMessage], "adapter_dispose_failed", 1, 1),
    ("dispose exception", {disposeThrow := true}, #[matched, initial, doneMessage], "adapter_dispose_failed", 1, 1),
    ("primary survives disposal failure", {disposeFailure := true}, #[matched, initial, mismatch], "step_mismatch", 1, 1),
    ("primary survives close failure", {closeThrow := true}, #[matched, initial, mismatch], "step_mismatch", 1, 1),
    ("close failure on success", {closeThrow := true}, #[matched, initial, doneMessage], "io", 1, 1)]
  for (label, options, replies, expected, disposals, callbacks) in cases do
    let session ← makeSession replies options
    let result ← runSession session
    let events ← session.events.get
    assert label (errorCode result == expected && occurrences events "dispose" == disposals &&
      occurrences events "compute" == callbacks && occurrences events "close" == 1)
    if label == "success" then
      assert "matched-before-factory order" (events == #["send", "recv", "factory", "recv", "compute", "send", "recv", "dispose", "close"])
      let sent ← session.sent.get
      let request := (StrictJson.parse sent[0]!).toOption.get!
      assert "required registration wire contract"
        ((request.getObjVal? "modelInterface" >>= fun ext => ext.getObjValAs? String "policy").toOption == some "require" &&
        (request.getObjVal? "modelInterface" >>= fun ext => ext.getObjVal? "contract" >>= fun c => c.getObjVal? "inline").toOption == some contractJson)
      assert "report_state uses public ITF encoding" (sent[1]! == ClientMessage.encode (.reportState (State.ofList [("count", .int 0)])))

private def registryTests : IO Unit := do
  for kind in ["absent", "ambiguous", "adapter", "profile", "computer", "metadata", "contract"] do
    let session ← makeSession #[matched, initial, doneMessage]
    let some registration := session.selection.registry[0]?
      | throw (IO.userError "missing test registration")
    let selection := match kind with
      | "absent" => {session.selection with registry := #[]}
      | "ambiguous" => {session.selection with registry := #[registration, registration]}
      | "adapter" => {session.selection with adapterId := "another"}
      | "profile" => {session.selection with registry := #[{registration with key := {registration.key with targetProfile := "another"}}]}
      | "computer" => {session.selection with registry := #[{registration with key := {registration.key with stateComputerContractVersion := "another"}}]}
      | "metadata" => {session.selection with metadata := {metadata with semanticDigest := "wrong"}}
      | _ => {session.selection with metadata := {metadata with contractJson := "{\"schema\":\"bad\"}"}}
    let expected := match kind with
      | "absent" | "adapter" => "adapter_not_registered" | "ambiguous" => "adapter_ambiguous"
      | "profile" => "target_profile_mismatch" | "computer" => "state_computer_contract_mismatch"
      | "metadata" => "descriptor_digest_invalid" | _ => "negotiation_status_unexpected"
    let result ← runSession {session with selection}
    assert s!"registry/metadata {kind} is inert"
      (errorCode result == expected && (← session.sent.get).isEmpty &&
       (← session.events.get) == #["close"])
    let binaryResult ← runClientWithTracesNegotiated
      (.binary "/nonexistent-mirrorlean-local-validation-must-precede-spawn") config #[] selection
    assert s!"registry/metadata {kind} precedes binary spawn" (errorCode binaryResult == expected)
  assert "strict nested contract fields"
    (Validation.contract (Json.mkObj ((contractJson.getObj?.toOption.get!).toList.map fun (key, value) =>
      (key, if key == "model" then Json.mkObj [("module", "Counter"), ("source", "x"), ("extra", .null)] else value)))).toOption.isNone

private def resourceTests : IO Unit := do
  let emptyVariant := Json.mkObj [("kind", "variant"), ("cases", .arr #[])]
  assert "empty closed variant is a valid uninhabited type" (Validation.modelType emptyVariant 0 0).isOk
  assert "sequence of empty variant is a valid container type"
    (Validation.modelType (Json.mkObj [("kind", "seq"), ("element", emptyVariant)]) 0 0).isOk
  let longSource := String.intercalate "/" (List.replicate 40 "long-segment") ++ "/Counter.tla"
  let sourceContract := Json.mkObj (change (contractJson.getObj?.toOption.get!).toList "model"
    (Json.mkObj [("module", "Counter"), ("source", .str longSource)]))
  assert "logical source path is not a stable-name field" (Validation.contract sourceContract).isOk
  let longVersion := String.ofList (List.replicate 260 '1') ++ ".0.0"
  let versionContract := Json.mkObj (change (contractJson.getObj?.toOption.get!).toList
    "interfaceVersion" (.str longVersion))
  assert "interface version is not a stable-name field" (Validation.contract versionContract).isOk
  assert "strict JSON byte limit"
    (StrictJson.parse (String.ofList (List.replicate 65536 ' '))).toOption.isNone
  let nested := String.ofList (List.replicate 130 '[') ++ "0" ++ String.ofList (List.replicate 130 ']')
  assert "strict JSON depth limit" (StrictJson.parse nested).toOption.isNone
  assert "strict JSON nested escaped duplicate"
    (StrictJson.parse "{\"outer\":{\"x\":1,\"\\u0078\":2}}").toOption.isNone
  assert "strict JSON trailing bytes" (StrictJson.parse "{}{}").toOption.isNone
  let deepType := (List.replicate 32 ()).foldl (fun item _ =>
    Json.mkObj [("kind", "seq"), ("element", item)]) (Json.mkObj [("kind", "int")])
  assert "model type depth limit" (Validation.modelType deepType 0 0).toOption.isNone
  assert "aggregate model type node limit"
    (Validation.modelType (Json.mkObj [("kind", "int")]) 0 8192).toOption.isNone
  assert "closed type shape"
    (Validation.modelType (Json.mkObj [("kind", "int"), ("other", .null)]) 0 0).toOption.isNone
  assert "UTF-8 name bound"
    (Validation.shortString (.str (String.ofList (List.replicate 200 '界')))).toOption.isNone
  let items := (contractJson.getObjVal? "initializers" >>= Json.getArr?).toOption.get!
  let tooMany := Json.mkObj (change (contractJson.getObj?.toOption.get!).toList "initializers"
    (.arr (Array.replicate 33 items[0]!)))
  assert "initializer count bound" (Validation.contract tooMany).toOption.isNone

private def registrationTests : IO Unit := do
  let session ← makeSession #[matched, initial, doneMessage]
  let result ← runClientNegotiated (.transport session.transport) config {numTraces := 1}
    session.selection (some {sources := #["MODULE Counter"]})
  assert "generated-trace registration runner" (errorCode result == "ok")
  let request := (StrictJson.parse (← session.sent.get)[0]!).toOption.get!
  assert "register preserves trace config and inline spec"
    ((request.getObjValAs? String "proto_step").toOption == some "register" &&
      (request.getObjVal? "traceConfig").isOk && (request.getObjVal? "spec").isOk)

private def sharedReplayTests : IO Unit := do
  let next := "{\"proto_step\":\"next_step\",\"action\":\"tick\",\"parameters\":{\"stride\":2}}"
  let mismatchWithoutAction := "{\"proto_step\":\"step_mismatch\",\"expected\":{\"count\":1},\"actual\":{\"count\":0},\"hints\":[]}"
  for terminal in [mismatchWithoutAction, "{\"proto_step\":\"gen_traces_done\",\"itfTracePaths\":[]}"] do
    let replies := #[matched, initial, "{\"proto_step\":\"step_ok\"}", next, initial, terminal]
    let legacy ← makeSession replies
    let negotiated ← makeSession replies
    let output := State.ofList [("count", .int 0)]
    let registrations := negotiated.selection.registry.map fun registration =>
      { registration with factory := fun context => do
          return (← registration.factory context).map fun binding =>
            { binding with computer := fun _ _ _ => pure (.ok output) } }
    let oldResult ← runClientWithTraces (.transport legacy.transport) config #[]
      (fun _ _ _ => pure output)
    let newResult ← runSession { negotiated with selection := {
      negotiated.selection with registry := registrations } }
    match oldResult, newResult with
    | .error old, .error (.legacy new) =>
        assert "shared replay preserves terminal error details" (old.toString == new.toString)
        if let .stepMismatch oldReport := old then
          assert "shared replay preserves mismatch action and parameters across reinitialization"
            (oldReport.action == "init" && oldReport.params.get? "stride" == some (.int 2))
    | _, _ => assert "shared replay error carrier parity" false
    assert "shared replay preserves report wire bytes"
      ((← legacy.sent.get).toList.drop 1 == (← negotiated.sent.get).toList.drop 1)
    assert "shared replay scopes transport and binding cleanup"
      (occurrences (← legacy.events.get) "close" == 1 &&
       occurrences (← negotiated.events.get) "close" == 1 &&
       occurrences (← negotiated.events.get) "dispose" == 1)

private def codecTests : IO Unit := do
  let huge : Int := 123456789012345678901234567890123456789012345678901234567890
  assert "unbounded native integers" ((NativeCodec.decode (α := Int) (.int huge)).toOption == some huge)
  assert "constructor separation null/tuple/record"
    ((NativeCodec.decode (α := MirrorNull) .null).isOk &&
      (NativeCodec.decode (α := MirrorNull) (.tuple #[])).toOption.isNone &&
      (NativeCodec.decode (α := MirrorNull) (.record #[])).toOption.isNone)
  let a := Value.set #[.int 1, .int 2]
  let b := Value.set #[.int 2, .int 1]
  assert "nested semantic equality" (equivalent a b)
  assert "set input semantic duplicate rejected"
    (NativeCodec.decode (α := MirrorSet (MirrorSet Int)) (.set #[a, b])).toOption.isNone
  assert "set output semantic duplicate rejected"
    (NativeCodec.encode (MirrorSet.mk #[MirrorSet.mk #[1, 2], MirrorSet.mk #[2, 1]] : MirrorSet (MirrorSet Int))).toOption.isNone
  assert "duplicate map input rejected"
    (NativeCodec.decode (α := MirrorMap Int) (.map #[(.str "x", .int 1), (.str "x", .int 2)])).toOption.isNone
  assert "duplicate map output rejected"
    (NativeCodec.encode (MirrorMap.mk #[("x", 1), ("x", 2)] : MirrorMap Int)).toOption.isNone
  assert "non-string map input rejected"
    (NativeCodec.decode (α := MirrorMap Int) (.map #[(.int 1, .int 2)])).toOption.isNone
  assert "closed record rejects duplicate keys" (checkRecord #[("x", .int 1), ("x", .int 2)] ["x", "y"]).toOption.isNone
  assert "closed record rejects extra fields" (checkRecord #[("x", .int 1), ("y", .int 2)] ["x"]).toOption.isNone
  for (marker, value) in [("#set", toJson ([1] : List Int)), ("#bigint", toJson "1"),
      ("#map", toJson ([] : List Int)), ("#tup", toJson ([] : List Int)),
      ("#unserializable", toJson "text")] do
    let json := Json.mkObj [(marker, value), ("ordinary", .bool true)]
    match Value.ofJson? json with
    | .ok (.record fields) =>
        assert s!"ordinary record preserves {marker}" (fields.size == 2)
    | _ => assert s!"ordinary record preserves {marker}" false
  assert "path field/index/variant"
    ((readPath (.record #[("x", .seq #[.variant "Some" (.int huge)])])
      [.field "x", .index 0, .variantValue "Some"]).toOption == some (.int huge))
  assert "path missing index rejects" (readPath (.seq #[]) [.index 0]).toOption.isNone
  assert "path wrong variant rejects" (readPath (.variant "Some" (.int 0)) [.variantValue "None"]).toOption.isNone

end ModelInterfaceTest

def main : IO Unit := do
  ModelInterfaceTest.admissionTests
  ModelInterfaceTest.lifecycleTests
  ModelInterfaceTest.registryTests
  ModelInterfaceTest.resourceTests
  ModelInterfaceTest.registrationTests
  ModelInterfaceTest.sharedReplayTests
  ModelInterfaceTest.codecTests
  IO.println "MODEL INTERFACE SDK TESTS PASSED"
