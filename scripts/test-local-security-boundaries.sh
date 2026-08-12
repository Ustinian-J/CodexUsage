#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

make build
build/CodexS.app/Contents/MacOS/CodexS --self-test-local-security-boundaries
