import MirrorLean.ServerMode
import MirrorLean.Transport

/-!
# MirrorLean server-mode loopback tests (Phase 1 + Phase 4)

Runs `openssl s_server -Verify 1 -tls1_3` (the fast TLS peer — no apalache
needed) with an ephemeral PKI (`test/gen-test-certs.sh`) and drives it with
`MirrorLean.ServerMode`. Covers the plan's TLS matrix rows:

* T2-lite happy path: send a palindrome, receive it echoed back (the server
  reverses text with `-rev`), close cleanly;
* T3 wrong CA (server cert signed by an unrelated CA) -> handshake rejected;
* T4 missing client cert file -> setup error; client cert signed by an
  unrelated CA -> server rejects the handshake;
* T5 hostname mismatch -> verification fails;
* T6 TLS 1.2-only peer -> the TLS 1.3-only client fails;
* T7 fingerprint pinning: correct `cert-sha256` connects, a wrong pin is
  rejected before any traffic;
* T8 group/other-readable key file (0644) -> rejected before connect;
* T11 pinned discovery: bad pin candidate skipped, good candidate used;
* T13 EOF mid-session: server closes right after the handshake -> `recv`
  returns `none` (the same `transportClosed` semantics as plain TCP).

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

/-- Spawn the TLS echo server with cert stem `stem` ("server" or "server2"),
`protocol` ("-tls1_3" or "-tls1_2"), one connection then exit.

`verifyReturnError` mirrors the real ModelMirrors server behavior: a client
certificate that does not verify against the CA aborts the handshake
(`openssl s_server` only *logs* verification failures by default and keeps
the connection; `-verify_return_error` makes it reject, like
`tls-server-params` `requireClientCert` in ModelMirrors). -/
def spawnServerWith (port : UInt16) (stem : String) (dir : String) (protocol : String)
    (verifyReturnError : Bool := true) : IO (IO.Process.Child (IO.Process.StdioConfig.mk IO.Process.Stdio.piped IO.Process.Stdio.inherit IO.Process.Stdio.inherit)) := do
  let args : IO.Process.SpawnArgs :=
    { cmd := "openssl",
      args := #["s_server", "-rev", "-Verify", "1", protocol, "-quiet"] ++
                (if verifyReturnError then #["-verify_return_error"] else #[]) ++
                #["-accept", toString port,
                  "-cert", dir ++ "/" ++ stem ++ ".crt",
                  "-key", dir ++ "/" ++ stem ++ ".key",
                  "-CAfile", dir ++ "/ca.crt",
                  "-naccept", "1"],
      stdin := .piped, stdout := .inherit, stderr := .inherit }
  IO.Process.spawn args

/-- Spawn the TLS 1.3 echo server with the default server certificate. -/
def spawnServer (port : UInt16) (dir : String) :=
  spawnServerWith port "server" dir "-tls1_3"

/-- Spawn an s_server that closes the connection immediately after the
handshake: stdin comes from `/dev/null`, and with no input to relay the
server shuts the TLS session down (clean EOF for the client). Used by the
T13 "mirror closes mid-session" test. -/
def spawnServerEof (port : UInt16) (dir : String) : IO (IO.Process.Child (IO.Process.StdioConfig.mk IO.Process.Stdio.piped IO.Process.Stdio.inherit IO.Process.Stdio.inherit)) := do
  let args : IO.Process.SpawnArgs :=
    { cmd := "sh",
      args := #["-c",
                "openssl s_server -Verify 1 -tls1_3 -quiet " ++
                "-accept " ++ toString port ++ " " ++
                "-cert " ++ dir ++ "/server.crt " ++
                "-key " ++ dir ++ "/server.key " ++
                "-CAfile " ++ dir ++ "/ca.crt -naccept 1 < /dev/null"],
      stdin := .piped, stdout := .inherit, stderr := .inherit }
  IO.Process.spawn args

/-- Run `body` against a fresh TLS 1.3 server; always kill + reap. -/
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

/-- SHA-256 (lowercase hex) of the certificate with stem `stem`. -/
def certFingerprint (dir : String) (stem : String) : IO String := do
  let out ← IO.Process.output
    { cmd := "sh",
      args := #["-c", s!"openssl x509 -in {dir}/{stem}.crt -outform DER | openssl dgst -sha256"],
      stdin := .piped, stdout := .piped, stderr := .piped }
  match (out.stdout.splitOn "=").getLast? with
  | some hex => pure hex.trimAscii.toString
  | none => throw (IO.userError s!"cannot parse fingerprint from {repr out.stdout}")

/-! ## Phase 3: pinned discovery (connectMirrorDiscovered) -/

