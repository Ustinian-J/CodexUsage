#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

WORKFLOW=".github/workflows/ci.yml"
[[ -f "$WORKFLOW" ]] || { echo "missing workflow: $WORKFLOW" >&2; exit 1; }

grep -Fqx '  contents: read' "$WORKFLOW"
grep -Fqx '          persist-credentials: false' "$WORKFLOW"

if grep -Eq '\$\{\{[[:space:]]*secrets\.' "$WORKFLOW"; then
  echo "CI must not consume repository secrets" >&2
  exit 1
fi

while IFS= read -r use_line; do
  action="${use_line#*uses: }"
  if [[ ! "$action" =~ ^actions/(checkout|upload-artifact)@[0-9a-f]{40}$ ]]; then
    echo "unapproved or unpinned action: $action" >&2
    exit 1
  fi
done < <(grep -E '^[[:space:]]+uses:' "$WORKFLOW")

grep -Fqx '        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5' "$WORKFLOW"
grep -Fqx '        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' "$WORKFLOW"
grep -Fqx '            runner: macos-15-intel' "$WORKFLOW"
grep -Fqx '            runner: macos-15' "$WORKFLOW"
grep -Fqx '            make_target: release-intel' "$WORKFLOW"
grep -Fqx '            make_target: release-arm64' "$WORKFLOW"

if grep -Eq 'check-release-ready|notarize-dmg|APPLE_ID|NOTARY_PASSWORD' Makefile; then
  echo "Makefile references an excluded release or credential path" >&2
  exit 1
fi

echo "CI supply-chain checks passed"
