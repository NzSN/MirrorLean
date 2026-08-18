import Std.Data.TreeMap
import Lean.Data.Json

/-!
# MirrorLean.Value

The Apalache ITF value model and its JSON (de)serialization.

This module is the M1 protocol core: it defines the Value type that mirrors
the Apalache Value (see Apalache/Types.hs in ModelMirrors) and the State
type used for variable valuations, together with the exact ITF JSON encoding
(ADR-015) that the mirror expects on the wire.

Representation note: Lean 4 does not support arbitrary nested inductive
types, so Value.record holds an Array (String × Value) rather than a State.
JSON objects always carry their keys in sorted order in Lean.Json (the
object is a sorted tree map), and State stays a sorted Std.TreeMap for
top-level valuations; helpers convert between the two representations.
-/

namespace MirrorLean

/-- The type of a TLA+ value in the ITF (Apalache trace) format.

* set keeps the array in the order it was received. We never diff states
  client-side (the mirror does), so no canonical set ordering is needed;
  structural equality is used in tests.
* map keys are Value to preserve the exact wire order of the key/value
  pairs, mirroring the TypeScript reference client.
* record holds key/value pairs in sorted key order (JSON objects in
  Lean.Json are sorted tree maps, and encoding sorts the pairs again).
-/
inductive Value where
  | int            : Int -> Value
  | bool           : Bool -> Value
  | str            : String -> Value
  | set            : Array Value -> Value
  | seq            : Array Value -> Value
  | tuple          : Array Value -> Value
  | map            : Array (Value × Value) -> Value
  | record         : Array (String × Value) -> Value
  | variant        : String -> Value -> Value
  | unserializable : String -> Value
  | null           : Value
deriving Inhabited, Repr, BEq

/-- A TLA+ state valuation: a sorted map from variable names to values.

A sorted map (rather than a hash map) gives deterministic key order in
report_state JSON and therefore deterministic, reproducible tests.
-/
abbrev State := Std.TreeMap String Value compare

namespace State

/-- Build a State from an association list (later entries overwrite earlier
ones for the same key; keys are sorted). -/
def ofList (pairs : List (String × Value)) : State := 
  Std.TreeMap.ofList pairs

/-- Turn a State into a Value record (sorted key order, since the map is
sorted). -/
def toValue (s : State) : Value := 
  .record s.toArray

end State

namespace Value

/-- Sort record pairs by key (records are kept in deterministic sorted order). -/
private def sortPairs (ps : Array (String × Value)) : List (String × Value) := 
  (State.ofList ps.toList).toList

/-- Encode a Value to its ITF JSON representation.

Rules (exactly the Haskell ToJSON Value instance in Apalache/Types.hs):

