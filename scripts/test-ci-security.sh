#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

WORKFLOW=".github/workflows/ci.yml"
WINDOWS_WORKFLOW=".github/workflows/windows.yml"
[[ -f "$WORKFLOW" ]] || { echo "missing workflow: $WORKFLOW" >&2; exit 1; }
[[ -f "$WINDOWS_WORKFLOW" ]] || { echo "missing workflow: $WINDOWS_WORKFLOW" >&2; exit 1; }

for workflow in "$WORKFLOW" "$WINDOWS_WORKFLOW"; do
  grep -Fqx '  contents: read' "$workflow"
  grep -Fqx '          persist-credentials: false' "$workflow"
done

if grep -Eq '\$\{\{[[:space:]]*secrets\.' "$WORKFLOW" "$WINDOWS_WORKFLOW"; then
  echo "CI must not consume repository secrets" >&2
  exit 1
fi

while IFS= read -r use_line; do
  action="${use_line#*uses: }"
  if [[ ! "$action" =~ ^actions/(checkout|upload-artifact|setup-dotnet)@[0-9a-f]{40}$ ]]; then
    echo "unapproved or unpinned action: $action" >&2
    exit 1
  fi
done < <(grep -E '^[[:space:]]+uses:' "$WORKFLOW" "$WINDOWS_WORKFLOW" | sed -E 's/^[^:]+://')

grep -Fqx '        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5' "$WORKFLOW"
grep -Fqx '        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' "$WORKFLOW"
grep -Fqx '        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5' "$WINDOWS_WORKFLOW"
grep -Fqx '        uses: actions/setup-dotnet@26b0ec14cb23fa6904739307f278c14f94c95bf1' "$WINDOWS_WORKFLOW"
grep -Fqx '        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' "$WINDOWS_WORKFLOW"
grep -Fqx '            runner: macos-15-intel' "$WORKFLOW"
grep -Fqx '            runner: macos-15' "$WORKFLOW"
grep -Fqx '            make_target: release-intel' "$WORKFLOW"
grep -Fqx '            make_target: release-arm64' "$WORKFLOW"
grep -Fqx '    runs-on: windows-2025' "$WINDOWS_WORKFLOW"
grep -Fqx '    "version": "10.0.302",' windows/global.json

if find windows -type f \( -name '*.dll' -o -name '*.sys' -o -name '*.bat' \) -print -quit | grep -q .; then
  echo "Windows source contains a forbidden precompiled or batch payload" >&2
  exit 1
fi
if grep -R --exclude='test-security.ps1' -nE '<PackageReference|auth\.json|HttpClient|WebClient|Download(File|String)|Invoke-Expression' windows/src windows/scripts; then
  echo "Windows source contains a forbidden dependency, credential path, or downloader" >&2
  exit 1
fi
WINDOWS_REMOTE_MONITOR='windows/src/CodexS.Windows/RemoteCodexTaskMonitor.cs'
if grep -Fq 'FileName = "ssh.exe"' "$WINDOWS_REMOTE_MONITOR"; then
  echo "Windows remote monitor must not resolve SSH through PATH" >&2
  exit 1
fi
for invariant in \
  'Environment.SystemDirectory' \
  '"OpenSSH", "ssh.exe"' \
  'FileName = OpenSshPath' \
  'RemoteHostName.Validate(host)' \
  'BatchMode=yes' \
  'StrictHostKeyChecking=yes' \
  'ServerAliveCountMax=3' \
  'ControlMaster=no' \
  'ControlPersist=no' \
  'ControlPath=none' \
  '"-F", sshConfigPath' \
  'Include ~/.ssh/config' \
  'TimeSpan.FromMinutes(5)' \
  'scan_started_at' \
  'scan_finished_at' \
  'handle.read(CHUNK_BYTES)' \
  'MAX_LINE_BYTES = 1048576' \
  'ClockRolledBack' \
  'RollbackRecoveryWindow' \
  'isinstance(path, str)' \
  'except FileNotFoundError:' \
  'stat_module.S_ISDIR' \
  'walk_errors = []' \
  'if not initial_complete:'; do
  grep -Fq "$invariant" "$WINDOWS_REMOTE_MONITOR" || {
    echo "missing Windows remote safety invariant: $invariant" >&2
    exit 1
  }
done
grep -Fq 'monitor.RefreshRemoteMonitoring();' windows/src/CodexS.Windows/TrayApplicationContext.cs || {
  echo "Windows manual refresh no longer reconnects authorized remote monitoring" >&2
  exit 1
}
grep -Fq 'if (remoteMonitoringEnabled) SynchronizeRemoteMonitoring();' windows/src/CodexS.Windows/CodexSessionMonitor.cs || {
  echo "Windows application startup no longer restores explicit remote-monitor authorization" >&2
  exit 1
}
grep -Fq 'if (!remoteMonitoringEnabled) return;' windows/src/CodexS.Windows/CodexSessionMonitor.cs || {
  echo "Windows remote monitoring no longer requires explicit persisted authorization" >&2
  exit 1
}
for forbidden in 'last_agent_message' 'ReadLineAsync' 'ReadToEndAsync' 'handle.read()'; do
  if grep -Fq "$forbidden" "$WINDOWS_REMOTE_MONITOR"; then
    echo "Windows remote monitor contains an unbounded or sensitive operation: $forbidden" >&2
    exit 1
  fi
done

WINDOWS_LOCAL_MONITOR='windows/src/CodexS.Windows/CodexSessionMonitor.cs'
for forbidden in 'CopyTo(memory)' 'new MemoryStream()' 'reducer.RemoveStaleRunning' \
  'IgnoreInaccessible = true' '.Where(Directory.Exists)'; do
  if grep -Fq "$forbidden" "$WINDOWS_LOCAL_MONITOR"; then
    echo "Windows local monitor contains an obsolete unbounded or runtime-pruning operation: $forbidden" >&2
    exit 1
  fi
done
for invariant in 'File.GetAttributes(root)' 'IgnoreInaccessible = false' \
  'ShouldPublishRemoteEventImmediately' \
  'ScheduleStateFlushLocked' 'FlushStateAfterDelayAsync'; do
  grep -Fq "$invariant" "$WINDOWS_LOCAL_MONITOR" || {
    echo "missing Windows local monitor safety invariant: $invariant" >&2
    exit 1
  }
done
for invariant in 'ChunkBytes = 64 * 1024' 'MaxLineBytes = 1024 * 1024' 'DiscardingOversizedLine'; do
  grep -Fq "$invariant" windows/src/CodexS.Windows/BoundedLineBuffer.cs || {
    echo "missing Windows bounded-line invariant: $invariant" >&2
    exit 1
  }
done
grep -Fq 'DailyTaskLimit = 20_000' windows/src/CodexS.Windows/TaskActivityReducer.cs || {
  echo "missing Windows daily task ledger bound" >&2
  exit 1
}
grep -Fq 'terminalSet.Contains(id) || dailyTasks.ContainsKey(id)' windows/src/CodexS.Windows/TaskActivityReducer.cs || {
  echo "missing Windows extended terminal deduplication" >&2
  exit 1
}

if grep -Eq 'check-release-ready|notarize-dmg|APPLE_ID|NOTARY_PASSWORD' Makefile; then
  echo "Makefile references an excluded release or credential path" >&2
  exit 1
fi

if grep -Fq 'rg ' \
  scripts/test-product-identity.sh \
  scripts/test-source-security.sh \
  scripts/test-runtime-menu.sh; then
  echo "CI audit scripts must use macOS system tools only" >&2
  exit 1
fi

echo "CI supply-chain checks passed"
