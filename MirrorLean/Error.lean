import MirrorLean.Value

/-!
# MirrorLean.Error

Error types for the MirrorLean protocol layer (design §7.1/§8.1):

* `DiffHint` / `PathSeg` — the path-based state-mismatch explanation that the
  mirror sends in `step_mismatch` messages, with rendering helpers ported
  from `Engine/Types.hs` (renderDiffHint / renderDiffHints / renderPath).
* `StepMismatchReport` — the full payload carried by `MirrorError.stepMismatch`.
* `MirrorError` — the single explicit error type for all protocol failures,
  mirroring MirrorRust's Result-based design.
-/

namespace MirrorLean

/-- A segment of a path into a state tree: `.field` or `[index]`. -/
inductive PathSeg where
  | field (s : String)
  | index (i : Nat)
deriving Repr, BEq

/-- A path-based state mismatch hint, exactly as decoded from the wire.

Wire shape (from Protocol/Format/Json.hs):
  {"kind": <kind>, "path": [{"field": s} | {"index": n}],
   "expected"/"actual" per kind}
-/
inductive DiffHint where
  | valueMismatch (path : Array PathSeg) (expected actual : Value)
  | missing       (path : Array PathSeg) (expected : Value)
  | extra         (path : Array PathSeg) (actual : Value)
  | missingElem   (path : Array PathSeg) (expected : Value)
  | extraElem     (path : Array PathSeg) (actual : Value)
  | typeMismatch  (path : Array PathSeg) (expected actual : Value)
  | truncated     (path : Array PathSeg)
deriving Repr, BEq

namespace DiffHint

/-- Project the path out of a hint. -/
def path : DiffHint → Array PathSeg
  | .valueMismatch p _ _ => p
  | .missing p _         => p
  | .extra p _           => p
  | .missingElem p _     => p
  | .extraElem p _       => p
  | .typeMismatch p _ _  => p
  | .truncated p         => p

end DiffHint

/-- Render a path to its textual form, e.g. `x.rec[1]`; the empty path is
`<state>`. Port of the TS renderPath (which strips the leading dot). -/
def renderPath (path : Array PathSeg) : String := 
  match path.toList with
  | [] => "<state>"
  | first :: rest =>
      let firstText := match first with
        | .field f => f
        | .index i => "[" ++ toString i ++ "]"
      rest.foldl (fun acc seg =>
        match seg with
        | .field f => acc ++ "." ++ f
        | .index i => acc ++ "[" ++ toString i ++ "]") firstText

/-- Render a value the way the TS renderHintValue does: the prettified JSON.
-/
def renderHintValue (v : Value) : String := 
  Lean.Json.compress (Value.prettify v)

/-- Render a single diff hint, e.g.
`at x.rec[1]: expected 2, got 3`. Port of renderDiffHint. -/
def renderDiffHint (h : DiffHint) : String := 
  let pre := "at " ++ renderPath (DiffHint.path h)
  match h with
  | .valueMismatch _p e a => pre ++ ": expected " ++ renderHintValue e ++ ", got " ++ renderHintValue a
  | .missing _p e       => pre ++ ": missing " ++ renderHintValue e
  | .extra _p a         => pre ++ ": unexpected " ++ renderHintValue a
  | .missingElem _p e   => pre ++ ": missing element " ++ renderHintValue e
  | .extraElem _p a     => pre ++ ": unexpected element " ++ renderHintValue a
  | .typeMismatch _p e a => pre ++ ": expected a value of shape " ++ renderHintValue e ++ ", got " ++ renderHintValue a
  | .truncated _p       => pre ++ ": further differences truncated"

/-- Render all hints, `; `-joined; the empty list renders `states differ`. -/
def renderDiffHints (hints : Array DiffHint) : String := 
  if hints.isEmpty then "states differ"
  else "; ".intercalate (hints.toList.map renderDiffHint)

/-- Everything the TS client uses in its step-mismatch error text. -/
structure StepMismatchReport where
  action   : String
  params   : State
  expected : State
  actual   : State
  hints    : Array DiffHint
deriving Repr

/-- The single explicit error type for the whole client surface.

Entry points return `IO (Except MirrorError α)`; this inductive covers I/O,
JSON, protocol, register, spec-invalid, step-mismatch (with the full
StepMismatchReport for rendering), transport closure and preset exhaustion.
-/
inductive MirrorError where
  | io                (e : IO.Error)
  | json              (msg : String)
  | specInvalid       (detail : String)
  | registerFailed    (detail : String)
  | protocol          (detail : String)
  | unexpectedMessage (step : String)
  | stepMismatch      (m : StepMismatchReport)
  | transportClosed
  | presetExhausted

namespace MirrorError

/-- Human-readable rendering of a MirrorError.

Includes the rendered diff hints for step mismatches. Empty expected/actual
states with no hints are reported as an invariant violation (as the mirror
signals violated state invariants that way).
-/
def toString : MirrorError → String
  | .io e => s!"I/O error: {e}"
  | .json msg => s!"JSON error: {msg}"
  | .specInvalid d => s!"spec invalid: {d}"
  | .registerFailed d => s!"register failed: {d}"
  | .protocol d => s!"protocol error: {d}"
  | .unexpectedMessage step => s!"unexpected message: {step}"
  | .stepMismatch m =>
      if m.expected.isEmpty && m.actual.isEmpty && m.hints.isEmpty then
        "invariant violation reported by the mirror"
      else
        let params := Lean.Json.compress (State.prettify m.params)
        let detail := 
          if m.hints.isEmpty then
            let exp := Lean.Json.compress (State.prettify m.expected)
            let act := Lean.Json.compress (State.prettify m.actual)
            s!" expected {exp}, got {act}"
          else
            s!": {renderDiffHints m.hints}"
        s!"step mismatch on action \"{m.action}\" with parameters {params}{detail}"
  | .transportClosed => "transport closed"
  | .presetExhausted => "preset states exhausted"

end MirrorError

end MirrorLean
