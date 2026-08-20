import MirrorLean.ServerMode
import MirrorLean.Transport

/-!
# MirrorLean server-mode — real Consul discovery test (T14, optional)

Gated on `CONSUL_BIN` (a Consul binary, e.g. from
<https://developer.hashicorp.com/consul/downloads>): when unset the test
prints a skip message and exits 0 — CI uses the in-process stub-registry
tests (`server-mode-test-discovery`) instead.

With `CONSUL_BIN` set, the test:

1. generates an ephemeral PKI (`test/gen-test-certs.sh`);
2. starts `consul agent -dev -bind 127.0.0.1 -client 127.0.0.1`;
3. starts an `openssl s_server` mTLS peer (certificate `server2.crt`,
   signed by the test CA);
4. registers a `modelmirrors` service with that peer's `cert-sha256`
   fingerprint via the Consul HTTP API (needs `curl`);
5. asserts `connectMirrorDiscovered` discovers the candidate, connects
   over mTLS with the registry pin, and the echo round-trips.

This is exactly the upstream flow: registry = location hint, mTLS +
`cert-sha256` pin = the trust boundary.
-/

open MirrorLean

namespace Test.ServerModeConsul

private def check (name : String) (cond : Bool) : IO Bool := do
  if cond then
    IO.println s!"  ok   - {name}"
    pure true
  else
    IO.println s!"  FAIL - {name}"
    pure false

/-- `true` when nothing is listening on 127.0.0.1:`port`. -/
private def portFree (port : UInt16) : IO Bool := do
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
private def findFreePort (start : UInt16) : IO UInt16 := do
  let mut p : UInt16 := start
  let mut free := false
  while !free && p < start + 100 do
    free ← portFree p
    if !free then p := p + 1
  if free then pure p else throw (IO.userError "no free test port found")

/-- Give the freshly spawned s_server peer a grace period (`retryDiscovered`
below absorbs any residual startup lag). Not a bind/connect probe: Lean
4.33's TCP `Server` has no `close`, so a bind-probe socket can outlive its
scope and the real server then dies with EADDRINUSE; a connect probe would
consume the test's single `-naccept 1` connection. -/
private def waitReady (port : UInt16) : IO Unit := do
  IO.sleep 500

/-- Wait until a TCP listener accepts on 127.0.0.1:`port` (HTTP probe; used
for the Consul agent, which must accept many connections). -/
private def waitHttp (port : UInt16) : IO Unit := do
  let mut n := 0
  let mut up := false
  while !up && n < 150 do
    let ok ← try
      let client ← Std.Async.TCP.Socket.Client.mk
      let addr : Std.Net.SocketAddress :=
        .v4 { addr := Std.Net.IPv4Addr.ofParts 127 0 0 1, port := port }
      Std.Async.Async.block (Std.Async.TCP.Socket.Client.connect client addr)
      Std.Async.Async.block (Std.Async.TCP.Socket.Client.shutdown client)
      pure true
    catch _ => pure false
    if ok then up := true else do
      IO.sleep 100
      n := n + 1
  pure ()

/-- Spawn the mTLS echo peer (`openssl s_server -rev -Verify 1 -tls1_3`
with the `server2` certificate, one connection then exit). -/
private def spawnPeer (port : UInt16) (dir : String) : IO (IO.Process.Child (IO.Process.StdioConfig.mk IO.Process.Stdio.piped IO.Process.Stdio.inherit IO.Process.Stdio.inherit)) := do
  let args : IO.Process.SpawnArgs :=
    { cmd := "openssl",
      args := #["s_server", "-rev", "-Verify", "1", "-tls1_3", "-quiet",
                "-accept", toString port,
                "-cert", dir ++ "/server2.crt",
                "-key", dir ++ "/server2.key",
                "-CAfile", dir ++ "/ca.crt",
                "-naccept", "1"],
      stdin := .piped, stdout := .inherit, stderr := .inherit }
  IO.Process.spawn args

/-- SHA-256 (lowercase hex) of the certificate with stem `stem`. -/
private def certFingerprint (dir : String) (stem : String) : IO String := do
  let out ← IO.Process.output
    { cmd := "sh",
      args := #["-c", s!"openssl x509 -in {dir}/{stem}.crt -outform DER | openssl dgst -sha256"],
      stdin := .piped, stdout := .piped, stderr := .piped }
  match (out.stdout.splitOn "=").getLast? with
  | some hex => pure hex.trimAscii.toString
  | none => throw (IO.userError s!"cannot parse fingerprint from {repr out.stdout}")

