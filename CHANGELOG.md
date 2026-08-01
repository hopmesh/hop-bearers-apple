# Changelog

Notable changes, generated from [conventional commits](https://www.conventionalcommits.org) by
git-cliff. Do not edit by hand.
## Unreleased

### Bug Fixes
- per-mirror repository, and retryable release artifacts (bf04449)
- make the PLAT-001 tests actually run, and correct what the last commit claimed (15065c8)
- disabling a transport now actually stops it (PLAT-001) (7b84c71)
- kill the LAN reap-test flake by pinning the ordering (a16a715)

### CI
- bump create-github-app-token to v3.2.0 across all mirrored components (efc9f6c)
- per-repo release workflows (publish on a vX.Y.Z tag) (277cf32)

### Chore
- purge em-dashes and en-dashes from source (d222435)
- drop the root license, license per-component (FSL-1.1-ALv2) (#146) (be2a5a7)
- finish the monorepo layout, kill platform stubs, unify the platform axis (O-1/O-3/O-4/O-5) (#115) (b56bb49)

### Documentation
- regenerate from conventional commits (2741000)
- regenerate from conventional commits (b96e019)
- regenerate from conventional commits (330c8c6)
- regenerate from conventional commits (096180b)
- regenerate from conventional commits (102ae67)
- regenerate from conventional commits (1572ae2)
- regenerate from conventional commits (a355901)
- branded, marketable READMEs for every sub-repo (9c2a477)

### Features
- finish inbound (import), drop export_pr (41c095e)
- auto-generate monorepo + per-library changelogs (git-cliff) (8c64c37)

### Other
- extract Multipeer so EVERY bearer registers with the manager (f3949f7)
- cut the frame cap to the protocol's, and pin it (2a16945)
- Apple was resetting the dial backoff at the wrong moment (f94599f)
- wire the relay pool end to end, and stop the wire guard false-firing (35946e0)
- fix Apple's dial backoff and pin the schedule across platforms (54f6f02)
- de-flake the LAN pending-cap test (hold the no-HELLO reaper) (8497488)
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

