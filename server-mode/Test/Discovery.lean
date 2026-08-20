import Std.Async.TCP
import MirrorLean.ServerMode.Discovery

/-!
# MirrorLean server-mode — registry discovery tests (Phase 2)

In-process stub Consul servers (raw `Std.Async.TCP` on an ephemeral
127.0.0.1 port, same pattern as the root `test/Main.lean` TCP loopback test)
exercise `discoverMirrors` against:

* a valid health response (candidates + `cert-sha256` extraction + the exact
  request line, Host header and Accept header);
* malformed JSON, non-array JSON, an empty array, a non-200 status, a
  garbage (non-HTTP) response, and a connection closed without a response —
  all must fail closed to `#[]`;
* a connection refused (no listener) and a silent (accept-but-never-reply)
  stub — both must throw a distinct "registry unavailable" IO error;
* chunked and read-to-EOF body framing;
* the `parseRegistryUrl` parser (valid forms, defaults, and rejections).
-/

open MirrorLean.ServerMode

namespace Test.Discovery

-- --------------------------------------------------------------------------
-- Tiny test framework (same shape as the root test/Main.lean helpers).
-- --------------------------------------------------------------------------

private def check (name : String) (cond : Bool) : IO Bool := do
  if cond then
    IO.println s!"  ok   - {name}"
    pure true
  else
    IO.println s!"  FAIL - {name}"
    pure false

private def checkEq (name : String) (got expected : String) : IO Bool := do
  if got == expected then
    IO.println s!"  ok   - {name}"
    pure true
  else
    IO.println s!"  FAIL - {name}"
    IO.println s!"         got:      {got}"
    IO.println s!"         expected: {expected}"
    pure false

-- --------------------------------------------------------------------------
-- Stub registry server
-- --------------------------------------------------------------------------

/--
Start an in-process stub registry on an ephemeral 127.0.0.1 port: accepts
one connection and hands the accepted socket to `respond`. Returns the port
and the accept/respond task.
-/
private def startStub (respond : Std.Async.TCP.Socket.Client → IO Unit)
    : IO (UInt16 × Task (Except IO.Error Unit)) := do
  let server ← Std.Async.TCP.Socket.Server.mk
  server.bind (Std.Net.SocketAddress.v4 { addr := Std.Net.IPv4Addr.ofParts 127 0 0 1, port := 0 })
  server.listen 5
  let sockName ← server.getSockName
  -- Accept inside the serve task itself. (An `IO.asTask` body whose FIRST
  -- action is `Task.get` on a still-pending task hard-blocks the spawning
  -- thread in the Lean runtime; starting with the accept's `Async.block`
  -- yields properly, as the root test/Main.lean loopback pattern shows.)
  let serveTask ← IO.asTask do
    let client ← Std.Async.Async.block server.accept
    respond client
  pure (sockName.port, serveTask)

/-- Read the client's request (best effort; one recv suffices for the small
requests the tests generate). -/
private def readRequest (client : Std.Async.TCP.Socket.Client) : IO String := do
  let bs ← Std.Async.Async.block (Std.Async.TCP.Socket.Client.recv? client 4096)
  pure ((String.fromUTF8? (bs.getD ByteArray.empty)).getD "")

/-- Close the write side so the client sees EOF. -/
private def closeWrite (client : Std.Async.TCP.Socket.Client) : IO Unit :=
  Std.Async.Async.block (Std.Async.TCP.Socket.Client.shutdown client)

/-- A `200 OK` response with a `Content-Length`-framed JSON body. -/
private def http200 (body : String) : String :=
  "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" ++
  "Content-Length: " ++ toString body.length ++ "\r\n\r\n" ++ body

private def hexDigitChar (n : Nat) : Char :=
  if n < 10 then Char.ofNat ('0'.toNat + n) else Char.ofNat ('a'.toNat + (n - 10))

private partial def hexOfAux (m : Nat) : String :=
  if m == 0 then ""
  else hexOfAux (m / 16) ++ String.singleton (hexDigitChar (m % 16))

private def hexOf (n : Nat) : String :=
  let s := hexOfAux n
  if s.isEmpty then "0" else s

/-- A chunked-encoded response body (one chunk per string in `chunks`). -/
private def chunked (chunks : List String) : String :=
  let enc := chunks.map (fun c => hexOf c.length ++ "\r\n" ++ c ++ "\r\n")
  enc.foldl (· ++ ·) "" ++ "0\r\n\r\n"

-- --------------------------------------------------------------------------
-- parseRegistryUrl unit tests
-- --------------------------------------------------------------------------

