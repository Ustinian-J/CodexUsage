using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CodexS.Windows;

internal static class RemoteHostName
{
    internal static string? Validate(string raw)
    {
        var value = raw.Trim();
        if (value.Length is 0 or > 255 || !char.IsLetterOrDigit(value[0])) return null;
        return value.All(character => char.IsLetterOrDigit(character) || character is '.' or '-' or '_')
            ? value : null;
    }

    internal static IReadOnlyList<string> Parse(string raw)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        return raw.Split([',', ';', ' ', '\t', '\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
            .Select(Validate).Where(value => value is not null && seen.Add(value)).Cast<string>().ToArray();
    }
}

internal static class RemoteReplayPolicy
{
    private static readonly TimeSpan RollbackRecoveryWindow = TimeSpan.FromDays(8);

    internal static bool ClockRolledBack(
        DateTimeOffset? previousCheckpoint, DateTimeOffset currentScanStart) =>
        previousCheckpoint is { } previous && currentScanStart < previous;

    internal static DateTimeOffset Cutoff(DateTimeOffset? previousCheckpoint, DateTimeOffset currentScanStart) =>
        previousCheckpoint is null || ClockRolledBack(previousCheckpoint, currentScanStart)
            ? currentScanStart : previousCheckpoint.Value;

    internal static TaskEventOrigin Origin(
        TaskEvent taskEvent, DateTimeOffset cutoff, bool clockRolledBack) =>
        clockRolledBack && taskEvent.Kind != TaskEventKind.Started
            ? taskEvent.OccurredAt >= cutoff - RollbackRecoveryWindow
                ? TaskEventOrigin.Recovery : TaskEventOrigin.Baseline
            : taskEvent.OccurredAt < cutoff ? TaskEventOrigin.Baseline : TaskEventOrigin.Recovery;

    internal static bool ShouldSkipStaleStart(
        TaskEvent taskEvent, TaskEventOrigin origin, DateTimeOffset scanStart, bool clockRolledBack) =>
        (origin == TaskEventOrigin.Baseline || clockRolledBack)
        && taskEvent.Kind == TaskEventKind.Started
        && taskEvent.OccurredAt < scanStart.AddHours(-12);
}

internal static class RemoteConnectionRetryPolicy
{
    internal static readonly TimeSpan[] Delays = [
        TimeSpan.FromSeconds(10),
        TimeSpan.FromSeconds(30),
        TimeSpan.FromMinutes(1),
        TimeSpan.FromMinutes(2),
        TimeSpan.FromMinutes(5)
    ];
    internal static readonly TimeSpan StableConnectionInterval = TimeSpan.FromMinutes(1);

    internal static int NormalizeFailures(int consecutiveFailures, TimeSpan? readyDuration) =>
        readyDuration >= StableConnectionInterval ? 0 : Math.Max(0, consecutiveFailures);

    internal static TimeSpan DelayForFailure(int consecutiveFailures) =>
        Delays[Math.Min(Math.Max(0, consecutiveFailures), Delays.Length - 1)];
}

internal sealed class RemoteHostStore
{
    private sealed class Settings
    {
        public Settings() { }
        public int SchemaVersion { get; set; }
        public List<string> Hosts { get; set; } = [];
        public Dictionary<string, DateTimeOffset> Checkpoints { get; set; } = new(StringComparer.OrdinalIgnoreCase);
        public bool Enabled { get; set; }
    }

    private Settings settings = LoadSettings();

    internal IReadOnlyList<string> Hosts => settings.Hosts;
    internal bool Enabled => settings.Enabled;
    internal DateTimeOffset? Checkpoint(string host) => settings.Checkpoints.GetValueOrDefault(host);

    internal void SaveHosts(IReadOnlyList<string> hosts)
    {
        settings.Hosts = hosts.ToList();
        Save();
    }

    internal void SaveEnabled(bool enabled)
    {
        settings.Enabled = enabled;
        Save();
    }

