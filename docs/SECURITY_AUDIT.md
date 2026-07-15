# Upstream security audit

Date: 2026-07-15  
Auditor: Codex  
Upstream: `https://github.com/shanggqm/codexU`  
Audited commit: `cc800ff7afa254237fd088cb63004390d6492a99`  
Current-tree file count: 75  
SHA-256 digest of the sorted per-file SHA-256 inventory: `990f004a5708db96377af925630301278a3de37e6a87fee9fb3296a451d830c6`

## Conclusion

The audited current tree contains no evidence of credential theft, hidden data upload, downloaded-code execution, third-party binary dependencies, Keychain access, or reads of `~/.codex/auth.json`. The runtime is source-only Swift plus shell packaging and self-test scripts.

This is a static source audit, not a mathematical proof that software can never be harmful. CodexUsage therefore imports an explicit allowlist from this exact commit, excludes upstream Git history and automation metadata, changes update ownership, disables automatic update checks by default, and verifies the built app again before installation.

Decision: **ALLOW with the exclusions and hardening listed below.**

## Source identity and integrity

- `git status --short` was empty at the audited commit.
- `git fsck --full --no-reflogs` completed without object-integrity errors.
- The repository contains no `Package.swift`, CocoaPods, Carthage, npm, Python dependency manifest, `.framework`, `.xcframework`, `.dylib`, `.so`, static library, or archive dependency.
- Executable files in the current tree are limited to the ten readable shell scripts under `scripts/`.
- Every shell script passed `bash -n`.
- Resources are plist/XML, PNG, and ICNS files. No executable binary is stored in `Resources/`.

## Historical risk review

The history contains two short-lived high-risk maintainer commits:

- `54cb441`: added GitHub review, command-runner, and maintainer UI capabilities.
- `d1af592`: added tests for that capability.

They were explicitly reverted by:

- `55aa1e5`: removed the maintainer capability and all related runtime files.
- `e196885`: removed its additional tests.

None of `MaintainerModels.swift`, `CodexReviewRunner.swift`, `GitHubMaintainerClient.swift`, `LocalCommandRunner.swift`, `MaintainerStore.swift`, `MaintainerTaskRepository.swift`, `MaintainerViews.swift`, or `test-maintainer.sh` exists in the audited tree. CodexUsage copies current files only and does not import upstream Git objects, so the reverted implementation cannot enter the new repository through history.

## Capability review

| Capability | Location | Purpose | Data sent or changed | Verdict |
|---|---|---|---|---|
| Launch `codex app-server` | `Sources/CodexUsageWidget/main.swift:996` | Read the signed-in Codex account, rate limits, and usage via local JSON-RPC | Sends only `initialize`, `account/read`, `account/rateLimits/read`, and `account/usage/read` to the child process over stdio | Allow |
| Launch `sqlite3 -readonly -json` | `Sources/CodexUsageWidget/main.swift:2313` | Query the local Codex thread database | Read-only local query; no network | Allow |
| Launch `/usr/bin/grep` | `Sources/CodexUsageWidget/main.swift:2043` | Select relevant event lines before local JSON parsing | Reads a selected local session file; no network | Allow |
| Read Codex state | `Sources/CodexUsageWidget/main.swift:1269-1325` and session parsing helpers | Aggregate token and task metadata | Local reads under `~/.codex`; no prompt or tool payload is retained in UI | Allow with runtime probe verification |
| Read optional Claude state | `Sources/CodexUsageWidget/Providers/ClaudeCode/ClaudeCodeRuntimeProvider.swift` | Optional multi-runtime usage view | Local reads under `~/.claude`; writes a derived cache under the app cache directory | Allow, but clearly disclose and keep independent from Codex data |
| Write derived caches | `Sources/CodexUsageWidget/main.swift:2386-2439` and Claude provider cache helpers | Avoid rescanning unchanged local sessions | Writes parsed usage summaries only under `~/Library/Caches`; no remote transfer | Allow |
| GitHub Releases GET | `Sources/CodexUsageWidget/Services/GitHubReleaseUpdateChecker.swift` | Check public release metadata | HTTP GET to a fixed GitHub API repository; sends app version and ETag, not local usage | Allow after re-pointing to `Ustinian-J/CodexUsage`; automatic checks default off |
| Open release URL | `Sources/CodexUsageWidget/Services/AppUpdateStore.swift:36` | User-triggered download/release page | Opens a URL in the default browser; does not silently download or execute | Allow |
| Register global shortcut | Carbon calls in `GlobalShortcut.swift` and `main.swift` | Show or hide the app | Registers a key combination; does not capture arbitrary keystrokes | Allow |
| Remove/package build directories | `Makefile`, `scripts/package-dmg.sh` | Deterministic local build and DMG staging | Deletes only project-relative `build/`, `dist/`, and validated DMG staging paths | Allow |
| Notarization credentials | `scripts/notarize-dmg.sh` | Optional Apple notarization | Would pass user-supplied Apple credentials to `xcrun notarytool` | Exclude from import because this build is not notarized |
| Release remote checks | `scripts/check-release-ready.sh` | Maintainer release guard | Contacts Git/GitHub when explicitly run | Exclude from import; not required for local build |