* int n -> {"#bigint": toString n}; null -> null
* set -> {"#set": [...]}; seq -> [...]; tuple -> {"#tup": [...]}
* map -> {"#map": [[enc k, enc v], ...]}
* record -> bare JSON object (keys sorted, deterministic)
* variant t v -> {"tag": t, "value": enc v}
* unserializable s -> {"#unserializable": s}
-/
partial def toJson (v : Value) : Lean.Json := 
  match v with
  | .int n        => Lean.Json.mkObj [("#bigint", toString n)]
  | .bool b       => b
  | .str s        => s
  | .set xs       => Lean.Json.mkObj [("#set", Lean.Json.arr (xs.map toJson))]
  | .seq xs       => Lean.Json.arr (xs.map toJson)
  | .tuple xs     => Lean.Json.mkObj [("#tup", Lean.Json.arr (xs.map toJson))]
  | .map ps       => Lean.Json.mkObj [("#map", Lean.Json.arr (ps.map fun (k, v) => Lean.Json.arr #[toJson k, toJson v]))]
  | .record ps    => Lean.Json.mkObj ((sortPairs ps).map fun (k, v) => (k, toJson v))
  | .variant t v  => Lean.Json.mkObj [("tag", t), ("value", toJson v)]
  | .unserializable s => Lean.Json.mkObj [("#unserializable", s)]
  | .null         => Lean.Json.null

/-- Value JSON encoding, exposed as a ToJson instance for use with
Json.opt and other generic helpers. -/
instance : Lean.ToJson Value := ⟨toJson⟩

/-- Parse a decimal integer string (optionally -prefixed) into an Int.

Lean's Int is arbitrary precision, matching the ITF #bigint semantics
exactly; the empty string is handled by the caller as null.
-/
private def bigIntOfString? (s : String) : Except String Int := 
  match s.toInt? with
  | some n => .ok n
  | none   => .error s!"Invalid bigint: {s}"

/-- Decode a JSON value into a Value, following the Haskell FromJSON
instance (with the two robustness fixes the TS client misses):

* {"#bigint": ""} decodes to null (the spec's meaning), not an error.
* decoding never throws; malformed shapes are reported via Except with a
  descriptive message.

Asymmetries (intentional, matching the reference implementations):
encoding boxes Set/Tuple/Map, but decoding an object with #set/#tup/#map
unboxes them, and a bare array always decodes to seq.
-/
partial def ofJson? (j : Lean.Json) : Except String Value := do
  match j with
  | .null => return .null
  | .bool b => return .bool b
  | .str s => return .str s
  | .num _ => return .int (← j.getInt?)
  | .arr xs => return .seq (← xs.mapM ofJson?)
  | .obj o => ofJsonObject? o
where
  /-- Decode an object-shaped JSON value following the ITF rules.

  Handles the #bigint, #tup, #set, #map, #unserializable and variant shapes,
  falling back to a record for any other object. {"#bigint": ""} decodes to
  null per the protocol spec. -/
  ofJsonObject? (o : Std.TreeMap.Raw String Lean.Json) : Except String Value := do
    if let some jv := o.get? "#bigint" then
      let s ← jv.getStr?
      if s == "" then
        return .null
      else
        return .int (← bigIntOfString? s)
    else if let some jv := o.get? "#tup" then
      let xs ← jv.getArr?
      return .tuple (← xs.mapM ofJson?)
    else if let some jv := o.get? "#set" then
      let xs ← jv.getArr?
      return .set (← xs.mapM ofJson?)
    else if let some jv := o.get? "#map" then
      let entries ← jv.getArr?
      let pairs ← entries.mapM fun entry => do
        let pair ← entry.getArr?
        match pair with
        | #[k, v] => do
            let kv ← ofJson? k
            let vv ← ofJson? v
            return (kv, vv)
        | _ => throw "Expected [key, value] pair in #map entry"
      return .map pairs
    else if let some jv := o.get? "#unserializable" then
      return .unserializable (← jv.getStr?)
    else if o.size == 2 && o.contains "tag" && o.contains "value" then
      match (o.get? "tag").get!.getStr? with
      | .ok t => return .variant t (← ofJson? (o.get? "value").get!)
      | .error _ => decodeRecord o  -- tag present but not a string: not a variant
    else
      decodeRecord o
  decodeRecord (o : Std.TreeMap.Raw String Lean.Json) : Except String Value := do
    let mut pairs : Array (String × Value) := #[]
    for (k, v) in o.toList do
      pairs := pairs.push (k, ← ofJson? v)
    return .record pairs

/-- Human-readable JSON rendering of a value, used in error messages
(ints become JSON numbers, variants keep their tag/value shape). -/
partial def prettify (v : Value) : Lean.Json := 
  match v with
  | .int n        => n
  | .bool b       => b
  | .str s        => s
  | .set xs       => Lean.Json.arr (xs.map prettify)
  | .seq xs       => Lean.Json.arr (xs.map prettify)
  | .tuple xs     => Lean.Json.arr (xs.map prettify)
  | .map ps       => Lean.Json.arr (ps.map fun (k, v) => Lean.Json.arr #[prettify k, prettify v])
  | .record ps    => Lean.Json.mkObj ((sortPairs ps).map fun (k, v) => (k, prettify v))
  | .variant t v  => Lean.Json.mkObj [("tag", t), ("value", prettify v)]
  | .unserializable s => s
  | .null         => Lean.Json.null

/-- Extract an integer value, or none. -/
def asInt? : Value -> Option Int
  | .int n => some n
  | _      => none

/-- Extract a string value, or none. -/
def asStr? : Value -> Option String
  | .str s => some s
  | _      => none

/-- Extract a record value as a State, or none.

The record pairs are converted to a sorted State (record pairs are kept in
sorted key order, so this preserves the ordering). -/
def asRecord? : Value -> Option State
  | .record ps => some (State.ofList ps.toList)
  | _          => none

end Value

/-- Encode a State to its ITF JSON object representation with sorted keys
(the map is already sorted; iteration order is deterministic). -/
def State.toJson (s : State) : Lean.Json := 
  Lean.Json.mkObj (s.toList.map fun (k, v) => (k, Value.toJson v))

instance : Lean.ToJson State := ⟨State.toJson⟩

/-- Decode an ITF JSON object into a State.

j must be a JSON object; every member value is decoded as a Value. -/
def State.ofJson? (j : Lean.Json) : Except String State := do
  let o ← j.getObj?
  let mut st : State := ∅
  for (k, v) in o.toList do
    st := st.insert k (← Value.ofJson? v)
  return st

/-- Human-readable JSON rendering of a state (for error messages). -/
def State.prettify (s : State) : Lean.Json := 
  Lean.Json.mkObj (s.toList.map fun (k, v) => (k, Value.prettify v))

/-- Look up a paramVars-style parameter record: returns the record stored
under varName as a State, or none if the key is missing or not a record. -/
def State.getParam? (s : State) (varName : String) : Option State := 
  match s.get? varName with
  | some v => Value.asRecord? v
  | none   => none

/-- Extract an integer parameter from a parameter record, defaulting to 0. -/
def State.getParamInt (s : State) (varName field : String) : Int := 
  match s.getParam? varName with
  | some rec =>
      match rec.get? field with
      | some (.int n) => n
      | _             => 0
  | none => 0

end MirrorLean
