import MirrorLean.Transport
import MirrorLean.Error
import MirrorLean.ServerMode.Discovery

/-!
# MirrorLean.ServerMode

Server-mode client support for ModelMirrors (`plans/server-mode.md`):

* `connectMirrorTls` — direct TLS 1.3 mutual-auth connection to
  `ModelMirrors --server --tls`, returned as a normal
  `MirrorLean.Transport` (so every `runClient*` / `ExploreSession` flow
  works unchanged over it).
* `TlsClientConfig` — CA, client certificate/key, optional server name
  (SNI/hostname verification) and optional `cert-sha256` fingerprint pin.
* Discovery (Phase 2, `MirrorLean.ServerMode.Discovery`, re-imported here):
  `ServiceInfo`, `RegistryUrl`, `discoverMirrors`.

The TLS engine is a small native shim (`native/mirrorlean_tls.c`) linked
into this package's targets via `-lssl -lcrypto`; `MirrorLean.Transport`
stays a pure-Lean module, so the baseline build has no OpenSSL dependency.

Debug logging (off by default):
* `MIRRORLEAN_DEBUG_TLS=1` — log the byte length of each line sent/received.
* `MIRRORLEAN_DEBUG_TLS_PLAIN=1` — additionally log full plaintext lines.
No secret material (keys/certificates) is ever logged.
-/

namespace MirrorLean.ServerMode

/-- TLS client configuration for `connectMirrorTls`. -/
structure TlsClientConfig where
  /-- PEM CA bundle used to verify the server. -/
  caFile : System.FilePath
  /-- PEM client certificate presented to the server. -/
  certFile : System.FilePath
  /-- PEM client private key (must not be group/other readable on POSIX). -/
  keyFile : System.FilePath
  /-- SNI + hostname-verification name; defaults to the connection host. -/
  serverName : Option String := none
  /-- Optional `cert-sha256` fingerprint (lowercase hex) pinned after the
      handshake; a mismatch closes the connection before any traffic. -/
  expectedCertSha256 : Option String := none
  deriving Repr

/-! ## Native TLS externs

All return values are the direct IO results of the C function (Lean 4.33
ABI, validated in Phase 0). Convention used here: a leading `String` is
empty on success and holds a human-readable error otherwise.
-/

/-- Connect: `("", handle)` on success, `(error, 0)` on failure. -/
@[extern "mirrorlean_tls_lean_connect"]
opaque tlsConnect (caFile certFile keyFile serverName host : String) (port : UInt16) : IO (String × UInt64)

/-- Read up to `max` bytes: `("", bytes)`; `("", empty)` at clean EOF. -/
@[extern "mirrorlean_tls_lean_read"]
opaque tlsRead (h : UInt64) (max : UInt64) : IO (String × ByteArray)

/-- Write all bytes: `""` on success, else an error message. -/
@[extern "mirrorlean_tls_lean_write"]
opaque tlsWrite (h : UInt64) (data : ByteArray) : IO String

/-- Best-effort close (close_notify) and free; never throws. -/
@[extern "mirrorlean_tls_lean_close"]
opaque tlsClose (h : UInt64) : IO Unit

/-- SHA-256 of the peer certificate: `("", 32-byte digest)`. -/
@[extern "mirrorlean_tls_lean_peer_cert_sha256"]
opaque tlsPeerCertSha256 (h : UInt64) : IO (String × ByteArray)

/-- Client-certificate expiry warning (`""` when fine). -/
@[extern "mirrorlean_tls_lean_cert_warning"]
opaque tlsCertWarning (h : UInt64) : IO String

/-! ## Helpers -/

/-- Lowercase hex digit for a value 0..15 (`'0'`=48, `'a'`=97). -/
private def hexDigit (n : Nat) : Char :=
  if n < 10 then Char.ofNat (48 + n) else Char.ofNat (87 + n)

/-- Lowercase hex encoding of a byte (for fingerprint comparison). -/
def byteToHex (b : UInt8) : String :=
  String.ofList [hexDigit (b.toNat / 16), hexDigit (b.toNat % 16)]

/-- Lowercase hex encoding of a `ByteArray`. -/
def bytesToHexLower (bs : ByteArray) : String :=
  (List.range bs.size).foldl (fun acc i => acc ++ byteToHex bs[i]!) ""

/-- Throw an `IO.userError` with a `connectMirrorTls`-style prefix. -/
private def tlsFail (pfx msg : String) : IO α :=
  throw (IO.userError s!"{pfx}: {msg}")

/-!
Connect to a TLS 1.3 server with mutual authentication and return a normal
`Transport`.

* Server is verified against `cfg.caFile` and the hostname/SAN
  (`cfg.serverName` defaults to `host`; also used for SNI).
* The client presents `cfg.certFile`/`cfg.keyFile`; on POSIX the key file
  must not be readable by group/other (0600).
* If `cfg.expectedCertSha256` is set, the peer certificate's SHA-256 is
  compared after the handshake; a mismatch closes the connection before
  any protocol traffic.
* A client-certificate expiry warning (< 7 days) is printed to stderr.
* On setup/handshake failure this throws `IO.userError` with a clear
  message (same contract as `spawnMirror` / `connectMirror`).