## Explicit negative findings

Searches of the current non-documentation tree found:

- No `Keychain`, `SecItem`, browser cookie, SSH key, cloud credential, or password-store access.
- No `auth.json` access.
- No HTTP `POST`, `PUT`, or `DELETE` implementation.
- No `curl`, `wget`, `nc`, `ssh`, `scp`, shell `eval`, base64 decoding, downloaded installer, or launch daemon.
- No arbitrary command string accepted from the UI.
- No background persistence mechanism outside normal app launch; no `launchctl` or login-item helper is present.
- No silent self-update. Release assets are opened in the browser only after user interaction.

## Import allowlist

The new repository may import only the current versions of:

- `Sources/CodexUsageWidget/**`
- `Resources/**`
- `tests/fixtures/**`
- `Makefile`
- `scripts/package-dmg.sh`
- `scripts/build-release-artifacts.sh`
- `scripts/test-macos-compatibility.sh`
- `scripts/test-parsers.sh`
- `scripts/test-particle-animation.sh`
- `scripts/test-rate-limits.sh`
- `scripts/test-statistics-time-zone.sh`
- `scripts/test-status-item.sh`
- `LICENSE`
- `SECURITY.md`
- `DISTRIBUTION.md`
- `CHANGELOG.md`
- `README.md`
- `README.en.md`
- `docs/DESIGN_SYSTEM.md`

## Exclusions

Do not import:

- Upstream `.git` history or Git objects.
- `.codex/**` and `.github/**` automation or templates.
- `scripts/notarize-dmg.sh`.
- `scripts/check-release-ready.sh`.
- Upstream generated `build/`, `dist/`, `.build/`, caches, or release assets.
- Any file whose content differs from audited commit `cc800ff7afa254237fd088cb63004390d6492a99` without a local review and test.

## Post-import hardening gates

1. Re-run high-risk capability searches against the imported tree.
2. Re-point the update checker to `Ustinian-J/CodexUsage` and make automatic checks opt-in.
3. Build from source with Apple system frameworks only.
4. Run the app's JSON probe and inspect keys and values for secrets or conversation content.
5. Verify the final app signature, Mach-O architecture, DMG contents, and checksum before installation.
6. Review every local diff from the audited baseline before pushing to GitHub.

## Local hardening addendum

The independent repository adds its own `.github/workflows/ci.yml`; it is not copied from upstream. The workflow has `contents: read`, does not consume secrets, and uses only `actions/checkout` and `actions/upload-artifact` pinned to reviewed full commit SHAs. `scripts/test-ci-security.sh` enforces those properties.

Automatic update checks now default to off, update metadata points to `Ustinian-J/CodexUsage`, and the Makefile no longer exposes the excluded upstream notarization or remote release-check targets. Current personal/test artifacts remain ad-hoc signed and explicitly not notarized.
