# MirrorLean server-mode — Phase 0 spike results (build mechanics)

- Status: **done** (Phase 0 of `plans/server-mode.md`)
- Date: 2026-08-20
- Deliverable: `server-mode/` (separate top-level package): `lakefile.lean`,
  `Spike.lean`, `native/spike.c`; spike executable `server-mode/.lake/build/bin/spike`.

## 1. Lake structure decision (D2)

**Decision: separate top-level package `server-mode/`** — the documented
fallback in `plans/server-mode.md` §4 D2. The root `lakefile.toml` is
**byte-identical** to before this phase (`git diff` empty); the baseline
`lake build` / `lake build test` / `smoke` targets are untouched and cannot
accidentally gain an OpenSSL dependency.

Why the primary option was rejected, verified against the Lake 5.0.0 source
(`<lean-sysroot>/src/lean/lake/`):

- The TOML config decoders (`Lake/Load/Toml.lean` `decodeTargetDecls`) only
  handle `lean_lib`, `lean_exe`, `input_file`, `input_dir`. Native/C targets
  (`extern_lib`, custom `target`, and the `nativeFacets` field) are
  **Lean-DSL-only**; `nativeFacets` is explicitly excluded from the TOML
  decoders.
- There is no supported `lakefile.lean` + `lakefile.toml` mix: if both exist,
  Lake uses `lakefile.lean` and ignores the TOML
  (`Lake/Load/Package.lean` `resolveConfigFile`), and there is no
  `import lakefile.toml` mechanism in the loader.
- `extern_lib` is deprecated in Lake 5 in favour of custom `target` +
  `moreLinkObjs` / `moreLinkLibs` (Lake README), which is what the spike uses.

Phase 1+ consequences: `MirrorLean/ServerMode.lean` and
`native/mirrorlean_tls.c` live in `server-mode/`; the package then `require`s
the root `mirrorlean` package by path to reuse `Transport` / `Error` /
`Client`. Server-mode tests/examples also live under `server-mode/` (the root
`test/`/`examples/` stay baseline-only). Build: `cd server-mode && lake build`.

## 2. Lake 5.0.0 mechanics validated

- Custom native target: `target native_spike (pkg : NPackage __name__) : System.FilePath := do ...`
  (use `__name__`, not the deprecated `_package.name`; `open System (FilePath)`).
- Input tracking: `let srcJob ← inputFile (pkg.dir / "native" / "spike.c") false`
  (returns `SpawnM (Job FilePath)`; lifts into `FetchM`).
- Build helper: `buildFileAfterDep oFile srcJob fun src => do compileO oFile src args compiler`
  — the target body's last expression is the `Job FilePath` (no trailing `pure`).
- Linking: `lean_exe spike where root := \`Spike; moreLinkObjs := #[`@/native_spike]; moreLinkArgs := #["-lssl", "-lcrypto"]`.
- `@[default_target]` on the spike exe makes `lake build` in `server-mode/` build it.
- The executable's `main` must be **top-level** in the root module (a
  `namespace` wrapper makes it `Spike.Spike.main` and the link fails with
  `undefined symbol: main`).
- C compile recipe: use the **system `cc`** with `-I <lean includeDir>` and
  `-fPIC`. The toolchain's bundled clang is unusable for system headers here:
  Lake passes it `-nostdinc -isystem <lean include dirs>`, so
  `<openssl/...>` / libc headers are not found. (`leanc` is the same bundled
  clang.) Phase 1 could alternatively add `-isystem /usr/include` etc. to the
  bundled clang; system `cc` was simplest and works.
- Package naming: hyphenated package names need the string form
  `package "mirrorlean-server-mode"`.

## 3. Lean ↔ C ABI findings (verified against generated C)

- **`@[extern]` IO functions**: Lean 4.33 does **not** use the old
  `lean_obj_arg *out` convention. Generated C declares e.g.
  `lean_object* mirrorlean_spike_sha256_hex(lean_object* data);` — the
  function returns the **IO result object** directly:
  `lean_io_result_mk_ok(v)` or `lean_io_result_mk_error(e)`.
  Zero-arg IO externs are `lean_object* f(void)`.
- Error payloads must be real `IO.Error` objects: use
  `lean_mk_io_user_error(lean_mk_string(buf))` (the runtime helper for
  `IO.Error.userError`, i.e. what `IO.userError` throws). A bare String
  payload hangs the exception handler.
