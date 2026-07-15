#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

make build >/dev/null
binary="build/CodexUsage.app/Contents/MacOS/CodexUsage"
"$binary" --self-test-reset-credits
"$binary" --self-test-subscription-expiration
