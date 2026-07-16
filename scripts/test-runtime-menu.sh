#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

source_file="Sources/CodexUsageWidget/UI/RuntimeViews.swift"
main_file="Sources/CodexUsageWidget/main.swift"

require_pattern() {
    local pattern="$1"
    local file="$2"
    local message="$3"
    if ! grep -Eq -- "$pattern" "$file"; then
        echo "runtime menu source test failed: $message" >&2
        exit 1
    fi
}

require_pattern 'language\.text\("打开主界面", "Open Main Window"\)' "$source_file" "main-window copy is missing"
require_pattern 'private var quotaResetTimesRow' "$source_file" "reset-time card is missing"
require_pattern 'RuntimeResetTimes\(' "$source_file" "reset-time model is not used"
require_pattern 'ForEach\(Array\(resetTimes\.rows\.enumerated\(\)\)' "$source_file" "both ordered reset rows are not rendered"
require_pattern 'runtimeStatusPopoverHeight\(for _: Int\).*432|return 432' "$main_file" "popover height is not 432 pt"

if grep -Eq -- 'AppUpdateMenuRow\(' "$source_file"; then
    echo "runtime menu source test failed: popover must not render AppUpdateMenuRow" >&2
    exit 1
fi

echo "runtime menu source test passed"
