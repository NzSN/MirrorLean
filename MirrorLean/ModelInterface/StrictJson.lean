import Lean.Data.Json.Parser

/-! Bounded duplicate-aware JSON for versioned negotiation objects. The
container parser follows Lean's Apache-2.0 Json.Parser (Gabriel Ebner and
Marc Huisinga); primitive strings retain its Unicode and escape validation. -/
namespace MirrorLean.ModelInterface.StrictJson
open Lean Std.Internal.Parsec Std.Internal.Parsec.String

private partial def numberChars (acc : String) : Parser String := do
  if ← isEof then return acc
  let c ← peek!
  if c.isDigit || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E' then
    if acc.length >= 4096 then fail "numeric token exceeds resource limit"
    skip
    numberChars (acc.push c)
  else return acc

private def number : Parser Json := do
  let token ← numberChars ""
  let parts := token.splitOn "e" |>.flatMap (·.splitOn "E")
  if parts.length > 1 then
    let exponent := parts[1]!
    let exponent := if exponent.startsWith "+" then (exponent.drop 1).copy else exponent
    let some n := exponent.toInt? | fail "invalid numeric exponent"
    if n.natAbs > 1024 then fail "numeric exponent exceeds resource limit"
  match Json.parse token with
  | .ok value => ws; return value
  | .error error => fail error

mutual
  private partial def value (depth : Nat) : Parser Json := do
    if depth > 128 then fail "JSON depth exceeds 128"
    let c ← peek!
    if c == '{' then
      skip; ws
      if (← peek!) == '}' then skip; ws; return .obj ∅
      else return .obj (← object depth ∅)
    else if c == '[' then
      skip; ws
      if (← peek!) == ']' then skip; ws; return .arr #[]
      else return .arr (← array depth #[])
    else if c == '"' then
      skip
      let text ← Lean.Json.Parser.str
      ws
      return .str text
    else if c == 't' then skipString "true"; ws; return .bool true
    else if c == 'f' then skipString "false"; ws; return .bool false
    else if c == 'n' then skipString "null"; ws; return .null
    else if c == '-' || c.isDigit then number
    else fail "expected JSON value"

  private partial def object (depth : Nat) (fields : Std.TreeMap.Raw String Json) :
      Parser (Std.TreeMap.Raw String Json) := do
    skipChar '"'
    let key ← Lean.Json.Parser.str
    if fields.contains key then fail s!"duplicate object key: {key}"
    ws; skipChar ':'; ws
    let item ← value (depth + 1)
    let fields := fields.insert key item
    let c ← any
    if c == '}' then ws; return fields
    else if c == ',' then ws; object depth fields
    else fail "expected comma or closing object brace"

  private partial def array (depth : Nat) (items : Array Json) : Parser (Array Json) := do
    let item ← value (depth + 1)
    let items := items.push item
    let c ← any
    if c == ']' then ws; return items
    else if c == ',' then ws; array depth items
    else fail "expected comma or closing array bracket"
end

def parse (text : String) : Except String Json := do
  if text.toUTF8.size > 65535 then throw "JSON exceeds protocol byte limit"
  (do ws; let result ← value 0; eof; return result : Parser Json).run text

end MirrorLean.ModelInterface.StrictJson
