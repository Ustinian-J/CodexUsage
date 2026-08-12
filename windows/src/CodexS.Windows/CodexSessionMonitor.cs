using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace CodexS.Windows;

internal sealed class CodexSessionMonitor : IDisposable
{
    private sealed class Cursor
    {
        internal long Offset;
        internal BoundedLineBuffer Lines = new();
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
    private readonly RemoteHostStore remoteHostStore = new();
    private readonly TaskActivityReducer reducer;
    private readonly Dictionary<string, RemoteCodexTaskMonitor> remoteMonitors = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, (bool Ready, string? Message)> remoteStatus = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> remoteReplays = new(StringComparer.OrdinalIgnoreCase);
    private readonly CancellationTokenSource cancellation = new();
    private readonly DateTimeOffset startedAt = DateTimeOffset.Now;
    private Task? worker;
    private bool initialScanFinished;
    private bool taskMonitorReady;
    private string? taskMonitorMessage = "正在读取 Codex 本地数据";
    private bool stateDirty;
    private bool stateFlushScheduled;
    private QuotaWindow? fiveHour;
    private QuotaWindow? sevenDay;
    private bool quotaStale = true;
    private string? statusMessage = "正在读取 Codex 本地数据";

    internal event Action<UsageSnapshot>? SnapshotChanged;
    internal event Action<TaskResult>? CompletionArrived;

    internal CodexSessionMonitor()
    {
        reducer = new TaskActivityReducer(stateStore.Load(), startedAt);
        SynchronizeRemoteHosts(remoteHostStore.Hosts, persist: false);
    }

    internal void Start()
    {
        worker ??= Task.Run(LoopAsync);
    }

    internal UsageSnapshot Current
    {
        get { lock (gate) return MakeSnapshot(); }
    }

    internal string RemoteHostsText
    {
        get { lock (gate) return string.Join(", ", remoteMonitors.Keys.Order(StringComparer.OrdinalIgnoreCase)); }
    }

