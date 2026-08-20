import MirrorLean.ServerMode
import MirrorLean.Transport

/-!
# MirrorLean server-mode loopback tests (Phase 1)

Runs `openssl s_server -rev -Verify 1 -tls1_3` with an ephemeral PKI
(`test/gen-test-certs.sh`) and drives it with `MirrorLean.ServerMode`:

* happy path: send a palindrome, receive it echoed back (the server
  reverses text), close cleanly;
* peer fingerprint pinning: correct `cert-sha256` connects, a wrong pin
  is rejected before any traffic;
* wrong CA, hostname mismatch, and insecure key-file mode all fail with
  clear errors.

Requires `openssl` on PATH. `main` must stay top-level (exe root module).
-/

open MirrorLean

/-- Compare a condition, printing PASS/FAIL; returns success. -/
def check (label : String) (ok : Bool) : IO Bool := do
  if ok then IO.println s!"PASS  {label}" else IO.println s!"FAIL  {label}"
  pure ok

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
  let mut p : UInt16 := 28443
  let mut free := false
  while !free && p < 28500 do
    free ← portFree p
    if !free then p := p + 1
  if free then pure p else throw (IO.userError "no free test port found")

/-- Spawn the TLS echo server (one connection, then exit). -/
def spawnServer (port : UInt16) (dir : String) : IO (IO.Process.Child (IO.Process.StdioConfig.mk IO.Process.Stdio.piped IO.Process.Stdio.inherit IO.Process.Stdio.inherit)) := do
  let args : IO.Process.SpawnArgs :=
    { cmd := "openssl",
      args := #["s_server", "-rev", "-Verify", "1", "-tls1_3", "-quiet",
                "-accept", toString port,
                "-cert", dir ++ "/server.crt",
                "-key", dir ++ "/server.key",
                "-CAfile", dir ++ "/ca.crt",
                "-naccept", "1"],
      stdin := .piped, stdout := .inherit, stderr := .inherit }
  IO.Process.spawn args

/-- Run `body` against a fresh server; always kill + reap the server. -/
def withServer (dir : String) (body : UInt16 → IO α) : IO α := do
  let port ← findFreePort
  let child ← spawnServer port dir
  try
    body port
  finally
    try child.kill catch _ => pure ()
    _ ← child.wait

/-- Retry `connectMirrorTls` while the server is still starting up. -/
partial def retryConnect (cfg : ServerMode.TlsClientConfig) (host : String) (port : UInt16) (attempts : Nat) : IO Transport := do
  try
    ServerMode.connectMirrorTls cfg host port
  catch e =>
    if attempts == 0 then throw e else do
      IO.sleep 100
      retryConnect cfg host port (attempts - 1)

/-- Assert that a connect fails with a message containing `needle`.

Retries while the server is still starting up ("cannot connect"), then
reports the first real handshake/setup failure. -/
partial def expectFailure (label needle : String) (cfg : ServerMode.TlsClientConfig)
    (host : String) (port : UInt16) (attempts : Nat) : IO Bool := do
  try
    let t ← ServerMode.connectMirrorTls cfg host port
    let _ ← t.close
    IO.println s!"FAIL  {label}: connect unexpectedly succeeded"
    pure false
  catch e =>
    let msg := toString e
    if msg.contains "cannot connect" && attempts > 0 then do
      IO.sleep 100
      expectFailure label needle cfg host port (attempts - 1)
    else if msg.contains needle then do
      IO.println s!"PASS  {label}"
      IO.println s!"      (error: {msg})"
      pure true
    else do
      IO.println s!"FAIL  {label}: error {repr msg} does not contain {repr needle}"
      pure false

/-- SHA-256 (lowercase hex) of the server certificate. -/
def serverFingerprint (dir : String) : IO String := do
  let out ← IO.Process.output
    { cmd := "sh",
      args := #["-c", s!"openssl x509 -in {dir}/server.crt -outform DER | openssl dgst -sha256"],
      stdin := .piped, stdout := .piped, stderr := .piped }
  match (out.stdout.splitOn "=").getLast? with
  | some hex => pure hex.trimAscii.toString
  | none => throw (IO.userError s!"cannot parse fingerprint from {repr out.stdout}")

