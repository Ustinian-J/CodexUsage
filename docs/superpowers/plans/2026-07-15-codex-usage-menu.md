# CodexUsage macOS Menu App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, audit, package, install, and publish a native macOS menu-bar app that shows Codex quota rings, local token totals, and today's task progress.

**Architecture:** Start from the MIT-licensed `shanggqm/codexU` implementation only after a source and supply-chain audit. Keep its local-first Swift/AppKit/SwiftUI architecture, rebrand it as an independent `CodexUsage` application, then add small pure-domain calculations for task progress and quota pace before wiring them into existing views.

**Tech Stack:** Swift 6, SwiftUI, AppKit/Cocoa, Carbon, UserNotifications, SQLite CLI, shell packaging scripts, GitHub.

## Global Constraints

- Minimum operating system: macOS 13.0.
- Runtime dependencies: Apple system frameworks only; no third-party package manager dependencies.
- Application and repository name: `CodexUsage`.
- Bundle identifier: `com.ustinianj.codexusage`.
- Preserve the upstream MIT copyright notice and document the upstream source.
- Never read or print token values from `~/.codex/auth.json`.
- Never upload usage, thread content, paths, logs, or account data.
- Missing data is unavailable, never fabricated as zero.
- Build both `x86_64` and `arm64` where the installed SDK supports the target.
- Unsigned/ad-hoc builds must be labeled “not notarized”.

---

### Task 1: Audit the upstream source before import

**Files:**
- Create: `docs/SECURITY_AUDIT.md`
- Read only: `/tmp/codexU-reference/**`

**Interfaces:**
- Consumes: upstream checkout at commit recorded by `git -C /tmp/codexU-reference rev-parse HEAD`.
- Produces: an allow/block decision and a hash-backed inventory in `docs/SECURITY_AUDIT.md`.

- [ ] **Step 1: Record source identity and inventory**

Run:

```bash
git -C /tmp/codexU-reference rev-parse HEAD
git -C /tmp/codexU-reference status --short
find /tmp/codexU-reference -type f -not -path '*/.git/*' -print0 | sort -z | xargs -0 shasum -a 256
```

Expected: a clean checkout, one immutable commit SHA, and hashes for every imported file.

- [ ] **Step 2: Search high-risk capabilities**

Run:

```bash
rg -n -i 'URLSession|https?://|Process\(|/bin/|/usr/bin/|osascript|curl|wget|nc |ssh|scp|Keychain|SecItem|auth\.json|access[_-]?token|refresh[_-]?token|password|upload|POST|PUT|DELETE|eval\(|base64|chmod|xattr|rm -rf|launchctl|SMAppService' /tmp/codexU-reference --glob '!*.md'
```

Expected: every result is classified in the audit. Allowed categories are Codex app-server launch, local SQLite reads, user-requested app installation, packaging cleanup, and GitHub Release GET checks. Any unexplained credential access, upload, shell download-and-execute, persistence, or obfuscation blocks import.

- [ ] **Step 3: Inspect build and release entry points**

Run:

```bash
sed -n '1,260p' /tmp/codexU-reference/Makefile
for f in /tmp/codexU-reference/scripts/*.sh; do sh -n "$f"; done
rg -n 'swift package|Package\.swift|Pods|Carthage|npm|pip|brew|curl|wget' /tmp/codexU-reference
```

Expected: scripts pass shell parsing; no downloaded build-time code or third-party dependency installation exists.

- [ ] **Step 4: Inspect data boundaries**

Review every `URLSession`, `Process`, file path, SQLite query, and app-server request. Write a table to `docs/SECURITY_AUDIT.md` with capability, file/line, purpose, data sent, verdict, and mitigation.

- [ ] **Step 5: Commit the audit**

```bash
git add docs/SECURITY_AUDIT.md
git commit -m "docs: audit upstream source and data boundaries"
```

### Task 2: Import the approved MIT baseline

**Files:**
- Create: `Sources/**`, `Resources/**`, `scripts/**`, `tests/**`
- Create: `Makefile`, `LICENSE`, `SECURITY.md`, `DISTRIBUTION.md`, `CHANGELOG.md`, `.gitignore`
- Create: `UPSTREAM.md`

