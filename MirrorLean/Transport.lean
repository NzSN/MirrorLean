import Std.Async.TCP
import Std.Async.DNS
import Std.Net

/-!
# MirrorLean.Transport

The transport layer for the Mirror replay protocol (design §6).

A `Transport` is a bidirectional, newline-delimited byte stream to a mirror process.
Frames are UTF-8 JSON objects, one per line; the protocol guarantees frames never
contain a raw newline, so line framing is unambiguous. Lines are `\n`-terminated,
and a trailing `\r` is tolerated and stripped defensively.

This module provides:

* `Transport` — the transport interface (send / recv / close)
* `spawnMirror` — spawn a mirror binary with piped stdio and return a `Transport`
* `connectMirror` — connect to a mirror over TCP and return a `Transport`
* `Transport.ofChild` — wrap an already-spawned child in a `Transport` (used by
  tests with a stub peer, and by callers that build `SpawnArgs` manually)
* `Target` — what a replay run targets: a binary path or an existing transport
-/

namespace MirrorLean

/--
A bidirectional, newline-delimited byte stream to a mirror process.

* `send` writes one line (terminated with `\n`) and flushes, so the mirror
  reliably receives the frame before `recv` is called (unflushed pipes deadlock).
* `recv` blocks for the next complete frame and returns `none` on clean EOF.
  Empty, oversized, invalid-UTF-8 and unterminated frames raise an I/O error.
* `close` signals end-of-file to the mirror's standard input and returns its
  exit code (`UInt32`).
-/
structure Transport where
  send  : String → IO Unit
  recv  : IO (Option String)
  close : IO UInt32
  /-- True only for network transports; async jobs are unavailable on stdio. -/
  asyncCapable : Bool := false

/-- Maximum UTF-8 payload size before the terminating LF is appended. -/
def maxProtocolLineBytes : Nat := 65535

/-- Enforce the protocol's outbound framing invariants before any write. -/
def validateProtocolLine (line : String) : IO Unit := do
  if line.isEmpty then
    throw (IO.userError "protocol line must not be empty")
  if line.contains '\n' then
    throw (IO.userError "protocol line contains an embedded newline")
  if line.toUTF8.size > maxProtocolLineBytes then
    throw (IO.userError "protocol line exceeds 65535-byte UTF-8 payload limit")

