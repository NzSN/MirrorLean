import Std.Async.TCP
import Std.Async.DNS
import Std.Async.Select
import Std.Async.Timer
import Std.Net
import Std.Time
import Lean.Data.Json

/-!
# MirrorLean.ServerMode.Discovery

Consul service-registry discovery for ModelMirrors server mode
(`plans/server-mode.md` Phase 2).

Mirrors are discovered through a Consul-compatible registry with a single
`GET /v1/health/service/modelmirrors?passing=true`, which returns an array of
entries. Each entry carries the mirror under `Service`: `Service.Address`,
`Service.Port`, and optionally `Service.Meta.cert-sha256` — the certificate
fingerprint used for post-handshake pinning (Phase 3).

This module provides:

* `ServiceInfo` — one discovered mirror candidate (host, port, optional
  `cert-sha256` fingerprint).
* `RegistryUrl` / `parseRegistryUrl` — the minimal v1 URL form
  `http://host[:port][/prefix]` (plain HTTP only; `https://` registries are
  rejected).
* `discoverMirrors` — fetch and decode the health endpoint, **failing
  closed**: any unusable response yields `#[]`, never a partial or guessed
  candidate list.

## Failure semantics of `discoverMirrors`

* **Throws** `IO.userError` only when the registry is unreachable or unusable
  at the transport level: malformed URL, DNS failure, connection failure,
  socket send failure, or a read timeout (no response bytes within
  `timeoutMs`). This is reported distinctly from "no candidates" so that
  `connectMirrorDiscovered` (Phase 3) can fall back to a direct connection.
* **Returns `#[]`** for everything else, matching the upstream ModelMirrors
  client (`Protocol/Registry.hs` `discoverServices`, which fails closed on
  any registry or parsing error): any received-but-unusable response —
  connection closed before a complete body, malformed status line / headers /
  chunk framing, invalid `Content-Length`, a non-200 status, malformed JSON,
  or JSON that is not an array — yields `#[]`. Entries that do not decode to
  a usable `ServiceInfo` (missing `Service`, empty `Address`, out-of-range
  `Port`) are skipped.

## The HTTP client

Deliberately minimal (plan §4 D3): a single HTTP/1.1 `GET` over
`Std.Async.TCP` with `Connection: close`, supporting `Content-Length`,
read-to-EOF and chunked bodies, and a bounded read timeout implemented by
racing the socket reader against a timer selector with
`Std.Async.Selectable.one`. The Lean 4.33 stdlib ships no HTTP *client*
(`Std.Http` is a sans-I/O server library), and MirrorLean stays
dependency-free, so the ~150 lines here are the whole stack.
-/

namespace MirrorLean.ServerMode

/-- A mirror discovered via the Consul service registry.

Matches upstream `Protocol/Registry.hs` `ServiceInfo` minus the service `ID`
(not needed by a client): host, port, and the registry-advertised
`cert-sha256` fingerprint used for post-handshake pinning (optional).
-/
structure ServiceInfo where
  host : String
  port : UInt16
  certSha256 : Option String
deriving Repr, BEq, Inhabited

/-- A parsed registry URL: `http://host[:port][/prefix]` (v1: plain HTTP only).

`pathPrefix` is normalized to either `""` or a string starting with `/` and
not ending with `/`; the health endpoint is requested at
`pathPrefix ++ "/v1/health/service/modelmirrors?passing=true"`.
(Note: the field is `pathPrefix`, not `prefix` — `prefix` is a Lean command
keyword.)
-/
structure RegistryUrl where
  host : String
  port : UInt16
  pathPrefix : String
deriving Repr, BEq

/-- The default Consul HTTP port. -/
private def defaultRegistryPort : UInt16 := 8500

private partial def stripTrailingChar (c : Char) : String → String
  | "" => ""
  | s => if s.back == c then stripTrailingChar c ((s.dropEnd 1).toString) else s

/-- The byte index of the first occurrence of `c` in `s`, or `none`.

Uses the Lean 4.33 `String.find?` (position-based) API, so the index is a
byte offset suitable for `String.take`/`String.drop`; `c` itself is used as
the search pattern (a `Char` has a `ToForwardSearcher` instance).
-/
private def indexOfChar (s : String) (c : Char) : Option Nat :=
  (s.find? c).map (fun p => p.offset.byteIdx)