- `Bool` is passed **unboxed** (`uint8_t`); `String` via
  `lean_string_cstr` / `lean_mk_string_from_bytes`; `ByteArray` via
  `lean_sarray_size` / `lean_sarray_cptr`, constructed with
  `lean_alloc_sarray(1, n, n)` + `memcpy` (pattern for Phase 1
  `peer_cert_sha256`).
- Pure externs (`: String`) return the value object directly.

## 4. Critical finding: Lean 4.33 already links `-lssl -lcrypto` for **every** executable

The toolchain's default link flags (`leanc --print-ldflags`, and visible in
every `.rsp` Lake generates) contain:

```
-Wl,--as-needed -Wl,-Bstatic -lgmp -lunwind -luv -lssl -lcrypto -Wl,-Bdynamic
... -Wl,--as-needed ... -lssl -lcrypto ...
```

**The Lean 4.33 toolchain BUNDLES its own `libssl.a` / `libcrypto.a`
(OpenSSL 3.6.0) in `<lean-sysroot>/lib/`** (the link line's `-L <sysroot>/lib`
comes before any system dir, so `-Bstatic -lssl` resolves to the bundled
static library — the Phase 0 spike's binary statically embeds OpenSSL 3.6.0).
Verified semantics (lld 22.1.4, the linker Lake uses):

- When no OpenSSL symbols are referenced, `--as-needed` drops the library:
  baseline binaries have **no libssl/libcrypto in DT_NEEDED** (`ldd` clean)
  and no OpenSSL symbols. The link succeeds using only the toolchain's own
  `-L` dirs — **system OpenSSL dev files are NOT needed to link any Lean 4.33
  executable** (verified by linking a baseline-style binary with only the
  toolchain's `-L` dirs on the search path).
- The toolchain bundles NO OpenSSL headers (`<sysroot>/include` has only
  `lean/` and `clang/`), so compiling our own C shim (`native/mirrorlean_tls.c`)
  is the only place **system `libssl-dev` headers** are required — and that is
  exactly the opt-in server-mode path.

Consequence: the plan's T1 gate "baseline green with no `libssl-dev`" holds
for real — the baseline needs no OpenSSL headers, no system OpenSSL libraries,
and has no OpenSSL in its binaries; the root build config is unchanged. Only
the opt-in server-mode targets need `libssl-dev` (headers) at build time.
The CI baseline job is unaffected.

## 5. Verification (all green)

```
# baseline (root, lakefile.toml untouched; git diff empty)
lake build && lake build test && lake build smoke
.lake/build/bin/test            # 115 tests, 0 failures
.lake/build/bin/smoke           # self-skips without MIRROR_BIN
ldd .lake/build/bin/{test,smoke}   # no libssl/libcrypto

# spike (opt-in)
cd server-mode && lake build
.lake/build/bin/spike           # SPIKE RESULT: ALL PASS (exit 0)
  # - OpenSSL version string via libssl
  # - SHA-256("abc") hex + raw 32-byte digest via libcrypto EVP
  # - UTF-8 String roundtrip with length preserved
  # - error-buffer marshalling: C buffer -> IO.Error.userError surfaced in Lean
nm server-mode/.lake/build/bin/spike | grep EVP_sha256   # statically linked
```

## 6. Pointers for Phase 1 (`connectMirrorTls`)

- Reuse the `native_spike` custom-target pattern for `native/mirrorlean_tls.c`
  (rename target; keep `moreLinkObjs` + `moreLinkArgs` on the server-mode
  library/exe targets).
- C-side error API: internal helpers take `char *errbuf, size_t errbuf_len`
  (OpenSSL `ERR_error_string_n`); at the boundary wrap with
  `lean_mk_io_user_error(lean_mk_string(errbuf))` — do **not** return bare
  strings as IO error payloads.
- The peer-certificate digest flow (`SSL_get_peer_certificate` +
  `X509_digest` → 32 bytes) maps directly onto the spike's
  `sha256_bytes` ByteArray pattern.
- Note the `-Bstatic -lssl` toolchain pair statically links OpenSSL into
  executables when `libssl.a` is present; keep the explicit `moreLinkArgs`
  anyway for portability to systems where only the shared libs exist.