/--
The concrete child type used by `spawnMirror`: stdin and stdout are piped (so the
client can talk to the mirror), stderr is inherited (so the mirror's error output
goes straight to the user's console).
-/
abbrev StdioPipedChild :=
  IO.Process.Child (IO.Process.StdioConfig.mk IO.Process.Stdio.piped IO.Process.Stdio.piped IO.Process.Stdio.inherit)

/-- Strip a trailing `\n` (and, defensively, a trailing `\r`) from a line. -/
def stripLineEnding (s : String) : String :=
  let s := if s.endsWith "\n" then (s.dropEnd 1).copy else s
  if s.endsWith "\r" then (s.dropEnd 1).copy else s

/-- Decode one complete frame, enforcing the byte limit before UTF-8 decoding. -/
def decodeProtocolFrame (bytes : ByteArray) : IO String := do
  let payload := if bytes.size > 0 && bytes[bytes.size - 1]! == 13 then
      bytes.extract 0 (bytes.size - 1) else bytes
  if payload.size > maxProtocolLineBytes then
    throw (IO.userError "protocol line exceeds 65535-byte UTF-8 payload limit")
  if payload.isEmpty then throw (IO.userError "empty protocol frame")
  match String.fromUTF8? payload with
  | some line => pure line
  | none => throw (IO.userError "invalid UTF-8 protocol frame")

/-- Bounded stdio reader. Reads no byte beyond the current frame. -/
private partial def readHandleFrame (handle : IO.FS.Handle) (bytes : ByteArray := .empty)
    : IO (Option String) := do
  let next ← handle.read 1
  if next.isEmpty then
    if bytes.isEmpty then return none
    else throw (IO.userError "truncated protocol frame at EOF")
  if next[0]! == 10 then return some (← decodeProtocolFrame bytes)
  if bytes.size >= maxProtocolLineBytes &&
      !(bytes.size == maxProtocolLineBytes && next[0]! == 13) then
    throw (IO.userError "protocol line exceeds 65535-byte UTF-8 payload limit")
  readHandleFrame handle (bytes ++ next)

/--
Wrap an already-spawned piped child in a `Transport`.

This is the constructor behind `spawnMirror`. Callers that need custom spawn
arguments (for example a stub peer with `SpawnArgs.args`) build the `SpawnArgs`
themselves, call `IO.Process.spawn`, and pass the resulting `StdioPipedChild`
here.
-/
def Transport.ofChild (child : StdioPipedChild) : Transport :=
  let stdin : IO.FS.Handle := child.stdin
  let stdout : IO.FS.Handle := child.stdout
  {
    send := fun line => do
      validateProtocolLine line
      IO.FS.Handle.putStrLn stdin line
      IO.FS.Handle.flush stdin,
    recv := readHandleFrame stdout,
    close := do
      let (_, child') ← child.takeStdin
      child'.wait
  }

/--
Spawn a mirror binary and return a `Transport` to it.

The child is spawned with stdin/stdout piped and stderr inherited. The mirror's
termination is mirror-driven in the replay protocol (it exits after reporting
`all_steps_done`), so `close` simply reaps the exit code.
-/
def spawnMirror (binPath : System.FilePath) : IO Transport := do
  let args : IO.Process.SpawnArgs :=
    { cmd := binPath.toString, args := #[], stdin := .piped, stdout := .piped, stderr := .inherit }
  let child : StdioPipedChild ← IO.Process.spawn args
  pure (Transport.ofChild child)

/-- The line terminator byte. -/
private def LF : UInt8 := 10

/--
Find the index of the first newline byte in a buffer, or `none`.
-/
private def findNewline (b : ByteArray) : Option Nat :=
  (List.range b.size).find? (fun i => b[i]! == LF)

/--
Read the next complete newline-terminated line, buffering partial reads.

Bytes accumulate in a buffer shared across calls (held in an `IO.Ref`); a single
`recv` may deliver several lines (or a partial line), so we split on `\n`
exactly once per call. A trailing `\r` is stripped (defensive CRLF handling).
EOF with an empty buffer yields `none`; a partial frame at EOF is an error.
The payload is bounded before further reads and decoded as strict UTF-8.

This is the shared newline-framing helper used by the TCP transport and the
TLS transport (`MirrorLean.ServerMode`); `recv` is any action returning the
next chunk of bytes or `none` at end-of-stream.
-/
partial def recvLine (recv : IO (Option ByteArray)) (buf : IO.Ref ByteArray)
    : IO (Option String) := do
  let b ← buf.get
  match findNewline b with
  | some i =>
      let lineBytes := b.extract 0 i
      buf.set (b.extract (i + 1) b.size)
      return some (← decodeProtocolFrame lineBytes)
  | none =>
      if b.size > maxProtocolLineBytes &&
          !(b.size == maxProtocolLineBytes + 1 && b[b.size - 1]! == 13) then
        throw (IO.userError "protocol line exceeds 65535-byte UTF-8 payload limit")
      let chunk ← recv
      match chunk with
      | none =>
          if b.isEmpty then return none
          else throw (IO.userError "truncated protocol frame at EOF")
      | some bs =>
          if bs.isEmpty then
            if b.isEmpty then return none
            else throw (IO.userError "truncated protocol frame at EOF")
          buf.set (b ++ bs)
          recvLine recv buf

/-- Resolve a host:port pair to a socket address (DNS first, then literal IP). -/
private def resolveAddress (host : String) (port : UInt16) : IO Std.Net.SocketAddress := do
  let service := toString port
  let addrs ← Std.Async.Async.block (Std.Async.DNS.getAddrInfo host service)
  let ip :=
    match addrs.toList with
    | ip :: _ => ip
    | [] =>
        match Std.Net.IPv4Addr.ofString host with
        | some a => Std.Net.IPAddr.v4 a
        | none =>
            match Std.Net.IPv6Addr.ofString host with
            | some a => Std.Net.IPAddr.v6 a
            | none =>
                Std.Net.IPAddr.v4 (Std.Net.IPv4Addr.ofParts 0 0 0 0)
  match ip with
  | Std.Net.IPAddr.v4 a => pure (Std.Net.SocketAddress.v4 { addr := a, port := port })
  | Std.Net.IPAddr.v6 a => pure (Std.Net.SocketAddress.v6 { addr := a, port := port })

/--
Connect to a mirror listening on `host:port` (TCP) and return a `Transport`.

The TCP transport mirrors the stdio one: `send` writes one line + `\n` and
flushes, `recv` returns the next `\n`-terminated line (buffering partial
reads; `none` at EOF), and `close` shuts down the write side and returns exit
code 0 (the mirror daemon process itself is not reaped by the client).
-/
def connectMirror (host : String) (port : UInt16) : IO Transport := do
  let client ← Std.Async.TCP.Socket.Client.mk
  let addr ← resolveAddress host port
  Std.Async.Async.block (Std.Async.TCP.Socket.Client.connect client addr)
  let buf ← IO.mkRef (ByteArray.empty : ByteArray)
  let recvFn : IO (Option ByteArray) := Std.Async.Async.block (Std.Async.TCP.Socket.Client.recv? client 4096)
  let t : Transport :=
    { asyncCapable := true,
      send := fun line => do
        validateProtocolLine line
        Std.Async.Async.block (Std.Async.TCP.Socket.Client.send client ((line ++ "\n").toUTF8))
        pure (),
      recv := recvLine recvFn buf,
      close := do
        Std.Async.Async.block (Std.Async.TCP.Socket.Client.shutdown client)
        pure 0,
    }
  pure t

/--
What a replay run targets: a mirror binary to spawn, or an already-open transport
(e.g. an interactive process, or a TCP connection).
-/
inductive Target where
  | binary (path : System.FilePath)
  | transport (t : Transport)

end MirrorLean