    internal void SetRemoteHosts(string rawValue) =>
        SynchronizeRemoteHosts(RemoteHostName.Parse(rawValue), persist: true);

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
            try
            {
                Scan();
            }
            catch (Exception error) when (IsRecoverableScanException(error))
            {
                lock (gate)
                {
                    taskMonitorReady = false;
                    taskMonitorMessage = "Codex 本地会话暂时不可读，正在重试";
                    if (remoteReplays.Count == 0) PublishLocked();
                }
            }
            try { await Task.Delay(TimeSpan.FromSeconds(2), cancellation.Token); }
            catch (OperationCanceledException) { break; }
        }
    }

    private void Scan()
    {
        var scanStarted = DateTimeOffset.Now;
        var rootCandidates = new[] {
            Path.Combine(AppPaths.CodexHome, "sessions"),
            Path.Combine(AppPaths.CodexHome, "archived_sessions")
        };

        var allSucceeded = true;
        var foundRoot = false;
        var files = new List<string>();
        var enumerationOptions = SessionEnumerationOptions();
        foreach (var root in rootCandidates)
        {
            try
            {
                if (!File.GetAttributes(root).HasFlag(FileAttributes.Directory)) continue;
                foundRoot = true;
                files.AddRange(Directory.EnumerateFiles(root, "*.jsonl", enumerationOptions));
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
            catch (IOException) { allSucceeded = false; }
            catch (UnauthorizedAccessException) { allSucceeded = false; }
        }
        if (!foundRoot && allSucceeded)
        {
            lock (gate)
            {
                taskMonitorReady = false;
                taskMonitorMessage = "未找到 Codex 本地会话目录";
                if (remoteReplays.Count == 0) PublishLocked();
            }
            return;
        }
        files.Sort(StringComparer.OrdinalIgnoreCase);
        foreach (var file in files)
        {
            try { ProcessFile(file); }
            catch (IOException) { allSucceeded = false; }
            catch (UnauthorizedAccessException) { allSucceeded = false; }
        }

        lock (gate)
        {
            if (!allSucceeded)
            {
                taskMonitorReady = false;
                taskMonitorMessage = "部分 Codex 本地会话暂时不可读，正在重试";
                if (stateDirty && remoteReplays.Count == 0)
                {
                    stateStore.Save(reducer.Persisted());
                    stateDirty = false;
                }
            }
            else if (!initialScanFinished)
            {
                reducer.FinishInitialScan(startedAt);
                initialScanFinished = true;
                taskMonitorReady = true;
                taskMonitorMessage = null;
                stateDirty = true;
                if (remoteReplays.Count == 0) FlushStateLocked();
            }
            else if (initialScanFinished && allSucceeded)
            {
                if (scanStarted - reducer.ReplayNotBefore >= TimeSpan.FromSeconds(30))
                {
                    reducer.AdvanceCheckpoint(scanStarted);
                    stateDirty = true;
                }
                taskMonitorReady = true;
                taskMonitorMessage = null;
                if (stateDirty && remoteReplays.Count == 0)
                {
                    stateStore.Save(reducer.Persisted());
                    stateDirty = false;
                }
            }
            if (remoteReplays.Count == 0) PublishLocked();
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
        var buffer = new byte[BoundedLineBuffer.ChunkBytes];
        int bytesRead;
        while ((bytesRead = stream.Read(buffer, 0, buffer.Length)) > 0)
        {
            cursor.Offset += bytesRead;
            foreach (var line in cursor.Lines.Append(buffer.AsSpan(0, bytesRead)))
                ParseLine(line, cursor, !replayed);
        }
        lock (gate) cursors[path] = cursor;
    }

    private void ParseLine(byte[] line, Cursor cursor, bool appendedLive)
    {
        var span = line.AsSpan();
        if (span.IndexOf("session_meta"u8) < 0 && span.IndexOf("token_count"u8) < 0
            && span.IndexOf("task_started"u8) < 0 && span.IndexOf("task_complete"u8) < 0
            && span.IndexOf("turn_aborted"u8) < 0) return;

        using var document = TryParseDocument(line);
        if (document is null) return;
        var root = document.RootElement;
        if (!TryGetSessionEnvelope(root, out var type, out var payload)) return;

        if (type == "session_meta")
        {
            var sessionId = ReadString(payload, "id") ?? ReadString(payload, "session_id");
            if (!string.IsNullOrWhiteSpace(sessionId) && sessionId.Length <= 512)
                cursor.SessionId = sessionId;
            var cwd = ReadString(payload, "cwd");
            if (!string.IsNullOrWhiteSpace(cwd))
            {
                var project = Path.GetFileName(cwd.TrimEnd('\\', '/'));
                if (!string.IsNullOrWhiteSpace(project))
                    cursor.Project = project[..Math.Min(255, project.Length)];
            }
            cursor.IsSubagent = IsSubagent(payload);
            return;
        }
        if (type != "event_msg" || cursor.IsSubagent) return;

        var eventType = ReadString(payload, "type");
        if (eventType == "token_count")
        {
            ParseToken(span, root, payload, cursor);
            return;
        }
        if (eventType is not ("task_started" or "task_complete" or "turn_aborted")) return;
        var turnId = ReadString(payload, "turn_id");
        if (string.IsNullOrWhiteSpace(turnId) || turnId.Length > 512) return;
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
                identity, cursor.SessionId, cursor.Project, null, occurredAt, kind), appendedLive);
            stateDirty = true;
        }
        if (completion is not null) CompletionArrived?.Invoke(completion);
    }

    private void ParseToken(ReadOnlySpan<byte> line, JsonElement root, JsonElement payload, Cursor cursor)
    {
        if (!TryReadTotalTokens(payload, out var current)) return;
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
        var progress = reducer.Progress(today);
        var todayTokens = tokensByDay.GetValueOrDefault(today);
        long sevenTokens = 0;
        for (var offset = 0; offset < 7; offset++) sevenTokens += tokensByDay.GetValueOrDefault(today.AddDays(-offset));
        var remoteFailure = remoteStatus.Values.FirstOrDefault(value => !value.Ready);
        var allSourcesReady = taskMonitorReady && remoteStatus.Values.All(value => value.Ready);
        var monitorMessage = taskMonitorReady ? remoteFailure.Message : taskMonitorMessage;
        return new UsageSnapshot(
            fiveHour, sevenDay, todayTokens, sevenTokens, tokensByDay.Values.Sum(),
            reducer.Running, reducer.Results, progress.Completed, progress.Total, allSourcesReady, monitorMessage,
            remoteMonitors.Keys.Order(StringComparer.OrdinalIgnoreCase).ToArray(), quotaStale, statusMessage);
    }

    private void PublishLocked() => SnapshotChanged?.Invoke(MakeSnapshot());

    private static string? ReadString(JsonElement objectElement, string name) =>
        objectElement.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() : null;

    internal static DateTimeOffset? ReadEpoch(JsonElement objectElement, string name)
    {
        if (!objectElement.TryGetProperty(name, out var value)) return null;
        double number;
        if (value.ValueKind == JsonValueKind.Number)
        {
            if (!value.TryGetDouble(out number)) return null;
        }
        else if (value.ValueKind != JsonValueKind.String
                 || !double.TryParse(value.GetString(), NumberStyles.Float,
                     CultureInfo.InvariantCulture, out number))
        {
            return null;
        }
        if (!double.IsFinite(number)) return null;
        var milliseconds = number > 100_000_000_000 ? number : number * 1000;
        if (milliseconds is < 0 or > 253_402_300_799_999) return null;
        return DateTimeOffset.FromUnixTimeMilliseconds((long)milliseconds);
    }

    private static DateTimeOffset? ReadTimestamp(JsonElement root) =>
        root.TryGetProperty("timestamp", out var value) && value.ValueKind == JsonValueKind.String
            && DateTimeOffset.TryParse(value.GetString(), out var timestamp) ? timestamp : null;

    internal static long TokenDelta(long previous, long current) =>
        current >= previous ? current - previous : current;

    internal static JsonDocument? TryParseDocument(ReadOnlyMemory<byte> line)
    {
        try { return JsonDocument.Parse(line); }
        catch (JsonException) { return null; }
    }

    internal static bool IsRecoverableScanException(Exception error) =>
        error is IOException or UnauthorizedAccessException or InvalidDataException or JsonException;

    internal static EnumerationOptions SessionEnumerationOptions() => new() {
        RecurseSubdirectories = true,
        IgnoreInaccessible = false,
        ReturnSpecialDirectories = false
    };

    internal static bool ShouldPublishRemoteEventImmediately(TaskEventOrigin origin) =>
        origin == TaskEventOrigin.Live;

    internal static bool IsSubagent(JsonElement payload) =>
        string.Equals(ReadString(payload, "thread_source"), "subagent", StringComparison.Ordinal)
        || payload.TryGetProperty("source", out var source) && source.ValueKind == JsonValueKind.Object
        && source.TryGetProperty("subagent", out _);

    internal static bool TryGetSessionEnvelope(
        JsonElement root, out string? type, out JsonElement payload)
    {
        type = null;
        payload = default;
        if (root.ValueKind != JsonValueKind.Object
            || !root.TryGetProperty("type", out var typeElement)
            || typeElement.ValueKind != JsonValueKind.String
            || !root.TryGetProperty("payload", out payload)
            || payload.ValueKind != JsonValueKind.Object) return false;
        type = typeElement.GetString();
        return type is not null;
    }

    internal static bool TryReadTotalTokens(JsonElement payload, out long current)
    {
        current = 0;
        return payload.ValueKind == JsonValueKind.Object
            && payload.TryGetProperty("info", out var info)
            && info.ValueKind == JsonValueKind.Object
            && info.TryGetProperty("total_token_usage", out var total)
            && total.ValueKind == JsonValueKind.Object
            && total.TryGetProperty("total_tokens", out var totalElement)
            && totalElement.ValueKind == JsonValueKind.Number
            && totalElement.TryGetInt64(out current);
    }

    private void SynchronizeRemoteHosts(IReadOnlyList<string> hosts, bool persist)
    {
        List<RemoteCodexTaskMonitor> removed = [];
        List<RemoteCodexTaskMonitor> added = [];
        lock (gate)
        {
            var desired = new HashSet<string>(hosts, StringComparer.OrdinalIgnoreCase);
            foreach (var host in remoteMonitors.Keys.Where(host => !desired.Contains(host)).ToArray())
            {
                removed.Add(remoteMonitors[host]);
                remoteMonitors.Remove(host);
                remoteStatus.Remove(host);
                remoteReplays.Remove(host);
                reducer.RemoveSource(host);
            }
            foreach (var host in hosts)
            {
                if (remoteMonitors.ContainsKey(host)) continue;
                var monitor = new RemoteCodexTaskMonitor(host, remoteHostStore.Checkpoint(host));
                monitor.EventArrived += (taskEvent, origin) => RemoteEventArrived(taskEvent, origin);
                monitor.ReplayStarted += () => RemoteReplayStarted(host);
                monitor.Ready += checkpoint => RemoteReady(host, checkpoint);
                monitor.Unavailable += message => RemoteUnavailable(host, message);
                remoteMonitors[host] = monitor;
                remoteStatus[host] = (false, $"正在连接远程任务主机 {host}");
                added.Add(monitor);
            }
            if (persist) remoteHostStore.SaveHosts(hosts);
            stateStore.Save(reducer.Persisted());
            stateDirty = false;
            PublishLocked();
        }
        foreach (var monitor in removed) monitor.Dispose();
        foreach (var monitor in added) monitor.Start();
    }

    private void RemoteEventArrived(TaskEvent taskEvent, TaskEventOrigin origin)
    {
        TaskResult? completion;
        lock (gate)
        {
            if (taskEvent.Source is not null && !remoteMonitors.ContainsKey(taskEvent.Source)) return;
            completion = reducer.Apply(taskEvent, origin);
            stateDirty = true;
            if (ShouldPublishRemoteEventImmediately(origin))
            {
                ScheduleStateFlushLocked();
                PublishLocked();
            }
        }
        if (completion is not null) CompletionArrived?.Invoke(completion);
    }

    private void RemoteReplayStarted(string host)
    {
        lock (gate)
        {
            if (!remoteMonitors.ContainsKey(host)) return;
            remoteReplays.Add(host);
            remoteStatus[host] = (false, $"正在同步远程任务主机 {host}");
        }
    }

    private void RemoteReady(string host, DateTimeOffset checkpoint)
    {
        lock (gate)
        {
            if (!remoteMonitors.ContainsKey(host)) return;
            remoteReplays.Remove(host);
            remoteStatus[host] = (true, null);
            FlushStateLocked();
            remoteHostStore.SaveCheckpoint(host, checkpoint);
            PublishLocked();
        }
    }

    private void ScheduleStateFlushLocked()
    {
        if (stateFlushScheduled || remoteReplays.Count > 0) return;
        stateFlushScheduled = true;
        _ = FlushStateAfterDelayAsync();
    }

    private async Task FlushStateAfterDelayAsync()
    {
        try { await Task.Delay(TimeSpan.FromSeconds(2), cancellation.Token); }
        catch (OperationCanceledException)
        {
            lock (gate) stateFlushScheduled = false;
            return;
        }
        lock (gate)
        {
            stateFlushScheduled = false;
            if (remoteReplays.Count > 0) return;
            FlushStateLocked();
        }
    }

    private void FlushStateLocked()
    {
        if (!stateDirty) return;
        stateStore.Save(reducer.Persisted());
        stateDirty = false;
    }

    private void RemoteUnavailable(string host, string message)
    {
        lock (gate)
        {
            if (!remoteMonitors.ContainsKey(host)) return;
            remoteReplays.Remove(host);
            remoteStatus[host] = (false, message);
            FlushStateLocked();
            PublishLocked();
        }
    }

    public void Dispose()
    {
        cancellation.Cancel();
        foreach (var monitor in remoteMonitors.Values) monitor.Dispose();
        remoteMonitors.Clear();
        try { worker?.Wait(TimeSpan.FromSeconds(2)); } catch { }
        lock (gate) FlushStateLocked();
        cancellation.Dispose();
    }
}