**Interfaces:**
- Consumes: Task 1 allow decision and the exact audited commit.
- Produces: a compilable local baseline with upstream attribution.

- [ ] **Step 1: Copy only audited paths**

Mechanically copy the allowlisted source, resource, test, and documentation files while excluding `.git`, `.github`, upstream automation metadata, build products, and distribution artifacts.

- [ ] **Step 2: Add upstream attribution**

`UPSTREAM.md` must contain:

```markdown
# Upstream attribution

CodexUsage incorporates code from [shanggqm/codexU](https://github.com/shanggqm/codexU),
audited at commit `cc800ff7afa254237fd088cb63004390d6492a99`, under the MIT License. The original copyright
notice is preserved in `LICENSE`.
```

- [ ] **Step 3: Run baseline tests before modifications**

Run:

```bash
make test-rate-limits
make test-statistics-time-zone
make test-status-item
make test-parsers
make test-macos-compatibility
```

Expected: every script exits 0.

- [ ] **Step 4: Build the unmodified baseline**

Run `make build`.

Expected: the app compiles and `codesign --verify --deep --strict build/codexU.app` exits 0.

- [ ] **Step 5: Commit the baseline**

```bash
git add Sources Resources scripts tests Makefile LICENSE SECURITY.md DISTRIBUTION.md CHANGELOG.md .gitignore UPSTREAM.md
git commit -m "chore: import audited codexU baseline"
```

### Task 3: Rebrand packaging and user-visible product identity

**Files:**
- Modify: `Makefile`
- Modify: `Resources/Info.plist`
- Rename: `Resources/codexU.icns` to `Resources/CodexUsage.icns`
- Rename: `Resources/codexU-icon.png` to `Resources/CodexUsage-icon.png`
- Modify: `Sources/CodexUsageWidget/main.swift`
- Modify: `Sources/CodexUsageWidget/Services/GitHubReleaseUpdateChecker.swift`
- Modify: `README.md`, `README.en.md`, `DISTRIBUTION.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: baseline build layout.
- Produces: `build/CodexUsage.app` with bundle identifier `com.ustinianj.codexusage` and update URL `Ustinian-J/CodexUsage`.

- [ ] **Step 1: Write a failing identity check**

Create `scripts/test-product-identity.sh` that asserts:

```bash
grep -q 'APP_NAME := CodexUsage' Makefile
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist | grep -qx 'com.ustinianj.codexusage'
/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' Resources/Info.plist | grep -qx 'CodexUsage'
! rg -n 'shanggqm/codexU' Sources Resources Makefile
```

- [ ] **Step 2: Verify the identity test fails**

Run `bash scripts/test-product-identity.sh`.

Expected: FAIL because the baseline still uses `codexU`.

- [ ] **Step 3: Apply the rebrand**

Set the app name, executable, icon, display name, bundle identifier, cache directories, UserDefaults suite keys, update repository, window titles, menu text, and packaged artifact names to `CodexUsage`. Do not replace protocol terms such as `codex`, paths under `~/.codex`, or the upstream attribution.

- [ ] **Step 4: Verify identity and build**

Run:

```bash
bash scripts/test-product-identity.sh
make build
codesign --verify --deep --strict build/CodexUsage.app
```

Expected: all commands exit 0.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: rebrand app as CodexUsage"
```

### Task 4: Add task-board project progress

**Files:**
- Create: `Sources/CodexUsageWidget/Domain/TaskProgress.swift`
- Create: `Sources/CodexUsageWidget/Domain/TaskProgressSelfTest.swift`
- Modify: `Sources/CodexUsageWidget/main.swift`
- Modify: `Sources/CodexUsageWidget/Services/JSONDumpWriter.swift`
- Create: `scripts/test-task-progress.sh`

**Interfaces:**
- Consumes: `TaskBoard.columns: [TaskColumn]` and `TaskColumnKind`.
- Produces: `TaskProgress(completed:total:percent:)` and `TaskBoard.progress`.