/-- In-process stub registry: accepts one connection and responds with `resp`. -/
def startStubRegistry (resp : String) : IO (UInt16 × Task (Except IO.Error Unit)) := do
  let server ← Std.Async.TCP.Socket.Server.mk
  server.bind (Std.Net.SocketAddress.v4 { addr := Std.Net.IPv4Addr.ofParts 127 0 0 1, port := 0 })
  server.listen 5
  let sockName ← server.getSockName
  let task ← IO.asTask do
    let client ← Std.Async.Async.block server.accept
    _ ← Std.Async.Async.block (Std.Async.TCP.Socket.Client.recv? client 4096)
    Std.Async.Async.block (Std.Async.TCP.Socket.Client.send client resp.toUTF8)
    Std.Async.Async.block (Std.Async.TCP.Socket.Client.shutdown client)
  pure (sockName.port, task)

/-- A `200 OK` JSON response with `Content-Length`. -/
def httpJson (body : String) : String :=
  "HTTP/1.1 200 OK
Content-Type: application/json
" ++
  "Content-Length: " ++ toString body.length ++ "

" ++ body

/-- Consul health entry for one candidate. -/
def consulEntry (host : String) (port : UInt16) (pin : Option String) : String :=
  let metaJson := match pin with
    | some p => "\"Meta\": {\"cert-sha256\": \"" ++ p ++ "\"}"
    | none => "\"Meta\": {}"
  "{\"Service\": {\"Address\": \"" ++ host ++ "\", \"Port\": " ++ toString port ++ ", " ++ metaJson ++ "}}"

/-- Stub registry with a wrong pin for `portA` then the correct pin for `portB`. -/
def stubRegistryBody (host : String) (portA portB : UInt16) (fpB : String) : String :=
  "[" ++ consulEntry host portA (some "0000000000000000000000000000000000000000000000000000000000000000")
  ++ "," ++ consulEntry host portB (some fpB) ++ "]"

/-- Kill and reap TLS servers (tolerant of already-exited children). -/
def cleanupServer (c : IO.Process.Child (IO.Process.StdioConfig.mk IO.Process.Stdio.piped IO.Process.Stdio.inherit IO.Process.Stdio.inherit)) : IO Unit := do
  try c.kill catch _ => pure ()
  try _ ← c.wait catch _ => pure ()
  pure ()

/-- Wait until a TCP listener is bound on 127.0.0.1:`port` (server
startup race; up to ~5 s).

Probes with a **bind** attempt, not a connect: a connect would be accepted
by `s_server -naccept 1` and consume the test's single connection. -/
def waitReady (port : UInt16) : IO Unit := do
  let mut n := 0
  let mut up := false
  while !up && n < 50 do
    let bindOk ← try
      let s ← Std.Async.TCP.Socket.Server.mk
      s.bind (Std.Net.SocketAddress.v4 { addr := Std.Net.IPv4Addr.ofParts 127 0 0 1, port := port })
      pure true
    catch _ => pure false
    if bindOk then do
      IO.sleep 100
      n := n + 1
    else
      up := true
  pure ()

