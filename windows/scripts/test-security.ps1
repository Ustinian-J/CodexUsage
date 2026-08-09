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

$project = Get-Content (Join-Path $root "src/CodexS.Windows/CodexS.Windows.csproj") -Raw
foreach ($required in @('<PublishSingleFile>true</PublishSingleFile>', '<SelfContained>true</SelfContained>', '<PublishTrimmed>false</PublishTrimmed>')) {
    if (-not $project.Contains($required)) { throw "Missing audited publish setting: $required" }
}
Write-Host "Windows source security checks passed"