def testParseUrl : IO Bool := do
  let a ← check "parse: bare host" (match parseRegistryUrl "http://consul" with
    | .ok u => u.host == "consul" && u.port == 8500 && u.pathPrefix == ""
    | .error _ => false)
  let b ← check "parse: host:port" (match parseRegistryUrl "http://consul:8501" with
    | .ok u => u.host == "consul" && u.port == 8501 && u.pathPrefix == ""
    | .error _ => false)
  let c ← check "parse: prefix" (match parseRegistryUrl "http://consul:8500/v1" with
    | .ok u => u.host == "consul" && u.port == 8500 && u.pathPrefix == "/v1"
    | .error _ => false)
  let d ← check "parse: prefix trailing slash" (match parseRegistryUrl "http://consul:8500/v1/" with
    | .ok u => u.pathPrefix == "/v1"
    | .error _ => false)
  let e ← check "parse: root slash" (match parseRegistryUrl "http://consul/" with
    | .ok u => u.pathPrefix == ""
    | .error _ => false)
  let f ← check "parse: deep prefix" (match parseRegistryUrl "http://c:1/a/b/" with
    | .ok u => u.pathPrefix == "/a/b"
    | .error _ => false)
  let g ← check "parse: rejects https" (match parseRegistryUrl "https://consul" with
    | .error _ => true
    | .ok _ => false)
  let h ← check "parse: rejects missing scheme" (match parseRegistryUrl "consul:8500" with
    | .error _ => true
    | .ok _ => false)
  let i ← check "parse: rejects empty host" (match parseRegistryUrl "http://" with
    | .error _ => true
    | .ok _ => false)
  let j ← check "parse: rejects empty port" (match parseRegistryUrl "http://c:" with
    | .error _ => true
    | .ok _ => false)
  let k ← check "parse: rejects non-numeric port" (match parseRegistryUrl "http://c:abc" with
    | .error _ => true
    | .ok _ => false)
  let l ← check "parse: rejects zero port" (match parseRegistryUrl "http://c:0" with
    | .error _ => true
    | .ok _ => false)
  let m ← check "parse: rejects out-of-range port" (match parseRegistryUrl "http://c:65536" with
    | .error _ => true
    | .ok _ => false)
  let n ← check "parse: rejects ipv6 literal" (match parseRegistryUrl "http://[::1]:8500" with
    | .error _ => true
    | .ok _ => false)
  pure (a && b && c && d && e && f && g && h && i && j && k && l && m && n)

-- --------------------------------------------------------------------------
-- discoverMirrors: response-content tests (all stub-served)
-- --------------------------------------------------------------------------

/-- A realistic Consul health response: three usable candidates (one with a
`cert-sha256`, one without, one with a non-string `cert-sha256`), plus
entries that must be skipped (empty Address, Port 0, Port > 65535, no
`Service` object, and a non-object array element). -/
private def validBody : String :=
  "[" ++
    "{\"Node\":{\"Node\":\"n1\"}," ++
      "\"Service\":{\"ID\":\"mm-1\",\"Service\":\"modelmirrors\",\"Address\":\"127.0.0.1\"," ++
      "\"Port\":8443,\"Meta\":{\"cert-sha256\":\"aa11bb22\"}}}," ++
    "{\"Node\":{\"Node\":\"n2\"}," ++
      "\"Service\":{\"ID\":\"mm-2\",\"Service\":\"modelmirrors\",\"Address\":\"10.0.0.2\"," ++
      "\"Port\":9443}}," ++
    "{\"Node\":{\"Node\":\"n3\"}," ++
      "\"Service\":{\"ID\":\"mm-3\",\"Service\":\"modelmirrors\",\"Address\":\"10.0.0.3\"," ++
      "\"Port\":10443,\"Meta\":{\"cert-sha256\":123}}}," ++
    "{\"Node\":{\"Node\":\"n4\"}," ++
      "\"Service\":{\"ID\":\"mm-4\",\"Service\":\"modelmirrors\",\"Address\":\"\",\"Port\":8443}}," ++
    "{\"Node\":{\"Node\":\"n5\"}," ++
      "\"Service\":{\"ID\":\"mm-5\",\"Service\":\"modelmirrors\",\"Address\":\"10.0.0.5\",\"Port\":0}}," ++
    "{\"Node\":{\"Node\":\"n6\"}," ++
      "\"Service\":{\"ID\":\"mm-6\",\"Service\":\"modelmirrors\",\"Address\":\"10.0.0.6\",\"Port\":99999}}," ++
    "{\"Node\":{\"Node\":\"n7\"}}," ++
    "\"not-an-object\"" ++
  "]"

