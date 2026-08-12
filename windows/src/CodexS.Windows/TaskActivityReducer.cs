namespace CodexS.Windows;

internal sealed class TaskActivityReducer
{
    private const int TerminalLimit = 8192;
    private const int ResultLimit = 50;
    private const int DailyHistoryDays = 9;
    internal const int DailyTaskLimit = 20_000;
    private readonly Dictionary<string, RunningTask> running = new(StringComparer.Ordinal);
    private readonly HashSet<string> terminalSet;
    private readonly List<string> terminalOrder;
    private readonly List<TaskResult> results;
    private readonly Dictionary<string, DailyTaskRecord> dailyTasks = new(StringComparer.Ordinal);
    private readonly Queue<string> dailyTaskOrder = new();
    private readonly DateTimeOffset localBaselineStartCutoff;
    private DateOnly lastDailyPruneDay;

    internal bool BaselineEstablished { get; private set; }
    internal DateTimeOffset ReplayNotBefore { get; private set; }

    internal TaskActivityReducer(PersistedState state, DateTimeOffset startedAt)
    {
        BaselineEstablished = state.BaselineEstablished;
        ReplayNotBefore = state.ReplayNotBefore ?? startedAt;
        localBaselineStartCutoff = startedAt.AddHours(-12);
        terminalOrder = (state.TerminalIds ?? new List<string>()).TakeLast(TerminalLimit).ToList();
        terminalSet = new HashSet<string>(terminalOrder, StringComparer.Ordinal);
        results = (state.Results ?? new List<TaskResult>())
            .OrderByDescending(item => item.CompletedAt).Take(ResultLimit).ToList();
        var today = DateOnly.FromDateTime(DateTime.Now);
        var oldest = today.AddDays(-(DailyHistoryDays - 1));
        foreach (var item in (state.DailyTasks ?? new List<DailyTaskRecord>())
                     .OfType<DailyTaskRecord>()
                     .Where(item => !string.IsNullOrWhiteSpace(item.Id) && item.Id.Length <= 1025
                                    && DailyDate(item) >= oldest && DailyDate(item) <= today)
                     .OrderBy(item => item.TerminalAt)
                     .TakeLast(DailyTaskLimit))
        {
            if (!dailyTasks.TryAdd(item.Id, item)) continue;
            dailyTaskOrder.Enqueue(item.Id);
        }
        lastDailyPruneDay = today;
    }

    internal TaskResult? Apply(TaskEvent taskEvent, bool appendedLive)
    {
        var origin = appendedLive ? TaskEventOrigin.Live
            : taskEvent.OccurredAt < ReplayNotBefore ? TaskEventOrigin.Baseline
            : BaselineEstablished ? TaskEventOrigin.Recovery : TaskEventOrigin.Live;
        return Apply(taskEvent, origin);
    }

    internal TaskResult? Apply(TaskEvent taskEvent, TaskEventOrigin origin)
    {
        if (taskEvent.Kind == TaskEventKind.Started)
        {
            if (origin == TaskEventOrigin.Baseline && taskEvent.Source is null
                && taskEvent.OccurredAt < localBaselineStartCutoff) return null;
            if (IsKnownTerminal(taskEvent.Id)) return null;
            var newerInSession = running.Values.FirstOrDefault(item =>
                item.SessionId == taskEvent.SessionId && item.StartedAt >= taskEvent.OccurredAt);
            if (newerInSession is not null) return null;
            foreach (var old in running.Values
                         .Where(item => item.SessionId == taskEvent.SessionId && item.Id != taskEvent.Id)
                         .Select(item => item.Id).ToArray())
                running.Remove(old);
            running[taskEvent.Id] = new RunningTask(
                taskEvent.Id, taskEvent.SessionId, taskEvent.Project, taskEvent.Source, taskEvent.OccurredAt);
            return null;
        }

        running.Remove(taskEvent.Id);
        var knownTerminal = IsKnownTerminal(taskEvent.Id);
        RecordDailyTerminal(taskEvent);
        if (knownTerminal)
        {
            RememberTerminalIdentity(taskEvent.Id);
            return null;
        }
        RememberTerminalIdentity(taskEvent.Id);
        if (origin == TaskEventOrigin.Baseline) return null;

        var result = new TaskResult(
            taskEvent.Id,
            taskEvent.Project,
            taskEvent.Source,
            taskEvent.OccurredAt,
            taskEvent.Kind == TaskEventKind.Interrupted,
            null);
        results.RemoveAll(item => item.Id == result.Id);
        results.Insert(0, result);
        if (results.Count > ResultLimit) results.RemoveRange(ResultLimit, results.Count - ResultLimit);
        return result;
    }