- [ ] **Step 1: Write failing pure-domain tests**

Test these cases in `TaskProgressSelfTest.run()`:

```swift
expect(TaskProgress.calculate(columns: []).percent == nil, "empty board has no percentage")
expect(TaskProgress.calculate(columns: sample(completed: 2, total: 4)).percent == 50, "two of four")
expect(TaskProgress.calculate(columns: sample(completed: 5, total: 5)).percent == 100, "all complete")
```

- [ ] **Step 2: Verify tests fail**

Run `bash scripts/test-task-progress.sh`.

Expected: compiler failure because `TaskProgress` does not exist.

- [ ] **Step 3: Implement the calculation**

```swift
struct TaskProgress: Equatable {
    let completed: Int
    let total: Int
    let percent: Int?

    static func calculate(columns: [TaskColumn]) -> TaskProgress {
        let total = columns.reduce(0) { $0 + $1.items.count }
        let completed = columns.first(where: { $0.id == .done })?.items.count ?? 0
        return TaskProgress(
            completed: completed,
            total: total,
            percent: total == 0 ? nil : Int((Double(completed) / Double(total) * 100).rounded())
        )
    }
}
```

- [ ] **Step 4: Wire progress into UI and JSON probe**

Show `完成 X / Y` and a determinate progress bar above the task columns. For an empty board show `暂无今日任务`. Add `taskBoard.progress` to `--dump-json`.

- [ ] **Step 5: Verify and commit**

Run:

```bash
bash scripts/test-task-progress.sh
make build
make probe
```

Expected: tests pass and probe includes `completed`, `total`, and nullable `percent`.

```bash
git add Sources scripts
git commit -m "feat: show today's project progress"
```

### Task 5: Add quota pace guidance

**Files:**
- Create: `Sources/CodexUsageWidget/Domain/QuotaPace.swift`
- Create: `Sources/CodexUsageWidget/Domain/QuotaPaceSelfTest.swift`
- Modify: `Sources/CodexUsageWidget/main.swift`
- Create: `scripts/test-quota-pace.sh`

**Interfaces:**
- Consumes: `RateLimitWindow.usedPercent`, `windowDurationMins`, `resetsAt`, and current time.
- Produces: `QuotaPace.status` with `.comfortable`, `.onPace`, `.fast`, or `.unavailable`.

- [ ] **Step 1: Write failing boundary tests**

Cover unavailable reset time, 50% elapsed/30% used, 50% elapsed/50% used, and 50% elapsed/80% used. Use fixed UTC timestamps.

- [ ] **Step 2: Verify failure**

Run `bash scripts/test-quota-pace.sh`.

Expected: compiler failure because `QuotaPace` does not exist.

- [ ] **Step 3: Implement minimal pace logic**

Calculate window start as `resetsAt - windowDurationMins * 60`, clamp elapsed fraction to `0...1`, and compare used fraction against elapsed fraction with a 0.10 tolerance.

- [ ] **Step 4: Show guidance**

Below each quota ring show one localized label: `使用宽裕`, `进度正常`, or `使用偏快`. Unknown inputs show no pace claim.

- [ ] **Step 5: Verify and commit**

Run `bash scripts/test-quota-pace.sh && make build` and commit with `feat: add quota pace guidance`.

### Task 6: Add opt-in local quota alerts

**Files:**
- Create: `Sources/CodexUsageWidget/Domain/QuotaAlertPolicy.swift`
- Create: `Sources/CodexUsageWidget/Domain/QuotaAlertPolicySelfTest.swift`
- Create: `Sources/CodexUsageWidget/Services/QuotaAlertService.swift`
- Modify: `Sources/CodexUsageWidget/main.swift`
- Modify: `Makefile`
- Create: `scripts/test-quota-alerts.sh`

**Interfaces:**
- Consumes: normalized quota windows and reset identifiers.
- Produces: at most one local notification for thresholds 20%, 10%, and 5% per quota reset cycle.

- [ ] **Step 1: Write policy tests**

