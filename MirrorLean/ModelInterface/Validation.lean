import MirrorLean.ModelInterface.StrictJson

namespace MirrorLean.ModelInterface.Validation
open Lean

def object (json : Json) (allowed required : List String) : Except String Unit := do
  let fields ← json.getObj?
  for (key, _) in fields.toList do
    if !allowed.contains key then throw s!"unknown field: {key}"
  for key in required do
    if !fields.contains key then throw s!"missing field: {key}"

def field (json : Json) (key : String) : Except String Json := json.getObjVal? key

def optional (json : Json) (key : String) : Option Json :=
  match json.getObjVal? key with
  | .ok .null | .error _ => none
  | .ok value => some value

def shortString (json : Json) : Except String String := do
  let value ← json.getStr?
  if value.toUTF8.size > 256 then throw "string exceeds 256 UTF-8 bytes"
  return value

def stringField (json : Json) (key : String) : Except String String :=
  field json key >>= shortString

def arrayField (json : Json) (key : String) (limit : Nat) : Except String (Array Json) := do
  let items ← field json key >>= Json.getArr?
  if items.size > limit then throw s!"{key} exceeds resource limit {limit}"
  return items

private def stableId (value : String) : Bool :=
  !value.isEmpty && (value.toList.head!).isUpper &&
    value.toList.all (fun c => c.toNat < 128 && c.isAlphanum)

private def idField (json : Json) : Except String String := do
  let id ← stringField json "id"
  if !stableId id then throw "invalid stable ID"
  return id

private def nonempty (value : String) : Except String Unit :=
  if value.isEmpty then .error "empty name" else .ok ()

private def moduleName (value : String) : Bool :=
  !value.isEmpty && ((value.toList.head!).isAlpha || value.startsWith "_") &&
    value.toList.all (fun c => c.toNat < 128 && (c.isAlphanum || c == '_'))

private def logicalPath (value : String) : Bool :=
  !value.isEmpty && !value.startsWith "/" && !value.contains '\\' && !value.contains ':' &&
    (value.splitOn "/").all (fun item => !item.isEmpty && item != "." && item != "..")

/-- Validate portable generated metadata types, counting every normalized node.
The static Lean profile intentionally rejects nonportable opaque/map-key types. -/
partial def modelType (json : Json) (depth nodes : Nat) : Except String Nat := do
  if depth >= 32 || nodes >= 8192 then throw "model type resource limit exceeded"
  let nodes := nodes + 1
  let kind ← stringField json "kind"
  if ["int", "bool", "str", "null"].contains kind then
    object json ["kind"] ["kind"]
    return nodes
  else if kind == "set" || kind == "seq" then
    object json ["kind", "element"] ["kind", "element"]
    modelType (← field json "element") (depth + 1) nodes
  else if kind == "tuple" then
    object json ["kind", "elements"] ["kind", "elements"]
    let mut nodes := nodes
    for item in ← arrayField json "elements" 8192 do
      nodes ← modelType item (depth + 1) nodes
    return nodes
  else if kind == "record" || kind == "variant" then
    let listKey := if kind == "record" then "fields" else "cases"
    let nameKey := if kind == "record" then "wireName" else "tag"
    let typeKey := if kind == "record" then "type" else "payload"
    object json ["kind", listKey] ["kind", listKey]
    let mut names : Array String := #[]
    let mut nodes := nodes
    for item in ← arrayField json listKey 8192 do
      object item [nameKey, typeKey] [nameKey, typeKey]
      let name ← stringField item nameKey
      nonempty name
      if names.contains name then throw "duplicate type member"
      names := names.push name
      nodes ← modelType (← field item typeKey) (depth + 1) nodes
    return nodes
  else if kind == "map" then
    object json ["kind", "key", "value"] ["kind", "key", "value"]
    let key ← field json "key"
    if (← stringField key "kind") != "str" then throw "Lean profile requires string map keys"
    let nodes ← modelType key (depth + 1) nodes
    modelType (← field json "value") (depth + 1) nodes
  else throw s!"unsupported Lean model type: {kind}"

