import MirrorLean.ModelInterface.Native
import MirrorLean.ModelInterface.Validation

/-! Additive required-negotiation support for compiled Lean bindings. Legacy
StateComputer, MirrorError, protocol constructors and wire bytes are unchanged.
Factories run only after exact matched admission, and disposal is scoped to
one returned binding. Remote descriptors are never interpreted or executed. -/
namespace MirrorLean.ModelInterface
open Lean

def descriptorSchema : String := "mirrors.model-interface-descriptor/v1"
def negotiationSchema : String := "mirrors.model-interface-negotiation/v1"
def stateComputerContractVersion : String := "mirrors.state-computer/v1"

structure RegistrationFailure where
  code : String
  message : String
  status : String
  expectedSemanticDigest : Option String := none
  actualSemanticDigest : Option String := none
  deriving Repr

inductive NegotiatedError where
  | legacy (error : MirrorError)
  | registration (failure : RegistrationFailure)
  | modelInterface (code message : String)

def NegotiatedError.toString : NegotiatedError → String
  | .legacy error => error.toString
  | .registration failure => s!"registration {failure.code}: {failure.message}"
  | .modelInterface code message => s!"model interface {code}: {message}"

instance : ToString NegotiatedError := ⟨NegotiatedError.toString⟩

private def fail {α : Type} (code message : String) : Except NegotiatedError α :=
  .error (.modelInterface code message)

private def validate {α : Type} (value : Except String α) : Except NegotiatedError α :=
  value.mapError (.modelInterface "negotiation_status_unexpected")

/-- Canonical lowercase digest. Construction validates spelling before any
registry lookup or wire comparison. -/
structure SemanticDigest where
  private mk ::
  hex : String
  deriving Repr, BEq

def SemanticDigest.fromHex (value : String) : Except NegotiatedError SemanticDigest := do
  if value.length != 64 || !value.toList.all (fun c =>
      ('0' <= c && c <= '9') || ('a' <= c && c <= 'f')) then
    fail "descriptor_digest_invalid" "digest must contain exactly 64 lowercase hex characters"
  return ⟨value⟩

def SemanticDigest.fromWire (value : String) : Except NegotiatedError SemanticDigest := do
  if !value.startsWith "sha256:" then
    fail "descriptor_digest_invalid" "wire digest must start with sha256:"
  SemanticDigest.fromHex (value.drop 7).copy

def SemanticDigest.toWire (digest : SemanticDigest) : String := "sha256:" ++ digest.hex

structure AdapterKey where
  semanticDigest : SemanticDigest
  adapterId : String
  targetProfile : String := "mirrorlean-v1"
  stateComputerContractVersion : String := ModelInterface.stateComputerContractVersion
  deriving Repr, BEq

structure MatchedBindingContext where
  private mk ::
  semanticDigest : SemanticDigest
  effectiveConfig : ApalacheConfig

abbrev AdapterFactory := MatchedBindingContext → IO (Except BindingError LocalBinding)

structure AdapterRegistration where
  key : AdapterKey
  factory : AdapterFactory

structure CompiledAdapterSelection where
  metadata : GeneratedMetadata
  adapterId : String
  registry : Array AdapterRegistration
  targetProfile : String := "mirrorlean-v1"
  stateComputerContractVersion : String := ModelInterface.stateComputerContractVersion

/-- Pure immutable exact-key lookup. No factory runs during selection. -/
def lookupAdapter (registry : Array AdapterRegistration) (key : AdapterKey) :
    Except NegotiatedError AdapterFactory := do
  let exact := registry.filter (fun item => item.key == key)
  if exact.size > 1 then fail "adapter_ambiguous" "multiple registrations match the exact adapter key"
  if let some entry := exact[0]? then return entry.factory
  let identity := registry.filter fun item =>
    item.key.semanticDigest == key.semanticDigest && item.key.adapterId == key.adapterId
  if !identity.isEmpty && identity.all (fun item => item.key.targetProfile != key.targetProfile) then
    fail "target_profile_mismatch" "registered adapter has another target profile"
  if identity.any (fun item => item.key.targetProfile == key.targetProfile) then
    fail "state_computer_contract_mismatch" "registered adapter has another StateComputer contract"
  fail "adapter_not_registered" "no registration matches the exact adapter key"

private def optionalDigest (json : Json) (key : String) :
    Except NegotiatedError (Option SemanticDigest) := do
  match Validation.optional json key with
  | none => return none
  | some value => return some (← SemanticDigest.fromWire (← validate value.getStr?))

