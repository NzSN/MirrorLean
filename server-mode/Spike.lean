import Std

/-!
# MirrorLean server-mode — Phase 0 spike

Throwaway executable proving the build mechanics
(plans/server-mode.md §6 Phase 0) before any real TLS code:

* `@[extern]` declarations resolved against `native/spike.c`,
* the C object linked via `moreLinkObjs` with `-lssl -lcrypto`,
* Lean `String` / `ByteArray` <-> C ABI,
* error-buffer marshalling for `IO`-style externs.

Known test vector: SHA-256 of `"abc"` is
`ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad`.
-/

-- OpenSSL version string; proves `-lssl -lcrypto` are linked and used.
@[extern "mirrorlean_spike_openssl_version"]
opaque opensslVersion : IO String

-- SHA-256 of a `ByteArray` as lowercase hex (ByteArray -> C -> String).
@[extern "mirrorlean_spike_sha256_hex"]
opaque sha256Hex (data : ByteArray) : IO String

-- SHA-256 of a `ByteArray` returned as raw bytes (C -> ByteArray).
@[extern "mirrorlean_spike_sha256_bytes"]
opaque sha256Bytes (data : ByteArray) : IO ByteArray

-- UTF-8 `String` roundtrip (String -> C -> String).
@[extern "mirrorlean_spike_echo"]
opaque spikeEcho (s : String) : String

-- Error-buffer marshalling: `fail=false` echoes `msg`; `fail=true` raises
-- an IO error whose message was formatted in a C caller-provided buffer.
@[extern "mirrorlean_spike_io_demo"]
opaque spikeIoDemo (fail : Bool) (msg : String) : IO String

/-- Compare two strings, printing a PASS/FAIL line; returns success. -/
def check (label : String) (actual expected : String) : IO Bool := do
  if actual == expected then
    IO.println s!"PASS  {label}"
    pure true
  else
    IO.println s!"FAIL  {label}: expected {repr expected}, got {repr actual}"
    pure false

def main : IO UInt32 := do
  IO.println "MirrorLean server-mode Phase 0 spike"
  IO.println "-------------------------------------"
  let mut ok := true

  -- 1. OpenSSL actually linked and used (the symbols are referenced).
  let ver ← opensslVersion
  IO.println s!"      OpenSSL version: {ver}"
  ok := ok && (← check "opensslVersion non-empty" (if ver.isEmpty then "" else "x") "x")

  -- 2. ByteArray -> C -> hex String over a known test vector.
  let abcSha256 := "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  let hex ← sha256Hex "abc".toUTF8
  ok := ok && (← check "sha256Hex(\"abc\")" hex abcSha256)

  -- 3. C -> ByteArray (raw digest); verify the exact 32 bytes match the
  --    known SHA-256 of "abc" (independent of the hex path).
  let raw ← sha256Bytes "abc".toUTF8
  ok := ok && (← check "sha256Bytes size" (toString raw.size) "32")
  let abcDigest : ByteArray := ByteArray.mk
    (#[0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
      0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
      0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
      0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad] : Array UInt8)
  let sameBytes : Bool := (List.range 32).all (fun i => raw[i]! == abcDigest[i]!)
  ok := ok && (← check "sha256Bytes content" (if sameBytes then "match" else "mismatch") "match")

  -- 4. String roundtrip with non-ASCII UTF-8, length preserved.
  let echo := spikeEcho "héllo→世界"
  ok := ok && (← check "spikeEcho UTF-8 roundtrip" echo "héllo→世界")
  ok := ok && (← check "spikeEcho length" (toString echo.length) "8")

  -- 5. Error-buffer marshalling: success path echoes, failure path raises.
  let rOk ← spikeIoDemo false "hello buffer"
  ok := ok && (← check "ioDemo success echoes" rOk "hello buffer")
  try
    let _ ← spikeIoDemo true "boom"
    IO.println "FAIL  ioDemo error path: no exception raised"
    ok := false
  catch e =>
    let msg := toString e
    IO.println s!"      error surfaced as: {msg}"
    ok := ok && (← check "ioDemo error message markers"
      (if msg.contains "boom" && msg.contains "code=42" then "ok" else msg) "ok")

  IO.println "-------------------------------------"
  if ok then
    IO.println "SPIKE RESULT: ALL PASS"
    pure 0
  else
    IO.println "SPIKE RESULT: FAILURES"
    pure 1