def testDiscoverValid : IO Bool := do
  let reqRef ← IO.mkRef ""
  let (port, _) ← startStub (fun client => do
    let req ← readRequest client
    reqRef.set req
    Std.Async.Async.block (Std.Async.TCP.Socket.Client.send client (http200 validBody).toUTF8))
  let found ← discoverMirrors s!"http://127.0.0.1:{port}"
  let req ← reqRef.get
  let a ← check "discover valid: request line" (req.startsWith "GET /v1/health/service/modelmirrors?passing=true HTTP/1.1")
  let b ← check "discover valid: Host header" (req.contains s!"Host: 127.0.0.1:{port}")
  let c ← check "discover valid: Connection header" (req.contains "Connection: close")
  let d ← check "discover valid: Accept header" (req.contains "Accept: application/json")
  let e ← checkEq "discover valid: candidate count" (toString found.size) "3"
  let expected : Array ServiceInfo := #[
    { host := "127.0.0.1", port := 8443,  certSha256 := some "aa11bb22" },
    { host := "10.0.0.2",  port := 9443,  certSha256 := none },
    { host := "10.0.0.3",  port := 10443, certSha256 := none }]
  let f ← check "discover valid: exact candidates" (found == expected)
  pure (a && b && c && d && e && f)

def testDiscoverMalformedJson : IO Bool := do
  let (port, _) ← startStub (fun client => do
    Std.Async.Async.block (Std.Async.TCP.Socket.Client.send client (http200 "{not json").toUTF8))
  let found ← discoverMirrors s!"http://127.0.0.1:{port}"
  checkEq "discover malformed json: empty" (toString found.size) "0"

def testDiscoverNonArray : IO Bool := do
  let (port, _) ← startStub (fun client => do
    Std.Async.Async.block (Std.Async.TCP.Socket.Client.send client (http200 "{\"Status\":\"ok\"}").toUTF8))
  let found ← discoverMirrors s!"http://127.0.0.1:{port}"
  checkEq "discover non-array json: empty" (toString found.size) "0"

def testDiscoverEmpty : IO Bool := do
  let (port, _) ← startStub (fun client => do
    Std.Async.Async.block (Std.Async.TCP.Socket.Client.send client (http200 "[]").toUTF8))
  let found ← discoverMirrors s!"http://127.0.0.1:{port}"
  checkEq "discover empty array: empty" (toString found.size) "0"

def testDiscoverNon200 : IO Bool := do
  let (port, _) ← startStub (fun client => do
    Std.Async.Async.block (Std.Async.TCP.Socket.Client.send client
      ("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 2\r\n\r\n{}").toUTF8))
  let found ← discoverMirrors s!"http://127.0.0.1:{port}"
  checkEq "discover non-200: empty" (toString found.size) "0"

def testDiscoverGarbage : IO Bool := do
  -- Bytes that are not HTTP at all (and never get a newline): the partial
  -- status line fails closed to #[] after the read timeout.
  let (port, _) ← startStub (fun client => do
    Std.Async.Async.block (Std.Async.TCP.Socket.Client.send client "hello garbage".toUTF8)
    closeWrite client)
  let found ← discoverMirrors s!"http://127.0.0.1:{port}" 300
  checkEq "discover garbage: empty" (toString found.size) "0"

def testDiscoverClosed : IO Bool := do
  -- Connection closed before any response. With the Lean 4.33 TCP API a
  -- peer-closed socket reads exactly like an idle one (no EOF flag), so
  -- this surfaces as a read timeout, not fail-closed `#[]`.
  let (port, _) ← startStub closeWrite
  try
    let _ ← discoverMirrors s!"http://127.0.0.1:{port}" 300
    check "discover closed: throws" false
  catch e =>
    check "discover closed: throws" ((toString e).contains "timed out")

def testDiscoverChunked : IO Bool := do
  let body := "[{\"Service\":{\"Address\":\"127.0.0.1\",\"Port\":8443,\"Meta\":{\"cert-sha256\":\"cc\"}}}]"
  let resp := "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++ chunked [body]
  let (port, _) ← startStub (fun client => do
    -- Read the request first: closing a socket with unread data sends RST.
    discard (Std.Async.Async.block (Std.Async.TCP.Socket.Client.recv? client 4096))
    Std.Async.Async.block (Std.Async.TCP.Socket.Client.send client resp.toUTF8))
  let found ← discoverMirrors s!"http://127.0.0.1:{port}"
  let a ← checkEq "discover chunked: count" (toString found.size) "1"
  let b ← check "discover chunked: candidate" (found.size > 0 &&
    found[0]!.host == "127.0.0.1" && found[0]!.port == 8443 && found[0]!.certSha256 == some "cc")
  pure (a && b)