private def checkedExtension (json : Json) (allowed required : List String) :
    Except NegotiatedError Unit := do
  validate (Validation.object json allowed required)
  if (← validate (Validation.stringField json "schema")) != negotiationSchema then
    fail "negotiation_status_unexpected" "unsupported negotiation schema"

/-- Strict required-verify admission. This operation is pure; successful
admission is the sole path that creates a MatchedBindingContext. -/
def admitMatched (line : String) (expected : SemanticDigest) :
    Except NegotiatedError Unit := do
  let json ← validate (StrictJson.parse line)
  let step ← validate (Validation.stringField json "proto_step")
  let extension := Validation.optional json "modelInterface"
  if step == "register_error" then
    let detail ← validate (Validation.field json "error" >>= Json.getStr?)
    let some extension := extension | throw (.legacy (.registerFailed detail))
    checkedExtension extension
      ["schema", "status", "code", "expectedSemanticDigest", "actualSemanticDigest", "provenanceDigest", "descriptorBytes"]
      ["schema", "status", "code"]
    let status ← validate (Validation.stringField extension "status")
    if !["mismatch", "unsupported", "unavailable"].contains status then
      fail "negotiation_status_unexpected" "invalid status on verify registration failure"
    let code ← validate (Validation.stringField extension "code")
    if code.isEmpty then fail "negotiation_status_unexpected" "empty registration failure code"
    let pin ← optionalDigest extension "expectedSemanticDigest"
    let actual ← optionalDigest extension "actualSemanticDigest"
    let _ ← optionalDigest extension "provenanceDigest"
    if pin.any (· != expected) then
      fail "interface_digest_mismatch" "registration failure does not refer to the requested pin"
    if status == "mismatch" && pin.isNone then
      fail "negotiation_status_unexpected" "mismatch failure lacks expectedSemanticDigest"
    if (Validation.optional extension "descriptorBytes").isSome then
      fail "negotiation_status_unexpected" "verify failure cannot contain descriptorBytes"
    throw (.registration ⟨code, detail, status, pin.map (·.toWire), actual.map (·.toWire)⟩)
  else if step == "protocol_error" then
    throw (.legacy (.protocol (← validate (Validation.field json "error" >>= Json.getStr?))))
  else if step != "spec_validated" then
    fail "negotiation_status_unexpected" s!"expected registration result, received {step}"
  let result ← validate (Validation.field json "result" >>= ValidateResult.ofJson?)
  if let .invalid detail := result then throw (.legacy (.specInvalid detail))
  let some extension := extension | fail "negotiation_missing" "required model-interface reply is missing"
  checkedExtension extension
    ["schema", "status", "descriptorSchema", "semanticDigest", "provenanceDigest", "descriptorBytes", "descriptor"]
    ["schema", "status"]
  if (← validate (Validation.stringField extension "status")) != "matched" then
    fail "negotiation_status_unexpected" "required verify accepts only matched"
  if (← validate (Validation.stringField extension "descriptorSchema")) != descriptorSchema then
    fail "negotiation_status_unexpected" "unsupported descriptor schema"
  let some digest ← optionalDigest extension "semanticDigest"
    | fail "negotiation_status_unexpected" "matched lacks semanticDigest"
  if digest != expected then fail "interface_digest_mismatch" "matched digest differs from requested pin"
  let _ ← optionalDigest extension "provenanceDigest"
  if (Validation.optional extension "descriptor").isSome ||
      (Validation.optional extension "descriptorBytes").isSome then
    fail "negotiation_status_unexpected" "matched cannot carry a descriptor or descriptorBytes"

