# CodexS

CodexS (Codex Secretary) is a local-first macOS menu bar and Windows tray app. It shows remaining Codex 5-hour and weekly quota as rings/two bars, tracks today/7-day/lifetime tokens, reports running and completed task activity, and builds a daily task board from local Codex conversations and automations.

> The current version is `0.4.2`. The [project repository](https://github.com/Ustinian-J/CodexUsage) is verified on clean GitHub Intel and Apple Silicon macOS runners. Until a Release is published, install only from source or from this repository's own CI artifact.

## Features

- Live 5-hour and 7-day quota rings with the remaining percentage in each ring.
- A single menu-bar state badge: red/play means running, green/check means idle, and gray/dash means unavailable. Unread completion is an independent blinking amber diamond, so running and unread remain visible together. The popover retains labeled red/yellow/green lights.
- Incremental local Codex task monitoring, optional native completion/interruption notifications, and a “Mark all read” action that clears yellow attention.
- Optional SSH task monitoring on macOS and Windows. Add aliases from `~/.ssh/config` and enable automatic remote monitoring. On macOS, CodexS first reuses a live OpenSSH control connection through a user-only temporary link, avoiding another jump-host MFA challenge; it opens an isolated, non-persistent connection only when no reusable connection exists. Reconnects back off through 10 seconds, 30 seconds, 1 minute, 2 minutes, and a 5-minute cap. Turning the switch off stops CodexS-owned channels and retries without closing a reused connection.
- Reset countdowns, used/remaining display modes, and multiple menu bar densities.
- Today, last-7-days, and lifetime token totals with uncached input, cached input, and output splits.
- A daily task board derived from local Codex threads and enabled automations. Conversation progress is estimated as `archived today / today's conversation tasks`; automations are excluded from completion.
- Quota pace guidance compares elapsed window time with used quota and labels it roomy, on pace, or fast; it does not predict an absolute token allowance.
- Optional local alerts at 20%, 10%, and 5% remaining; off by default and emitted at most once per threshold per reset cycle.
- Official reset-credit count and per-item expiry from `rateLimitResetCredits.availableCount` and each backend-provided `expiresAt` value.
- An account-cycle dashboard for 5-hour and 7-day reset times, plan type, reset-credit details, and subscription expiry countdown.
- Opt-in local subscription-expiry tracking because the current official `account/read` schema does not expose that date; it is never uploaded.
- The menu bar popover switches directly between Codex and Claude Code and renders only one runtime at a time; Codex reset and account details never appear in the Claude Code view.
- The popover shows separate 5h and 7d next-reset rows plus only traffic-light state and running/unread counts; it does not show a task list. “Open Main Window” opens CodexS itself.
- Menu bar percentages and progress fills represent remaining quota by default, like a battery indicator; a capsule background and outline separate CodexS from adjacent status items.
- Subscription expiry is completely omitted until explicitly configured on the local Mac; the app neither queries the web nor infers a date.
- Usage trends, project rankings, and tool/Skill statistics.
- Optional local Claude Code statistics; hiding Claude Code in Settings stops background scans of `~/.claude`.
- `Command + U` shows or hides the main window by default.
- The Windows x64 build is a self-contained, dependency-free EXE with per-user installation; its tray icon uses the same two quota meters, task state badge, and unread marker as the Mac app.

## Security and Privacy

This repository does not fork upstream history. Source was imported through an explicit allowlist after auditing fixed upstream commit `cc800ff7afa254237fd088cb63004390d6492a99`. See [the upstream security audit](docs/SECURITY_AUDIT.md) and [UPSTREAM.md](UPSTREAM.md).

- No third-party Swift, npm, Python, CocoaPods, or precompiled framework dependencies.
- No access to `~/.codex/auth.json`, Keychain, browser cookies, or cloud credentials. When remote monitoring is enabled, system OpenSSH uses the existing configuration; CodexS never opens, copies, or stores SSH keys or passwords.
- No upload of usage, conversations, tasks, paths, or account data.
- Task monitoring extracts only the start, completion, and interruption fields it needs. If a log line contains `last_agent_message`, CodexS ignores it and never stores, displays, notifies, or uploads that text.
- Static Skill statistics read only regular `SKILL.md` files up to 1 MiB under approved local Skill roots; symlinks, non-regular files, and paths outside those roots are rejected.
- Debug logs are written only when `CODEXUSAGE_DEBUG=1` is explicitly set, under the system-provided per-user temporary directory, with symlink rejection and user-only file permissions.
- The only runtime internet request is an optional GitHub Release metadata `GET`; automatic checks are off by default.
- No silent update download, replacement, or execution.
- CI uses only official GitHub Actions pinned to full commit SHAs, `contents: read`, and no repository secrets.
- `test-source-security.sh` continuously rejects credential access, network writes, downloaders, login persistence, third-party dependency manifests, and precompiled libraries. SSH is allowed only in the reviewed remote-task monitor with fixed safety options.
- The remote parser runs only in memory for the SSH session, installs no service, writes no remote files, and returns only allowlisted task metadata—never prompts, response text, tool arguments/output, or `last_agent_message`.
- Low-quota alerts are delivered by the local macOS notification center and contain only the window, remaining percentage, and reset time.
- Task notifications are also local and contain only the outcome, never the title, project path, or conversation text.
- Every DMG is accompanied by a SHA-256 checksum.

A static audit materially reduces risk but cannot mathematically prove that software is harmless forever. Release builds are still compiled on a clean runner, architecture/signature checked, mounted and inspected, and hashed again. See [SECURITY.md](SECURITY.md) for reporting and the exact local data scope.

## Local Data Sources

CodexS reads local metadata from:

- Codex `app-server` account, quota, and usage responses.
- `~/.codex/state_5.sqlite` thread and token metadata.
- Token/tool metadata in local and archived Codex session JSONL files, plus task start, completion, and interruption events.
- Enabled automation metadata under `~/.codex/automations/`.
- Local usage/task metadata under `~/.claude/` only while the Claude Code runtime is visible.

For compatibility with earlier builds, CodexS keeps the `com.ustinianj.codexusage` bundle ID, `CodexUsage.*` settings keys, and `~/Library/Caches/CodexUsage/` cache directory. The app does not need or read Codex login tokens.

## Install

Download the matching DMG and checksum from GitHub Releases or a successful GitHub Actions run:

- Apple Silicon: `CodexS-<version>-mac-arm64.dmg`
- Intel: `CodexS-<version>-mac-x86_64.dmg`
- Windows x64: `CodexS-<version>-windows-x64.exe`

Verify before opening:

```sh
shasum -a 256 -c CodexS-<version>-mac-<arch>.dmg.sha256
```

On Windows, compare `Get-FileHash CodexS-<version>-windows-x64.exe -Algorithm SHA256` with the `.sha256` file, then double-click the EXE and choose install or one-time run.

Open the DMG and drag `CodexS.app` to `Applications`. If `CodexUsage.app` is already installed, remove it manually after confirming CodexS works so two apps with the same bundle ID do not coexist. Current personal test builds are ad-hoc signed, so Gatekeeper may require Finder **Right-click > Open** or **System Settings > Privacy & Security > Open Anyway** on first launch.

## Requirements

- macOS 13 or later.
- A local, signed-in Codex installation.
- Codex must have been used at least once so its local state database exists.
- Windows monitors native Windows Codex sessions and can also monitor Linux/macOS SSH hosts with Python 3. WSL-only sessions are not detected unless exposed through an SSH host alias.
- Remote hosts require strict known-host verification and Python 3. A macOS jump chain that requires MFA needs an already-live reusable OpenSSH control connection; batch mode cannot enter the code, so otherwise CodexS remains in its capped reconnect cycle.

## Build From Source

A version of Xcode or Xcode Command Line Tools compatible with the installed macOS SDK is required:

```sh
make build
make run
```

Useful checks:

```sh
make probe
make test-ci-security
make test-macos-compatibility
```

Package the current architecture:

```sh
make release
```

Build the Intel target explicitly:

```sh
make release-intel
# Equivalent low-level override:
make clean release TARGET_TRIPLE="x86_64-apple-macos13.0"
```

See [DISTRIBUTION.md](DISTRIBUTION.md) for signing, notarization, and full release verification.

## Unofficial Project

CodexS is not an official OpenAI product. The current Codex quota interface exposes rolling-window percentages and reset times rather than absolute quota sizes, so the app displays remaining percentages.

## License

MIT. See [LICENSE](LICENSE). This project includes MIT-licensed code from [shanggqm/codexU](https://github.com/shanggqm/codexU) and preserves the original copyright notice.