Test disabled default, first threshold crossing, repeated refresh suppression, lower threshold crossing, and reset-cycle clearing.

- [ ] **Step 2: Verify failure**

Run `bash scripts/test-quota-alerts.sh`.

Expected: compiler failure because `QuotaAlertPolicy` does not exist.

- [ ] **Step 3: Implement pure policy and service adapter**

Keep notification state in UserDefaults using only window kind, threshold, and reset timestamp. Request notification permission only after the user enables alerts in Settings. Notification text contains quota kind, remaining percentage, and reset time; it contains no thread or path data.

- [ ] **Step 4: Link the system framework and expose setting**

Add `-framework UserNotifications`. The setting defaults to off.

- [ ] **Step 5: Verify and commit**

Run `bash scripts/test-quota-alerts.sh && make build` and commit with `feat: add opt-in quota alerts`.

### Task 7: Complete documentation and packaging

**Files:**
- Modify: `README.md`, `README.en.md`, `SECURITY.md`, `DISTRIBUTION.md`, `CHANGELOG.md`
- Modify: `scripts/package-dmg.sh`, `scripts/build-release-artifacts.sh`, `scripts/check-release-ready.sh`
- Modify: `Resources/Info.plist`

**Interfaces:**
- Consumes: verified `build/CodexUsage.app`.
- Produces: installable `dist/CodexUsage-<version>-mac-x86_64.dmg` and SHA-256.

- [ ] **Step 1: Document exact behavior and limits**

Document quota source, token source, task progress formula, privacy boundaries, upstream attribution, Intel/Apple Silicon builds, and the manual Gatekeeper path for a non-notarized build.

- [ ] **Step 2: Run release packaging**

Run `make release` on the current Intel host.

Expected: one x86_64 DMG plus `.sha256` under `dist/`.

- [ ] **Step 3: Verify the artifact**

Mount the DMG read-only; verify the app, Applications symlink, bundle metadata, Mach-O architecture, codesign, and checksum; then detach it.

- [ ] **Step 4: Commit**

```bash
git add README.md README.en.md SECURITY.md DISTRIBUTION.md CHANGELOG.md Resources scripts Makefile
git commit -m "docs: prepare CodexUsage distribution"
```

### Task 8: Final local verification and installation

**Files:**
- No source changes unless verification reveals a defect.

**Interfaces:**
- Consumes: final source and DMG.
- Produces: evidence that the requested app works on the user's Mac.

- [ ] **Step 1: Run the full suite**

```bash
make test-rate-limits
make test-statistics-time-zone
make test-status-item
make test-parsers
bash scripts/test-task-progress.sh
bash scripts/test-quota-pace.sh
bash scripts/test-quota-alerts.sh
bash scripts/test-product-identity.sh
make test-macos-compatibility
make build
make probe
git diff --check
```

Expected: all tests exit 0; probe contains quota, token, and task data without secrets.

- [ ] **Step 2: Inspect app behavior**

Launch the app, verify the menu-bar rings and centered values visually, open the runtime menu and main window, refresh once, inspect task progress, and quit cleanly.

- [ ] **Step 3: Install**

Copy the verified app to `/Applications/CodexUsage.app` only after explicit system approval. Reopen it from Applications and repeat the menu-bar smoke test.

### Task 9: Create and publish the GitHub repository

**Files:**
- No new local source files.

**Interfaces:**
- Consumes: clean verified `main` branch.
- Produces: public `https://github.com/Ustinian-J/CodexUsage` with pushed source.

- [ ] **Step 1: Confirm browser login**

Use the connected Chrome session to verify the active GitHub identity is `Ustinian-J`.

- [ ] **Step 2: Create the repository**

Create public repository `CodexUsage` without auto-generated README, license, or `.gitignore`.

- [ ] **Step 3: Add remote and push**

```bash
git remote add origin https://github.com/Ustinian-J/CodexUsage.git
git push -u origin main
```

- [ ] **Step 4: Verify remote state**

Confirm the repository page shows the expected README, MIT license, SECURITY audit, source tree, and latest local commit SHA.