    internal void SaveCheckpoint(string host, DateTimeOffset checkpoint)
    {
        settings.Checkpoints[host] = checkpoint;
        Save();
    }

    private static Settings LoadSettings()
    {
        try
        {
            if (!File.Exists(AppPaths.RemoteHostsFile)) return new Settings { SchemaVersion = 3 };
            var value = JsonSerializer.Deserialize<Settings>(File.ReadAllText(AppPaths.RemoteHostsFile));
            if (value is null) return new Settings { SchemaVersion = 3 };
            var hosts = RemoteHostName.Parse(string.Join(",", value.Hosts ?? new List<string>())).ToList();
            var checkpoints = value.Checkpoints
                ?? new Dictionary<string, DateTimeOffset>(StringComparer.OrdinalIgnoreCase);
            return new Settings {
                SchemaVersion = 3,
                Hosts = hosts,
                Enabled = RestoresMonitoringAuthorization(value.SchemaVersion, value.Enabled),
                Checkpoints = UsesRemoteClockCheckpoints(value.SchemaVersion)
                    ? new Dictionary<string, DateTimeOffset>(checkpoints, StringComparer.OrdinalIgnoreCase)
                    : new Dictionary<string, DateTimeOffset>(StringComparer.OrdinalIgnoreCase)
            };
        }
        catch { return new Settings { SchemaVersion = 3 }; }
    }

    internal static bool UsesRemoteClockCheckpoints(int schemaVersion) => schemaVersion is 2 or 3;
    internal static bool RestoresMonitoringAuthorization(int schemaVersion, bool enabled) =>
        schemaVersion == 3 && enabled;
    internal static bool RestoresMonitoringAuthorizationFromJson(string json)
    {
        try
        {
            var value = JsonSerializer.Deserialize<Settings>(json);
            return value is not null
                && RestoresMonitoringAuthorization(value.SchemaVersion, value.Enabled);
        }
        catch (JsonException) { return false; }
    }

    private void Save()
    {
        Directory.CreateDirectory(AppPaths.DataDirectory);
        var temporary = AppPaths.RemoteHostsFile + ".new";
        File.WriteAllText(temporary, JsonSerializer.Serialize(settings, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temporary, AppPaths.RemoteHostsFile, true);
    }
}

internal sealed class RemoteCodexTaskMonitor : IDisposable
{
    internal static readonly string OpenSshPath = Path.Combine(
        Environment.SystemDirectory, "OpenSSH", "ssh.exe");

    private readonly string host;
    private readonly CancellationTokenSource cancellation = new();
    private DateTimeOffset? recoveryCheckpoint;
    private Task? worker;
    private Process? process;
    private int consecutiveFailures;
    private long? readyAtTimestamp;
    private string? isolatedSshConfigPath;
    private readonly object processGate = new();
    private bool disposed;

    internal event Action<TaskEvent, TaskEventOrigin>? EventArrived;
    internal event Action? ReplayStarted;
    internal event Action<DateTimeOffset>? Ready;
    internal event Action<string>? Unavailable;

    internal RemoteCodexTaskMonitor(string host, DateTimeOffset? recoveryCheckpoint)
    {
        this.host = host;
        this.recoveryCheckpoint = recoveryCheckpoint;
    }

    internal void Start() => worker ??= Task.Run(RunAsync);

    private async Task RunAsync()
    {
        while (!cancellation.IsCancellationRequested)
        {
            var stage = Math.Min(consecutiveFailures + 1, RemoteConnectionRetryPolicy.Delays.Length);
            Unavailable?.Invoke(
                $"正在连接远程任务主机 {host}（重连阶段 {stage}/{RemoteConnectionRetryPolicy.Delays.Length}）");
            readyAtTimestamp = null;
            try { await RunConnectionAsync(cancellation.Token); }
            catch (OperationCanceledException) { break; }
            catch { }
            if (cancellation.IsCancellationRequested) break;
            var readyDuration = readyAtTimestamp is { } started
                ? Stopwatch.GetElapsedTime(started) : (TimeSpan?)null;
            consecutiveFailures = RemoteConnectionRetryPolicy.NormalizeFailures(
                consecutiveFailures, readyDuration);
            var delay = RemoteConnectionRetryPolicy.DelayForFailure(consecutiveFailures);
            consecutiveFailures++;
            Unavailable?.Invoke(
                $"远程任务主机 {host} 连接中断，{RetryDelayText(delay)}后自动重试");
            try { await Task.Delay(delay, cancellation.Token); }
            catch (OperationCanceledException) { break; }
        }
    }

