import MirrorLean

/-!
# MirrorLean Counter example

Port of the Counter quickstart (MirrorECMA / MirrorRust READMEs): the Lean
program is the system under test; the mirror replays apalache-generated
counterexample traces of specs/Counter.tla and checks every reported state
against the model, variable by variable.

Run (from the repository root, with apalache on PATH):

    export PATH="$HOME/.elan/bin:$PATH"
    export PATH="$HOME/.local/bin/apalache/bin:$PATH"
    export MIRROR_BIN=/path/to/ModelMirrors
    lake build counter-example && .lake/build/bin/counter-example
-/

open MirrorLean

/-- The Counter state machine: count accumulates the stride the model
chooses each step. The reported state mirrors the spec variables
(count, parameters, action_taken); the mirror diffState ignores the
meta keys, but reporting them keeps the client faithful to the trace shape. -/
def counterComputer : IO StateComputer := do
  let count ← IO.mkRef 0
  return fun action params prev => do
    if action == "init" || prev.toList.isEmpty then
      count.set 0
      pure <| State.ofList
        [ ("count", .int 0)
        , ("parameters", .record #[("stride", .int 0)])
        , ("action_taken", .str "init") ]
    else
      let stride := State.getParamInt params "parameters" "stride"
      count.modify (fun n => n + stride)
      pure <| State.ofList
        [ ("count", .int (← count.get))
        , ("parameters", .record #[("stride", .int stride)])
        , ("action_taken", .str "tick") ]

def main : IO Unit := do
  let bin ← match ← IO.getEnv "MIRROR_BIN" with
    | some p => pure p
    | none   => pure "/home/nzsn/Repos/ModelMirros/dist-newstyle/build/x86_64-linux/ghc-9.14.1/ModelMirrors-0.1.0.0/x/ModelMirrors/build/ModelMirrors/ModelMirrors"
  match ← runClient
    (.binary (System.FilePath.mk bin))
    { specPath := "specs/Counter.tla", invariant := "TraceComplete",
      lengthBound := 6, constInit := some "CInit", paramVars := some "parameters" }
    { numTraces := 10, view := some "View" }
    (← counterComputer)
  with
  | .ok ()   => IO.println "all traces replayed: implementation matches the model"
  | .error e => IO.eprintln s!"conformance failed: {MirrorError.toString e}"
                IO.Process.exit 1
