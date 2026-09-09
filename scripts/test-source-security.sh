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
  case "$file" in
    Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift|\
    Sources/CodexUsageWidget/Services/ChatGPTSSHHostDiscovery.swift|\
    Sources/CodexUsageWidget/Domain/CodexTaskActivitySelfTest.swift)
      ;;
    *)
      fail "SSH capability outside the reviewed remote monitoring boundary: $file"
      ;;
  esac
done <<< "$ssh_files"

process_matches="$(grep -nF 'Process()' "${source_code_files[@]}" || true)"
process_count="$(printf '%s\n' "$process_matches" | sed '/^$/d' | wc -l | tr -d ' ')"
[[ "$process_count" == "9" ]] || fail "Process launch surface changed: expected 9 reviewed sites, found $process_count"

grep -Fq 'process.arguments = [' Sources/CodexUsageWidget/main.swift \
  || fail "reviewed Codex app-server launch changed"
for feature in plugins recommended_plugins remote_plugin apps; do
  grep -Fq "\"--disable\", \"$feature\"" Sources/CodexUsageWidget/main.swift \
    || fail "quota reader must disable unrelated app-server feature: $feature"
done
grep -Fq 'responseGroup.wait(timeout: .now() + 20)' Sources/CodexUsageWidget/main.swift \
  || fail "quota reader timeout must cover the app-server reset-credit fallback"
grep -Fq 'LIMIT 24;' Sources/CodexUsageWidget/main.swift \
  || fail "local quota fallback must bound the rollout candidate set"
grep -Fq 'let maximumBytes: UInt64 = 512 * 1024' Sources/CodexUsageWidget/main.swift \
  || fail "local quota fallback must bound bytes read per rollout"
grep -Fq 'values.isSymbolicLink != true' Sources/CodexUsageWidget/main.swift \
  || fail "local quota fallback must reject symlinks"
if grep -Fq '"id": 4, "method": "account/usage/read"' Sources/CodexUsageWidget/main.swift; then
  fail "quota reader must not request the unrelated slow cloud usage profile"
fi
grep -Fq 'let grepPath = "/usr/bin/grep"' Sources/CodexUsageWidget/main.swift \
  || fail "reviewed grep launch changed"
grep -Fq 'process.arguments = ["-readonly", "-json", dbPath, query]' Sources/CodexUsageWidget/Services/ReadOnlySQLite.swift \
  || fail "reviewed read-only SQLite launch changed"
grep -Fq 'process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")' Sources/CodexUsageWidget/Services/CodexTaskMonitor.swift \
  || fail "reviewed rollout liveness executable changed"
grep -Fq 'process.arguments = ["-n", "-P", "-w", "-S", "2", "-F0n", "--"] + candidates' Sources/CodexUsageWidget/Services/CodexTaskMonitor.swift \
  || fail "reviewed rollout liveness arguments changed"
grep -Fq 'helper.executableURL = executableURL' Sources/CodexUsageWidget/Domain/GlobalShortcutSelfTest.swift \
  || fail "reviewed self-test helper launch changed"
grep -Fq 'process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift \
  || fail "reviewed SSH executable changed"
grep -Fq 'process.executableURL = URL(fileURLWithPath: "/bin/ps")' Sources/CodexUsageWidget/Services/ChatGPTSSHHostDiscovery.swift \
  || fail "reviewed ChatGPT SSH discovery executable changed"
grep -Fq 'arguments: ["-axo", "pid=,ppid=,ucomm="]' Sources/CodexUsageWidget/Services/ChatGPTSSHHostDiscovery.swift \
  || fail "ChatGPT SSH discovery must first inspect process ownership without unrelated command lines"
grep -Fq 'allowedProcessIDs.contains(processID)' Sources/CodexUsageWidget/Services/ChatGPTSSHHostDiscovery.swift \
  || fail "ChatGPT SSH discovery command-line phase must remain scoped to owned SSH process IDs"
grep -Fq 'CodexBoundedPipeCollector(maximumBytes: maximumOutputBytes)' Sources/CodexUsageWidget/Services/ChatGPTSSHHostDiscovery.swift \
  || fail "ChatGPT SSH discovery output must remain bounded"
grep -Fq 'hasAncestor(record.parentProcessID, in: chatGPTRoots' Sources/CodexUsageWidget/Services/ChatGPTSSHHostDiscovery.swift \
  || fail "remote discovery must require ChatGPT process ancestry"
grep -Fq 'CodexRemoteHost.validated(token)' Sources/CodexUsageWidget/Services/ChatGPTSSHHostDiscovery.swift \
  || fail "discovered SSH hosts must pass validation"
grep -Fq 'CodexRemoteHost.validated(host) == host' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift \
  || fail "remote SSH host validation changed"
for option in 'BatchMode=yes' 'StrictHostKeyChecking=yes' 'ServerAliveCountMax=3' \
  'ControlMaster=no' 'ControlPersist=no' 'ControlPath=none'; do
  grep -Fq "\"$option\"" Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift \
    || fail "reviewed SSH safety option changed: $option"
done
grep -Fq '"-F", sshConfigPath' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift \
  || fail "remote SSH must use the isolated config for ProxyJump children"
grep -Fq 'process.arguments = ["-G", host]' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift \
  || fail "SSH control reuse must resolve the configured alias without opening a connection"
grep -Fq 'status.st_uid == geteuid()' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift \
  || fail "SSH control reuse must require a socket owned by the current user"
grep -Fq 'Darwin.symlink(source, link)' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift \
  || fail "SSH control reuse must use an isolated link instead of the user control path directly"