    private static string RetryDelayText(TimeSpan delay) => delay.TotalMinutes >= 1
        ? $"{(int)delay.TotalMinutes} 分钟" : $"{(int)delay.TotalSeconds} 秒";

    private async Task RunConnectionAsync(CancellationToken token)
    {
        if (RemoteHostName.Validate(host) != host)
            throw new InvalidOperationException("Invalid SSH host alias");
        if (!File.Exists(OpenSshPath))
            throw new FileNotFoundException("System OpenSSH client is unavailable", OpenSshPath);
        var sshConfigPath = PrepareIsolatedSshConfig();

        var startInfo = new ProcessStartInfo {
            FileName = OpenSshPath,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        foreach (var argument in new[] {
            "-F", sshConfigPath, "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=yes", "-o", "ControlMaster=no",
            "-o", "ControlPersist=no", "-o", "ControlPath=none", host, RemoteCommand
        }) startInfo.ArgumentList.Add(argument);

        using var connection = new Process { StartInfo = startInfo };
        lock (processGate)
        {
            if (disposed || token.IsCancellationRequested)
                throw new OperationCanceledException(token);
            if (!connection.Start()) throw new InvalidOperationException("Could not start OpenSSH");
            process = connection;
        }
        var stderrDrain = DrainAsync(connection.StandardError.BaseStream, token);
        var lineBuffer = new BoundedLineBuffer();
        var outputBuffer = new byte[BoundedLineBuffer.ChunkBytes];
        var streamReady = false;
        DateTimeOffset? activeScanStart = null;
        DateTimeOffset? replayCutoff = null;
        var clockRolledBack = false;

        try
        {
            while (!token.IsCancellationRequested)
            {
                var bytesRead = await connection.StandardOutput.BaseStream.ReadAsync(outputBuffer, token);
                if (bytesRead == 0) break;
                foreach (var line in lineBuffer.Append(outputBuffer.AsSpan(0, bytesRead)))
                {
                    RemoteEnvelope? envelope;
                    try { envelope = JsonSerializer.Deserialize<RemoteEnvelope>(line); }
                    catch (JsonException) { continue; }
                    if (envelope?.Kind == "error")
                    {
                        Unavailable?.Invoke($"远程任务主机 {host} 未找到可读的 Codex 会话");
                        continue;
                    }
                    if (envelope?.Kind == "scan_started")
                    {
                        if (!TryUnixTime(envelope.ScanStartedAt, out var scanStart))
                            throw new InvalidDataException("Remote scan watermark is invalid");
                        activeScanStart = scanStart;
                        clockRolledBack = RemoteReplayPolicy.ClockRolledBack(
                            recoveryCheckpoint, scanStart);
                        replayCutoff = RemoteReplayPolicy.Cutoff(recoveryCheckpoint, scanStart);
                        ReplayStarted?.Invoke();
                        continue;
                    }
                    if (envelope?.Kind == "ready")
                    {
                        if (!TryUnixTime(envelope.ScanStartedAt, out var scanStart)
                            || !TryUnixTime(envelope.ScanFinishedAt, out var scanFinish)
                            || activeScanStart != scanStart || scanFinish < scanStart)
                            throw new InvalidDataException("Remote ready watermark is invalid");
                        streamReady = true;
                        readyAtTimestamp = Stopwatch.GetTimestamp();
                        recoveryCheckpoint = scanStart;
                        Ready?.Invoke(scanStart);
                        continue;
                    }
                    var parsed = ParseEvent(envelope);
                    if (parsed is null) continue;
                    if (streamReady)
                        EventArrived?.Invoke(parsed, TaskEventOrigin.Live);
                    else if (replayCutoff is { } cutoff && activeScanStart is { } scanStart)
                    {
                        var origin = RemoteReplayPolicy.Origin(parsed, cutoff, clockRolledBack);
                        if (!RemoteReplayPolicy.ShouldSkipStaleStart(
                                parsed, origin, scanStart, clockRolledBack))
                            EventArrived?.Invoke(parsed, origin);
                    }
                }
            }

            await connection.WaitForExitAsync(token);
        }
        finally
        {
            try { if (!connection.HasExited) connection.Kill(true); } catch { }
            try { await stderrDrain; } catch (OperationCanceledException) { }
            lock (processGate)
            {
                if (ReferenceEquals(process, connection)) process = null;
            }
        }
    }

    private static async Task DrainAsync(Stream stream, CancellationToken token)
    {
        var buffer = new byte[BoundedLineBuffer.ChunkBytes];
        while (await stream.ReadAsync(buffer, token) > 0) { }
    }

    private string PrepareIsolatedSshConfig()
    {
        if (isolatedSshConfigPath is { } existing && File.Exists(existing)) return existing;
        var directory = Path.Combine(Path.GetTempPath(), "CodexS-ssh");
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, $"{Guid.NewGuid():N}.conf");
        var systemConfig = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "ssh", "ssh_config").Replace('\\', '/');
        File.WriteAllText(path, $"""
            Host *
                ControlMaster no
                ControlPersist no
                ControlPath none
            Include ~/.ssh/config
            Include "{systemConfig}"
            """);
        isolatedSshConfigPath = path;
        return path;
    }