/-- Retry `connectMirrorDiscovered` while services/pins settle. -/
private partial def retryDiscovered (cfg : ServerMode.TlsClientConfig) (reg : String) (attempts : Nat) : IO Transport := do
  try
    ServerMode.connectMirrorDiscovered cfg reg
  catch e =>
    if attempts == 0 then throw e else do
      IO.sleep 200
      retryDiscovered cfg reg (attempts - 1)

/-- Kill and reap a child (tolerant of already-exited children). -/
private def cleanup (c : IO.Process.Child (IO.Process.StdioConfig.mk IO.Process.Stdio.piped IO.Process.Stdio.inherit IO.Process.Stdio.inherit)) : IO Unit := do
  try c.kill catch _ => pure ()
  try _ ← c.wait catch _ => pure ()
  pure ()

/-- Run the gated test. -/
def run (consulBin : String) : IO UInt32 := do
  IO.println s!"Test.ServerModeConsul: using consul {consulBin}"
  -- 1. ephemeral PKI
  let dir ← IO.FS.createTempDir
  let dirS := dir.toString
  let script ← do
    let appDir ← IO.appDir
    let root ← IO.FS.realPath (appDir / "../../../..")
    pure (root / "server-mode" / "test" / "gen-test-certs.sh")
  let gen ← IO.Process.output
    { cmd := "sh", args := #["-c", s!"{script} {dirS}"],
      stdin := .piped, stdout := .piped, stderr := .piped }
  if gen.exitCode != 0 then do
    IO.eprintln s!"consul test: cert generation failed: {gen.stderr}"
    return 1
  IO.println "  ok   - ephemeral PKI generated"

  -- 2. Consul agent (dev mode, HTTP on 127.0.0.1:8500); log via shell redirect
  let consulLog := dirS ++ "/consul.log"
  let consul ← IO.Process.spawn
    { cmd := "sh",
      args := #["-c", s!"exec {consulBin} agent -dev -bind 127.0.0.1 -client 127.0.0.1 > {consulLog} 2>&1"],
      stdin := .piped, stdout := .inherit, stderr := .inherit }
  waitHttp 8500
  IO.println "  ok   - consul agent up on 127.0.0.1:8500"

  -- 3. mTLS echo peer (server2 cert)
  let port ← findFreePort 28700
  let peer ← spawnPeer port dirS
  waitReady port

  -- 4. register the service with the peer's pin
  let fp ← certFingerprint dirS "server2"
  let regJson := "{\"ID\":\"mm-consul-test\",\"Name\":\"modelmirrors\"," ++
                 "\"Address\":\"127.0.0.1\",\"Port\":" ++ toString port ++ "," ++
                 "\"Meta\":{\"cert-sha256\":\"" ++ fp ++ "\"}}"
  let reg ← IO.Process.output
    { cmd := "curl",
      args := #["-sf", "-X", "PUT", "-d", regJson,
                "http://127.0.0.1:8500/v1/agent/service/register"],
      stdin := .piped, stdout := .piped, stderr := .piped }
  if reg.exitCode != 0 then do
    IO.eprintln s!"consul test: service registration failed: {reg.stderr}"
    cleanup peer
    try consul.kill catch _ => pure ()
    _ ← consul.wait
    return 1
  IO.println "  ok   - service registered with cert-sha256 pin"

  -- 5. discover + pinned connect
  let cfg : ServerMode.TlsClientConfig :=
    { caFile := dirS ++ "/ca.crt", certFile := dirS ++ "/client.crt", keyFile := dirS ++ "/client.key" }
  let mut ok := true
  try
    let t ← retryDiscovered cfg "http://127.0.0.1:8500" 30
    t.send "abccba"
    let line ← t.recv
    let _ ← t.close
    ok := ok && (← check "discover + pinned connect: echo round-trip over real Consul"
      (line == some "abccba"))
  catch e =>
    IO.eprintln s!"consul test: connectMirrorDiscovered failed: {toString e}"
    ok := false

  -- cleanup
  cleanup peer
  try consul.kill catch _ => pure ()
  _ ← consul.wait
  if ok then do
    IO.println "Test.ServerModeConsul: ALL PASS"
    pure 0
  else do
    IO.println "Test.ServerModeConsul: FAILURES"
    IO.println s!"--- consul log:"
    try
      let log ← IO.FS.readFile (System.FilePath.mk consulLog)
      IO.println log
    catch _ => pure ()
    pure 1

end Test.ServerModeConsul

def main : IO UInt32 := do
  match ← IO.getEnv "CONSUL_BIN" with
  | none =>
      IO.println "CONSUL_BIN not set; skipping real-Consul test"
      pure 0
  | some bin =>
      Test.ServerModeConsul.run bin
