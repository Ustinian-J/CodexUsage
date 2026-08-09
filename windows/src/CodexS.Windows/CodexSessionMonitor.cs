using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace CodexS.Windows;

internal sealed class CodexSessionMonitor : IDisposable
{
    private sealed class Cursor
    {
        internal long Offset;
        internal byte[] Partial = [];
        internal long LastTokenTotal;
        internal string SessionId = string.Empty;
        internal string Project = "Codex";
        internal bool IsSubagent;
    }

    private readonly object gate = new();
    private readonly Dictionary<string, Cursor> cursors = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<DateOnly, long> tokensByDay = [];
    private readonly HashSet<string> tokenFingerprints = new(StringComparer.Ordinal);
    private readonly StateStore stateStore = new();
    private readonly TaskActivityReducer reducer;
    private readonly CancellationTokenSource cancellation = new();
    private readonly DateTimeOffset startedAt = DateTimeOffset.Now;
    private Task? worker;
    private bool initialScanFinished;
    private bool taskMonitorReady;
    private bool stateDirty;
    private QuotaWindow? fiveHour;
    private QuotaWindow? sevenDay;
    private bool quotaStale = true;
    private string? statusMessage = "正在读取 Codex 本地数据";

    internal event Action<UsageSnapshot>? SnapshotChanged;
    internal event Action<TaskResult>? CompletionArrived;

    internal CodexSessionMonitor()
    {
        reducer = new TaskActivityReducer(stateStore.Load(), startedAt);
    }

    internal void Start()
    {
        worker ??= Task.Run(LoopAsync);
    }

    internal UsageSnapshot Current
    {
        get { lock (gate) return MakeSnapshot(); }
    }

    internal void SetQuota(QuotaWindow? five, QuotaWindow? seven, bool stale, string? message)
    {
        lock (gate)
        {
            fiveHour = five ?? fiveHour;
            sevenDay = seven ?? sevenDay;
            quotaStale = stale;
            statusMessage = message;
            PublishLocked();
        }
    }

    internal void MarkRead(string id)
    {
        lock (gate)
        {
            if (!reducer.MarkRead(id)) return;
            stateStore.Save(reducer.Persisted());
            stateDirty = false;
            PublishLocked();
        }
    }

    internal void MarkAllRead()
    {
        lock (gate)
        {
            if (!reducer.MarkAllRead()) return;
            stateStore.Save(reducer.Persisted());
            stateDirty = false;
            PublishLocked();
        }
    }

    private async Task LoopAsync()
    {
        while (!cancellation.IsCancellationRequested)
        {
            Scan();
            try { await Task.Delay(TimeSpan.FromSeconds(2), cancellation.Token); }
            catch (OperationCanceledException) { break; }
        }
    }

    private void Scan()
    {
        var scanStarted = DateTimeOffset.Now;
        var roots = new[] {
            Path.Combine(AppPaths.CodexHome, "sessions"),
            Path.Combine(AppPaths.CodexHome, "archived_sessions")
        }.Where(Directory.Exists).ToArray();

        if (roots.Length == 0)
        {
            lock (gate)
            {
                taskMonitorReady = false;
                statusMessage = "未找到 Codex 本地会话目录";
                PublishLocked();
            }
            return;
        }

        var allSucceeded = true;
        var files = roots.SelectMany(root => Directory.EnumerateFiles(root, "*.jsonl", SearchOption.AllDirectories))
            .Order(StringComparer.OrdinalIgnoreCase).ToArray();
        foreach (var file in files)
        {
            try { ProcessFile(file); }
            catch (IOException) { allSucceeded = false; }
            catch (UnauthorizedAccessException) { allSucceeded = false; }
        }

        lock (gate)
        {
            if (!initialScanFinished && allSucceeded)
            {
                reducer.FinishInitialScan(startedAt);
                initialScanFinished = true;
                taskMonitorReady = true;
                statusMessage = null;
                stateStore.Save(reducer.Persisted());
                stateDirty = false;
            }
            else if (initialScanFinished && allSucceeded)
            {
                if (scanStarted - reducer.ReplayNotBefore >= TimeSpan.FromSeconds(30))
                {
                    reducer.AdvanceCheckpoint(scanStarted);
                    reducer.RemoveStaleRunning(scanStarted.AddHours(-12));
                    stateDirty = true;
                }
                taskMonitorReady = true;
                if (stateDirty)
                {
                    stateStore.Save(reducer.Persisted());
                    stateDirty = false;
                }
            }
            PublishLocked();
        }
    }

    private void ProcessFile(string path)
    {
        Cursor cursor;
        bool replayed;
        lock (gate)
        {
            replayed = !cursors.TryGetValue(path, out cursor!);
            cursor ??= new Cursor { SessionId = Path.GetFileNameWithoutExtension(path) };
        }

        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete, 64 * 1024, FileOptions.SequentialScan);
        if (stream.Length < cursor.Offset)
        {
            cursor = new Cursor { SessionId = Path.GetFileNameWithoutExtension(path) };
            replayed = true;
        }
        if (stream.Length == cursor.Offset)
        {
            lock (gate) cursors[path] = cursor;
            return;
        }

        stream.Seek(cursor.Offset, SeekOrigin.Begin);
        using var memory = new MemoryStream();
        stream.CopyTo(memory);
        var appended = memory.ToArray();
        cursor.Offset += appended.Length;
        var combined = new byte[cursor.Partial.Length + appended.Length];
        Buffer.BlockCopy(cursor.Partial, 0, combined, 0, cursor.Partial.Length);
        Buffer.BlockCopy(appended, 0, combined, cursor.Partial.Length, appended.Length);