def testDiscoverNoContentLength : IO Bool := do
  -- No Content-Length: read to EOF (we send Connection: close).
  let body := "[{\"Service\":{\"Address\":\"127.0.0.1\",\"Port\":8443}}]"
  let resp := "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n" ++ body
  let (port, _) ← startStub (fun client => do
    discard (Std.Async.Async.block (Std.Async.TCP.Socket.Client.recv? client 4096))
    Std.Async.Async.block (Std.Async.TCP.Socket.Client.send client resp.toUTF8)
    closeWrite client)
  -- Small timeoutMs: the read-until-silence fallback waits one full
  -- timeout after the body arrives (EOF is undetectable on this stdlib).
  let found ← discoverMirrors s!"http://127.0.0.1:{port}" 400
  let a ← checkEq "discover eof-framed: count" (toString found.size) "1"
  let b ← check "discover eof-framed: candidate" (found.size > 0 &&
    found[0]!.host == "127.0.0.1" && found[0]!.port == 8443)
  pure (a && b)

-- --------------------------------------------------------------------------
-- discoverMirrors: transport-error tests (must throw, distinctly)
-- --------------------------------------------------------------------------

def testDiscoverRefused : IO Bool := do
  -- Bind a socket but never listen: connecting must be refused. (The
  -- Std.Async.TCP API has no `Server.close`; a bound-but-unlistened port
  -- deterministically yields ECONNREFUSED on localhost.)
  let server ← Std.Async.TCP.Socket.Server.mk
  server.bind (Std.Net.SocketAddress.v4 { addr := Std.Net.IPv4Addr.ofParts 127 0 0 1, port := 0 })
  let port := (← server.getSockName).port
  try
    let _ ← discoverMirrors s!"http://127.0.0.1:{port}"
    check "discover refused: throws" false
  catch e =>
    let msg := toString e
    check "discover refused: throws" (msg.contains "unavailable" && msg.contains "127.0.0.1")

def testDiscoverTimeout : IO Bool := do
  -- Stub accepts and reads the request but never replies; the client must
  -- give up after `timeoutMs` and throw a distinct timeout error.
  let (port, _) ← startStub (fun client => do
    discard (Std.Async.Async.block (Std.Async.TCP.Socket.Client.recv? client 4096))
    IO.sleep 5000)
  try
    let _ ← discoverMirrors s!"http://127.0.0.1:{port}" 200
    check "discover timeout: throws" false
  catch e =>
    check "discover timeout: throws" ((toString e).contains "timed out")

def testDiscoverBadUrl : IO Bool := do
  try
    let _ ← discoverMirrors "https://consul"
    check "discover bad url: throws" false
  catch e =>
    check "discover bad url: throws" ((toString e).contains "invalid registry URL")

-- --------------------------------------------------------------------------
-- main
-- --------------------------------------------------------------------------

def allTests : List (String × IO Bool) :=
  [
    ("registry URL parse", testParseUrl),
    ("discover: valid response", testDiscoverValid),
    ("discover: malformed JSON", testDiscoverMalformedJson),
    ("discover: non-array JSON", testDiscoverNonArray),
    ("discover: empty array", testDiscoverEmpty),
    ("discover: non-200 status", testDiscoverNon200),
    ("discover: garbage response", testDiscoverGarbage),
    ("discover: closed without response", testDiscoverClosed),
    ("discover: chunked body", testDiscoverChunked),
    ("discover: read-to-EOF body", testDiscoverNoContentLength),
    ("discover: connection refused", testDiscoverRefused),
    ("discover: read timeout", testDiscoverTimeout),
    ("discover: bad URL", testDiscoverBadUrl),
  ]

def main : IO UInt32 := do
  IO.println "MirrorLean server-mode: registry discovery tests"
  IO.println "-----------------------------------------------"
  let mut failures : Nat := 0
  let mut count : Nat := 0
  for (name, test) in allTests do
    count := count + 1
    IO.print s!"[{name}] "
    match ← test with
    | true => IO.println "PASS"
    | false => failures := failures + 1; IO.println "FAIL"
  IO.println s!""
  IO.println s!"{count} tests, {failures} failures"
  if failures > 0 then
    throw (IO.userError s!"{failures} test(s) failed")
  pure 0

end Test.Discovery

/-- Executable entry point: run the registry discovery tests. -/
def main : IO UInt32 := Test.Discovery.main
