# MirrorLean — remaining jobs

Recorded: 2026-08-18. See plans/status.md for what is done; docs/design.md is the spec.

## J1 — M3: MirrorLean/Spec.lean (spec closure walk) — DONE
- specFromFile / specFromFiles per design section 7 (port of MirrorECMA/src/spec.ts)
- Hand-written TLA+ scanner (NO regex module in Lean 4.33):
  - strip \\* line comments and (* ... *) block comments (nested), full char scan
  - find EXTENDS / INSTANCE keywords at line start (possibly indented)
  - split module list on commas; first whitespace-delimited token per entry; drop WITH substitutions
- Builtins never resolved as files: Naturals, Integers, Reals, Sequences, FiniteSets, TLC, Bags, Apalache
- Lookup order for Name.tla: importing file's directory, then searchDirs (default: TLA_LIBRARY_PATH, colon-separated)
- Ambiguity (same module name resolving to different files in more than one directory) is an error
- Output ApalacheSpec with the root source first; SpecError { msg : String; contexts : Array String }
- Verified: 115 tests / 0 failures; real smoke (d) register_explore + (e) explore-session PASS

## J2 — M3: MirrorLean/Transport.lean — connectMirror (TCP) — DONE
- def connectMirror (host : String) (port : UInt16) : IO Transport
- Std.Async.TCP.Socket.Client (mk/connect/send/recv?/shutdown); bridge the Async monad to IO with .block
- recv = buffered line reader over Client.recv? 4096: accumulate bytes, split on \n, strip trailing \r, none on EOF/zero-byte reads
- send writes line + \n as ByteArray; close = shutdown, exit code 0
- Verified: TCP loopback unit test in test/Main.lean (in-process Std.Async.TCP server, canned lines in order)

## J3 — M3: tests (test/Main.lean, 102 -> 115, all green) — DONE
- Spec closure tests: fixtures under test/fixtures/ (root + EXTENDS chain + INSTANCE ... WITH + builtin refs + TLA_LIBRARY_PATH lookup + ambiguity error)
- Explore reply decode tests: fixture JSON for explorer_ready and every explore_* reply -> correct MirrorMessage constructors
- TCP loopback test: in-process Std.Async.TCP server on 127.0.0.1, ephemeral port; accept one connection; serve canned spec_validated/initial_state/all_steps_done; drive connectMirror; assert lines in order

## J4 — M3: smoke additions (test/Smoke.lean, same MIRROR_BIN gating) — DONE
- (c) runClientValidate with counterCfg, bound 3 -> ok; invariant NoSuchInvariant -> register_error -> registerFailed
- (d) runClientExplore + (e) scripted ExploreSession walk (start -> assumeTransition 0 -> nextStep -> queryState -> checkInvariant 0 -> rollback 0 -> done)
- (d)/(e) run against specs/CounterExplore.tla (constant-free twin of Counter.tla): apalache explorer has no cinit, so specs with CONSTANTS fail in the explorer (mirror docs/apalache/interactive.md "CONSTANTS and CInit")
- Compile clean; skip path stays green when MIRROR_BIN unset; real smoke run:
  export PATH="$HOME/.elan/bin:$HOME/.local/bin/apalache/bin:$PATH"
  export MIRROR_BIN=/home/nzsn/Repos/ModelMirros/dist-newstyle/build/x86_64-linux/ghc-9.14.1/ModelMirrors-0.1.0.0/x/ModelMirrors/build/ModelMirrors/ModelMirrors
  .lake/build/bin/smoke
  -> (a)-(e) all PASS, "smoke: all checks passed"
## J5 — M4: polish — DONE
- MirrorError.toString format test (stepMismatch carries action/params/hints; empty expected/actual + no hints -> invariant violation reported by the mirror) — DONE (test/Main.lean section 7, 115 green)
- README.md full rewrite modeled on MirrorECMA README: architecture diagram, Counter quick start, full API listing, three oracle modes, build/test instructions, MIRROR_BIN gating, ExploreSession.start naming note — DONE
- LICENSE (ISC), .gitignore (.lake/, build/, *.olean, *.ilean, leanpkg.path, *.c, *.o, .agent-teams/, _apalache-out/), .github/workflows/ci.yml (elan pinned v4.33.0; lake build; test exe; smoke exe self-skips) — DONE
- Final self-review vs design sections 5-9 (public names exported via MirrorLean.lean umbrella, wire tables 5.5/5.6 match) — DONE
- Clean build: export PATH="$HOME/.elan/bin:$PATH"; rm -rf .lake/build && lake build && lake build test && .lake/build/bin/test -> 115 tests, 0 failures; smoke rebuilt and (a)-(e) PASS against the real mirror

## Server-mode: phases 0–5 COMPLETE (see plans/status.md)

All six server-mode plan phases (0–5) are done and verified: separate
`server-mode/` package (C shim + exes), TLS 1.3 mTLS transport
(`connectMirrorTls`), Consul discovery (`discoverMirrors`, fail-closed),
pinned discovery (`connectMirrorDiscovered`), full test matrix T1–T15
(loopback 15 checks, stub-registry 13 tests, real E2E flows (a)–(e) over
mTLS, CONSUL_BIN-gated real Consul, MIRROR_BIN-gated smoke), and a CI
`server-mode` job with the baseline job explicitly exercising the
no-server-mode build.

### Follow-ups (deliberately out of v1, documented in README/design)
- `https://` registry URLs (v1 is plain HTTP; mTLS + cert-sha256 pinning
  remain the trust boundary — a registry can only cause DoS, never bypass).
- IPv6 literal parsing in `parseRegistryUrl` (`[::1]:8500` is rejected;
  the TLS connect itself supports IPv6 hosts via getaddrinfo AF_UNSPEC).
- macOS/Homebrew OpenSSL build validation (CI pins Ubuntu OpenSSL 3;
  Linux-first per plan §10).
- Running the CONSUL_BIN-gated T14 test in CI with a real Consul agent
  (CI currently uses the stub registry by design).

## Project status: COMPLETE — all jobs J1-J5 done; server-mode phases 0–5 done; see plans/status.md


