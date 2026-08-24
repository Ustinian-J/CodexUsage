# Changelog

## Unreleased

## 0.4.1 - 2026-08-24

- Fixed a stuck red task light by reconciling orphaned local starts only after the rollout has been quiet for 30 seconds and two bounded checks confirm that no process still holds it open.
- Stopped hidden runtimes from scanning their local data sources during background refreshes.
- Restricted Skill static-file inspection to approved roots, regular files, and a 1 MiB size limit, and moved opt-in debug logging to a symlink-safe per-user temporary file.
- Hardened local and SSH task monitoring with remote-clock replay watermarks, bounded streaming parsers, baseline-only stale-start filtering, fixed Windows OpenSSH resolution, and recoverable malformed-record handling.
- Decoupled Windows daily task progress from the 50-item notification list so full same-day baseline history is counted without generating old alerts.
- Removed unreachable update/menu components, obsolete JSON serialization helpers, and the legacy CodexUsage icon; macOS resources now use an explicit packaging allowlist.
- Renamed the GitHub repository identity and update endpoint from `Ustinian-J/CodexUsage` to `Ustinian-J/CodexS` while preserving bundle IDs, settings keys, cache paths, and legacy asset matching for upgrades.

## 0.4.0 - 2026-08-10

- Added opt-in SSH task monitoring on macOS and Windows using aliases from the user's existing OpenSSH config.
- Added a long-lived, read-only remote event stream that parses rollout files on the remote host and returns only start, completion, interruption, project, thread-title, ID, and timestamp metadata.
- Added per-host recovery checkpoints, reconnect handling, remote-source labels, and conservative unavailable state so a disconnected remote source cannot appear idle.
- Added remote-host controls to Mac Settings and the Windows dashboard without storing passwords, keys, Codex credentials, prompts, responses, or tool output.
- Extended the source and CI security policies to allow only the reviewed system SSH launch with host validation, batch authentication, strict host-key checking, and a fixed remote parser.

## 0.3.0 - 2026-08-09

- Renamed the user-facing app, executable, installer, and release repository identity to CodexS (Codex Secretary) while preserving the existing bundle ID, settings keys, notification identifiers, and cache paths for upgrade compatibility.
- Added local Codex task monitoring from rollout start, completion, and interruption events while ignoring and never retaining final-response text.
- Added a fixed-width task state badge with red/play running, green/check idle, gray/dash unavailable, and an independent blinking amber unread marker, including live Reduce Motion behavior and accessible text.
- Added a polished task-activity card with running/unread counts, recent outcomes, review actions, and “Mark all read”.
- Added optional native task-completion alerts, checkpointed cold-start recovery, copied-event deduplication, subagent filtering, partial-line handling, legacy SQLite schema fallback, and periodic stale-running recovery.
- Standardized 5h and 7d quota identity colors across the menu bar and popover for faster comparison.
- Added a native Windows x64 tray build with the same quota/token/task semantics, local completion alerts, a polished dashboard, per-user single-EXE install/uninstall, and no third-party runtime packages.

## 0.2.3 - 2026-07-16

- Replaced the ambiguous runtime-specific open command with “Open Main Window”.
- Removed version checking from the compact menu bar popover while keeping update controls in Settings.
- Added a polished account-cycle card with separate 5h and 7d next-reset rows above reset-credit information.
- Increased the popover height and kept the footer controls on one unclipped row.

## 0.2.2 - 2026-07-15

- Changed the menu bar default from used quota to remaining quota.
- The numeric percentage and progress fill now represent remaining quota by default, like a battery indicator, without adding extra label text.
- Added a subtle capsule background and stronger outline around every menu bar display mode so CodexUsage has a clear boundary from adjacent apps.

## 0.2.1 - 2026-07-15

- Changed the menu bar popover to show exactly one selected runtime at a time, with an explicit Codex / Claude Code selector.
- Removed the cross-runtime token total from the menu bar popover so Codex and Claude Code remain clearly separated.
- Restricted reset-credit, account-cycle, and locally configured subscription details to the Codex view.
- Hidden subscription expiry everywhere until a date is explicitly configured on the local Mac.

## 0.2.0 - 2026-07-15

- Added official reset-credit monitoring from `rateLimitResetCredits`, including the available reset count and every backend-provided expiry time.
- Added a dedicated account-cycle dashboard for 5-hour and 7-day reset timestamps, reset-credit details, plan type, and subscription expiry.
- Added an opt-in, local-only subscription expiry date because the current Codex `account/read` schema does not expose a subscription expiry field.
- Added a compact reset/subscription summary directly to the menu bar popover.
- Added parser, persistence, and calendar-day self-tests for reset credits and subscription expiry.

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
