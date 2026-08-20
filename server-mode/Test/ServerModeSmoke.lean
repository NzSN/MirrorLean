import MirrorLean
import MirrorLean.ServerMode

/-!
# MirrorLean server-mode E2E smoke (gated on MIRROR_BIN)

The real end-to-end over mTLS: starts an actual
`ModelMirrors --server <port> --tls --cert … --key … --ca …` (T15/T2 of
`plans/server-mode.md`), generates an ephemeral PKI with
`test/gen-test-certs.sh`, connects with `ServerMode.connectMirrorTls`, and
runs the same five flows as the baseline `test/Smoke.lean` — (a) trace
replay, (b) generate+replay, (c) validate, (d) register_explore,
(e) explore-session walk — every JSON-lines session over the mTLS channel.

Gating (same as `test/Smoke.lean`):

* `MIRROR_BIN` unset -> prints a skip message and exits 0.
* `MIRROR_BIN` set -> must point at a ModelMirrors binary built with
  server mode (`--server --tls`); `apalache-mc` must be on PATH (the mirror
  runs it per session), and `openssl` must be on PATH (cert generation).

Paths are computed from the executable location (`IO.appDir` ->
`../../../../` is the repo root: `server-mode/.lake/build/bin`), so the
smoke works from any working directory. Spec paths handed to the mirror are
absolute (the mirror's apalache run dir is per-session), and the mirror
process is spawned with the repo root as its working directory.
-/

open MirrorLean

/-- The repo root (canonical): `server-mode/.lake/build/bin` -> four
levels up, then symlinks resolved. -/
def repoRoot : IO System.FilePath := do
  let appDir ← IO.appDir
  IO.FS.realPath (appDir / "../../../..")

/-- Parse one ITF trace file into its sequence of variable valuations. -/
def parseItfStates (content : String) : Except String (Array State) := do
  let j ← Lean.Json.parse content
  let o ← j.getObj?
  let varsArr ← match o.get? "vars" with
    | some v => v.getArr?
    | none   => throw "trace has no vars array"
  let vars ← varsArr.mapM (fun v => v.getStr?)
  let statesArr ← match o.get? "states" with
    | some v => v.getArr?
    | none   => throw "trace has no states array"
  statesArr.mapM fun sj => do
    let so ← sj.getObj?
    let mut st : State := ∅
    for v in vars do
      match so.get? v with
      | some jv => st := st.insert v (← Value.ofJson? jv)
      | none    => throw s!"trace state is missing variable {v}"
    return st

/-- The Counter machine (same as `examples/Counter.lean`, kept local so the
smoke binary is self-contained). -/
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

/-- Counter config for the replay/generate/validate flows (canonical spec
with `CInit`). -/
def counterCfg (root : System.FilePath) : ApalacheConfig :=
  { specPath := (root / "specs" / "Counter.tla").toString,
    invariant := "TraceComplete", lengthBound := 6,
    constInit := some "CInit", paramVars := some "parameters" }

/-- `true` when nothing is listening on 127.0.0.1:`port`. -/
def portFree (port : UInt16) : IO Bool := do
  try
    let client ← Std.Async.TCP.Socket.Client.mk
    let addr : Std.Net.SocketAddress :=
      .v4 { addr := Std.Net.IPv4Addr.ofParts 127 0 0 1, port := port }
    Std.Async.Async.block (Std.Async.TCP.Socket.Client.connect client addr)
    Std.Async.Async.block (Std.Async.TCP.Socket.Client.shutdown client)
    pure false
  catch _ =>
    pure true

/-- Pick a free TCP port by probing a small range. -/
def findFreePort : IO UInt16 := do
  let mut p : UInt16 := 28543
  let mut free := false
  while !free && p < 28600 do
    free ← portFree p
    if !free then p := p + 1
  if free then pure p else throw (IO.userError "no free test port found")

/-- Give the freshly spawned mirror a grace period before the first flow
connects (`retryConnect` below absorbs any residual startup lag).

Not a bind/connect probe: Lean 4.33's `Std.Async.TCP.Socket.Server` has no
`close`, so a bind-probe socket can outlive its scope and the real server
then dies with EADDRINUSE; a connect probe would open a real session. -/
def waitReady (port : UInt16) : IO Unit := do
  IO.sleep 800

/-- Start the mTLS mirror server, redirecting its stdout/stderr into
`logFile` / `logFile.err` (via `sh -c exec ...`), so the smoke's own output
stays clean and the logs are available on failure. Note: `dir`/`logFile`
are test temp paths without spaces. -/
def spawnMirror (bin : String) (port : UInt16) (dir : String) (logFile : String) (cwd : System.FilePath)
    : IO (IO.Process.Child (IO.Process.StdioConfig.mk IO.Process.Stdio.piped IO.Process.Stdio.inherit IO.Process.Stdio.inherit)) := do
  let cmdLine := String.intercalate " " [
      bin, "--server", toString port, "--tls",
      "--cert", dir ++ "/server.crt",
      "--key", dir ++ "/server.key",
      "--ca", dir ++ "/ca.crt",
      "--jobs", "2"]
  let args : IO.Process.SpawnArgs :=
    { cmd := "sh",
      args := #["-c", s!"exec {cmdLine} > {logFile} 2> {logFile}.err"],
      cwd := some cwd,
      stdin := .piped, stdout := .inherit, stderr := .inherit }
  IO.Process.spawn args

/-- Retry `connectMirrorTls` while the server is still starting up. -/
partial def retryConnect (cfg : ServerMode.TlsClientConfig) (host : String) (port : UInt16) (attempts : Nat) : IO Transport := do
  try
    ServerMode.connectMirrorTls cfg host port
  catch e =>
    if attempts == 0 then throw e else do
      IO.sleep 100
      retryConnect cfg host port (attempts - 1)

/--
Run `flow` over fresh mTLS connections. The flow receives a `fresh` thunk
that returns a NEW `Transport` each time it is called — every `runClient*`
call must use its own connection, because those helpers close the transport
when the session ends (`withClose`). Sharing one transport across two
sessions (as a naive validate-then-fail case would) closes the TLS handle
twice and corrupts the heap.
-/
def withTls (cfg : ServerMode.TlsClientConfig) (port : UInt16)
    (flow : (IO Transport) → IO (Except MirrorError Unit)) : IO (Except MirrorError Unit) := do
  try
    flow (retryConnect cfg "127.0.0.1" port 100)
  catch e =>
    pure (.error (.tls (toString e)))

/-- (a) replay the checked-in violation trace through the mirror. -/
def replayTrace (fresh : IO Transport) (root : System.FilePath) : IO (Except MirrorError Unit) := do
  let traceFile := root / "specs" / "traces" / "violation.itf.json"
  let traceText ← IO.FS.readFile traceFile
  match parseItfStates traceText with
  | .error e => pure (.error (.json e))
  | .ok states => do
      let compute ← presetClient states
      let tr ← fresh
      runClientWithTraces (.transport tr) (counterCfg root) #[traceFile] compute

/-- (b) generate fresh counterexample traces and replay them. -/
def generateAndReplay (fresh : IO Transport) (root : System.FilePath) : IO (Except MirrorError Unit) := do
  let tr ← fresh
  runClient (.transport tr) (counterCfg root) { numTraces := 10, view := some "View" } (← counterComputer)

/-- (c) validate-only sessions (TWO sessions, one fresh connection each): a
valid config reports ok; an invariant that does not exist in the spec is an
apalache config error -> register_error -> registerFailed. -/
def validateCases (fresh : IO Transport) (root : System.FilePath) : IO (Except MirrorError Unit) := do
  let tr1 ← fresh
  match ← runClientValidate (.transport tr1) (counterCfg root) 3 with
  | .error e => pure (.error e)
  | .ok () =>
      let badCfg : ApalacheConfig := { counterCfg root with invariant := "NoSuchInvariant" }
      let tr2 ← fresh
      match ← runClientValidate (.transport tr2) badCfg 3 with
      | .ok ()        => pure (.error (.unexpectedMessage "validate expected registerFailed"))
      | .error (.registerFailed _) => pure (.ok ())
      | .error e      => pure (.error e)

/-- (d) mirror-driven explore: register_explore against CounterExplore.tla
(the constant-free twin of Counter.tla). -/
def exploreMode (fresh : IO Transport) (root : System.FilePath) : IO (Except MirrorError Unit) := do
  match ← specFromFile (root / "specs" / "CounterExplore.tla") with
  | .error e   => pure (.error (.specInvalid (e.msg)))
  | .ok spec =>
      let tr ← fresh
      runClientExplore (.transport tr) spec #["TraceComplete"] #[] 3 (← counterComputer)

/-- (e) client-driven explore session: a scripted walk over CounterExplore.tla. -/
def exploreSessionWalk (fresh : IO Transport) (root : System.FilePath) : IO (Except MirrorError Unit) := do
  match ← specFromFile (root / "specs" / "CounterExplore.tla") with
  | .error e => pure (.error (.specInvalid (e.msg)))
  | .ok spec =>
      let tr ← fresh
      match ← startExploreSession (.transport tr) spec #["TraceComplete"] #[] with
      | .error e => pure (.error e)
      | .ok s =>
          if s.ready.initTransitions != 1 then
            pure (.error (.unexpectedMessage s!"initTransitions {s.ready.initTransitions}"))
          else if s.ready.stateInvariants != 1 then
            pure (.error (.unexpectedMessage s!"stateInvariants {s.ready.stateInvariants}"))
          else if s.ready.nextTransitions == 0 then
            pure (.error (.unexpectedMessage "no next transitions"))
          else do
            match ← ExploreSession.assumeTransition s 0 with
            | .error e => pure (.error e)
            | .ok .enabled =>
                match ← ExploreSession.nextStep s with
                | .error e => pure (.error e)
                | .ok 1 =>
                    match ← ExploreSession.queryState s with
                    | .error e => pure (.error e)
                    | .ok st =>
                        if st.toList.isEmpty then
                          pure (.error (.unexpectedMessage "queryState empty"))
                        else
                          match ← ExploreSession.checkInvariant s 0 with
                          | .error e => pure (.error e)
                          | .ok .satisfied =>
                              match ← ExploreSession.rollback s 0 with
                              | .error e => pure (.error e)
                              | .ok 0 => ExploreSession.done s
                              | .ok n  => pure (.error (.unexpectedMessage s!"rollback -> {n}"))
                          | .ok _ => pure (.error (.unexpectedMessage "checkInvariant not satisfied"))
                | .ok n => pure (.error (.unexpectedMessage s!"nextStep -> {n}"))
            | .ok _ => pure (.error (.unexpectedMessage "assumeTransition not enabled"))

/-- Run flow `name` over fresh mTLS connections; prints PASS/FAIL. -/
def runFlow (name : String) (cfg : ServerMode.TlsClientConfig) (port : UInt16)
    (flow : (IO Transport) → IO (Except MirrorError Unit)) : IO Bool := do
  match ← withTls cfg port flow with
  | .ok () => do IO.println s!"server-mode smoke {name}: PASS"; pure true
  | .error e => do
      IO.eprintln s!"server-mode smoke {name} FAILED: {MirrorError.toString e}"
      pure false

def main : IO UInt32 := do
  let some bin ← IO.getEnv "MIRROR_BIN" | do
    IO.println "MIRROR_BIN not set; skipping server-mode smoke"
    return 0
  IO.println s!"server-mode smoke: using mirror {bin}"
  let root ← repoRoot
  let dir ← IO.FS.createTempDir
  let dirS := dir.toString
  let script := root / "server-mode" / "test" / "gen-test-certs.sh"
  let gen ← IO.Process.output
    { cmd := "sh", args := #["-c", s!"{script} {dirS}"],
      stdin := .piped, stdout := .piped, stderr := .piped }
  if gen.exitCode != 0 then do
    IO.eprintln s!"server-mode smoke: cert generation failed: {gen.stderr}"
    return 1
  IO.println "server-mode smoke: ephemeral PKI generated"

  let port ← findFreePort
  let logFile := dirS ++ "/mirror.log"
  let child ← spawnMirror bin port dirS logFile root
  waitReady port
  let cfg : ServerMode.TlsClientConfig :=
    { caFile := dirS ++ "/ca.crt", certFile := dirS ++ "/client.crt", keyFile := dirS ++ "/client.key" }
  let mut ok := true
  ok := ok && (← runFlow "a) trace replay" cfg port (fun fresh => replayTrace fresh root))
  ok := ok && (← runFlow "b) generate+replay" cfg port (fun fresh => generateAndReplay fresh root))
  ok := ok && (← runFlow "c) validate" cfg port (fun fresh => validateCases fresh root))
  ok := ok && (← runFlow "d) register_explore" cfg port (fun fresh => exploreMode fresh root))
  ok := ok && (← runFlow "e) explore-session walk" cfg port (fun fresh => exploreSessionWalk fresh root))
  try child.kill catch _ => pure ()
  _ ← child.wait
  if ok then
    IO.println "server-mode smoke: all checks passed (flows (a)-(e) over mTLS)"
    pure 0
  else do
    IO.println "server-mode smoke: FAILURES"
    for logPath in [logFile, logFile ++ ".err"] do
      IO.println s!"--- mirror log ({logPath}):"
      try
        let log ← IO.FS.readFile (System.FilePath.mk logPath)
        IO.println log
      catch _ => pure ()
    pure 1