    internal static bool TryUnixTime(double? seconds, out DateTimeOffset value)
    {
        value = default;
        if (seconds is null || !double.IsFinite(seconds.Value)) return false;
        var milliseconds = seconds.Value * 1000;
        if (!double.IsFinite(milliseconds)
            || milliseconds is < 0 or > 253_402_300_799_999) return false;
        value = DateTimeOffset.FromUnixTimeMilliseconds((long)milliseconds);
        return true;
    }

    private TaskEvent? ParseEvent(RemoteEnvelope? value)
    {
        if (value?.Kind != "event" || string.IsNullOrWhiteSpace(value.Event)
            || string.IsNullOrWhiteSpace(value.TurnId) || string.IsNullOrWhiteSpace(value.ThreadId)
            || value.TurnId.Length > 512 || value.ThreadId.Length > 512
            || !TryUnixTime(value.OccurredAt, out var occurredAt)) return null;
        var kind = value.Event switch {
            "started" => TaskEventKind.Started,
            "completed" => TaskEventKind.Completed,
            "aborted" => TaskEventKind.Interrupted,
            _ => (TaskEventKind?)null
        };
        if (kind is null) return null;
        var identity = Guid.TryParse(value.TurnId, out var guid)
            ? guid.ToString("D").ToLowerInvariant()
            : $"{value.ThreadId}:{value.TurnId}";
        return new TaskEvent(
            identity, value.ThreadId,
            string.IsNullOrWhiteSpace(value.ProjectName) ? "Codex" : value.ProjectName[..Math.Min(255, value.ProjectName.Length)],
            host,
            occurredAt, kind.Value);
    }

    private static string ShellQuote(string value) => "'" + value.Replace("'", "'\\''") + "'";
    private static readonly string RemoteCommand = "$SHELL -lc " + ShellQuote("python3 -u -c " + ShellQuote(RemoteScript));

