import MirrorLean
import MirrorLean.ServerMode

/-!
# MirrorLean server-mode example

Connects to a `ModelMirrors --server --tls` mirror over TLS 1.3 with mutual
authentication — directly or via a Consul-compatible registry — and runs the
Counter replay (the same computer as `examples/Counter.lean`) over that
transport, so every JSON-lines flow goes through the mTLS connection.

Environment:

* `MIRROR_CA`    — PEM CA bundle used to verify the server (default `ca.crt`)
* `MIRROR_CERT`  — PEM client certificate (default `client.crt`)
* `MIRROR_KEY`   — PEM client key, mode 0600 on POSIX (default `client.key`)
* `MIRROR_HOST`  — direct-connect host (default `127.0.0.1`)
* `MIRROR_PORT`  — direct-connect port (default `8443`)
* `MIRROR_CERT_SHA256` — optional direct fingerprint pin (lowercase hex)
* `MODELMIRRORS_REGISTRY` — optional; when set, candidates are discovered
  from this Consul URL (`http://host[:port][/prefix]`) and tried in order
  with each candidate's `cert-sha256` pin instead of a direct connect.

Example (from `server-mode/`, after `lake build server-mode-example`):

    MIRROR_CA=ca.crt MIRROR_CERT=client.crt MIRROR_KEY=client.key \
    MIRROR_HOST=127.0.0.1 MIRROR_PORT=8443 \
    .lake/build/bin/server-mode-example

No private keys are committed; the certs come from your own key
generation (see `test/gen-test-certs.sh` for the ephemeral test PKI).
-/

open MirrorLean

/-! The Counter state machine (same as `examples/Counter.lean`, inlined so
this example stays self-contained: that module is an executable root, not
an importable library module). -/
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

/-- `IO.getEnv` with a fallback. -/
def envOr (name fallback : String) : IO String := do
  match ← IO.getEnv name with
  | some v => pure v
  | none => pure fallback

/-- Parse a port string, defaulting to `defPort` on garbage. -/
def parsePort (s : String) (defPort : UInt16) : UInt16 :=
  match s.toNat? with
  | some n => if n > 0 && n <= 65535 then UInt16.ofNat n else defPort
  | none => defPort

def main : IO Unit := do
  let ca   ← envOr "MIRROR_CA" "ca.crt"
  let cert ← envOr "MIRROR_CERT" "client.crt"
  let key  ← envOr "MIRROR_KEY" "client.key"
  let host ← envOr "MIRROR_HOST" "127.0.0.1"
  let port := parsePort (← envOr "MIRROR_PORT" "8443") 8443
  let pin? ← IO.getEnv "MIRROR_CERT_SHA256"
  let cfg : ServerMode.TlsClientConfig :=
    { caFile := ca, certFile := cert, keyFile := key, expectedCertSha256 := pin? }

  let t ← match ← IO.getEnv "MODELMIRRORS_REGISTRY" with
    | some reg => do
        IO.println s!"mirrorlean: discovering candidates from {reg}"
        ServerMode.connectMirrorDiscovered cfg reg
    | none => do
        IO.println s!"mirrorlean: connecting directly to {host}:{port} (TLS 1.3 mTLS)"
        ServerMode.connectMirrorTls cfg host port

  match ← runClient
    (.transport t)
    { specPath := "specs/Counter.tla", invariant := "TraceComplete",
      lengthBound := 6, constInit := some "CInit", paramVars := some "parameters" }
    { numTraces := 10, view := some "View" }
    (← counterComputer)
  with
  | .ok () => IO.println "all traces replayed over mTLS: implementation matches the model"
  | .error e =>
      IO.eprintln s!"conformance failed: {MirrorError.toString e}"
      IO.Process.exit 1