        var lineStart = 0;
        for (var index = 0; index < combined.Length; index++)
        {
            if (combined[index] != (byte)'\n') continue;
            var length = index - lineStart;
            if (length > 0 && combined[index - 1] == (byte)'\r') length--;
            if (length > 0) ParseLine(combined.AsSpan(lineStart, length), cursor, !replayed);
            lineStart = index + 1;
        }
        cursor.Partial = combined[lineStart..];
        lock (gate) cursors[path] = cursor;
    }

    private void ParseLine(ReadOnlySpan<byte> line, Cursor cursor, bool appendedLive)
    {
        if (!line.Contains("session_meta"u8) && !line.Contains("token_count"u8)
            && !line.Contains("task_started"u8) && !line.Contains("task_complete"u8)
            && !line.Contains("turn_aborted"u8)) return;

        using var document = JsonDocument.Parse(line.ToArray());
        var root = document.RootElement;
        if (!root.TryGetProperty("type", out var typeElement)) return;
        var type = typeElement.GetString();
        if (!root.TryGetProperty("payload", out var payload)) return;

        if (type == "session_meta")
        {
            cursor.SessionId = ReadString(payload, "id") ?? ReadString(payload, "session_id") ?? cursor.SessionId;
            var cwd = ReadString(payload, "cwd");
            if (!string.IsNullOrWhiteSpace(cwd)) cursor.Project = Path.GetFileName(cwd.TrimEnd('\\', '/'));
            cursor.IsSubagent = string.Equals(ReadString(payload, "thread_source"), "subagent", StringComparison.Ordinal)
                || payload.TryGetProperty("source", out var source) && source.TryGetProperty("subagent", out _);
            return;
        }
        if (type != "event_msg" || cursor.IsSubagent) return;

        var eventType = ReadString(payload, "type");
        if (eventType == "token_count")
        {
            ParseToken(line, root, payload, cursor);
            return;
        }
        if (eventType is not ("task_started" or "task_complete" or "turn_aborted")) return;
        var turnId = ReadString(payload, "turn_id");
        if (string.IsNullOrWhiteSpace(turnId)) return;
        var occurredAt = ReadEpoch(payload, eventType == "task_started" ? "started_at" : "completed_at")
            ?? ReadTimestamp(root) ?? DateTimeOffset.Now;
        var identity = Guid.TryParse(turnId, out var guid)
            ? guid.ToString("D").ToLowerInvariant()
            : $"{cursor.SessionId}:{turnId}";
        var kind = eventType switch {
            "task_started" => TaskEventKind.Started,
            "task_complete" => TaskEventKind.Completed,
            _ => TaskEventKind.Interrupted
        };

        TaskResult? completion;
        lock (gate)
        {
            completion = reducer.Apply(new TaskEvent(
                identity, cursor.SessionId, cursor.Project, occurredAt, kind), appendedLive);
            stateDirty = true;
        }
        if (completion is not null) CompletionArrived?.Invoke(completion);
    }

    private void ParseToken(ReadOnlySpan<byte> line, JsonElement root, JsonElement payload, Cursor cursor)
    {
        if (!payload.TryGetProperty("info", out var info)
            || !info.TryGetProperty("total_token_usage", out var total)
            || !total.TryGetProperty("total_tokens", out var totalElement)
            || !totalElement.TryGetInt64(out var current)) return;
        var delta = TokenDelta(cursor.LastTokenTotal, current);
        cursor.LastTokenTotal = current;
        if (delta <= 0) return;
        var fingerprint = Convert.ToHexString(SHA256.HashData(line));
        lock (gate)
        {
            if (!tokenFingerprints.Add(fingerprint)) return;
            var date = DateOnly.FromDateTime((ReadTimestamp(root) ?? DateTimeOffset.Now).LocalDateTime);
            tokensByDay[date] = tokensByDay.GetValueOrDefault(date) + delta;
        }
    }

    private UsageSnapshot MakeSnapshot()
    {
        var today = DateOnly.FromDateTime(DateTime.Now);
        var todayTokens = tokensByDay.GetValueOrDefault(today);
        long sevenTokens = 0;
        for (var offset = 0; offset < 7; offset++) sevenTokens += tokensByDay.GetValueOrDefault(today.AddDays(-offset));
        return new UsageSnapshot(
            fiveHour, sevenDay, todayTokens, sevenTokens, tokensByDay.Values.Sum(),
            reducer.Running, reducer.Results, taskMonitorReady, quotaStale, statusMessage);
    }

    private void PublishLocked() => SnapshotChanged?.Invoke(MakeSnapshot());

    private static string? ReadString(JsonElement objectElement, string name) =>
        objectElement.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() : null;

    private static DateTimeOffset? ReadEpoch(JsonElement objectElement, string name)
    {
        if (!objectElement.TryGetProperty(name, out var value)) return null;
        if (value.TryGetDouble(out var seconds)) return DateTimeOffset.FromUnixTimeMilliseconds((long)(seconds * 1000));
        return value.ValueKind == JsonValueKind.String && double.TryParse(value.GetString(), out seconds)
            ? DateTimeOffset.FromUnixTimeMilliseconds((long)(seconds * 1000)) : null;
    }

    private static DateTimeOffset? ReadTimestamp(JsonElement root) =>
        root.TryGetProperty("timestamp", out var value) && value.ValueKind == JsonValueKind.String
            && DateTimeOffset.TryParse(value.GetString(), out var timestamp) ? timestamp : null;

    internal static long TokenDelta(long previous, long current) =>
        current >= previous ? current - previous : current;

    public void Dispose()
    {
        cancellation.Cancel();
        try { worker?.Wait(TimeSpan.FromSeconds(2)); } catch { }
        cancellation.Dispose();
    }
}