grep -Fq 'Darwin.mkdir($0, S_IRWXU)' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift \
  || fail "SSH control reuse must protect its short temporary directory with mode 0700"
grep -Fq 'linkURL.path.utf8.count <= 100' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift \
  || fail "SSH control reuse must stay below the Unix socket path limit"
grep -Fq '"-O", "check"' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift \
  || fail "SSH control reuse must verify that the existing master is live"
grep -Fq '"ControlMaster=auto"' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift \
  || fail "SSH control reuse must opt in only for a verified existing master"
grep -Fq 'Include ~/.ssh/config' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift \
  || fail "isolated SSH config no longer imports validated user aliases"
grep -Fq 'Include /etc/ssh/ssh_config' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift \
  || fail "isolated SSH config no longer imports system aliases"
grep -Fq 'queue.sync {' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift \
  || fail "remote SSH shutdown must finish synchronously"
ssh_config_block="$(sed -n '/let contents = """/,/^[[:space:]]*"""/p' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift)"
include_line="$(printf '%s\n' "$ssh_config_block" | grep -nF 'Include ' | head -1 | cut -d: -f1)"
[[ -n "$include_line" ]] || fail "isolated SSH config is missing the user config include"
for option in 'BatchMode yes' 'StrictHostKeyChecking yes' 'ConnectTimeout 8' \
  'ControlMaster no' 'ControlPersist no' 'ControlPath none'; do
  option_line="$(printf '%s\n' "$ssh_config_block" | grep -nF "$option" | head -1 | cut -d: -f1)"
  [[ -n "$option_line" && "$option_line" -lt "$include_line" ]] \
    || fail "isolated SSH option must precede the user config include: $option"
done
grep -Fq 'probeQueue.async {' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift \
  || fail "SSH control reuse probes must not block the monitor lifecycle queue"
grep -Fq 'self.authorizationGeneration == authorization' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift \
  || fail "SSH control reuse completion must reject stale authorization generations"
grep -Fq 'self.connectionGeneration == connection' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift \
  || fail "SSH control reuse completion must reject stale connection generations"
grep -Fq 'static let remoteCommand = "/usr/bin/env CODEXS_REMOTE_SCRIPT="' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift \
  || fail "remote command must use env for POSIX and C-family login shell compatibility"
stop_block="$(sed -n '/^[[:space:]]*func stop() {/,/^[[:space:]]*private func launch()/p' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift)"
for invariant in 'queue.sync {' 'restartWorkItem?.cancel()' 'terminateSSHChild()'; do
  printf '%s\n' "$stop_block" | grep -Fq "$invariant" \
    || fail "remote SSH synchronous stop invariant changed: $invariant"
done
terminate_block="$(sed -n '/^[[:space:]]*private func terminateSSHChild()/,/^[[:space:]]*private func prepareIsolatedSSHConfig()/p' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift)"
for invariant in 'systemUptime + 0.5' 'usleep(10_000)' 'Darwin.kill(process.processIdentifier, SIGKILL)'; do
  printf '%s\n' "$terminate_block" | grep -Fq "$invariant" \
    || fail "remote SSH bounded termination invariant changed: $invariant"
done
grep -Fq 'remoteMonitorIDs[key] == monitorID' Sources/CodexUsageWidget/Services/CodexTaskMonitor.swift \
  || fail "stale remote monitor callbacks must be rejected by generation"
grep -Fq 'static let delays: [TimeInterval] = [10, 30, 60, 120, 300]' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift \
  || fail "remote SSH reconnect backoff changed"
grep -Fq 'requestRemoteHostDiscovery(forceRestartUnavailable: true)' Sources/CodexUsageWidget/Services/CodexTaskMonitor.swift \
  || fail "manual remote refresh must rediscover ChatGPT-owned SSH before reconnecting"
grep -Fq 'applyDiscoveredRemoteHosts([])' Sources/CodexUsageWidget/Services/CodexTaskMonitor.swift \
  || fail "remote monitoring must fail closed when ChatGPT SSH discovery is unavailable"
grep -Fq 'taskActivityStore.refreshRemoteMonitoring()' Sources/CodexUsageWidget/main.swift \
  || fail "manual refresh no longer reconnects authorized remote monitoring"
grep -Fq 'taskActivityStore.start(remoteMonitoringEnabled: settings.remoteMonitoringEnabled)' Sources/CodexUsageWidget/main.swift \
  || fail "application startup no longer restores explicit remote-monitor authorization"
if grep -Fq 'last_agent_message' Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift; then
  fail "remote task monitor must not select or transmit completion message text"
fi
if grep -Fq 'preview' Sources/CodexUsageWidget/Services/CodexTaskMonitor.swift \
  Sources/CodexUsageWidget/Services/RemoteCodexTaskMonitor.swift; then
  fail "task monitors must not select or transmit conversation preview text"
fi
if grep -Fq '/tmp/codexusage.log' Sources/CodexUsageWidget/main.swift Sources/CodexUsageWidget/Services/*.swift; then
  fail "debug logs must not use a shared predictable /tmp path"
fi
grep -Fq 'O_NOFOLLOW' Sources/CodexUsageWidget/Services/SecureDebugLogWriter.swift \
  || fail "secure debug logging must reject symbolic links"
grep -Fq 'SkillFileAccessPolicy.read(path: path)' Sources/CodexUsageWidget/main.swift \
  || fail "Skill metadata reads must use the reviewed bounded file policy"
if grep -nF 'Data(contentsOf:' Sources/CodexUsageWidget/main.swift | grep -Fq 'skill'; then
  fail "Skill metadata must not use an unbounded Data(contentsOf:) read"
fi

echo "source security checks passed"