/--
Parse a registry URL of the v1 form `http://host[:port][/prefix]`.

* plain `http://` only — `https://` is rejected with an error (v1 scope);
* the port defaults to 8500 (the Consul HTTP port) when omitted;
* `host` must be non-empty and contain no `:` (IPv6 literals are not
  supported in v1 — use a hostname or an IPv4 address);
* the prefix may contain slashes; a trailing `/` is stripped.
-/
def parseRegistryUrl (url : String) : Except String RegistryUrl := do
  if url.startsWith "https://" then
    throw "https:// registry URLs are not supported in v1 (plain http:// only)"
  unless url.startsWith "http://" do
    throw "registry URL must start with http://"
  let rest := (url.drop 7).toString
  if rest.isEmpty then
    throw "registry URL has no host"
  let slashIdx := (indexOfChar rest '/').getD rest.utf8ByteSize
  let authority := (rest.take slashIdx).toString
  let pathPart := (rest.drop slashIdx).toString
  let hostPort := authority.splitOn ":"
  let host :=
    match hostPort with
    | h :: _ => h
    | [] => ""
  if host.isEmpty then
    throw "registry URL has an empty host"
  let port ← match hostPort with
    | [_] => pure defaultRegistryPort
    | [_, ps] =>
        if ps.isEmpty then
          throw "registry URL has an empty port"
        else
          match ps.toNat? with
          | none => throw s!"registry URL port is not a number: {ps}"
          | some n =>
              if n == 0 || n > 65535 then
                throw s!"registry URL port out of range (1-65535): {ps}"
              else
                pure (UInt16.ofNat n)
    | _ =>
        throw "registry URL host must be a hostname or IPv4 address (IPv6 literals are not supported in v1)"
  let pathPrefix := if pathPart.isEmpty then "" else stripTrailingChar '/' pathPart
  pure { host := host, port := port, pathPrefix := pathPrefix }

-- --------------------------------------------------------------------------
-- Minimal HTTP/1.1 GET client over Std.Async.TCP
-- --------------------------------------------------------------------------

private def LF : UInt8 := 10
private def CR : UInt8 := 13

private def findByte (b : ByteArray) (c : UInt8) : Option Nat :=
  (List.range b.size).find? (fun i => b[i]! == c)

private def stripCr (s : String) : String :=
  if s.endsWith "\r" then (s.dropEnd 1).toString else s

/-- The outcome of one timed socket read. -/
private inductive ReadOutcome where
  | data (bs : ByteArray)
  | eof
  | timedOut

/--
Read up to `size` bytes from `client` within `timeoutMs` milliseconds.