-/
def connectMirrorTls (cfg : TlsClientConfig) (host : String) (port : UInt16) : IO Transport := do
  let serverName := cfg.serverName.getD host
  let (err, h) ← tlsConnect cfg.caFile.toString cfg.certFile.toString cfg.keyFile.toString serverName host port
  if h == 0 then
    tlsFail "connectMirrorTls" (if err.isEmpty then "TLS connect returned no handle" else err)
  -- Client-certificate expiry warning (cheap; C shim reports it).
  let warn ← tlsCertWarning h
  unless warn.isEmpty do
    IO.eprintln s!"mirrorlean: WARNING: {warn}"
  -- Fingerprint pinning (direct-connect `cert-sha256`).
  if let some expected := cfg.expectedCertSha256 then
    let (perr, digest) ← tlsPeerCertSha256 h
    if !perr.isEmpty then do
      tlsClose h
      tlsFail "connectMirrorTls" s!"cannot read peer certificate fingerprint: {perr}"
    let actual := bytesToHexLower digest
    if actual.toLower != expected.toLower then do
      tlsClose h
      tlsFail "connectMirrorTls"
        s!"peer certificate fingerprint mismatch (expected {expected}, got {actual})"
  -- Debug logging behind environment flags (line lengths by default).
  let debugTls ← ((· == some "1") <$> IO.getEnv "MIRRORLEAN_DEBUG_TLS")
  let debugPlain ← ((· == some "1") <$> IO.getEnv "MIRRORLEAN_DEBUG_TLS_PLAIN")
  let buf ← IO.mkRef (ByteArray.empty : ByteArray)
  -- Owned by the Transport's `close`; set to 0 once freed (idempotent close).
  let hRef ← IO.mkRef h
  let recvFn : IO (Option ByteArray) := do
    let (rerr, data) ← tlsRead h 4096
    if !rerr.isEmpty then
      tlsFail "TLS recv" rerr
    if data.isEmpty then pure none else pure (some data)
  let t : Transport :=
    {
      send := fun line => do
        MirrorLean.validateProtocolLine line
        let payload := line ++ "\n"
        if debugTls then do
          IO.eprintln s!"mirrorlean TLS >> {payload.length} bytes"
          if debugPlain then IO.eprintln s!"mirrorlean TLS >> {repr payload}" else pure ()
        let werr ← tlsWrite h payload.toUTF8
        unless werr.isEmpty do
          tlsFail "TLS send" werr,
      recv := do
        let line ← MirrorLean.recvLine recvFn buf
        if debugTls then
          match line with
          | some l => do
              IO.eprintln s!"mirrorlean TLS << {l.length} bytes"
              if debugPlain then IO.eprintln s!"mirrorlean TLS << {repr l}" else pure ()
          | none => IO.eprintln "mirrorlean TLS << EOF"
        pure line,
      close := do
        -- Idempotent: tlsClose frees the native handle, so a second
        -- close is a no-op. A `Transport` is single-owner — the
        -- runClient*/ExploreSession helpers close it exactly once;
        -- extra closes are tolerated (stdio/TCP merely need harmless
        -- double-shutdown; TLS would double-free).
        let hcur ← hRef.get
        unless hcur == 0 do
          tlsClose hcur
          hRef.set 0
        pure 0,
    }
  pure t

/-!
A typed variant of `connectMirrorTls` for callers that surface errors
through `Except MirrorError`: setup/handshake failures map to
`MirrorError.tls` (with the raw message), I/O failures to
`MirrorError.io`.
-/
def connectMirrorTls' (cfg : TlsClientConfig) (host : String) (port : UInt16) : IO (Except MirrorError Transport) := do
  try
    let t ← connectMirrorTls cfg host port
    pure (Except.ok t)
  catch
    | .userError msg => pure (Except.error (.tls msg))
    | e => pure (Except.error (.io e))

/-!
Discover candidates from a Consul-compatible registry (`discoverMirrors`)
and try each in order with `cert-sha256` pinning, returning the first
`Transport` whose handshake AND fingerprint check succeed.

* A candidate's registry-advertised `certSha256` becomes
  `expectedCertSha256` for that attempt; candidates without a fingerprint
  are attempted unpinned.
* On failure the connection is closed and the next candidate is tried.
* If the registry is unreachable, `discoverMirrors` throws (clear error;
  a direct `connectMirrorTls` remains possible).
* An empty candidate list, or every candidate failing, throws an
  `IO.userError` with the aggregated per-candidate errors.
-/
def connectMirrorDiscovered (cfg : TlsClientConfig) (registryUrl : String) : IO Transport := do
  let candidates ← discoverMirrors registryUrl
  if candidates.isEmpty then
    throw (IO.userError
      s!"connectMirrorDiscovered: registry '{registryUrl}' returned no candidates")
  let acc ← candidates.foldlM (init := (Sum.inl #[] : Sum (Array String) Transport)) fun acc c => do
    match acc with
    | .inr _ => pure acc
    | .inl errs =>
        let ccfg : TlsClientConfig := { cfg with expectedCertSha256 := c.certSha256 }
        try
          let t ← connectMirrorTls ccfg c.host c.port
          pure (.inr t)
        catch e =>
          pure (.inl (errs.push s!"{c.host}:{c.port}: {toString e}"))
  match acc with
  | .inr t => pure t
  | .inl errs =>
      throw (IO.userError
        s!"connectMirrorDiscovered: all {candidates.size} candidate(s) from registry '{registryUrl}' failed:\n{String.intercalate "\n" errs.toList}")

end MirrorLean.ServerMode
