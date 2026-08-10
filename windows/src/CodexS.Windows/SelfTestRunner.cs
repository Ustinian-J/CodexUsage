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

            using var rateDocument = JsonDocument.Parse("""
                {"rateLimitsByLimitId":{"codex":{"secondary":{"usedPercent":25,"windowDurationMins":10080,"resetsAt":1800007200},"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1800003600}}}}
                """);
            var windows = CodexAppServerClient.ParseWindows(rateDocument.RootElement);
            Expect(windows.Five?.RemainingPercent == 90, "5h quota classification");
            Expect(windows.Seven?.RemainingPercent == 75, "7d quota classification independent of order");

            var now = DateTimeOffset.Now;
            var reducer = new TaskActivityReducer(new PersistedState(), now);
            var first = new TaskEvent("turn-1", "session-a", "project", null, now.AddMinutes(1), TaskEventKind.Started);
            var second = new TaskEvent("turn-2", "session-a", "project", null, now.AddMinutes(2), TaskEventKind.Started);
            reducer.Apply(first, appendedLive: false);
            reducer.Apply(second, appendedLive: false);
            Expect(reducer.Running.Count == 1 && reducer.Running[0].Id == "turn-2", "new turn replaces stale start");
            var completion = reducer.Apply(second with { OccurredAt = now.AddMinutes(3), Kind = TaskEventKind.Completed }, appendedLive: false);
            Expect(completion is not null && reducer.Results.Count == 1, "first-scan completion after watermark is live");
            Expect(reducer.MarkAllRead() && reducer.Results[0].ReadAt is not null, "mark all read");

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
