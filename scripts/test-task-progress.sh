#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

make build >/dev/null
build/CodexUsage.app/Contents/MacOS/CodexUsage --self-test-task-progress
