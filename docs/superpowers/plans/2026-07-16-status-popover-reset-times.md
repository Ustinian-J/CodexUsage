# Status Popover Reset Times Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the ambiguous runtime-specific open button, remove update checking from the menu-bar popover, and add a polished two-row 5h/7d reset-time card above reset-credit information.

**Architecture:** Keep runtime data local and reuse `RateWindow.resetsAt`. Add a small pure presentation model for stable 5h/7d row ordering and missing-value behavior, then render it in `RuntimeStatusMenuView` with the existing account-cycle card styling. Preserve update features outside the popover and enforce the visual/copy contract with a focused source test plus dual-architecture CI.

**Tech Stack:** Swift 5, SwiftUI, AppKit, shell self-tests, Make, GitHub Actions on macOS Intel and Apple Silicon.

## Global Constraints

- macOS deployment target remains 13.0.
- No third-party dependencies, new network requests, credential reads, Keychain access, or background persistence.
- The popover remains 380 pt wide and may grow vertically; content must not be compressed to fit.
- Both 5h and 7d reset rows are always present for the Codex account panel; a missing time renders as `--`.
- The update row is removed only from the popover; Settings update controls remain intact.
- The task board remains read-only in this change.

---

### Task 1: Stable 5h/7d reset-time presentation model

**Files:**
- Create: `Sources/CodexUsageWidget/Domain/RuntimeResetTimes.swift`
- Create: `Sources/CodexUsageWidget/Domain/RuntimeResetTimesSelfTest.swift`
- Modify: `Sources/CodexUsageWidget/main.swift`
- Create: `scripts/test-runtime-reset-times.sh`
- Modify: `Makefile`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `RateWindow.resetsAt` from the current Codex 5h and 7d windows.
- Produces: `RuntimeResetTimes.init(fiveHourQuota:sevenDayQuota:)` and ordered `rows: [RuntimeResetTimeRow]` with `.fiveHour` followed by `.sevenDay`.

- [ ] **Step 1: Write the failing presentation-model self-test**

Create `RuntimeResetTimesSelfTest.swift` with tests that construct distinct 5h/7d dates, assert two ordered rows, and assert that a missing 5h time remains nil rather than borrowing 7d:

```swift
import Foundation

enum RuntimeResetTimesSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        let fiveHourDate = Date(timeIntervalSince1970: 1_800_000_000)
        let sevenDayDate = Date(timeIntervalSince1970: 1_800_100_000)
        let summary = RuntimeResetTimes(
            fiveHourQuota: RateWindow(usedPercent: 25, windowDurationMins: 300, resetsAt: fiveHourDate),
            sevenDayQuota: RateWindow(usedPercent: 40, windowDurationMins: 10_080, resetsAt: sevenDayDate)
        )
        expect(summary.rows.map(\.window) == [.fiveHour, .sevenDay], "reset rows must stay in 5h then 7d order")
        expect(summary.rows.map(\.resetsAt) == [fiveHourDate, sevenDayDate], "each row must preserve its own reset time")

        let missingFiveHour = RuntimeResetTimes(
            fiveHourQuota: nil,
            sevenDayQuota: RateWindow(usedPercent: 40, windowDurationMins: 10_080, resetsAt: sevenDayDate)
        )
        expect(missingFiveHour.rows.count == 2, "missing quota data must not collapse the two-row layout")
        expect(missingFiveHour.rows[0].resetsAt == nil, "missing 5h data must stay unavailable")
        expect(missingFiveHour.rows[1].resetsAt == sevenDayDate, "7d data must remain on the 7d row")

        if failures.isEmpty {
            print("runtime reset times self-test passed")
            return true
        }
        failures.forEach { fputs("runtime reset times self-test failed: \($0)\n", stderr) }
        return false
    }
}
```

- [ ] **Step 2: Add the CLI/test wiring and verify RED**

Add `--self-test-runtime-reset-times` dispatch in `CodexUsageMain.main`, a `scripts/test-runtime-reset-times.sh` wrapper that builds and runs it, the `test-runtime-reset-times` Make target, and the direct binary invocation in GitHub Actions after `--self-test-rate-limits`.

Run:

```bash
./scripts/test-runtime-reset-times.sh
```

Expected: compilation fails because `RuntimeResetTimes` and `RuntimeResetTimeRow` do not exist.

- [ ] **Step 3: Implement the minimal pure model**

Create `RuntimeResetTimes.swift`:

```swift
import Foundation

enum RuntimeResetWindow: Equatable {
    case fiveHour
    case sevenDay

    var shortLabel: String {
        switch self {
        case .fiveHour: return "5h"
        case .sevenDay: return "7d"
        }
    }
}

struct RuntimeResetTimeRow: Equatable {
    let window: RuntimeResetWindow
    let resetsAt: Date?
}

struct RuntimeResetTimes: Equatable {
    let rows: [RuntimeResetTimeRow]

    init(fiveHourQuota: RateWindow?, sevenDayQuota: RateWindow?) {
        rows = [
            RuntimeResetTimeRow(window: .fiveHour, resetsAt: fiveHourQuota?.resetsAt),
            RuntimeResetTimeRow(window: .sevenDay, resetsAt: sevenDayQuota?.resetsAt)
        ]
    }
}
```

- [ ] **Step 4: Verify GREEN**

Run:

```bash
./scripts/test-runtime-reset-times.sh
```

Expected: `runtime reset times self-test passed`.

- [ ] **Step 5: Commit the presentation model**

```bash
git add Sources/CodexUsageWidget/Domain/RuntimeResetTimes.swift Sources/CodexUsageWidget/Domain/RuntimeResetTimesSelfTest.swift Sources/CodexUsageWidget/main.swift scripts/test-runtime-reset-times.sh Makefile .github/workflows/ci.yml
git commit -m "test: define runtime reset time rows"
```

### Task 2: Polished popover layout and unambiguous copy

**Files:**
- Modify: `Sources/CodexUsageWidget/UI/RuntimeViews.swift`
- Modify: `Sources/CodexUsageWidget/main.swift`
- Create: `scripts/test-runtime-menu.sh`
- Modify: `Makefile`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `RuntimeResetTimes.rows`, existing `runtimeCompactDateTime`, and current `WidgetPalette` card colors.
- Produces: a two-row `quotaResetTimesRow`, the “打开主界面 / Open Main Window” command, and a 432 pt popover height.

- [ ] **Step 1: Write the failing source contract test**

Create `scripts/test-runtime-menu.sh`:

```bash
#!/bin/bash
set -euo pipefail

source_file="Sources/CodexUsageWidget/UI/RuntimeViews.swift"
main_file="Sources/CodexUsageWidget/main.swift"

rg -q 'language\.text\("打开主界面", "Open Main Window"\)' "$source_file"
rg -q 'private var quotaResetTimesRow' "$source_file"
rg -q 'RuntimeResetTimes\(' "$source_file"
rg -q 'ForEach\(resetTimes\.rows' "$source_file"
rg -q 'runtimeStatusPopoverHeight\(for _: Int\).*432|return 432' "$main_file"

if rg -q 'AppUpdateMenuRow\(' "$source_file"; then
    echo "runtime menu source test failed: popover must not render AppUpdateMenuRow" >&2
    exit 1
fi

echo "runtime menu source test passed"
```

Add a `test-runtime-menu` Make target and call the script in CI's audit step after `test-source-security.sh`.

- [ ] **Step 2: Run the source contract test to verify RED**

Run:

```bash
./scripts/test-runtime-menu.sh
```

Expected: non-zero exit because the popover still says “打开 Codex”, renders `AppUpdateMenuRow`, and has no reset-time card.

- [ ] **Step 3: Replace the update row with the two-row reset card**

In `RuntimeStatusMenuView.body`, insert `quotaResetTimesRow` immediately before `accountCycleRow` inside the existing Codex-details condition, and delete `AppUpdateMenuRow(updateStore:language:)`.

Add these properties and helpers:

```swift
private var resetTimes: RuntimeResetTimes {
    RuntimeResetTimes(
        fiveHourQuota: codexSnapshot?.fiveHourQuota,
        sevenDayQuota: codexSnapshot?.sevenDayQuota
    )
}

private var quotaResetTimesRow: some View {
    VStack(spacing: 0) {
        ForEach(Array(resetTimes.rows.enumerated()), id: \.offset) { index, row in
            if index > 0 {
                Divider().padding(.vertical, 5)
            }
            HStack(spacing: 8) {
                Text(language.text("\(row.window.shortLabel) 下次重置", "\(row.window.shortLabel) next reset"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(row.resetsAt.map(runtimeCompactDateTime) ?? "--")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
        }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(WidgetPalette.controlFill(colorScheme))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(WidgetPalette.controlStroke(colorScheme), lineWidth: 0.8)
            )
    )
}
```

- [ ] **Step 4: Change the command copy and increase height**

Replace the footer title with:

```swift
title: language.text("打开主界面", "Open Main Window")
```

