#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

grep -q '^APP_NAME := CodexUsage$' Makefile
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist \
  | grep -qx 'com.ustinianj.codexusage'
/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' Resources/Info.plist \
  | grep -qx 'CodexUsage'
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' Resources/Info.plist \
  | grep -qx 'CodexUsage'
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist \
  | grep -qx '0.2.3'
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist \
  | grep -qx '5'
grep -q '当前版本为 `0.2.3`' README.md
grep -q 'The current version is `0.2.3`' README.en.md
grep -q 'owner: String = "Ustinian-J"' Sources/CodexUsageWidget/Services/GitHubReleaseUpdateChecker.swift
grep -q 'repo: String = "CodexUsage"' Sources/CodexUsageWidget/Services/GitHubReleaseUpdateChecker.swift
grep -q 'automaticUpdateChecksEnabled = false' Sources/CodexUsageWidget/main.swift

identity_files=(Makefile)
while IFS= read -r file; do
  identity_files+=("$file")
done < <(find Sources Resources -type f -print)

if grep -nE 'shanggqm/codexU' "${identity_files[@]}"; then
  echo "legacy upstream repository identity found" >&2
  exit 1
fi

while IFS= read -r file; do
  [[ "$file" == "scripts/test-product-identity.sh" ]] && continue
  identity_files+=("$file")
done < <(find scripts -type f -print)

if grep -nEi '(^|[^[:alnum:]_])codexu([^[:alnum:]_]|$)|codexu\.' "${identity_files[@]}"; then
  echo "legacy product identity found" >&2
  exit 1
fi

echo "product identity checks passed"
