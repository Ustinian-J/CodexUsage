#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

grep -q '^APP_NAME := CodexS$' Makefile
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist \
  | grep -qx 'com.ustinianj.codexusage'
/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' Resources/Info.plist \
  | grep -qx 'CodexS'
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' Resources/Info.plist \
  | grep -qx 'CodexS'
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist \
  | grep -qx '0.3.0'
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist \
  | grep -qx '6'
grep -q '当前版本为 `0.3.0`' README.md
grep -q 'The current version is `0.3.0`' README.en.md
grep -q 'owner: String = "Ustinian-J"' Sources/CodexUsageWidget/Services/GitHubReleaseUpdateChecker.swift
grep -q 'repo: String = "CodexUsage"' Sources/CodexUsageWidget/Services/GitHubReleaseUpdateChecker.swift
grep -q 'automaticUpdateChecksEnabled = false' Sources/CodexUsageWidget/main.swift
grep -q '"CodexUsage.taskActivity.v1"' Sources/CodexUsageWidget/Services/CodexTaskMonitor.swift
grep -q 'Library/Caches/CodexUsage' Sources/CodexUsageWidget/Providers/RuntimeProvider.swift
grep -q '<AssemblyName>CodexS</AssemblyName>' windows/src/CodexS.Windows/CodexS.Windows.csproj
grep -q '<Version>0.3.0</Version>' windows/src/CodexS.Windows/CodexS.Windows.csproj
grep -q 'CodexS-0.3.0-windows-x64.exe' .github/workflows/windows.yml

identity_files=(Makefile)
while IFS= read -r file; do
  identity_files+=("$file")
done < <(find Sources Resources -type f -print)
while IFS= read -r file; do
  identity_files+=("$file")
done < <(find windows -type f -print)

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
