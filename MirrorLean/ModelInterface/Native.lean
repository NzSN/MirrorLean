import MirrorLean.Client

/-! Checked native values shared by statically generated Lean interfaces.
The ordinary protocol Value equality/codec remains unchanged. -/
namespace MirrorLean.ModelInterface

structure BindingError where
  code : String
  message : String
  deriving Repr, BEq

def shape : BindingError :=
  ⟨"input_shape_mismatch", "value does not match the declared type"⟩

def observationError (error : BindingError) : BindingError :=
  { error with code := "observation_shape_mismatch" }

/-- Recursive model equality, including unordered sets and maps. Checked
codecs establish uniqueness before using this relation for native values. -/
partial def equivalent : Value → Value → Bool
  | .set xs, .set ys => xs.size == ys.size && xs.all (fun x => ys.any (equivalent x))
  | .seq xs, .seq ys | .tuple xs, .tuple ys =>
      xs.size == ys.size && (xs.zip ys).all (fun (x, y) => equivalent x y)
  | .map xs, .map ys => xs.size == ys.size && xs.all (fun (k, v) =>
      ys.any fun (l, w) => equivalent k l && equivalent v w)
  | .record xs, .record ys => xs.size == ys.size && xs.all (fun (k, v) =>
      ys.any fun (l, w) => k == l && equivalent v w)
  | .variant tag x, .variant other y => tag == other && equivalent x y
  | x, y => x == y

private def unique (items : Array Value) : Bool := Id.run do
  for i in [:items.size] do
    for j in [:i] do
      if equivalent items[i]! items[j]! then return false
  return true

def checkRecord (items : Array (String × Value)) (keys : List String) :
    Except BindingError Unit := do
  if items.size != keys.length || keys.eraseDups.length != keys.length then throw shape
  for key in keys do
    if (items.filter (fun entry => entry.1 == key)).size != 1 then throw shape

class NativeCodec (α : Type) where
  decode : Value → Except BindingError α
  encode : α → Except BindingError Value

instance : NativeCodec Int where
  decode | .int value => .ok value | _ => .error shape
  encode value := .ok (.int value)
instance : NativeCodec Bool where
  decode | .bool value => .ok value | _ => .error shape
  encode value := .ok (.bool value)
instance : NativeCodec String where
  decode | .str value => .ok value | _ => .error shape
  encode value := .ok (.str value)

structure MirrorNull where
  deriving Repr, BEq, Inhabited
structure MirrorSeq (α : Type) where
  items : Array α
  deriving Repr, BEq, Inhabited
structure MirrorSet (α : Type) where
  items : Array α
  deriving Repr, BEq, Inhabited
structure MirrorMap (α : Type) where
  entries : Array (String × α)
  deriving Repr, BEq, Inhabited

instance : NativeCodec MirrorNull where
  decode | .null => .ok {} | _ => .error shape
  encode _ := .ok .null
instance [NativeCodec α] : NativeCodec (MirrorSeq α) where
  decode
    | .seq items => return ⟨← items.mapM NativeCodec.decode⟩
    | _ => .error shape
  encode value := do
    let items ← (value.items.mapM NativeCodec.encode).mapError observationError
    return .seq items
instance [NativeCodec α] : NativeCodec (MirrorSet α) where
  decode
    | .set items => do
        let decoded ← items.mapM NativeCodec.decode
        if !unique items then throw shape
        return ⟨decoded⟩
    | _ => .error shape
  encode value := do
    let items ← (value.items.mapM NativeCodec.encode).mapError observationError
    if !unique items then throw (observationError shape)
    return .set items
instance [NativeCodec α] : NativeCodec (MirrorMap α) where
  decode
    | .map items => do
        let mut names : Array String := #[]
        let mut entries := #[]
        for (key, value) in items do
          let name ← NativeCodec.decode (α := String) key
          if names.contains name then throw shape
          names := names.push name
          entries := entries.push (name, ← NativeCodec.decode value)
        return ⟨entries⟩
    | _ => .error shape
  encode value := do
    let mut names : Array String := #[]
    let mut entries := #[]
    for (name, value) in value.entries do
      if names.contains name then throw (observationError shape)
      names := names.push name
      entries := entries.push (.str name, ← (NativeCodec.encode value).mapError observationError)
    return .map entries

inductive PathSegment where
  | field (name : String)
  | index (index : Nat)
  | variantValue (tag : String)
  deriving Repr, BEq

private def pathStep (value : Value) (segment : PathSegment) : Except BindingError Value :=
  match segment, value with
  | .field name, .record fields => do
      let entries := fields.filter (fun pair => pair.1 == name)
      if entries.size != 1 then throw shape
      return entries[0]!.2
  | .index index, .seq items | .index index, .tuple items =>
      match items[index]? with | some item => .ok item | none => .error shape
  | .variantValue expected, .variant tag payload =>
      if expected == tag then .ok payload else .error shape
  | _, _ => .error shape

def readPath (root : Value) (path : List PathSegment) : Except BindingError Value :=
  path.foldlM pathStep root

abbrev FallibleStateComputer := String → State → State → IO (Except BindingError State)

structure GeneratedMetadata where
  semanticDigest : String
  contractJson : String
  deriving Repr

structure LocalBinding where
  semanticDigest : String
  computer : FallibleStateComputer
  assertCompatibleConfig : ApalacheConfig → Except BindingError Unit
  coverage : IO (Array (String × Nat)) := pure #[]
  dispose : IO (Except BindingError Unit) := pure (.ok ())

end MirrorLean.ModelInterface
