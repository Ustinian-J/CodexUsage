using System.Text;
using System.Text.Json;

namespace CodexS.Windows;

internal static class SelfTestRunner
{
    internal static int Run()
    {
        try
        {
            Expect(CodexSessionMonitor.TokenDelta(100, 145) == 45, "token cumulative delta");
            Expect(CodexSessionMonitor.TokenDelta(145, 20) == 20, "token counter reset");
            Expect(RemoteHostName.Validate("codex") == "codex", "safe SSH alias");
            Expect(RemoteHostName.Validate("-oProxyCommand=bad") is null, "SSH option injection rejected");
            Expect(RemoteHostName.Validate("host;touch") is null, "remote shell metacharacters rejected");
            Expect(RemoteHostName.Parse("codex, build-box CODEX").SequenceEqual(["codex", "build-box"]),
                "remote aliases deduplicated");
            Expect(Path.IsPathRooted(RemoteCodexTaskMonitor.OpenSshPath)
                   && RemoteCodexTaskMonitor.OpenSshPath == Path.Combine(
                       Environment.SystemDirectory, "OpenSSH", "ssh.exe"),
                "system OpenSSH path must not use PATH lookup");
            Expect(!RemoteHostStore.UsesRemoteClockCheckpoints(1)
                   && RemoteHostStore.UsesRemoteClockCheckpoints(2)
                   && RemoteHostStore.UsesRemoteClockCheckpoints(3),
                "legacy local-clock remote checkpoints must be discarded");
            Expect(!RemoteHostStore.RestoresMonitoringAuthorization(2, enabled: true)
                   && RemoteHostStore.RestoresMonitoringAuthorization(3, enabled: true)
                   && !RemoteHostStore.RestoresMonitoringAuthorization(3, enabled: false)
                   && !RemoteHostStore.RestoresMonitoringAuthorization(99, enabled: true),
                "remote-monitor authorization must fail closed for legacy and unknown schemas");
            Expect(!RemoteHostStore.RestoresMonitoringAuthorizationFromJson("""{"Enabled":true}""")
                   && RemoteHostStore.RestoresMonitoringAuthorizationFromJson(
                       """{"SchemaVersion":3,"Enabled":true}"""),
                "missing remote settings schema must not inherit the current authorized version");
            Expect(RemoteConnectionRetryPolicy.DelayForFailure(0) == TimeSpan.FromSeconds(10)
                   && RemoteConnectionRetryPolicy.DelayForFailure(1) == TimeSpan.FromSeconds(30)
                   && RemoteConnectionRetryPolicy.DelayForFailure(4) == TimeSpan.FromMinutes(5)
                   && RemoteConnectionRetryPolicy.DelayForFailure(20) == TimeSpan.FromMinutes(5)
                   && RemoteConnectionRetryPolicy.NormalizeFailures(4, TimeSpan.FromMinutes(1)) == 0
                   && RemoteConnectionRetryPolicy.NormalizeFailures(4, TimeSpan.FromSeconds(59)) == 4,
                "remote reconnects must use capped backoff and reset after a stable connection");

            var lineBuffer = new BoundedLineBuffer();
            Expect(lineBuffer.Append("{\"kind\":"u8).Count == 0, "partial line must remain buffered");
            var splitLines = lineBuffer.Append("\"ready\"}\r\n"u8);
            Expect(splitLines.Count == 1
                   && Encoding.UTF8.GetString(splitLines[0]) == "{\"kind\":\"ready\"}",
                "bounded line buffer must join chunks and trim CRLF");
            var oversized = new byte[BoundedLineBuffer.MaxLineBytes + 1];
            Array.Fill(oversized, (byte)'x');
            Expect(lineBuffer.Append(oversized).Count == 0
                   && lineBuffer.DiscardingOversizedLine
                   && lineBuffer.BufferedByteCount <= BoundedLineBuffer.MaxLineBytes,
                "oversized line must be discarded within the memory bound");
            var recoveredLines = lineBuffer.Append("\n{\"ok\":true}\n"u8);
            Expect(recoveredLines.Count == 1
                   && Encoding.UTF8.GetString(recoveredLines[0]) == "{\"ok\":true}",
                "line buffer must recover after an oversized line");

            using var malformed = CodexSessionMonitor.TryParseDocument("{broken"u8.ToArray());
            Expect(malformed is null, "malformed JSON line must be ignored");
            using var sourceString = JsonDocument.Parse("""{"source":"cli"}""");
            Expect(!CodexSessionMonitor.IsSubagent(sourceString.RootElement),
                "non-object session source must not terminate parsing");
            using var invalidEpoch = JsonDocument.Parse("""{"value":"NaN","huge":"1e400"}""");
            Expect(CodexSessionMonitor.ReadEpoch(invalidEpoch.RootElement, "value") is null
                   && CodexSessionMonitor.ReadEpoch(invalidEpoch.RootElement, "huge") is null,
                "non-finite session timestamps must be rejected");
            foreach (var malformedShape in new[] {
                         "[]", "{\"type\":7,\"payload\":{}}", "{\"type\":\"event_msg\",\"payload\":[]}" })
            {
                using var shape = JsonDocument.Parse(malformedShape);
                Expect(!CodexSessionMonitor.TryGetSessionEnvelope(
                        shape.RootElement, out _, out _),
                    "malformed session object shapes must be ignored");
            }
            using var validShape = JsonDocument.Parse(
                """{"type":"event_msg","payload":{"type":"task_complete"}}""");
            Expect(CodexSessionMonitor.TryGetSessionEnvelope(
                    validShape.RootElement, out var validType, out _)
                   && validType == "event_msg",
                "valid session shape must still parse after malformed input");
            using var badTokenShape = JsonDocument.Parse(
                """{"info":{"total_token_usage":"bad"}}""");
            using var validTokenShape = JsonDocument.Parse(
                """{"info":{"total_token_usage":{"total_tokens":42}}}""");
            Expect(!CodexSessionMonitor.TryReadTotalTokens(badTokenShape.RootElement, out _)
                   && CodexSessionMonitor.TryReadTotalTokens(validTokenShape.RootElement, out var parsedTokens)
                   && parsedTokens == 42,
                "malformed token objects must not prevent the next valid value");
            Expect(CodexSessionMonitor.IsRecoverableScanException(new JsonException())
                   && CodexSessionMonitor.IsRecoverableScanException(new IOException()),
                "bad JSON and transient file errors must keep the worker retrying");
            var enumerationOptions = CodexSessionMonitor.SessionEnumerationOptions();
            Expect(enumerationOptions.RecurseSubdirectories && !enumerationOptions.IgnoreInaccessible,
                "inaccessible session directories must fail the scan before checkpoint advancement");
            Expect(CodexSessionMonitor.ShouldPublishRemoteEventImmediately(TaskEventOrigin.Live)
                   && !CodexSessionMonitor.ShouldPublishRemoteEventImmediately(TaskEventOrigin.Baseline)
                   && !CodexSessionMonitor.ShouldPublishRemoteEventImmediately(TaskEventOrigin.Recovery),
                "remote replay must batch snapshots until ready");

            using var rateDocument = JsonDocument.Parse("""
                {"rateLimitsByLimitId":{"codex":{"secondary":{"usedPercent":25,"windowDurationMins":10080,"resetsAt":1800007200},"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1800003600}}}}
                """);
            var windows = CodexAppServerClient.ParseWindows(rateDocument.RootElement);
            Expect(windows.Five?.RemainingPercent == 90, "5h quota classification");
            Expect(windows.Seven?.RemainingPercent == 75, "7d quota classification independent of order");

            var now = DateTimeOffset.Now;
            var remoteScanStart = now.AddHours(-3);
            var beforeRemoteScan = new TaskEvent(
                "before-scan", "remote-session", "project", "codex",
                remoteScanStart.AddMilliseconds(-1), TaskEventKind.Completed);
            var concurrentRemote = beforeRemoteScan with {
                Id = "at-scan", OccurredAt = remoteScanStart
            };
            Expect(RemoteReplayPolicy.Cutoff(null, remoteScanStart) == remoteScanStart,
                "first remote scan must use its own clock watermark");
            Expect(RemoteReplayPolicy.Origin(beforeRemoteScan, remoteScanStart, clockRolledBack: false)
                   == TaskEventOrigin.Baseline
                   && RemoteReplayPolicy.Origin(concurrentRemote, remoteScanStart, clockRolledBack: false)
                   == TaskEventOrigin.Recovery,
                "events concurrent with the first remote scan must recover rather than become history");
            var preRollbackCheckpoint = remoteScanStart.AddHours(1);
            var clockRolledBack = RemoteReplayPolicy.ClockRolledBack(
                preRollbackCheckpoint, remoteScanStart);
            Expect(clockRolledBack
                   && RemoteReplayPolicy.Cutoff(preRollbackCheckpoint, remoteScanStart) == remoteScanStart
                   && RemoteReplayPolicy.Origin(
                       beforeRemoteScan, remoteScanStart, clockRolledBack) == TaskEventOrigin.Recovery,
                "remote clock rollback must replay terminal events before the new watermark");
            var boundaryLocalTime = DateTime.Today.AddHours(12);
            var rollbackBoundaryScan = new DateTimeOffset(
                boundaryLocalTime, TimeZoneInfo.Local.GetUtcOffset(boundaryLocalTime));
            var boundaryRollbackCompletion = beforeRemoteScan with {
                Id = "boundary-rollback", OccurredAt = rollbackBoundaryScan.AddDays(-8)
            };
            Expect(RemoteReplayPolicy.Origin(
                       boundaryRollbackCompletion, rollbackBoundaryScan, clockRolledBack)
                   == TaskEventOrigin.Recovery
                   && RemoteReplayPolicy.Origin(
                       boundaryRollbackCompletion with {
                           Id = "outside-rollback",
                           OccurredAt = rollbackBoundaryScan.AddDays(-8).AddTicks(-1)
                       }, rollbackBoundaryScan, clockRolledBack) == TaskEventOrigin.Baseline,
                "remote clock rollback recovery must use an exact eight-day window away from midnight");
            var rollbackBoundaryLedger = new TaskActivityReducer(
                new PersistedState(), rollbackBoundaryScan);
            rollbackBoundaryLedger.Apply(
                boundaryRollbackCompletion, TaskEventOrigin.Baseline);
            Expect(rollbackBoundaryLedger.Persisted().DailyTasks.Any(item =>
                       item.Id == boundaryRollbackCompletion.Id),
                "nine calendar-day buckets must cover the full eight-day rollback window");
            Expect(RemoteReplayPolicy.Cutoff(remoteScanStart.AddMinutes(-5), remoteScanStart)
                   == remoteScanStart.AddMinutes(-5),
                "remote reconnect must recover events after the prior checkpoint");
            var staleRemoteStart = new TaskEvent(
                "remote-stale", "remote-stale-session", "project", "codex",
                remoteScanStart.AddHours(-13), TaskEventKind.Started);
            Expect(RemoteReplayPolicy.ShouldSkipStaleStart(
                       staleRemoteStart, TaskEventOrigin.Baseline, remoteScanStart, clockRolledBack: false)
                   && !RemoteReplayPolicy.ShouldSkipStaleStart(
                       staleRemoteStart, TaskEventOrigin.Recovery, remoteScanStart, clockRolledBack: false)
                   && RemoteReplayPolicy.ShouldSkipStaleStart(
                       staleRemoteStart, TaskEventOrigin.Recovery, remoteScanStart, clockRolledBack: true)
                   && !RemoteReplayPolicy.ShouldSkipStaleStart(
                       staleRemoteStart with { OccurredAt = remoteScanStart.AddHours(-1) },
                       TaskEventOrigin.Baseline, remoteScanStart, clockRolledBack: true),
                "remote scans may filter only stale starts, including during clock rollback");
            Expect(RemoteCodexTaskMonitor.TryUnixTime(1_800_000_000, out var remoteTime)
                   && remoteTime == DateTimeOffset.FromUnixTimeSeconds(1_800_000_000)
                   && !RemoteCodexTaskMonitor.TryUnixTime(double.PositiveInfinity, out _),
                "remote watermarks must be finite Unix timestamps");

            var reducer = new TaskActivityReducer(new PersistedState(), now);
            var first = new TaskEvent("turn-1", "session-a", "project", null, now.AddMinutes(1), TaskEventKind.Started);
            var second = new TaskEvent("turn-2", "session-a", "project", null, now.AddMinutes(2), TaskEventKind.Started);
            reducer.Apply(first, appendedLive: false);
            reducer.Apply(second, appendedLive: false);
            Expect(reducer.Running.Count == 1 && reducer.Running[0].Id == "turn-2", "new turn replaces stale start");
            var completion = reducer.Apply(second with { OccurredAt = now.AddMinutes(3), Kind = TaskEventKind.Completed }, appendedLive: false);
            Expect(completion is not null && reducer.Results.Count == 1, "first-scan completion after watermark is live");
            Expect(reducer.MarkAllRead() && reducer.Results[0].ReadAt is not null, "mark all read");

            var staleLocal = new TaskActivityReducer(new PersistedState(), now);
            var oldLocalStart = new TaskEvent(
                "old-local", "old-local-session", "project", null,
                now.AddHours(-13), TaskEventKind.Started);
            staleLocal.Apply(oldLocalStart, TaskEventOrigin.Baseline);
            Expect(staleLocal.Running.Count == 0, "stale local baseline start must be skipped");
            staleLocal.Apply(oldLocalStart with { Id = "old-live", SessionId = "old-live-session" },
                TaskEventOrigin.Live);
            staleLocal.Apply(oldLocalStart with { Id = "old-recovery", SessionId = "old-recovery-session" },
                TaskEventOrigin.Recovery);
            staleLocal.FinishInitialScan(now);
            Expect(staleLocal.Running.Count == 2,
                "initial-scan completion must not delete long live or recovery tasks");

            var localNoon = DateTime.Today.AddHours(12);
            var todayEventTime = new DateTimeOffset(localNoon, TimeZoneInfo.Local.GetUtcOffset(localNoon));
            var daily = new TaskActivityReducer(new PersistedState(), todayEventTime);
            for (var index = 0; index < 75; index++)
            {
                daily.Apply(new TaskEvent($"today-{index}", $"today-session-{index}", "project", null,
                    todayEventTime.AddSeconds(index), TaskEventKind.Completed), TaskEventOrigin.Baseline);
            }
            daily.Apply(new TaskEvent("today-interrupted", "today-interrupted-session", "project", null,
                todayEventTime.AddMinutes(2), TaskEventKind.Interrupted), TaskEventOrigin.Baseline);
            var today = DateOnly.FromDateTime(DateTime.Today);
            Expect(daily.Results.Count == 0 && daily.Progress(today) == new TaskProgressCounts(75, 76),
                "daily progress must include baseline history beyond the notification limit");
            var dailyRecovered = new TaskActivityReducer(daily.Persisted(), todayEventTime.AddHours(1));
            Expect(dailyRecovered.Progress(today) == new TaskProgressCounts(75, 76),
                "daily progress must survive persistence");
            daily.Apply(new TaskEvent("today-running", "today-running-session", "project", null,
                todayEventTime.AddMinutes(3), TaskEventKind.Started), TaskEventOrigin.Baseline);
            daily.Apply(new TaskEvent("today-0", "today-session-0", "project", null,
                todayEventTime.AddMinutes(4), TaskEventKind.Completed), TaskEventOrigin.Recovery);
            Expect(daily.Progress(today) == new TaskProgressCounts(75, 77),
                "running tasks must count once and replayed terminals must remain idempotent");

            var oversizedDailyState = new PersistedState {
                DailyTasks = Enumerable.Range(0, TaskActivityReducer.DailyTaskLimit + 25)
                    .Select(index => new DailyTaskRecord(
                        $"bounded-{index}", todayEventTime.AddSeconds(index), Interrupted: false))
                    .ToList()
            };
            var boundedDaily = new TaskActivityReducer(oversizedDailyState, todayEventTime);
            Expect(boundedDaily.Persisted().DailyTasks.Count == TaskActivityReducer.DailyTaskLimit,
                "daily task ledger must enforce its hard record limit");

            var remote = new TaskEvent("remote-turn", "remote-session", "backend", "codex",
                now.AddMinutes(4), TaskEventKind.Started);
            reducer.Apply(remote, TaskEventOrigin.Baseline);
            reducer.RemoveSource("CODEX");
            Expect(reducer.Running.All(item => item.Source is null), "disabled remote running tasks removed");

            var longHistory = new TaskActivityReducer(new PersistedState(), now);
            for (var index = 0; index < 8_300; index++)
            {
                var old = new TaskEvent($"old-{index}", $"session-{index}", "project", null,
                    now.AddDays(-2).AddSeconds(index), TaskEventKind.Completed);
                Expect(longHistory.Apply(old, appendedLive: false) is null, "old replay must not notify");
            }
            Expect(longHistory.Results.Count == 0, "bounded ledger replay must stay baseline");
            var longPersisted = longHistory.Persisted();
            Expect(longPersisted.TerminalIds.Count == 8_192
                   && !longPersisted.TerminalIds.Contains("old-0")
                   && longPersisted.DailyTasks.Any(item => item.Id == "old-0"),
                "daily terminal ledger must retain known state beyond the 8192-ID ledger");
            var rollbackRecovered = new TaskActivityReducer(longPersisted, now);
            var evictedTerminal = new TaskEvent(
                "old-0", "session-0", "project", "codex",
                now.AddDays(-2), TaskEventKind.Completed);
            Expect(rollbackRecovered.Apply(evictedTerminal, TaskEventOrigin.Recovery) is null
                   && rollbackRecovered.Results.Count == 0,
                "daily terminal ledger must suppress rollback duplicates evicted from the 8192-ID ledger");
            rollbackRecovered.Apply(
                evictedTerminal with {
                    Id = "old-1", SessionId = "session-1", Kind = TaskEventKind.Started
                }, TaskEventOrigin.Recovery);
            Expect(rollbackRecovered.Running.Count == 0,
                "known rollback terminals must not be resurrected as running tasks");

            var persisted = reducer.Persisted();
            var recovered = new TaskActivityReducer(persisted, now.AddHours(1));
            var duplicate = recovered.Apply(second with { Kind = TaskEventKind.Completed }, appendedLive: false);
            Expect(duplicate is null, "terminal event must remain idempotent after restart");

            var installRoot = Path.GetFullPath(AppPaths.InstallDirectory);
            var localData = Path.GetFullPath(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
            Expect(installRoot.StartsWith(localData, StringComparison.OrdinalIgnoreCase), "per-user install root");
            return 0;
        }
        catch
        {
            return 1;
        }
    }

    private static void Expect(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }
}
