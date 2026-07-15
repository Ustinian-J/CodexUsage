# CodexUsage Distribution

CodexUsage is distributed outside the Mac App Store as a DMG.

## Supported Targets

- macOS 13 or later.
- Apple Silicon with the `arm64` DMG.
- Intel with the `x86_64` DMG.
- A local Codex installation and signed-in account are required for live quota data.

## Local Test Build

```sh
make release
```

The command creates an ad-hoc signed DMG and a SHA-256 file under `dist/`. Gatekeeper may require a manual **Open Anyway** confirmation on another Mac.

Explicit architecture targets:

```sh
make release-arm64
make release-intel
make release-all
```

The equivalent Intel override is:

```sh
make clean release TARGET_TRIPLE="x86_64-apple-macos13.0"
```

## Verify an Artifact

```sh
shasum -a 256 -c dist/CodexUsage-<version>-mac-<arch>.dmg.sha256
hdiutil verify dist/CodexUsage-<version>-mac-<arch>.dmg
```

Mount it read-only, inspect the binary architecture, and verify its signature:

```sh
mount_dir="$(mktemp -d)"
hdiutil attach -nobrowse -readonly -mountpoint "$mount_dir" dist/CodexUsage-<version>-mac-<arch>.dmg
file "$mount_dir/CodexUsage.app/Contents/MacOS/CodexUsage"
codesign --verify --deep --strict "$mount_dir/CodexUsage.app"
hdiutil detach "$mount_dir"
rmdir "$mount_dir"
```

The repository CI performs these checks for Intel on `macos-15-intel` and Apple Silicon on the arm64 `macos-15` runner.

## CI Supply-Chain Policy

- Workflow permission is limited to `contents: read`.
- Repository secrets are not consumed.
- Only GitHub-owned actions are allowed.
- Every action is pinned to a reviewed 40-character commit SHA.
- `scripts/test-ci-security.sh` rejects floating tags, unapproved actions, secret references, or reintroduction of excluded credential-bearing release scripts.

## Public Signing and Notarization

Developer ID signing and Apple notarization are intentionally not automated in this repository yet. The audited import excluded upstream credential-handling notarization scripts. A future public release workflow must be reviewed separately, use a dedicated Developer ID identity, keep credentials in GitHub protected environments, and run Apple's `notarytool` without logging secrets.

Until that workflow exists, artifacts are for personal/test installation and must not be described as notarized.
