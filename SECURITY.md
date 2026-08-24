# Security Policy

## Supported Versions

The latest version on the default branch is the supported version.

## Reporting A Vulnerability

Please report security issues privately instead of opening a public issue when the report includes account data, local file paths, thread titles, local Codex database contents, or other sensitive information.

Include:

- macOS version.
- CodexS version.
- Whether the issue affects app launch, local file reads, quota reads, packaging, or update distribution.
- Minimal reproduction steps without private Codex data.

## Local Data Scope

CodexS reads:

- `~/.codex/state_5.sqlite`
- `~/.codex/automations/**/automation.toml`
- local responses from `codex app-server`
- `~/.codex/sessions/**/rollout-*.jsonl` and `~/.codex/archived_sessions/*.jsonl` token/tool metadata
- `task_started`, `task_complete`, and `turn_aborted` event fields from current Codex rollout files
- when the Claude Code runtime is visible, `~/.claude/projects/**/*.jsonl` assistant `message.usage` and `tool_use.name` metadata
- when the Claude Code runtime is visible, `~/.claude/tasks/**/*.json` task status/title metadata
- when the Claude Code runtime is visible, optional `~/Library/Caches/CodexUsage/claude-code/statusline-snapshot.json`
- optional `~/Library/Caches/CodexUsage/update-check.json` for cached GitHub Release update metadata
- optional SSH remote Codex task metadata: host alias, task/thread IDs, thread title, project basename, event type, timestamp, outcome, and read state

Task activity persistence uses the legacy-compatible `CodexUsage.taskActivity.v1` local `UserDefaults` key and stores only task IDs, thread titles, project basenames, outcomes, timestamps, read state, and a recovery watermark. It deliberately ignores and never persists or exposes `last_agent_message`. CodexS keeps the existing `com.ustinianj.codexusage` bundle ID and `~/Library/Caches/CodexUsage/` cache namespace so an upgrade does not lose settings or repeat alerts.

On macOS, CodexS periodically launches the fixed system binary `/usr/sbin/lsof` with exact, normalized rollout paths to recover from a missing terminal event. It reads only whether those files are still open; it does not read process environments, arguments, file contents, prompts, responses, or tool data. The probe is bounded, times out, and fails open: an unavailable or ambiguous result keeps the task marked as running.

Remote monitoring is opt-in and stores only a persistent enabled flag, validated SSH config aliases, and per-host recovery timestamps. New and upgraded installations keep the flag off until the user explicitly enables it. While enabled, CodexS keeps at most one long-lived system OpenSSH connection per host and automatically reconnects with delays from 10 seconds to a five-minute cap; disabling it stops CodexS-owned connections and cancels future retries. CodexS launches the platform OpenSSH client with batch authentication, strict host-key checking, connection timeout, and keepalive limits. A temporary local config disables `ControlMaster`, `ControlPersist`, and `ControlPath` before including the user's and system SSH aliases, so the same isolation also reaches implicit `ProxyJump` helpers; the file contains no credentials and is removed when monitoring stops. The host value is passed as a separate validated argument, never interpolated into a local shell. A fixed Python 3 parser runs in memory on the remote host, opens Codex state/session files read-only, emits only allowlisted task metadata, and does not create or modify remote files. OpenSSH may use keys or an agent configured by the user, but CodexS never opens, copies, logs, or persists those credentials.

It should not upload local usage, transcript, task, thread, account, or path data to a third-party service. Claude Code transcript parsing must not store prompt text, assistant response text, tool arguments, or tool output.

Static Skill inspection is limited to regular `SKILL.md` files under `~/.codex/skills/`, `~/.codex/plugins/cache/`, or `~/.agents/skills/`. Paths outside those roots, symbolic links, non-regular files, and files larger than 1 MiB are rejected. Debug logging is disabled unless `CODEXUSAGE_DEBUG=1` is set; enabled logs use a `CodexS/debug.log` file under the system-provided per-user temporary directory, reject symbolic links, and are restricted to the current user.

## Network Scope

CodexS is local-first. The update checker may request public GitHub Release metadata from `https://api.github.com/repos/Ustinian-J/CodexUsage/releases` during automatic checks when enabled or when the user manually checks for updates. After the user explicitly configures SSH hosts and enables automatic remote monitoring, CodexS opens long-lived encrypted SSH connections to those aliases solely for remote task events.

Update requests must not include local usage, transcript, task, thread, account, path, prompt, response, tool argument, or tool output data. The update checker may send standard HTTPS headers such as `User-Agent` and `If-None-Match` for ETag caching.

CodexS must not silently download, install, replace, or relaunch the app as part of the GitHub Release check. It may open the user's default browser to a matching DMG asset or the Release page.

Automatic update checks are disabled by default. Enabling them is an explicit user setting.

## Local Notifications

Quota alerts are disabled by default. Enabling them explicitly requests macOS notification permission. Alert state stores only the quota window kind, reset timestamp, and thresholds already emitted. Notification content contains only the window label, remaining percentage, and reset time; it must not contain account, thread, prompt, task, path, token credential, or transcript data.

Task-completion alerts are enabled by default for this feature and use the same native notification permission. Their title contains only “completed” or “interrupted,” and their body only asks the user to open CodexS. Thread titles, project names, paths, prompts, responses, and tool data must not appear in notification content.

Reset-credit details are read only from the official local Codex app-server response and are not persisted outside the current in-memory snapshot. Subscription expiry tracking is disabled by default; when enabled, only the user-selected date and enabled flag are stored in local `UserDefaults`. CodexS does not read `auth.json`, decode JWT claims, inspect browser cookies, or call private billing endpoints to infer subscription dates.

## Build Supply Chain

- The repository has no third-party package manager dependency or vendored binary framework.
- CI permissions are limited to `contents: read` and CI does not consume repository secrets.
- CI may use only GitHub-owned actions pinned to full commit SHAs.
- `scripts/test-ci-security.sh` enforces the current action allowlist and rejects floating tags.
- `scripts/test-source-security.sh` rejects credential access, network write methods, downloaders, persistence helpers, third-party dependency manifests, and precompiled libraries. It permits only reviewed process launches, locks the local liveness probe to `/usr/sbin/lsof` with fixed arguments, and permits SSH only in the reviewed remote-task monitor with fixed safety options.
- Release artifacts include SHA-256 checksums and are verified for DMG integrity, Mach-O architecture, and code signature before installation.
- Developer ID notarization automation is deliberately absent until it receives a separate credential and workflow review.
