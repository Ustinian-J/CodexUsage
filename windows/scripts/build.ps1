$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root "src/CodexS.Windows/CodexS.Windows.csproj"
$publish = Join-Path $root "artifacts/publish"
$dist = Join-Path $root "../dist"
$version = "0.3.0"
$asset = Join-Path $dist "CodexS-$version-windows-x64.exe"

if (Test-Path $publish) { Remove-Item $publish -Recurse -Force }
New-Item -ItemType Directory -Force -Path $publish, $dist | Out-Null

dotnet publish $project -c Release -r win-x64 --self-contained true -o $publish
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }

$outputs = @(Get-ChildItem $publish -File)
if ($outputs.Count -ne 1 -or $outputs[0].Name -ne "CodexS.exe") {
    throw "Expected exactly one self-contained CodexS.exe output"
}
Copy-Item $outputs[0].FullName $asset -Force

& $asset --self-test-all
if ($LASTEXITCODE -ne 0) { throw "Windows self-tests failed" }

$hash = (Get-FileHash $asset -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $(Split-Path $asset -Leaf)" | Set-Content "$asset.sha256" -Encoding ascii -NoNewline
Write-Host "Windows release artifact: $asset"
