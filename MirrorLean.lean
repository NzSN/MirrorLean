import MirrorLean.Value
import MirrorLean.Error
import MirrorLean.Protocol
import MirrorLean.Transport
import MirrorLean.Client
import MirrorLean.Spec
import MirrorLean.Async

/-!
# MirrorLean

Umbrella module for the MirrorLean Lean 4 client library for the
ModelMirrors protocol. Re-exports the full public surface:

* `MirrorLean.Value` — the ITF `Value`/`State` model and codecs
* `MirrorLean.Error` — `DiffHint`/`PathSeg`/`MirrorError` and renderers
* `MirrorLean.Protocol` — configs, `ClientMessage`/`MirrorMessage`, codecs
* `MirrorLean.Transport` — stdio + TCP transports (send / recv / close),
  `spawnMirror`, `connectMirror`, `Target`
* `MirrorLean.Spec` — spec source closure walk (`specFromFile`/`specFromFiles`)
* `MirrorLean.Client` — `StateComputer`, replay / gen-traces / validate loops,
  `ExploreSession`, entry points
-/

namespace MirrorLean

end MirrorLean