private def prepare (registration : ClientMessage) (selection : CompiledAdapterSelection) :
    Except NegotiatedError (String × SemanticDigest × AdapterFactory) := do
  match registration with
  | .register .. | .registerTraces .. => pure ()
  | _ => fail "negotiation_status_unexpected" "negotiation extends only register and register_traces"
  if selection.targetProfile != "mirrorlean-v1" then
    fail "target_profile_mismatch" "Lean runner requires mirrorlean-v1"
  if selection.stateComputerContractVersion != stateComputerContractVersion then
    fail "state_computer_contract_mismatch" "Lean runner requires mirrors.state-computer/v1"
  let digest ← SemanticDigest.fromHex selection.metadata.semanticDigest
  let contract ← validate (StrictJson.parse selection.metadata.contractJson)
  validate (Validation.contract contract)
  let key : AdapterKey := {
    semanticDigest := digest
    adapterId := selection.adapterId
    targetProfile := selection.targetProfile
    stateComputerContractVersion := selection.stateComputerContractVersion }
  let factory ← lookupAdapter selection.registry key
  let request := Json.mkObj [
    ("schema", .str negotiationSchema), ("request", .str "verify"), ("policy", .str "require"),
    ("acceptDescriptorSchemas", .arr #[.str descriptorSchema]),
    ("expectedSemanticDigest", .str digest.toWire), ("contract", Json.mkObj [("inline", contract)])]
  let fields ← validate (ClientMessage.toJson registration).getObj?
  let line := (Json.obj (fields.insert "modelInterface" request)).compress
  if line.toUTF8.size > maxProtocolLineBytes then
    fail "negotiation_status_unexpected" "registration exceeds protocol byte limit"
  return (line, digest, factory)

private def decodeReplay (line : String) : Except MirrorError MirrorMessage := do
  let json ← (StrictJson.parse line).mapError MirrorError.json
  (MirrorMessage.ofJson? json).mapError MirrorError.json

private def replay (transport : Transport) (computer : FallibleStateComputer) :
    IO (Except NegotiatedError Unit) :=
  Internal.replay transport (fun action state previous => do
    let result ← try computer action state previous
      catch error => pure (.error ⟨"adapter_failure", error.toString⟩)
    pure (result.mapError fun error => .modelInterface error.code error.message))
    NegotiatedError.legacy decodeReplay

private def withBinding (transport : Transport) (config : ApalacheConfig)
    (digest : SemanticDigest) (factory : AdapterFactory) : IO (Except NegotiatedError Unit) := do
  let created ← try factory ⟨digest, config⟩
    catch error => pure (.error ⟨"adapter_factory_failed", error.toString⟩)
  let binding ← match created with
    | .error error => return .error (.modelInterface "adapter_factory_failed" s!"{error.code}: {error.message}")
    | .ok binding => pure binding
  -- Cleanup belongs to this scope immediately after successful acquisition.
  let primary ← try
      match SemanticDigest.fromHex binding.semanticDigest with
      | .error _ => pure (.error (.modelInterface "binding_digest_mismatch" "binding digest is not canonical"))
      | .ok actual =>
          if actual != digest then pure (.error (.modelInterface "binding_digest_mismatch" "binding has another semantic digest"))
          else match binding.assertCompatibleConfig config with
            | .error error => pure (.error (.modelInterface "binding_config_mismatch" s!"{error.code}: {error.message}"))
            | .ok () => replay transport binding.computer
    catch error => pure (.error (.legacy (.io error)))
  let cleanup ← try binding.dispose
    catch error => pure (.error ⟨"adapter_dispose_failed", error.toString⟩)
  match primary, cleanup with
  | .error error, _ => return .error error
  | .ok (), .error error => return .error (.modelInterface "adapter_dispose_failed" s!"{error.code}: {error.message}")
  | .ok (), .ok () => return .ok ()

private def run (target : Target) (config : ApalacheConfig) (registration : ClientMessage)
    (selection : CompiledAdapterSelection) : IO (Except NegotiatedError Unit) := do
  let (line, digest, factory) ← match prepare registration selection with
    | .ok prepared => pure prepared
    | .error error =>
        -- A supplied transport is already acquired, but invalid local metadata
        -- must never spawn a process solely to close it again.
        if let .transport transport := target then
          try let _ ← transport.close catch _ => pure ()
        return .error error
  let transport ← try
      match target with | .binary path => spawnMirror path | .transport transport => pure transport
    catch error => return .error (.legacy (.io error))
  let primary ← try
      transport.send line
      let some first ← transport.recv | pure (.error (.legacy .transportClosed))
      match admitMatched first digest with
      | .error error => pure (.error error)
      | .ok () => withBinding transport config digest factory
    catch error => pure (.error (.legacy (.io error)))
  let closed ← try let _ ← transport.close; pure (.ok ())
    catch error => pure (.error (.legacy (.io error)))
  match primary with | .error error => return .error error | .ok () => return closed

def runClientNegotiated (target : Target) (config : ApalacheConfig)
    (traceConfig : TraceGenerationConfig) (selection : CompiledAdapterSelection)
    (spec? : Option ApalacheSpec := none) : IO (Except NegotiatedError Unit) :=
  run target config (.register config traceConfig spec?) selection

def runClientWithTracesNegotiated (target : Target) (config : ApalacheConfig)
    (tracePaths : Array System.FilePath) (selection : CompiledAdapterSelection) :
    IO (Except NegotiatedError Unit) :=
  run target config (.registerTraces config (tracePaths.map (·.toString))) selection

end MirrorLean.ModelInterface