    private const string RemoteScript = """
import datetime
import json
import os
import stat as stat_module
import sys
import time

CHUNK_BYTES = 65536
MAX_LINE_BYTES = 1048576

def emit(value):
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")), flush=True)

def timestamp(value):
    if not isinstance(value, str):
        return None
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None

def event_time(payload, root, key):
    try:
        value = float(payload.get(key))
        return value / 1000.0 if value > 100000000000 else value
    except (TypeError, ValueError):
        return timestamp(root.get("timestamp"))

def project_name(path):
    if not isinstance(path, str):
        return None
    value = (path or "").replace("\\", "/").rstrip("/")
    return value.rsplit("/", 1)[-1] if value else None

def valid_id(value):
    return isinstance(value, str) and 0 < len(value.encode("utf-8")) <= 512

def source(path):
    session_id = os.path.splitext(os.path.basename(path))[0]
    project = None
    created = 0.0
    try:
        with open(path, "rb") as handle:
            for _ in range(100):
                line = handle.readline(MAX_LINE_BYTES + 1)
                if not line:
                    break
                if len(line) > MAX_LINE_BYTES:
                    while line and not line.endswith(b"\n"):
                        line = handle.readline(MAX_LINE_BYTES + 1)
                    continue
                try:
                    root = json.loads(line)
                except Exception:
                    continue
                if not isinstance(root, dict):
                    continue
                if root.get("type") != "session_meta":
                    continue
                payload = root.get("payload") or {}
                if not isinstance(payload, dict):
                    continue
                source_value = payload.get("source")
                if payload.get("thread_source") == "subagent" or isinstance(source_value, dict) and "subagent" in source_value:
                    return None, True
                candidate_id = payload.get("id") or payload.get("session_id")
                if valid_id(candidate_id):
                    session_id = candidate_id
                project = project_name(payload.get("cwd"))
                created = timestamp(root.get("timestamp")) or 0.0
                break
    except OSError:
        return None, False
    return (session_id, project, created), True

def discover_home():
    for value in (os.environ.get("CODEX_HOME"), os.path.expanduser("~/.codex")):
        if value and os.path.isdir(os.path.join(value, "sessions")):
            return value
    return None

def discover(home):
    paths = []
    complete = True
    for directory in (os.path.join(home, "sessions"), os.path.join(home, "archived_sessions")):
        try:
            directory_stat = os.stat(directory)
        except FileNotFoundError:
            continue
        except OSError:
            complete = False
            continue
        if not stat_module.S_ISDIR(directory_stat.st_mode):
            complete = False
            continue
        walk_errors = []
        for root, _, files in os.walk(directory, onerror=walk_errors.append):
            paths.extend(os.path.join(root, name) for name in files if name.endswith(".jsonl"))
        if walk_errors:
            complete = False
    sources = {}
    for path in paths:
        metadata, readable = source(path)
        if not readable:
            complete = False
        elif metadata is not None:
            sources[path] = metadata
    return sources, complete

def consume_chunk(cursor, chunk):
    lines = []
    offset = 0
    while offset < len(chunk):
        newline = chunk.find(b"\n", offset)
        if newline < 0:
            segment = chunk[offset:]
            if not cursor["dropping"]:
                if len(cursor["partial"]) + len(segment) > MAX_LINE_BYTES:
                    cursor["partial"].clear()
                    cursor["dropping"] = True
                else:
                    cursor["partial"].extend(segment)
            break
        segment = chunk[offset:newline]
        if not cursor["dropping"]:
            if len(cursor["partial"]) + len(segment) > MAX_LINE_BYTES:
                cursor["partial"].clear()
                cursor["dropping"] = True
            else:
                cursor["partial"].extend(segment)
        if not cursor["dropping"] and cursor["partial"]:
            line = bytes(cursor["partial"])
            lines.append(line[:-1] if line.endswith(b"\r") else line)
        cursor["partial"].clear()
        cursor["dropping"] = False
        offset = newline + 1
    return lines

def parse_event_line(line, metadata):
    if b"task_started" not in line and b"task_complete" not in line and b"turn_aborted" not in line:
        return
    try:
        root = json.loads(line)
    except Exception:
        return
    if not isinstance(root, dict):
        return
    if root.get("type") != "event_msg":
        return
    payload = root.get("payload") or {}
    if not isinstance(payload, dict):
        return
    event_type = payload.get("type")
    if event_type not in ("task_started", "task_complete", "turn_aborted"):
        return
    turn_id = payload.get("turn_id")
    occurred = event_time(payload, root, "started_at" if event_type == "task_started" else "completed_at")
    session_id, project, created = metadata
    if not isinstance(turn_id, str) or not turn_id or occurred is None or occurred + 1 < created:
        return
    emit({"kind":"event","event":{"task_started":"started","task_complete":"completed","turn_aborted":"aborted"}[event_type],"turn_id":turn_id,"occurred_at":occurred,"thread_id":session_id,"project_name":project})

def read_file(path, metadata, cursors):
    try:
        stat = os.stat(path)
        cursor = cursors.get(path, {"offset": 0, "inode": stat.st_ino, "partial": bytearray(), "dropping": False})
        if stat.st_size < cursor["offset"] or stat.st_ino != cursor["inode"]:
            cursor = {"offset": 0, "inode": stat.st_ino, "partial": bytearray(), "dropping": False}
        cursors[path] = cursor
        if stat.st_size == cursor["offset"]:
            return True
        with open(path, "rb") as handle:
            handle.seek(cursor["offset"])
            while True:
                chunk = handle.read(CHUNK_BYTES)
                if not chunk:
                    break
                cursor["offset"] += len(chunk)
                for line in consume_chunk(cursor, chunk):
                    parse_event_line(line, metadata)
    except OSError:
        return False
    return True

def main():
    home = discover_home()
    if not home:
        emit({"kind":"error"})
        return 2
    cursors = {}
    scan_started = time.time()
    emit({"kind":"scan_started","scan_started_at":scan_started})
    sources, initial_complete = discover(home)
    if not sources:
        emit({"kind":"error"})
        return 2
    for path in sorted(sources):
        if not read_file(path, sources[path], cursors):
            initial_complete = False
    if not initial_complete:
        emit({"kind":"error"})
        return 3
    emit({"kind":"ready","scan_started_at":scan_started,"scan_finished_at":time.time()})
    tick = 0
    while True:
        time.sleep(1)
        tick += 1
        if tick % 10 == 0:
            discovered, _ = discover(home)
            sources.update(discovered)
        for path in sorted(sources):
            read_file(path, sources[path], cursors)

try:
    sys.exit(main())
except KeyboardInterrupt:
    pass
except Exception:
    emit({"kind":"error"})
    sys.exit(2)
""";

