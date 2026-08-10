$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$sources = Get-ChildItem (Join-Path $root "src") -Recurse -File

if ($sources | Select-String -Pattern '<PackageReference|auth\.json|HttpClient|WebClient|Download(File|String)|Invoke-Expression|Add-MpPreference|Set-MpPreference') {
    throw "Windows source security policy rejected a forbidden dependency, credential path, downloader, or security-control change"
}
if (Get-ChildItem $root -Recurse -File -Include *.dll,*.sys,*.bat) {
    throw "Precompiled libraries, drivers, and batch files are forbidden"
}

$remote = Get-Content (Join-Path $root "src/CodexS.Windows/RemoteCodexTaskMonitor.cs") -Raw
foreach ($required in @('FileName = "ssh.exe"', 'BatchMode=yes', 'StrictHostKeyChecking=yes', 'RemoteHostName.Validate(host)')) {
    if (-not $remote.Contains($required)) { throw "Remote SSH safety invariant changed: $required" }
}
if ($remote.Contains('last_agent_message')) {
    throw "Remote monitor must not select or transmit completion message text"
}

$project = Get-Content (Join-Path $root "src/CodexS.Windows/CodexS.Windows.csproj") -Raw
foreach ($required in @('<PublishSingleFile>true</PublishSingleFile>', '<SelfContained>true</SelfContained>', '<PublishTrimmed>false</PublishTrimmed>')) {
    if (-not $project.Contains($required)) { throw "Missing audited publish setting: $required" }
}
Write-Host "Windows source security checks passed"
