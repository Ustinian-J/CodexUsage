# Changelog

## Unreleased

## 0.1.0 - 2026-07-15

- Created the independent `CodexUsage` macOS app and `com.ustinianj.codexusage` bundle identity.
- Imported a source-only allowlist from audited `shanggqm/codexU` commit `cc800ff7afa254237fd088cb63004390d6492a99` while excluding upstream Git history, automation metadata, credential-bearing notarization helpers, and release-remote scripts.
- Added a hash-backed upstream security audit and local-first data boundary documentation.
- Disabled automatic update checks by default and pointed manual GitHub Release checks to `Ustinian-J/CodexUsage`.
- Added a least-privilege dual-architecture GitHub Actions build for Intel and Apple Silicon: official actions pinned to full verified commits, `contents: read`, no secrets, self-tests, DMG verification, and SHA-256 artifact output.
- Added an automated CI supply-chain policy test that rejects floating action tags, unapproved actions, secret references, and excluded release credential paths.
- Added heuristic daily conversation progress above the task board, excluding recurring automations and exposing the calculation in the JSON probe.
- Added quota pace guidance that compares elapsed window time with used quota and reports roomy, on-pace, or fast without inventing an absolute allowance.
- Added opt-in macOS local notifications at 20%, 10%, and 5% remaining, deduplicated per quota reset cycle and containing no conversation or path data.

## Upstream Heritage

The initial UI, local Codex/Claude readers, token aggregation, task board, menu bar renderer, packaging foundation, and existing self-tests derive from the MIT-licensed upstream project. Detailed provenance is recorded in [UPSTREAM.md](UPSTREAM.md) and [docs/SECURITY_AUDIT.md](docs/SECURITY_AUDIT.md).
