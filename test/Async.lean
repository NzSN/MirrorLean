import test.AsyncSupport

open MirrorLean

def main : IO Unit := do
  AsyncTests.frames
  AsyncTests.vectors
  if let some binary ← IO.getEnv "MIRROR_BIN" then
    let port := UInt16.ofNat (20000 + (← IO.monoMsNow) % 20000)
    let server ← IO.Process.spawn { cmd := binary, args := #["--serve", toString port, "--bind", "127.0.0.1", "--jobs", "4"], stdin := .null }
    try
      IO.sleep 400
      AsyncTests.live (connectMirror "127.0.0.1" port)
    finally
      server.kill
      let _ ← server.wait
  IO.println "ASYNC CLIENT CONFORMANCE GREEN"
