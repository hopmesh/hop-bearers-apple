# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### CI
- bump create-github-app-token to v3.2.0 across all mirrored components (efc9f6c)
- per-repo release workflows (publish on a vX.Y.Z tag) (277cf32)

### Chore
- drop the root license, license per-component (FSL-1.1-ALv2) (#146) (be2a5a7)
- finish the monorepo layout, kill platform stubs, unify the platform axis (O-1/O-3/O-4/O-5) (#115) (b56bb49)

### Documentation
- branded, marketable READMEs for every sub-repo (9c2a477)

### Other
- CLA gate on contributions (preserve commercial relicensing of core) (5a9aa7d)
- SECURITY.md per component + enable-security in the bootstrap script (a1492e9)
- copyright holder is Hop Mesh, LLC (7d8c514)
- fill the Apache-2.0 copyright placeholder (2026 Jason Waldrip) (2fb7d1c)
- Apache-2.0 for everything except core/ (only the protocol stays FSL) (0fe9439)
- CHANGE_REQUEST sync-back + document merge/conversation + confidentiality (9e1dec2)
- route dedup through the pure keep-rule cores; fix inverted Android dedup-ordering docs (#72) (8a083a1)
- strip em-dashes from this session's Apple coverage test files (#67) (f11147f)
- split into HopContract (no libhop) + Hop (libhop node) — unblocks the app cutover (7f0eeb3)
- rename sdk/wrappers/swift -> sdk/wrappers/Hop (clean SwiftPM package id) (ee6245c)
- re-home all four bearers as independent packages on the Hop SDK (05124fe)

### Refactor
- enforce purpose/platform/package (collapse sdk/wrappers, apps/web -> apps/web/site) (#116) (afd52df)

### Testing
- seam refactor takes BleBearer 7% → 97% (CB-free cores), replace shadow tests (#69) (36f184b)
- real loopback integration tests for LAN + Relay bearers to >=80% coverage, CI gating, compile-bug root cause (#63) (c53d864)

