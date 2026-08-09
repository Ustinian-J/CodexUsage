namespace CodexS.Windows;

internal sealed class TaskActivityReducer
{
    private const int TerminalLimit = 8192;
    private const int ResultLimit = 50;
    private readonly Dictionary<string, RunningTask> running = new(StringComparer.Ordinal);
    private readonly HashSet<string> terminalSet;
    private readonly List<string> terminalOrder;
    private readonly List<TaskResult> results;

    internal bool BaselineEstablished { get; private set; }
    internal DateTimeOffset ReplayNotBefore { get; private set; }

    internal TaskActivityReducer(PersistedState state, DateTimeOffset startedAt)
    {
        BaselineEstablished = state.BaselineEstablished;
        ReplayNotBefore = state.ReplayNotBefore ?? startedAt;
        terminalOrder = state.TerminalIds.TakeLast(TerminalLimit).ToList();
        terminalSet = new HashSet<string>(terminalOrder, StringComparer.Ordinal);
        results = state.Results.OrderByDescending(item => item.CompletedAt).Take(ResultLimit).ToList();
    }

    internal TaskResult? Apply(TaskEvent taskEvent, bool appendedLive)
    {
        var originIsBaseline = !appendedLive && taskEvent.OccurredAt < ReplayNotBefore;
        if (taskEvent.Kind == TaskEventKind.Started)
        {
            if (terminalSet.Contains(taskEvent.Id)) return null;
            var newerInSession = running.Values.FirstOrDefault(item =>
                item.SessionId == taskEvent.SessionId && item.StartedAt >= taskEvent.OccurredAt);
            if (newerInSession is not null) return null;
            foreach (var old in running.Values
                         .Where(item => item.SessionId == taskEvent.SessionId && item.Id != taskEvent.Id)
                         .Select(item => item.Id).ToArray())
                running.Remove(old);
            running[taskEvent.Id] = new RunningTask(
                taskEvent.Id, taskEvent.SessionId, taskEvent.Project, taskEvent.OccurredAt);
            return null;
        }

        running.Remove(taskEvent.Id);
        if (!terminalSet.Add(taskEvent.Id)) return null;
        terminalOrder.Add(taskEvent.Id);
        while (terminalOrder.Count > TerminalLimit)
        {
            terminalSet.Remove(terminalOrder[0]);
            terminalOrder.RemoveAt(0);
        }
        if (originIsBaseline) return null;

        var result = new TaskResult(
            taskEvent.Id,
            taskEvent.Project,
            taskEvent.OccurredAt,
            taskEvent.Kind == TaskEventKind.Interrupted,
            null);
        results.RemoveAll(item => item.Id == result.Id);
        results.Insert(0, result);
        if (results.Count > ResultLimit) results.RemoveRange(ResultLimit, results.Count - ResultLimit);
        return result;
    }

    internal void FinishInitialScan(DateTimeOffset checkpoint)
    {
        BaselineEstablished = true;
        ReplayNotBefore = checkpoint;
        RemoveStaleRunning(checkpoint.AddHours(-12));
    }

    internal void AdvanceCheckpoint(DateTimeOffset checkpoint)
    {
        if (checkpoint > ReplayNotBefore) ReplayNotBefore = checkpoint;
    }

    internal void RemoveStaleRunning(DateTimeOffset cutoff)
    {
        foreach (var id in running.Values.Where(item => item.StartedAt < cutoff).Select(item => item.Id).ToArray())
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

    internal PersistedState Persisted() => new()
    {
        BaselineEstablished = BaselineEstablished,
        ReplayNotBefore = ReplayNotBefore,
        TerminalIds = terminalOrder.ToList(),
        Results = results.ToList()
    };
}
