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
if ($remote.Contains('FileName = "ssh.exe"')) {
    throw "Remote SSH must not resolve an executable through PATH"
}
foreach ($required in @('Environment.SystemDirectory', '"OpenSSH", "ssh.exe"', 'FileName = OpenSshPath',
        'BatchMode=yes', 'StrictHostKeyChecking=yes', 'ServerAliveCountMax=3',
        'RemoteHostName.Validate(host)', 'scan_started_at', 'scan_finished_at',
        'handle.read(CHUNK_BYTES)', 'MAX_LINE_BYTES = 1048576', 'ClockRolledBack',
        'RollbackRecoveryWindow', 'isinstance(path, str)', 'except FileNotFoundError:',
        'stat_module.S_ISDIR', 'walk_errors = []', 'if not initial_complete:')) {
    if (-not $remote.Contains($required)) { throw "Remote SSH safety invariant changed: $required" }
}
foreach ($forbidden in @('last_agent_message', 'ReadLineAsync', 'ReadToEndAsync', 'handle.read()')) {
    if ($remote.Contains($forbidden)) { throw "Remote monitor contains an unbounded or sensitive operation: $forbidden" }
}

$localMonitor = Get-Content (Join-Path $root "src/CodexS.Windows/CodexSessionMonitor.cs") -Raw
foreach ($forbidden in @('CopyTo(memory)', 'new MemoryStream()', 'reducer.RemoveStaleRunning',
        'IgnoreInaccessible = true', '.Where(Directory.Exists)')) {
    if ($localMonitor.Contains($forbidden)) { throw "Local task monitor contains an obsolete unbounded or runtime-pruning operation: $forbidden" }
}
foreach ($required in @('File.GetAttributes(root)', 'IgnoreInaccessible = false',
        'ShouldPublishRemoteEventImmediately',
        'ScheduleStateFlushLocked', 'FlushStateAfterDelayAsync')) {
    if (-not $localMonitor.Contains($required)) { throw "Local monitor safety invariant changed: $required" }
}
$bounded = Get-Content (Join-Path $root "src/CodexS.Windows/BoundedLineBuffer.cs") -Raw
foreach ($required in @('ChunkBytes = 64 * 1024', 'MaxLineBytes = 1024 * 1024', 'DiscardingOversizedLine')) {
    if (-not $bounded.Contains($required)) { throw "Bounded line safety invariant changed: $required" }
}
$reducer = Get-Content (Join-Path $root "src/CodexS.Windows/TaskActivityReducer.cs") -Raw
if (-not $reducer.Contains('DailyTaskLimit = 20_000') -or
        -not $reducer.Contains('terminalSet.Contains(id) || dailyTasks.ContainsKey(id)')) {
    throw "Daily task ledger must keep its audited hard record limit"
}

$project = Get-Content (Join-Path $root "src/CodexS.Windows/CodexS.Windows.csproj") -Raw
foreach ($required in @('<PublishSingleFile>true</PublishSingleFile>', '<SelfContained>true</SelfContained>', '<PublishTrimmed>false</PublishTrimmed>')) {
    if (-not $project.Contains($required)) { throw "Missing audited publish setting: $required" }
}
Write-Host "Windows source security checks passed"
