# MirrorLean product versions and Mirrors compatibility

This repository adopts the [Mirrors ecosystem version policy](https://github.com/NzSN/Mirrors/blob/main/Docs/ecosystem-versioning.md).

Its public contract is: Public Lean modules/declarations, client behavior and generated-binding integration.

The initial 0.1 compatibility release uses Git tag `v0.1.0`. Compatible fix
releases use this repository's own `v0.1.x` sequence. Before 1.0, compatible
fixes increment PATCH; features or breaking changes increment MINOR, with
migration notes for breaking changes. After 1.0, incompatible supported usage
increments MAJOR, compatible additions/deprecations increment MINOR, and
compatible fixes increment PATCH. Runtime/compiler/platform requirements are
part of the supported contract.

The selected Mirrors `v0.1.0` baseline is the unchanged source commit
`ea8091c0c723f3f561044a5c1efb91d12e7aaf5f`. Its embedded executable version
remains `v0.0.3.2`; the release tag and exact commit establish this one-time
baseline alias. Future ordinary releases must align product metadata and tags.

`mirrors-compatibility.json` records the tested server/profile scope and
evidence. Matching version numbers do not establish interoperability by
themselves. Wire/schema/profile versions and exact semantic digests remain
independent. A generated target or Gate backend that was not exercised is not
implied by the component tag. Live model operations and full framework
qualification remain separate from supplied-trace compatibility.

Published historical source/package versions are not silently reinterpreted.
This user-requested Git release-line reset does not publish or overwrite
packages in npm, crates.io, or another package registry.