Change `runtimeStatusPopoverHeight(for:)` to return `432` while preserving the 380 pt width and existing 12 pt section spacing.

- [ ] **Step 5: Verify GREEN and compile**

Run:

```bash
./scripts/test-runtime-menu.sh
make build
build/CodexUsage.app/Contents/MacOS/CodexUsage --self-test-runtime-reset-times
```

Expected: source contract passes, build exits 0, and reset-time self-test passes.

- [ ] **Step 6: Commit the popover UI**

```bash
git add Sources/CodexUsageWidget/UI/RuntimeViews.swift Sources/CodexUsageWidget/main.swift scripts/test-runtime-menu.sh Makefile .github/workflows/ci.yml
git commit -m "feat: show both quota reset times in popover"
```

### Task 3: Release identity and user documentation

**Files:**
- Modify: `Resources/Info.plist`
- Modify: `CHANGELOG.md`
- Modify: `README.md`
- Modify: `README.en.md`

**Interfaces:**
- Consumes: the completed popover behavior.
- Produces: version `0.2.3`, build `5`, and user-facing documentation matching the UI.

- [ ] **Step 1: Write failing identity checks**

Add these assertions to `scripts/test-product-identity.sh`:

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist \
  | grep -qx '0.2.3'
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist \
  | grep -qx '5'
grep -q '当前版本为 `0.2.3`' README.md
grep -q 'Current version: `0.2.3`' README.en.md
```

Then run:

```bash
./scripts/test-product-identity.sh
```

Expected: FAIL because `Resources/Info.plist` still reports `0.2.2` build `4`.

- [ ] **Step 2: Update version and documentation**

Set `CFBundleShortVersionString` to `0.2.3` and `CFBundleVersion` to `5`. Add a changelog entry describing the unambiguous main-window button, removed popover update row, and separate 5h/7d reset times. Update both READMEs without claiming task-state editing exists.

- [ ] **Step 3: Verify identity and documentation**

Run:

```bash
plutil -lint Resources/Info.plist
./scripts/test-product-identity.sh
rg -n '0\.2\.3|打开主界面|5h.*7d' CHANGELOG.md README.md README.en.md
```

Expected: plist valid, product identity passes, and documentation contains the new version and feature language.

- [ ] **Step 4: Commit release metadata**

```bash
git add Resources/Info.plist CHANGELOG.md README.md README.en.md scripts/test-product-identity.sh
git commit -m "docs: prepare CodexUsage 0.2.3"
```

### Task 4: Full verification, publication, and safe installation

**Files:**
- Verify all changed files.
- No new production interfaces.

- [ ] **Step 1: Run complete local gates**

```bash
for script in scripts/*.sh; do bash -n "$script"; done
./scripts/test-product-identity.sh
./scripts/test-macos-compatibility.sh
./scripts/test-ci-security.sh
./scripts/test-source-security.sh
./scripts/test-runtime-menu.sh
git diff --check
git status --short
```

Expected: every gate exits 0 and only intentional changes, if any, appear.

- [ ] **Step 2: Run all available binary self-tests**

```bash
make build
binary="build/CodexUsage.app/Contents/MacOS/CodexUsage"
"$binary" --self-test-runtime-reset-times
"$binary" --self-test-status-item
"$binary" --self-test-rate-limits
"$binary" --self-test-task-progress
"$binary" --self-test-reset-credits
"$binary" --self-test-updates
```

Expected: all self-tests print `passed` and exit 0.

- [ ] **Step 3: Push the feature branch and verify dual-architecture CI**

```bash
git push -u origin codex/status-popover-reset-times
```

Expected: GitHub Actions reports success for both Intel and Apple Silicon build/package jobs.

- [ ] **Step 4: Verify the Intel release artifact before installation**

Download only the `CodexUsage-intel` artifact from the passing run. Verify the GitHub artifact SHA-256, inner DMG checksum, `hdiutil verify`, bundle version `0.2.3` build `5`, `x86_64` architecture, and `codesign --verify --deep --strict` before copying it to `/Applications`.

- [ ] **Step 5: Back up, install, and run the verified app**

Stop the existing CodexUsage process, preserve `/Applications/CodexUsage.app` under a unique `/private/tmp` backup path, install the verified `0.2.3` app, and launch it.

- [ ] **Step 6: Verify the installed result**

Run the installed `--self-test-runtime-reset-times` and `--self-test-status-item`, confirm one running process, confirm version/build/architecture/signature, and inspect the menu-bar popover to ensure both reset rows are visible above reset credits and the three footer buttons are not clipped.
