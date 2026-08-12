#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)}"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"

if [[ "$VERSION" != "$PLIST_VERSION" ]]; then
  echo "Requested version $VERSION does not match Info.plist version $PLIST_VERSION" >&2
  exit 1
fi

plutil -lint Resources/Info.plist
git diff --check

make test-macos-compatibility
make build >/dev/null
build/CodexS.app/Contents/MacOS/CodexS --self-test-statistics-time-zone
build/CodexS.app/Contents/MacOS/CodexS --self-test-status-item
build/CodexS.app/Contents/MacOS/CodexS --self-test-rate-limits
build/CodexS.app/Contents/MacOS/CodexS --self-test-runtime-provider-scopes
build/CodexS.app/Contents/MacOS/CodexS --self-test-task-progress
build/CodexS.app/Contents/MacOS/CodexS --self-test-task-activity
build/CodexS.app/Contents/MacOS/CodexS --self-test-local-security-boundaries
build/CodexS.app/Contents/MacOS/CodexS --self-test-quota-pace
build/CodexS.app/Contents/MacOS/CodexS --self-test-quota-alerts
build/CodexS.app/Contents/MacOS/CodexS --self-test-particle-animation
build/CodexS.app/Contents/MacOS/CodexS --self-test-updates
./scripts/test-parsers.sh

make release-all

verify_asset() {
  local arch="$1"
  local expected_arch="$2"
  local dmg="dist/CodexS-${VERSION}-mac-${arch}.dmg"
  local checksum="${dmg}.sha256"
  local mount_dir

  [[ -f "$dmg" ]] || { echo "Missing release asset: $dmg" >&2; exit 1; }
  [[ -f "$checksum" ]] || { echo "Missing checksum: $checksum" >&2; exit 1; }
  (cd "$(dirname "$checksum")" && shasum -a 256 -c "$(basename "$checksum")")
  hdiutil verify "$dmg" >/dev/null

  mount_dir="$(mktemp -d)"
  hdiutil attach -nobrowse -readonly -mountpoint "$mount_dir" "$dmg" >/dev/null
  file "$mount_dir/CodexS.app/Contents/MacOS/CodexS" | grep -q "$expected_arch"
  codesign --verify --deep --strict "$mount_dir/CodexS.app"
  hdiutil detach "$mount_dir" >/dev/null
  rmdir "$mount_dir"
}

verify_asset arm64 arm64
verify_asset x86_64 x86_64

echo "Release artifacts verified for CodexS $VERSION"
cat "dist/CodexS-${VERSION}-mac-arm64.dmg.sha256"
cat "dist/CodexS-${VERSION}-mac-x86_64.dmg.sha256"