    private bool IsKnownTerminal(string id) => terminalSet.Contains(id) || dailyTasks.ContainsKey(id);

    private void RememberTerminalIdentity(string id)
    {
        if (!terminalSet.Add(id)) return;
        terminalOrder.Add(id);
        while (terminalOrder.Count > TerminalLimit)
        {
            terminalSet.Remove(terminalOrder[0]);
            terminalOrder.RemoveAt(0);
        }
    }

    internal void FinishInitialScan(DateTimeOffset checkpoint)
    {
        BaselineEstablished = true;
        ReplayNotBefore = checkpoint;
    }

    internal void AdvanceCheckpoint(DateTimeOffset checkpoint)
    {
        if (checkpoint > ReplayNotBefore) ReplayNotBefore = checkpoint;
    }

    internal void RemoveSource(string source)
    {
        foreach (var id in running.Values
                     .Where(item => string.Equals(item.Source, source, StringComparison.OrdinalIgnoreCase))
                     .Select(item => item.Id).ToArray())
            running.Remove(id);
    }

    internal bool MarkRead(string id)
    {
        var index = results.FindIndex(item => item.Id == id && item.ReadAt is null);
        if (index < 0) return false;
        results[index] = results[index] with { ReadAt = DateTimeOffset.Now };
        return true;
    }

    internal bool MarkAllRead()
    {
        var changed = false;
        for (var index = 0; index < results.Count; index++)
        {
            if (results[index].ReadAt is not null) continue;
            results[index] = results[index] with { ReadAt = DateTimeOffset.Now };
            changed = true;
        }
        return changed;
    }

    internal IReadOnlyList<RunningTask> Running => running.Values
        .OrderByDescending(item => item.StartedAt).ToArray();
    internal IReadOnlyList<TaskResult> Results => results.ToArray();

    internal TaskProgressCounts Progress(DateOnly day)
    {
        PruneDailyTasks(day);
        var terminal = dailyTasks.Values.Where(item =>
            DateOnly.FromDateTime(item.TerminalAt.LocalDateTime) == day).ToArray();
        var runningToday = running.Values.Count(item =>
            DateOnly.FromDateTime(item.StartedAt.LocalDateTime) == day);
        return new TaskProgressCounts(
            terminal.Count(item => !item.Interrupted),
            terminal.Length + runningToday);
    }

    internal PersistedState Persisted()
    {
        PruneDailyTasks(DateOnly.FromDateTime(DateTime.Now));
        return new PersistedState {
            BaselineEstablished = BaselineEstablished,
            ReplayNotBefore = ReplayNotBefore,
            TerminalIds = terminalOrder.ToList(),
            Results = results.ToList(),
            DailyTasks = dailyTasks.Values.OrderByDescending(item => item.TerminalAt).ToList()
        };
    }

    private void RecordDailyTerminal(TaskEvent taskEvent)
    {
        var today = DateOnly.FromDateTime(DateTime.Now);
        PruneDailyTasks(today);
        var terminalDate = DateOnly.FromDateTime(taskEvent.OccurredAt.LocalDateTime);
        if (terminalDate < today.AddDays(-(DailyHistoryDays - 1)) || terminalDate > today) return;
        var item = new DailyTaskRecord(
            taskEvent.Id, taskEvent.OccurredAt, taskEvent.Kind == TaskEventKind.Interrupted);
        if (!dailyTasks.TryAdd(item.Id, item)) return;
        dailyTaskOrder.Enqueue(item.Id);
        while (dailyTasks.Count > DailyTaskLimit && dailyTaskOrder.TryDequeue(out var oldestId))
            dailyTasks.Remove(oldestId);
    }

    private void PruneDailyTasks(DateOnly today)
    {
        if (lastDailyPruneDay == today) return;
        var oldest = today.AddDays(-(DailyHistoryDays - 1));
        foreach (var id in dailyTasks.Values.Where(item =>
                     DailyDate(item) < oldest || DailyDate(item) > today)
                 .Select(item => item.Id).ToArray())
            dailyTasks.Remove(id);
        var retainedIds = dailyTaskOrder.Where(dailyTasks.ContainsKey).ToArray();
        dailyTaskOrder.Clear();
        foreach (var id in retainedIds) dailyTaskOrder.Enqueue(id);
        lastDailyPruneDay = today;
    }

    private static DateOnly DailyDate(DailyTaskRecord item) =>
        DateOnly.FromDateTime(item.TerminalAt.LocalDateTime);
}
