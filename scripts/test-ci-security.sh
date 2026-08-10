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
grep -Fq 'FileName = "ssh.exe"' windows/src/CodexS.Windows/RemoteCodexTaskMonitor.cs
grep -Fq 'RemoteHostName.Validate(host)' windows/src/CodexS.Windows/RemoteCodexTaskMonitor.cs
grep -Fq 'StrictHostKeyChecking=yes' windows/src/CodexS.Windows/RemoteCodexTaskMonitor.cs
if grep -Fq 'last_agent_message' windows/src/CodexS.Windows/RemoteCodexTaskMonitor.cs; then
  echo "Windows remote monitor must not select message text" >&2
  exit 1
fi

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