private def optionalType (json : Json) (nodes : Nat) : Except String Nat := do
  match optional json "expectedType" with
  | none => return nodes
  | some value => modelType value 0 nodes

private def path (json : Json) (root : String) : Except String Unit := do
  object json ["root", "path"] ["root", "path"]
  if (← stringField json "root") != root then throw "input projection root does not match phase"
  for segment in ← arrayField json "path" 32 do
    let fields ← segment.getObj?
    if fields.size != 1 then throw "path segment must have one selector"
    match fields.toList with
    | [("field", value)] | [("variantValue", value)] =>
        nonempty (← shortString value)
    | [("index", value)] => let _ ← value.getNat?; pure ()
    | _ => throw "unsupported Lean path segment"

private def action (json : Json) (root : String) (nodes : Nat) :
    Except String (String × Array String × Nat) := do
  object json ["id", "wireAction", "wireAliases", "inputs"]
    ["id", "wireAction", "wireAliases", "inputs"]
  let id ← idField json
  let primary ← stringField json "wireAction"
  nonempty primary
  let mut labels := #[primary]
  for alias in ← arrayField json "wireAliases" 16 do
    let name ← shortString alias
    nonempty name
    if labels.contains name then throw "duplicate action label"
    labels := labels.push name
  let mut ids : Array String := #[]
  let mut nodes := nodes
  for input in ← arrayField json "inputs" 128 do
    object input ["id", "from", "expectedType"] ["id", "from"]
    let id ← idField input
    if ids.contains id then throw "duplicate input ID"
    ids := ids.push id
    path (← field input "from") root
    nodes ← optionalType input nodes
  return (id, labels, nodes)

def contract (json : Json) : Except String Unit := do
  let keys := ["schema", "interfaceVersion", "model", "wire", "initializers", "actions", "observations"]
  object json keys keys
  if (← stringField json "schema") != "mirrors.model-interface/v1" then throw "unsupported contract schema"
  let version ← field json "interfaceVersion" >>= Json.getStr?
  let components := version.splitOn "."
  if components.length != 3 || !components.all (fun item =>
      !item.isEmpty && item.toList.all (fun c => '0' <= c && c <= '9')) then
    throw "interfaceVersion must have three decimal components"
  let model ← field json "model"
  object model ["module", "source"] ["module", "source"]
  if !moduleName (← stringField model "module") then throw "invalid model module name"
  if !logicalPath (← field model "source" >>= Json.getStr?) then throw "invalid logical source path"
  let wire ← field json "wire"
  object wire ["actionVariable", "parameterVariable"] ["actionVariable", "parameterVariable"]
  if (← stringField wire "actionVariable") != "action_taken" then throw "unsupported action variable"
  if let some parameter := optional wire "parameterVariable" then nonempty (← shortString parameter)
  let initializers ← arrayField json "initializers" 32
  if initializers.isEmpty then throw "no initializer"
  let actions ← arrayField json "actions" 256
  let mut ids : Array String := #[]
  let mut labels : Array String := #[]
  let mut nodes := 0
  for (items, root) in [(initializers, "initialState"), (actions, "stepParameters")] do
    for item in items do
      let (id, names, count) ← action item root nodes
      if ids.contains id then throw "duplicate action ID"
      ids := ids.push id
      for name in names do
        if labels.contains name then throw "duplicate action label"
        labels := labels.push name
      nodes := count
  let mut observationIds : Array String := #[]
  let mut wireNames : Array String := #[]
  for observation in ← arrayField json "observations" 1024 do
    object observation ["id", "wireName", "provenance", "expectedType"] ["id", "wireName", "provenance"]
    let id ← idField observation
    let name ← stringField observation "wireName"
    nonempty name
    if observationIds.contains id || wireNames.contains name then throw "duplicate observation"
    observationIds := observationIds.push id
    wireNames := wireNames.push name
    if (← stringField observation "provenance") != "implementation" then
      throw "generated observations require implementation provenance"
    nodes ← optionalType observation nodes

end MirrorLean.ModelInterface.Validation