    private sealed class RemoteEnvelope
    {
        public RemoteEnvelope() { }
        [JsonPropertyName("kind")]
        public string? Kind { get; set; }
        [JsonPropertyName("event")]
        public string? Event { get; set; }
        [JsonPropertyName("turn_id")]
        public string? TurnId { get; set; }
        [JsonPropertyName("occurred_at")]
        public double? OccurredAt { get; set; }
        [JsonPropertyName("thread_id")]
        public string? ThreadId { get; set; }
        [JsonPropertyName("project_name")]
        public string? ProjectName { get; set; }
        [JsonPropertyName("scan_started_at")]
        public double? ScanStartedAt { get; set; }
        [JsonPropertyName("scan_finished_at")]
        public double? ScanFinishedAt { get; set; }
    }

    public void Dispose()
    {
        Process? activeProcess;
        lock (processGate)
        {
            disposed = true;
            cancellation.Cancel();
            activeProcess = process;
        }
        try { activeProcess?.Kill(true); } catch { }
        try { worker?.Wait(TimeSpan.FromSeconds(2)); } catch { }
        activeProcess?.Dispose();
        if (isolatedSshConfigPath is { } path)
        {
            try { File.Delete(path); } catch { }
            isolatedSshConfigPath = null;
        }
        cancellation.Dispose();
    }
}