/--
Gate: a stub registry listing a bad fingerprint first and a good candidate
second connects to the good candidate; empty and all-fail registries raise
clear errors.
-/
def testDiscovered (dir : String) : IO Bool := do
  let mut ok := true
  let fpB ← certFingerprint dir "server2"
  -- (a) bad pin then good pin -> connects to the good candidate.
  ok := ok && (← do
    let portA ← findFreePort
    let childA ← spawnServerWith portA "server" dir "-tls1_3"
    waitReady portA
    let portB ← findFreePort  -- after A is listening, so B differs
    let childB ← spawnServerWith portB "server2" dir "-tls1_3"
    waitReady portB
    let body := stubRegistryBody "127.0.0.1" portA portB fpB
    let (regPort, _) ← startStubRegistry (httpJson body)
    let cfg : ServerMode.TlsClientConfig :=
      { caFile := dir ++ "/ca.crt", certFile := dir ++ "/client.crt", keyFile := dir ++ "/client.key" }
    try
      let t ← ServerMode.connectMirrorDiscovered cfg s!"http://127.0.0.1:{regPort}"
      t.send "abccba"
      let line ← t.recv
      let _ ← t.close
      check "pinned discovery: bad pin skipped, good candidate connected"
        (line == some "abccba")
    catch e =>
      IO.println s!"FAIL  pinned discovery: {toString e}"
      pure false
    finally
      cleanupServer childA
      cleanupServer childB)
  -- (b) empty registry -> clear error.
  ok := ok && (← do
    let (regPort, _) ← startStubRegistry (httpJson "[]")
    let cfg : ServerMode.TlsClientConfig :=
      { caFile := dir ++ "/ca.crt", certFile := dir ++ "/client.crt", keyFile := dir ++ "/client.key" }
    try
      let _ ← ServerMode.connectMirrorDiscovered cfg s!"http://127.0.0.1:{regPort}"
      IO.println "FAIL  discovered: empty registry unexpectedly connected"
      pure false
    catch e =>
      let msg := toString e
      if msg.contains "no candidates" then do
        IO.println "PASS  discovered: empty registry raises 'no candidates'"
        pure true
      else do
        IO.println s!"FAIL  discovered: unexpected error {repr msg}"
        pure false
    finally
      pure ())
  -- (c) all candidates fail -> aggregated error.
  ok := ok && (← do
    let portA ← findFreePort
    let childA ← spawnServerWith portA "server" dir "-tls1_3"
    waitReady portA
    let body := "[" ++ consulEntry "127.0.0.1" portA (some "0000000000000000000000000000000000000000000000000000000000000000") ++ "]"
    let (regPort, _) ← startStubRegistry (httpJson body)
    let cfg : ServerMode.TlsClientConfig :=
      { caFile := dir ++ "/ca.crt", certFile := dir ++ "/client.crt", keyFile := dir ++ "/client.key" }
    try
      let _ ← ServerMode.connectMirrorDiscovered cfg s!"http://127.0.0.1:{regPort}"
      IO.println "FAIL  discovered: all-fail registry unexpectedly connected"
      pure false
    catch e =>
      let msg := toString e
      if msg.contains "all 1 candidate(s) failed" && msg.contains "fingerprint mismatch" then do
        IO.println "PASS  discovered: all candidates failing raises aggregated error"
        pure true
      else do
        IO.println s!"FAIL  discovered: unexpected error {repr msg}"
        pure false
    finally
      cleanupServer childA)
  pure ok

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
    let fp ← certFingerprint dir "server"
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

  -- 7. (T4) client cert signed by an unrelated CA: the server (started with
  -- `-Verify 1 -verify_return_error` against ca.crt) rejects the handshake.
  -- In TLS 1.3 the server's Finished arrives before it processes the
  -- client's certificate, so the client's connect may complete and the
  -- rejection surfaces on the first I/O instead — either way the session
  -- must fail before any protocol traffic flows.
  ok := ok && (← withServer dir fun port => do
    let cfg : ServerMode.TlsClientConfig :=
      { caFile := dir ++ "/ca.crt", certFile := dir ++ "/client-bad.crt", keyFile := dir ++ "/client-bad.key" }
    try
      let t ← retryConnect cfg "127.0.0.1" port 20
      t.send "hello"
      let _ ← t.recv
      let _ ← t.close
      IO.println "FAIL  invalid client cert: session unexpectedly usable after server rejection"
      pure false
    catch e =>
      let msg := toString e
      if msg.contains "TLS send" || msg.contains "TLS recv" || msg.contains "handshake" then do
        IO.println "PASS  invalid client cert: server rejected (failure on first I/O)"
        IO.println s!"      (error: {msg})"
        pure true
      else do
        IO.println s!"FAIL  invalid client cert: unexpected error {repr msg}"
        pure false)

  -- 8. (T4) missing client certificate file fails at setup, before any
  -- connection is attempted (no server needed).
  ok := ok && (← do
    let cfg : ServerMode.TlsClientConfig :=
      { caFile := dir ++ "/ca.crt", certFile := dir ++ "/does-not-exist.crt", keyFile := dir ++ "/client.key" }
    try
      let _ ← ServerMode.connectMirrorTls cfg "127.0.0.1" 1
      IO.println "FAIL  missing client cert: connect unexpectedly succeeded"
      pure false
    catch e =>
      let msg := toString e
      if msg.contains "cannot load client certificate" then do
        IO.println "PASS  missing client cert: setup error before connect"
        pure true
      else do
        IO.println s!"FAIL  missing client cert: error {repr msg}"
        pure false)

  -- 9. (T6) a TLS 1.2-only peer: the TLS 1.3-only client must fail.
  ok := ok && (← do
    let port ← findFreePort
    let child ← spawnServerWith port "server" dir "-tls1_2"
    waitReady port
    let cfg : ServerMode.TlsClientConfig :=
      { caFile := dir ++ "/ca.crt", certFile := dir ++ "/client.crt", keyFile := dir ++ "/client.key" }
    let res ← expectFailure "TLS 1.2 peer rejected (TLS 1.3-only client)" "handshake" cfg "127.0.0.1" port 20
    cleanupServer child
    pure res)

  -- 10. (T13) server closes right after the handshake: recv returns none
  -- (EOF), the same transportClosed semantics as plain TCP.
  ok := ok && (← do
    let port ← findFreePort
    let child ← spawnServerEof port dir
    waitReady port
    let cfg : ServerMode.TlsClientConfig :=
      { caFile := dir ++ "/ca.crt", certFile := dir ++ "/client.crt", keyFile := dir ++ "/client.key" }
    let mut res := true
    try
      let t ← retryConnect cfg "127.0.0.1" port 20
      let line ← t.recv
      let line2 ← t.recv
      let _ ← t.close
      if line == none && line2 == none then
        IO.println "PASS  EOF mid-session: recv returns none (transportClosed)"
      else do
        IO.println s!"FAIL  EOF mid-session: expected none, got {line} / {line2}"
        res := false
    catch e =>
      IO.println s!"FAIL  EOF mid-session: {toString e}"
      res := false
    cleanupServer child
    pure res)

  -- Phase 3: pinned discovery.
  ok := ok && (← testDiscovered dir)

  IO.println "------------------------------------------------"
  if ok then
    IO.println "SERVER-MODE TESTS: ALL PASS"
    pure 0
  else
    IO.println "SERVER-MODE TESTS: FAILURES"
    pure 1
