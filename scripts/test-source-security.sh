#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  echo "source security check failed: $1" >&2
  exit 1
}

for manifest in Package.swift Podfile Cartfile package.json package-lock.json yarn.lock pnpm-lock.yaml requirements.txt pyproject.toml; do
  [[ ! -e "$manifest" ]] || fail "third-party dependency manifest present: $manifest"
done

if find Sources Resources -type f \( \
  -name '*.dylib' -o -name '*.so' -o -name '*.a' -o \
  -name '*.framework' -o -name '*.xcframework' -o -name '*.jar' \
\) -print -quit | grep -q .; then
  fail "precompiled library present under Sources or Resources"
fi

if rg -n -i \
  'Keychain|SecItem|auth\.json|browser.*cookie|access[_-]?token|password|private[_-]?key' \
  Sources --glob '!*.md'; then
  fail "credential or secret access pattern found"
fi

if rg -n \
  'httpMethod[[:space:]]*=[[:space:]]*"(POST|PUT|PATCH|DELETE)"|uploadTask\(|downloadTask\(' \
  Sources --glob '!*.md'; then
  fail "network write or background download pattern found"
fi

network_files="$(rg -l 'URLSession|https?://' Sources --glob '!*.md' || true)"
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  case "$file" in
    Sources/CodexUsageWidget/Services/GitHubReleaseUpdateChecker.swift|\
    Sources/CodexUsageWidget/Domain/AppUpdate.swift|\
    Sources/CodexUsageWidget/Domain/AppUpdateSelfTest.swift)
      ;;
    *)
      fail "network capability outside the reviewed update checker: $file"
      ;;
  esac
done <<< "$network_files"

if rg -n -i \
  '(^|[^[:alnum:]_])(curl|wget|nc|ssh|scp|osascript|launchctl)([^[:alnum:]_]|$)|SMAppService|eval[[:space:]]*\(' \
  Sources scripts Makefile --glob '!test-source-security.sh' --glob '!*.md'; then
  fail "download, remote shell, scripting, or persistence pattern found"
fi

process_count="$(rg -n 'Process\(\)' Sources --glob '!*.md' | wc -l | tr -d ' ')"
[[ "$process_count" == "4" ]] || fail "Process launch surface changed: expected 4 reviewed sites, found $process_count"

rg -Fq 'process.arguments = ["app-server"]' Sources/CodexUsageWidget/main.swift \
  || fail "reviewed Codex app-server launch changed"
rg -Fq 'let grepPath = "/usr/bin/grep"' Sources/CodexUsageWidget/main.swift \
  || fail "reviewed grep launch changed"
rg -Fq 'process.arguments = ["-readonly", "-json", dbPath, query]' Sources/CodexUsageWidget/main.swift \
  || fail "reviewed read-only SQLite launch changed"
rg -Fq 'helper.executableURL = executableURL' Sources/CodexUsageWidget/Domain/GlobalShortcutSelfTest.swift \
  || fail "reviewed self-test helper launch changed"

echo "source security checks passed"