def main : IO UInt32 := do
  IO.println "MirrorLean server-mode loopback tests (Phase 1)"
  IO.println "------------------------------------------------"
  let mut ok := true

  let dir ← IO.FS.createTempDir
  let appDir ← IO.appDir
  let script := appDir / "../../../test/gen-test-certs.sh"
  let gen ← IO.Process.output
    { cmd := "sh",
      args := #["-c", s!"{script} {dir}"],
      stdin := .piped, stdout := .piped, stderr := .piped }
  if gen.exitCode != 0 then do
    IO.println s!"FAIL  cert generation: {gen.stderr}"
    return 1
  IO.println "PASS  ephemeral PKI generated"
  let dir := dir.toString

  -- 1. happy path: send a palindrome, receive it echoed back (reversed).
  ok := ok && (← withServer dir fun port => do
    let cfg : ServerMode.TlsClientConfig :=
      { caFile := dir ++ "/ca.crt", certFile := dir ++ "/client.crt", keyFile := dir ++ "/client.key" }
    let t ← retryConnect cfg "127.0.0.1" port 20
    t.send "racecar"
    let line ← t.recv
    let echoOk := line == some "racecar"
    let _ ← t.close
    check "happy path: palindrome echoed over TLS 1.3 mTLS" echoOk)

  -- 2. correct fingerprint pin connects.
  ok := ok && (← withServer dir fun port => do
    let fp ← serverFingerprint dir
    let cfg : ServerMode.TlsClientConfig :=
      { caFile := dir ++ "/ca.crt", certFile := dir ++ "/client.crt", keyFile := dir ++ "/client.key",
        expectedCertSha256 := some fp }
    let t ← retryConnect cfg "127.0.0.1" port 20
    t.send "abccba"
    let line ← t.recv
    let echoOk := line == some "abccba"
    let _ ← t.close
    check "fingerprint pin: correct cert-sha256 connects" echoOk)

  -- 3. wrong fingerprint pin is rejected before any traffic.
  ok := ok && (← withServer dir fun port => do
    let cfg : ServerMode.TlsClientConfig :=
      { caFile := dir ++ "/ca.crt", certFile := dir ++ "/client.crt", keyFile := dir ++ "/client.key",
        expectedCertSha256 := some "0000000000000000000000000000000000000000000000000000000000000000" }
    expectFailure "fingerprint pin: mismatch rejected" "fingerprint mismatch" cfg "127.0.0.1" port 20)

  -- 4. wrong CA (client cert used as trust anchor) fails the handshake.
  ok := ok && (← withServer dir fun port => do
    let cfg : ServerMode.TlsClientConfig :=
      { caFile := dir ++ "/ca2.crt", certFile := dir ++ "/client.crt", keyFile := dir ++ "/client.key" }
    expectFailure "wrong CA: handshake rejected" "verification failed" cfg "127.0.0.1" port 20)

  -- 5. hostname mismatch fails verification.
  ok := ok && (← withServer dir fun port => do
    let cfg : ServerMode.TlsClientConfig :=
      { caFile := dir ++ "/ca.crt", certFile := dir ++ "/client.crt", keyFile := dir ++ "/client.key",
        serverName := some "wrong.example" }
    expectFailure "hostname mismatch: rejected" "mismatch" cfg "127.0.0.1" port 20)

  -- 6. group/other-readable key file is rejected before connecting.
  ok := ok && (← do
    let looseKey := dir ++ "/loose.key"
    let cp ← IO.Process.output
      { cmd := "sh", args := #["-c", s!"cp {dir}/client.key {looseKey} && chmod 644 {looseKey}"],
        stdin := .piped, stdout := .piped, stderr := .piped }
    if cp.exitCode != 0 then
      IO.println s!"FAIL  key-permission setup: {cp.stderr}"
      pure false
    else
      let cfg : ServerMode.TlsClientConfig :=
        { caFile := dir ++ "/ca.crt", certFile := dir ++ "/client.crt", keyFile := looseKey }
      -- no server needed: the permission check happens before any connect
      try
        let _ ← ServerMode.connectMirrorTls cfg "127.0.0.1" 1
        IO.println "FAIL  key permission: connect unexpectedly succeeded"
        pure false
      catch e =>
        let msg := toString e
        if msg.contains "must not be readable" then do
          IO.println "PASS  key permission: group/other-readable key rejected"
          pure true
        else do
          IO.println s!"FAIL  key permission: error {repr msg}"
          pure false)

  IO.println "------------------------------------------------"
  if ok then
    IO.println "SERVER-MODE TESTS: ALL PASS"
    pure 0
  else
    IO.println "SERVER-MODE TESTS: FAILURES"
    pure 1
