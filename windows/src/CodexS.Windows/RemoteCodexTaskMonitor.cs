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

internal sealed class RemoteHostStore
{
    private sealed class Settings
    {
        public Settings() { }
        public int SchemaVersion { get; set; } = 1;
        public List<string> Hosts { get; set; } = [];
        public Dictionary<string, DateTimeOffset> Checkpoints { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    }

    private Settings settings = LoadSettings();

    internal IReadOnlyList<string> Hosts => settings.Hosts;
    internal DateTimeOffset? Checkpoint(string host) => settings.Checkpoints.GetValueOrDefault(host);

    internal void SaveHosts(IReadOnlyList<string> hosts)
    {
        settings.Hosts = hosts.ToList();
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
            if (!File.Exists(AppPaths.RemoteHostsFile)) return new Settings();
            var value = JsonSerializer.Deserialize<Settings>(File.ReadAllText(AppPaths.RemoteHostsFile));
            return value?.SchemaVersion == 1 ? value : new Settings();
        }
        catch { return new Settings(); }
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
    private readonly string host;
    private readonly CancellationTokenSource cancellation = new();
    private DateTimeOffset? recoveryCheckpoint;
    private Task? worker;
    private Process? process;

    internal event Action<TaskEvent, TaskEventOrigin>? EventArrived;
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
            try { await RunConnectionAsync(cancellation.Token); }
            catch (OperationCanceledException) { break; }
            catch { Unavailable?.Invoke($"远程任务主机 {host} 暂时不可用"); }
            try { await Task.Delay(TimeSpan.FromSeconds(10), cancellation.Token); }
            catch (OperationCanceledException) { break; }
        }
    }

    private async Task RunConnectionAsync(CancellationToken token)
    {
        if (RemoteHostName.Validate(host) != host)
            throw new InvalidOperationException("Invalid SSH host alias");

        var startInfo = new ProcessStartInfo {
            FileName = "ssh.exe",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        foreach (var argument in new[] {
            "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=yes", host, RemoteCommand
        }) startInfo.ArgumentList.Add(argument);

        using var connection = new Process { StartInfo = startInfo };
        process = connection;
        if (!connection.Start()) throw new InvalidOperationException("Could not start OpenSSH");
        var stderrDrain = connection.StandardError.ReadToEndAsync(token);
        var replay = new List<TaskEvent>();
        var streamReady = false;

        while (!token.IsCancellationRequested)
        {
            var line = await connection.StandardOutput.ReadLineAsync(token);
            if (line is null) break;
            RemoteEnvelope? envelope;
            try { envelope = JsonSerializer.Deserialize<RemoteEnvelope>(line); }
            catch (JsonException) { continue; }
            if (envelope?.Kind == "error")
            {
                Unavailable?.Invoke($"远程任务主机 {host} 未找到可读的 Codex 会话");
                continue;
            }
            if (envelope?.Kind == "ready")
            {
                foreach (var taskEvent in replay.OrderBy(item => item.OccurredAt))
                {
                    var origin = recoveryCheckpoint is null || taskEvent.OccurredAt < recoveryCheckpoint
                        ? TaskEventOrigin.Baseline : TaskEventOrigin.Recovery;
                    EventArrived?.Invoke(taskEvent, origin);
                }
                replay.Clear();
                streamReady = true;
                recoveryCheckpoint = DateTimeOffset.Now;
                Ready?.Invoke(recoveryCheckpoint.Value);
                continue;
            }
            var parsed = ParseEvent(envelope);
            if (parsed is null) continue;
            if (streamReady) EventArrived?.Invoke(parsed, TaskEventOrigin.Live);
            else replay.Add(parsed);
        }

        await connection.WaitForExitAsync(token);
        await stderrDrain;
        if (!token.IsCancellationRequested)
            Unavailable?.Invoke($"远程任务主机 {host} 暂时不可用");
    }

    private TaskEvent? ParseEvent(RemoteEnvelope? value)
    {
        if (value?.Kind != "event" || string.IsNullOrWhiteSpace(value.Event)
            || string.IsNullOrWhiteSpace(value.TurnId) || string.IsNullOrWhiteSpace(value.ThreadId)
            || value.OccurredAt is null || !double.IsFinite(value.OccurredAt.Value)
            || value.OccurredAt.Value is < 0 or > 253402300799) return null;
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
            identity, value.ThreadId, value.ProjectName ?? "Codex", host,
            DateTimeOffset.FromUnixTimeMilliseconds((long)(value.OccurredAt.Value * 1000)), kind.Value);
    }

    private static string ShellQuote(string value) => "'" + value.Replace("'", "'\\''") + "'";
    private static readonly string RemoteCommand = "$SHELL -lc " + ShellQuote("python3 -u -c " + ShellQuote(RemoteScript));

    private const string RemoteScript = """
import datetime
import glob
import json
import os
import sys
import time

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
    value = (path or "").replace("\\", "/").rstrip("/")
    return value.rsplit("/", 1)[-1] if value else None

def source(path):
    session_id = os.path.splitext(os.path.basename(path))[0]
    project = None
    created = 0.0
    try:
        with open(path, "rb") as handle:
            for _ in range(100):
                line = handle.readline()
                if not line:
                    break
                try:
                    root = json.loads(line)
                except Exception:
                    continue
                if root.get("type") != "session_meta":
                    continue
                payload = root.get("payload") or {}
                source_value = payload.get("source")
                if payload.get("thread_source") == "subagent" or isinstance(source_value, dict) and "subagent" in source_value:
                    return None
                session_id = payload.get("id") or payload.get("session_id") or session_id
                project = project_name(payload.get("cwd"))
                created = timestamp(root.get("timestamp")) or 0.0
                break
    except OSError:
        return None
    return session_id, project, created

def discover_home():
    for value in (os.environ.get("CODEX_HOME"), os.path.expanduser("~/.codex")):
        if value and os.path.isdir(os.path.join(value, "sessions")):
            return value
    return None

def discover(home):
    paths = []
    for directory in (os.path.join(home, "sessions"), os.path.join(home, "archived_sessions")):
        paths.extend(glob.glob(os.path.join(directory, "**", "*.jsonl"), recursive=True))
    return {path: metadata for path in paths if (metadata := source(path)) is not None}

def read_file(path, metadata, cursors):
    try:
        stat = os.stat(path)
        cursor = cursors.get(path, {"offset": 0, "inode": stat.st_ino, "partial": b""})
        if stat.st_size < cursor["offset"] or stat.st_ino != cursor["inode"]:
            cursor = {"offset": 0, "inode": stat.st_ino, "partial": b""}
        if stat.st_size == cursor["offset"]:
            cursors[path] = cursor
            return
        with open(path, "rb") as handle:
            handle.seek(cursor["offset"])
            appended = handle.read()
        cursor["offset"] += len(appended)
        lines = (cursor["partial"] + appended).split(b"\n")
        cursor["partial"] = lines.pop()
        cursors[path] = cursor
    except OSError:
        return
    session_id, project, created = metadata
    for line in lines:
        if b"task_started" not in line and b"task_complete" not in line and b"turn_aborted" not in line:
            continue
        try:
            root = json.loads(line)
        except Exception:
            continue
        if root.get("type") != "event_msg":
            continue
        payload = root.get("payload") or {}
        event_type = payload.get("type")
        if event_type not in ("task_started", "task_complete", "turn_aborted"):
            continue
        turn_id = payload.get("turn_id")
        occurred = event_time(payload, root, "started_at" if event_type == "task_started" else "completed_at")
        if not isinstance(turn_id, str) or not turn_id or occurred is None or occurred + 1 < created:
            continue
        emit({"kind":"event","event":{"task_started":"started","task_complete":"completed","turn_aborted":"aborted"}[event_type],"turn_id":turn_id,"occurred_at":occurred,"thread_id":session_id,"project_name":project})

def main():
    home = discover_home()
    if not home:
        emit({"kind":"error"})
        return 2
    cursors = {}
    sources = discover(home)
    if not sources:
        emit({"kind":"error"})
        return 2
    for path in sorted(sources):
        read_file(path, sources[path], cursors)
    emit({"kind":"ready"})
    tick = 0
    while True:
        time.sleep(1)
        tick += 1
        if tick % 10 == 0:
            sources.update(discover(home))
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
    }

    public void Dispose()
    {
        cancellation.Cancel();
        try { process?.Kill(true); } catch { }
        try { worker?.Wait(TimeSpan.FromSeconds(2)); } catch { }
        process?.Dispose();
        cancellation.Dispose();
    }
}
