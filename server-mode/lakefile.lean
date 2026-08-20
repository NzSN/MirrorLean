import Lake
open Lake DSL
open System (FilePath)

/-!
# server-mode package (MirrorLean server-mode)

This is a **separate top-level package** — the Phase 0 decision from
`plans/server-mode.md` §6 / D2.

Why separate: Lake 5.0.0 TOML configuration files cannot declare native/C
targets. The TOML decoders only handle `lean_lib`, `lean_exe`, `input_file`,
and `input_dir`, and both `extern_lib` and custom `target` declarations (plus
`nativeFacets`) are Lean-DSL-only. There is no supported way to mix
`lakefile.lean` and `lakefile.toml`. So the plan's primary option ("optional
root module in lakefile.toml") is not expressible in this Lake version, and
we take the plan's documented fallback: a separate top-level package.

Consequence (the important one): the root `lakefile.toml` stays
**byte-identical**, so the baseline `lake build` / `lake build test` /
`smoke` targets can never accidentally gain an OpenSSL dependency. Server
mode is opt-in at build time: `cd server-mode && lake build`.

Phase 0 spike contents:
  * `native/spike.c`  — throwaway FFI shim (String / ByteArray / OpenSSL)
  * `Spike.lean`      — `@[extern]` declarations + self-checking `main`
  * `lakefile.lean`   — custom `target` for the C object + `-lssl -lcrypto`

Phase 1+ will grow this package into the real server-mode module
(`MirrorLean/ServerMode.lean`, `native/mirrorlean_tls.c`), with this
package requiring the root `mirrorlean` package by path.
-/

package "mirrorlean-server-mode"

/--
Compile `native/spike.c` into an object file.

This is the pattern Phase 1+ will reuse for `native/mirrorlean_tls.c`:
a custom `target` producing object files, attached to `lean_exe` /
`lean_lib` targets via `moreLinkObjs`, with `-lssl -lcrypto` supplied via
`moreLinkArgs`. (`extern_lib` is deprecated in Lake 5; the README
recommends custom targets + `moreLinkObjs` / `moreLinkLibs`.)
-/
target native_spike (pkg : NPackage __name__) : FilePath := do
  let lean ← getLeanInstall
  let oFile : FilePath := pkg.buildDir / "native" / "spike.o"
  let srcJob ← inputFile (pkg.dir / "native" / "spike.c") false
  -- The shim needs BOTH Lean's headers (`lean/lean.h`) and system headers
  -- (`<openssl/...>`, libc). The toolchain's bundled clang builds with
  -- `-nostdinc` (no system include dirs), so we use the system `cc`, which
  -- searches `/usr/include` by default, and add Lean's include dir on top.
  buildFileAfterDep oFile srcJob fun src => do
    compileO oFile src #["-I", lean.includeDir.toString, "-fPIC"] "cc"

/--
Spike executable: proves the build mechanics end to end.

* `@[extern]` symbols resolved against `native/spike.c`,
* the C object linked into the executable,
* `-lssl -lcrypto` actually used (the shim calls OpenSSL),
* Lean `String` / `ByteArray` <-> C ABI and error-buffer marshalling.
-/
@[default_target]
lean_exe spike where
  root := `Spike
  moreLinkObjs := #[`@/native_spike]
  moreLinkArgs := #["-lssl", "-lcrypto"]
