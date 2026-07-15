# Security Policy

## Supported Versions

The latest version on the default branch is the supported version.

## Reporting A Vulnerability

Please report security issues privately instead of opening a public issue when the report includes account data, local file paths, thread titles, local Codex database contents, or other sensitive information.

Include:

- macOS version.
- CodexUsage version.
- Whether the issue affects app launch, local file reads, quota reads, packaging, or update distribution.
- Minimal reproduction steps without private Codex data.

## Local Data Scope

CodexUsage reads:

- `~/.codex/state_5.sqlite`
- `~/.codex/automations/**/automation.toml`
- local responses from `codex app-server`
- `~/.codex/sessions/**/rollout-*.jsonl` and `~/.codex/archived_sessions/*.jsonl` token metadata
- `~/.claude/projects/**/*.jsonl` assistant `message.usage` and `tool_use.name` metadata
- `~/.claude/tasks/**/*.json` task status/title metadata
- optional `~/Library/Caches/CodexUsage/claude-code/statusline-snapshot.json`
- optional `~/Library/Caches/CodexUsage/update-check.json` for cached GitHub Release update metadata

It should not upload local usage, transcript, task, thread, account, or path data to a third-party service. Claude Code transcript parsing must not store prompt text, assistant response text, tool arguments, or tool output.

## Network Scope

CodexUsage is local-first. The update checker may request public GitHub Release metadata from `https://api.github.com/repos/Ustinian-J/CodexUsage/releases` during automatic checks when enabled or when the user manually checks for updates.

Update requests must not include local usage, transcript, task, thread, account, path, prompt, response, tool argument, or tool output data. The update checker may send standard HTTPS headers such as `User-Agent` and `If-None-Match` for ETag caching.

CodexUsage must not silently download, install, replace, or relaunch the app as part of the GitHub Release check. It may open the user's default browser to a matching DMG asset or the Release page.

Automatic update checks are disabled by default. Enabling them is an explicit user setting.

## Build Supply Chain

- The repository has no third-party package manager dependency or vendored binary framework.
- CI permissions are limited to `contents: read` and CI does not consume repository secrets.
- CI may use only GitHub-owned actions pinned to full commit SHAs.
- `scripts/test-ci-security.sh` enforces the current action allowlist and rejects floating tags.
- Release artifacts include SHA-256 checksums and are verified for DMG integrity, Mach-O architecture, and code signature before installation.
- Developer ID notarization automation is deliberately absent until it receives a separate credential and workflow review.