Races the socket read against a timer with `Std.Async.Selectable.one`; a
timer win is reported as `timedOut` (the socket stays usable for a later
read).
-/
private def recvWithTimeout (client : Std.Async.TCP.Socket.Client) (size : UInt64) (timeoutMs : Nat)
    : IO ReadOutcome := do
  let sleepSel ← Std.Async.Async.block (Std.Async.Selector.sleep (Std.Time.Millisecond.Offset.ofNat timeoutMs))
  let recvSel : Std.Async.Selectable ReadOutcome :=
    { selector := Std.Async.TCP.Socket.Client.recvSelector client size
      cont := fun bs => pure (match bs with
        | some b => ReadOutcome.data b
        | none   => ReadOutcome.eof) }
  let timerSel : Std.Async.Selectable ReadOutcome :=
    { selector := sleepSel
      cont := fun _ => pure ReadOutcome.timedOut }
  Std.Async.Async.block (Std.Async.Selectable.one #[recvSel, timerSel])

/-- A buffered, timed reader over a raw socket, used for the registry HTTP
exchange. -/
structure HttpBuf where
  client : Std.Async.TCP.Socket.Client
  buf : IO.Ref ByteArray
  eof : IO.Ref Bool
  timeoutMs : Nat

/--
Append one socket read to the buffer; returns `false` at end of input.

Throws `IO.userError` on a read timeout (the registry hung) — the
"registry unavailable" case is reported distinctly from "no candidates".
-/
private def fill (hb : HttpBuf) : IO Bool := do
  let b ← hb.buf.get
  match ← recvWithTimeout hb.client 4096 hb.timeoutMs with
  | .timedOut => throw (IO.userError "registry request timed out")
  | .eof =>
      hb.eof.set true
      pure false
  | .data bs =>
      if bs.isEmpty then
        hb.eof.set true
        pure false
      else
        hb.buf.set (b ++ bs)
        pure true

/--
Read the next `\n`-terminated line (stripping a trailing `\r`), or `none` at
end of input.
-/
private partial def readLine (hb : HttpBuf) : IO (Option String) := do
  let b ← hb.buf.get
  match findByte b LF with
  | some i =>
      let lineBytes := b.extract 0 i
      hb.buf.set (b.extract (i + 1) b.size)
      pure (some (stripCr (String.fromUTF8? lineBytes |>.getD "")))
  | none =>
      if ← hb.eof.get then pure none
      else
        match ← fill hb with
        | false => pure none
        | true => readLine hb

/-- Read exactly `n` bytes, or report an error if input ends first. -/
private partial def readExact (hb : HttpBuf) (n : Nat) : IO (Except String ByteArray) := do
  let b ← hb.buf.get
  if b.size ≥ n then
    hb.buf.set (b.extract n b.size)
    pure (.ok (b.extract 0 n))
  else
    if ← hb.eof.get then
      pure (.error "connection closed mid-response (truncated body)")
    else
      match ← fill hb with
      | false => pure (.error "connection closed mid-response (truncated body)")
      | true => readExact hb n

/-- Read the rest of the input (until end of input). -/
private partial def readToEnd (hb : HttpBuf) : IO ByteArray := do
  if ← hb.eof.get then
    let b ← hb.buf.get
    hb.buf.set ByteArray.empty
    pure b
  else
    match ← fill hb with
    | false =>
        let b ← hb.buf.get
        hb.buf.set ByteArray.empty
        pure b
    | true => readToEnd hb

private def hexDigit (c : Char) : Option Nat :=
  if '0' ≤ c ∧ c ≤ '9' then some (c.toNat - '0'.toNat)
  else if 'a' ≤ c ∧ c ≤ 'f' then some (10 + c.toNat - 'a'.toNat)
  else if 'A' ≤ c ∧ c ≤ 'F' then some (10 + c.toNat - 'A'.toNat)
  else none

private partial def parseHexAux (s : String) (i : Nat) (acc : Nat) : Option Nat :=
  match String.Pos.Raw.get? s ({ byteIdx := i } : String.Pos.Raw) with
  | none => some acc
  | some c =>
      match hexDigit c with
      | none => none
      | some v => parseHexAux s (i + 1) (acc * 16 + v)

/-- Parse a non-empty lowercase/uppercase hex string as a `Nat`. -/
private def parseHex (s : String) : Option Nat :=
  parseHexAux s 0 0

/-- Consume chunked trailers (lines after the terminating `0` chunk) up to
the empty line; the payload was already collected in `acc`. -/
private partial def readChunkTrailers (hb : HttpBuf) (acc : ByteArray) : IO (Except String ByteArray) := do
  match ← readLine hb with
  | none => pure (.error "connection closed in chunked trailers")
  | some "" => pure (.ok acc)
  | some _ => readChunkTrailers hb acc

/-- Decode a chunked-encoded body, collecting the payload into `acc`. -/
private partial def readChunked (hb : HttpBuf) (acc : ByteArray) : IO (Except String ByteArray) := do
  match ← readLine hb with
  | none => pure (.error "connection closed mid-chunk (truncated body)")
  | some line =>
      let sizeStr :=
        match line.splitOn ";" with
        | sizePart :: _ => (sizePart.trimAscii).toString
        | [] => ""
      if sizeStr.isEmpty then
        pure (.error s!"malformed chunk size (empty line: {line})")
      else
        match parseHex sizeStr with
        | none => pure (.error s!"malformed chunk size: {line}")
        | some 0 => readChunkTrailers hb acc
        | some n =>
            match ← readExact hb n with
            | .error e => pure (.error e)
            | .ok chunk =>
                match ← readExact hb 2 with
                | .error e => pure (.error e)
                | .ok term =>
                    if term ≠ (ByteArray.mk #[CR, LF]) then
                      pure (.error "malformed chunk terminator")
                    else
                      readChunked hb (acc ++ chunk)

private def parseHeaderLine (line : String) : Option (String × String) :=
  match indexOfChar line ':' with
  | none => none
  | some i =>
      let name := ((line.take i).toString.trimAscii).toString.toLower
      let value := ((line.drop (i + 1)).toString.trimAscii).toString
      if name.isEmpty then none else some (name, value)

private partial def readHeaders (hb : HttpBuf) : IO (Except String (Array (String × String))) := do
  match ← readLine hb with
  | none => pure (.error "connection closed before the response headers completed")
  | some "" => pure (.ok #[])
  | some line =>
      match parseHeaderLine line with
      | none => pure (.error s!"malformed response header: {line}")
      | some h =>
          match ← readHeaders hb with
          | .error e => pure (.error e)
          | .ok rest => pure (.ok (rest.push h))

private def headerVal (headers : Array (String × String)) (name : String) : Option String :=
  match headers.find? (fun (n, _) => n == name) with
  | some (_, v) => some v
  | none => none

/-- Parse an HTTP status line, returning the status code. -/
private def parseStatusLine (line : String) : Except String Nat := do
  match line.splitOn " " with
  | [] => throw "empty status line"
  | version :: rest =>
      unless version.startsWith "HTTP/" do
        throw s!"not an HTTP status line: {line}"
      match rest with
      | [] => throw s!"status line has no status code: {line}"
      | codeStr :: _ =>
          match codeStr.toNat? with
          | none => throw s!"malformed status code: {line}"
          | some code => pure code

/-- Read status lines, skipping informational (1xx) ones. -/
private partial def readStatus (hb : HttpBuf) : IO (Except String Nat) := do
  match ← readLine hb with
  | none => pure (.error "connection closed before a response")
  | some line =>
      match parseStatusLine line with
      | .error _ => pure (.error s!"malformed HTTP status line: {line}")
      | .ok code =>
          if code / 100 == 1 then readStatus hb else pure (.ok code)

/--
Read the response body per the framing headers: chunked wins over
`Content-Length` (RFC 7230 §3.3.3); otherwise `Content-Length`; otherwise
read to end of input (we always send `Connection: close`).
-/
private def readBody (hb : HttpBuf) (headers : Array (String × String)) : IO (Except String ByteArray) := do
  let te := headerVal headers "transfer-encoding"
  if te.map (fun v => v.toLower.contains "chunked") == some true then
    readChunked hb ByteArray.empty
  else
    match headerVal headers "content-length" with
    | some cl =>
        match (cl.trimAscii).toString.toNat? with
        | none => pure (.error s!"invalid Content-Length header: {cl}")
        | some n => readExact hb n
    | none =>
        let b ← readToEnd hb
        pure (.ok b)

/-- A fully read HTTP response (headers are consumed; only status and body
are kept). -/
private structure HttpResponse where
  status : Nat
  body : ByteArray

/--
Resolve a host:port pair to a socket address (DNS first, then a literal IP
address), throwing a clear error when the host does not resolve at all.
-/
private def resolveAddress (host : String) (port : UInt16) : IO Std.Net.SocketAddress := do
  let service := toString port
  let addrs ← Std.Async.Async.block (Std.Async.DNS.getAddrInfo host service)
  let ip ← match addrs.toList with
    | ip :: _ => pure ip
    | [] =>
        match Std.Net.IPv4Addr.ofString host with
        | some a => pure (Std.Net.IPAddr.v4 a)
        | none =>
            match Std.Net.IPv6Addr.ofString host with
            | some a => pure (Std.Net.IPAddr.v6 a)
            | none => throw (IO.userError s!"registry host does not resolve: {host}")
  match ip with
  | Std.Net.IPAddr.v4 a => pure (Std.Net.SocketAddress.v4 { addr := a, port := port })
  | Std.Net.IPAddr.v6 a => pure (Std.Net.SocketAddress.v6 { addr := a, port := port })

/--
Perform the registry GET request.

Transport-level failures (DNS, connect, send, timeout) throw `IO.userError`;
anything received-but-unusable is reported as `.error` so the caller fails
closed to `#[]`.
-/
private def httpGet (url : RegistryUrl) (timeoutMs : Nat) : IO (Except String HttpResponse) := do
  let client ← Std.Async.TCP.Socket.Client.mk
  let addr ← resolveAddress url.host url.port
  Std.Async.Async.block (Std.Async.TCP.Socket.Client.connect client addr)
  let reqPath := url.pathPrefix ++ "/v1/health/service/modelmirrors?passing=true"
  let req :=
    "GET " ++ reqPath ++ " HTTP/1.1\r\n" ++
    "Host: " ++ url.host ++ ":" ++ toString url.port ++ "\r\n" ++
    "Connection: close\r\n" ++
    "Accept: application/json\r\n\r\n"
  Std.Async.Async.block (Std.Async.TCP.Socket.Client.send client req.toUTF8)
  let buf ← IO.mkRef (ByteArray.empty : ByteArray)
  let eof ← IO.mkRef false
  let hb : HttpBuf := { client := client, buf := buf, eof := eof, timeoutMs := timeoutMs }
  match ← readStatus hb with
  | .error e => pure (.error e)
  | .ok status =>
      match ← readHeaders hb with
      | .error e => pure (.error e)
      | .ok headers =>
          match ← readBody hb headers with
          | .error e => pure (.error e)
          | .ok body => pure (.ok { status := status, body := body })

-- --------------------------------------------------------------------------
-- Consul JSON decode (fail closed)
-- --------------------------------------------------------------------------

/--
Decode one Consul health entry into a `ServiceInfo`, or `none` when the
entry does not carry a usable candidate.

Matches upstream `Protocol/Registry.hs` `toServiceInfo`: the `Service`
object must exist with a non-empty string `Address` and a numeric `Port`
(here additionally bounded to 1-65535); missing/unexpected fields are
ignored, and the optional `Service.Meta.cert-sha256` string is carried when
present.
-/
private def serviceInfoOfJson? (j : Lean.Json) : Option ServiceInfo := do
  let svc ← (j.getObjVal? "Service").toOption
  let addr ← (svc.getObjVal? "Address").toOption.bind (fun jv => (Lean.Json.getStr? jv).toOption)
  if addr.isEmpty then none
  let portN ← (svc.getObjVal? "Port").toOption.bind (fun jv => (Lean.Json.getNat? jv).toOption)
  if portN == 0 || portN > 65535 then none
  let certSha256 : Option String :=
    match (svc.getObjVal? "Meta").toOption with
    | some metaObj =>
        match (metaObj.getObjVal? "cert-sha256").toOption with
        | some v => (Lean.Json.getStr? v).toOption
        | none => none
    | none => none
  some { host := addr, port := UInt16.ofNat portN, certSha256 := certSha256 }

/--
Discover mirror candidates from a Consul-compatible registry.

Fetches `GET <prefix>/v1/health/service/modelmirrors?passing=true` (plain
HTTP only) and decodes the Consul health response, failing closed:

* transport failures (unreachable registry, timeout) **throw**
  `IO.userError` — reported distinctly from "no candidates" so callers can
  fall back to a direct connection;
* any received-but-unusable response — non-200 status, malformed HTTP/JSON,
  JSON that is not an array — returns `#[]`;
* entries that do not decode into a usable `ServiceInfo` are skipped.

The optional `timeoutMs` bounds each socket read (default 5000 ms).
-/
def discoverMirrors (registryUrl : String) (timeoutMs : Nat := 5000) : IO (Array ServiceInfo) := do
  match parseRegistryUrl registryUrl with
  | .error msg => throw (IO.userError s!"invalid registry URL: {msg}")
  | .ok url =>
      try
        match ← httpGet url timeoutMs with
        | .error _ => pure #[]  -- malformed/incomplete response: fail closed
        | .ok resp =>
            if resp.status ≠ 200 then pure #[]
            else
              let bodyStr := (String.fromUTF8? resp.body).getD ""
              match Lean.Json.parse bodyStr with
              | .error _ => pure #[]
              | .ok jv =>
                  match jv.getArr? with
                  | .error _ => pure #[]
                  | .ok entries => pure (entries.filterMap serviceInfoOfJson?)
      catch e =>
        throw (IO.userError s!"registry {registryUrl} unavailable: {toString e}")

end MirrorLean.ServerMode
