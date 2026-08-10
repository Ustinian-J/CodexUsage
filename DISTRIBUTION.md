# CodexS Distribution

CodexS is distributed as macOS DMGs and a self-contained Windows EXE.

## Supported Targets

- macOS 13 or later.
- Apple Silicon with the `arm64` DMG.
- Intel with the `x86_64` DMG.
- A local Codex installation and signed-in account are required for live quota data.
- Windows 10 version 1809 or later / Windows 11 x64 with the `windows-x64.exe`; native Windows sessions and optional Linux/macOS SSH task sources are supported.
- Remote task monitoring requires a working system OpenSSH client, a configured non-interactive host alias, strict known-host verification, and Python 3 on the remote host.

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
shasum -a 256 -c dist/CodexS-<version>-mac-<arch>.dmg.sha256
hdiutil verify dist/CodexS-<version>-mac-<arch>.dmg
```

Mount it read-only, inspect the binary architecture, and verify its signature:

```sh
mount_dir="$(mktemp -d)"
hdiutil attach -nobrowse -readonly -mountpoint "$mount_dir" dist/CodexS-<version>-mac-<arch>.dmg
file "$mount_dir/CodexS.app/Contents/MacOS/CodexS"
codesign --verify --deep --strict "$mount_dir/CodexS.app"
hdiutil detach "$mount_dir"
rmdir "$mount_dir"
```

The repository CI performs these checks for Intel on `macos-15-intel` and Apple Silicon on the arm64 `macos-15` runner.

## Windows Installer

Download `CodexS-<version>-windows-x64.exe` and its checksum. The EXE is self-contained: double-clicking offers either a per-user install under `%LOCALAPPDATA%\Programs\CodexS` or a one-time run. Installation does not require administrator rights, login startup is off by default, and uninstall is available from the tray menu and Windows Installed Apps.

```powershell
(Get-FileHash .\CodexS-<version>-windows-x64.exe -Algorithm SHA256).Hash.ToLower()
Get-Content .\CodexS-<version>-windows-x64.exe.sha256
```

The Windows build uses only .NET WinForms and Windows system APIs, with no NuGet business packages, WebView, third-party installer, downloaded script, or precompiled library in the repository. It reads native Windows Codex JSONL under `%USERPROFILE%\.codex` and starts the user's installed `codex app-server` only for quota reads. Unsigned test builds can trigger Microsoft Defender SmartScreen's unknown-publisher warning; SHA-256 verification confirms file integrity but does not replace Authenticode publisher identity.

## CI Supply-Chain Policy

- Workflow permission is limited to `contents: read`.
- Repository secrets are not consumed.
- Only GitHub-owned actions are allowed.
- Every action is pinned to a reviewed 40-character commit SHA.
- `scripts/test-ci-security.sh` rejects floating tags, unapproved actions, secret references, or reintroduction of excluded credential-bearing release scripts.

## Public Signing and Notarization

Developer ID signing and Apple notarization are intentionally not automated in this repository yet. The audited import excluded upstream credential-handling notarization scripts. A future public release workflow must be reviewed separately, use a dedicated Developer ID identity, keep credentials in GitHub protected environments, and run Apple's `notarytool` without logging secrets.

Until that workflow exists, artifacts are for personal/test installation and must not be described as notarized.
