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
grep -q 'owner: String = "Ustinian-J"' Sources/CodexUsageWidget/Services/GitHubReleaseUpdateChecker.swift
grep -q 'repo: String = "CodexUsage"' Sources/CodexUsageWidget/Services/GitHubReleaseUpdateChecker.swift
grep -q 'automaticUpdateChecksEnabled = false' Sources/CodexUsageWidget/main.swift
! rg -n 'shanggqm/codexU' Sources Resources Makefile

echo "product identity checks passed"
