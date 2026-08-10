namespace CodexS.Windows;

internal sealed record QuotaWindow(double RemainingPercent, DateTimeOffset? ResetsAt);

internal sealed record TaskResult(
    string Id,
    string Project,
    string? Source,
    DateTimeOffset CompletedAt,
    bool Interrupted,
    DateTimeOffset? ReadAt);

internal sealed record RunningTask(
    string Id, string SessionId, string Project, string? Source, DateTimeOffset StartedAt);

internal enum TaskEventKind { Started, Completed, Interrupted }
internal enum TaskEventOrigin { Baseline, Live, Recovery }

internal sealed record TaskEvent(
    string Id,
    string SessionId,
    string Project,
    string? Source,
    DateTimeOffset OccurredAt,
    TaskEventKind Kind);

internal sealed record UsageSnapshot(
    QuotaWindow? FiveHour,
    QuotaWindow? SevenDay,
    long TodayTokens,
    long SevenDayTokens,
    long LifetimeTokens,
    IReadOnlyList<RunningTask> Running,
    IReadOnlyList<TaskResult> Results,
    bool TaskMonitorReady,
    string? TaskMonitorMessage,
    IReadOnlyList<string> RemoteHosts,
    bool QuotaStale,
    string? StatusMessage)
{
    internal static readonly UsageSnapshot Starting = new(
        null, null, 0, 0, 0, [], [], false, "正在读取 Codex 本地数据", [], true, "正在读取 Codex 本地数据");

    internal int UnreadCount => Results.Count(item => item.ReadAt is null);
    internal int TodayCompletedCount => Results.Count(item =>
        item.CompletedAt.LocalDateTime.Date == DateTime.Today && !item.Interrupted);
    internal int TodayTaskCount => Results.Count(item =>
        item.CompletedAt.LocalDateTime.Date == DateTime.Today) + Running.Count(item =>
            item.StartedAt.LocalDateTime.Date == DateTime.Today);
}

internal sealed class PersistedState
{
    public int SchemaVersion { get; set; } = 1;
    public bool BaselineEstablished { get; set; }
    public DateTimeOffset? ReplayNotBefore { get; set; }
    public List<string> TerminalIds { get; set; } = [];
    public List<TaskResult> Results { get; set; } = [];
}
