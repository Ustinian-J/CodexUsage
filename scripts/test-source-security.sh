#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  echo "source security check failed: $1" >&2
  exit 1
}

source_code_files=()
while IFS= read -r file; do
  source_code_files+=("$file")
done < <(find Sources -type f ! -name '*.md' -print)

for manifest in Package.swift Podfile Cartfile package.json package-lock.json yarn.lock pnpm-lock.yaml requirements.txt pyproject.toml; do
  [[ ! -e "$manifest" ]] || fail "third-party dependency manifest present: $manifest"
done

if find Sources Resources -type f \( \
  -name '*.dylib' -o -name '*.so' -o -name '*.a' -o \
  -name '*.framework' -o -name '*.xcframework' -o -name '*.jar' \
\) -print -quit | grep -q .; then
  fail "precompiled library present under Sources or Resources"
fi

if grep -nEi \
  'Keychain|SecItem|auth\.json|browser.*cookie|access[_-]?token|password|private[_-]?key' \
  "${source_code_files[@]}"; then
  fail "credential or secret access pattern found"
fi

if grep -nE \
  'httpMethod[[:space:]]*=[[:space:]]*"(POST|PUT|PATCH|DELETE)"|uploadTask\(|downloadTask\(' \
  "${source_code_files[@]}"; then
  fail "network write or background download pattern found"
fi

network_files="$(grep -lE 'URLSession|https?://' "${source_code_files[@]}" || true)"
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

reviewed_files=(Makefile)
while IFS= read -r file; do
  [[ "$file" == "scripts/test-source-security.sh" || "$file" == *.md ]] && continue
  reviewed_files+=("$file")
done < <(find Sources scripts -type f -print)

if grep -nEi \
  '(^|[^[:alnum:]_])(curl|wget|nc|scp|osascript|launchctl)([^[:alnum:]_]|$)|SMAppService|eval[[:space:]]*\(' \
  "${reviewed_files[@]}"; then
  fail "download, remote shell, scripting, or persistence pattern found"
fi

ssh_files="$(grep -lE '/usr/bin/ssh|executable(URL|Path).*[sS][sS][hH]' "${source_code_files[@]}" || true)"
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  [[ "$file" == "Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift" ]] \
    || fail "SSH capability outside the reviewed remote task monitor: $file"
done <<< "$ssh_files"

process_matches="$(grep -nF 'Process()' "${source_code_files[@]}" || true)"
process_count="$(printf '%s\n' "$process_matches" | sed '/^$/d' | wc -l | tr -d ' ')"
[[ "$process_count" == "5" ]] || fail "Process launch surface changed: expected 5 reviewed sites, found $process_count"

grep -Fq 'process.arguments = ["app-server"]' Sources/CodexUsageWidget/main.swift \
  || fail "reviewed Codex app-server launch changed"
grep -Fq 'let grepPath = "/usr/bin/grep"' Sources/CodexUsageWidget/main.swift \
  || fail "reviewed grep launch changed"
grep -Fq 'process.arguments = ["-readonly", "-json", dbPath, query]' Sources/CodexUsageWidget/Services/ReadOnlySQLite.swift \
  || fail "reviewed read-only SQLite launch changed"
grep -Fq 'helper.executableURL = executableURL' Sources/CodexUsageWidget/Domain/GlobalShortcutSelfTest.swift \
  || fail "reviewed self-test helper launch changed"
grep -Fq 'process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift \
  || fail "reviewed SSH executable changed"
grep -Fq 'CodexRemoteHost.validated(host) == host' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift \
  || fail "remote SSH host validation changed"
for option in 'BatchMode=yes' 'StrictHostKeyChecking=yes' 'ServerAliveCountMax=3'; do
  grep -Fq "\"$option\"" Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift \
    || fail "reviewed SSH safety option changed: $option"
done
if grep -Fq 'last_agent_message' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift; then
  fail "remote task monitor must not select or transmit completion message text"
fi

echo "source security checks passed"
