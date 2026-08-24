using System.Diagnostics;
using System.Text.Json;

namespace CodexS.Windows;

internal sealed record QuotaReadResult(QuotaWindow? FiveHour, QuotaWindow? SevenDay, string? Error)
{
    internal bool Succeeded => Error is null && (FiveHour is not null || SevenDay is not null);
}

internal sealed class CodexAppServerClient
{
    internal async Task<QuotaReadResult> ReadAsync(CancellationToken cancellationToken)
    {
        var executable = FindCodex();
        if (executable is null) return new QuotaReadResult(null, null, "未找到 codex 命令");

        using var process = new Process { StartInfo = BuildStartInfo(executable) };
        try
        {
            if (!process.Start()) return new QuotaReadResult(null, null, "无法启动 codex app-server");
        }
        catch
        {
            return new QuotaReadResult(null, null, "无法启动 codex app-server");
        }

        _ = process.StandardError.ReadToEndAsync(cancellationToken);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(12));
        try
        {
            await WriteAsync(process, new {
                id = 1,
                method = "initialize",
                @params = new {
                    clientInfo = new { name = "codexs", title = "CodexS", version = "0.4.1" },
                    capabilities = new { experimentalApi = true, optOutNotificationMethods = Array.Empty<string>() }
                }
            }, timeout.Token);

            QuotaWindow? five = null;
            QuotaWindow? seven = null;
            while (!timeout.IsCancellationRequested)
            {
                var line = await process.StandardOutput.ReadLineAsync(timeout.Token);
                if (line is null) break;
                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;
                if (!root.TryGetProperty("id", out var idElement) || !idElement.TryGetInt32(out var id)) continue;
                if (id == 1)
                {
                    await WriteAsync(process, new { method = "initialized" }, timeout.Token);
                    await WriteAsync(process, new { id = 2, method = "account/rateLimits/read" }, timeout.Token);
                    continue;
                }
                if (id != 2) continue;
                if (root.TryGetProperty("error", out _))
                    return new QuotaReadResult(null, null, "Codex 额度读取失败");
                if (!root.TryGetProperty("result", out var result))
                    return new QuotaReadResult(null, null, "Codex 额度响应不完整");
                (five, seven) = ParseWindows(result);
                return five is null && seven is null
                    ? new QuotaReadResult(null, null, "Codex 额度窗口无法识别")
                    : new QuotaReadResult(five, seven, null);
            }
            return new QuotaReadResult(null, null, "Codex 额度响应超时");
        }
        catch (OperationCanceledException)
        {
            return new QuotaReadResult(null, null, "Codex 额度响应超时");
        }
        catch
        {
            return new QuotaReadResult(null, null, "Codex 额度响应无法解析");
        }
        finally
        {
            try
            {
                process.StandardInput.Close();
                if (!process.HasExited) process.Kill(entireProcessTree: true);
            }
            catch { }
        }
    }

    internal static (QuotaWindow? Five, QuotaWindow? Seven) ParseWindows(JsonElement result)
    {
        JsonElement limits;
        if (result.TryGetProperty("rateLimitsByLimitId", out var byId)
            && byId.TryGetProperty("codex", out var codex))
            limits = codex;
        else if (result.TryGetProperty("rateLimits", out var legacy))
            limits = legacy;
        else
            return (null, null);

        var windows = new List<(int? Minutes, QuotaWindow Window)>();
        foreach (var name in new[] { "primary", "secondary" })
        {
            if (!limits.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Object) continue;
            if (!value.TryGetProperty("usedPercent", out var usedElement) || !usedElement.TryGetDouble(out var used)) continue;
            int? minutes = value.TryGetProperty("windowDurationMins", out var duration)
                && duration.TryGetInt32(out var parsedMinutes) ? parsedMinutes : null;
            DateTimeOffset? reset = value.TryGetProperty("resetsAt", out var resetElement)
                && resetElement.TryGetInt64(out var epoch) ? DateTimeOffset.FromUnixTimeSeconds(epoch) : null;
            windows.Add((minutes, new QuotaWindow(Math.Clamp(100 - used, 0, 100), reset)));
        }
        var five = windows.SingleOrDefault(item => item.Minutes == 300).Window;
        var seven = windows.SingleOrDefault(item => item.Minutes == 10080).Window;
        if (five is null && seven is null && windows.Count == 2
            && windows.All(item => item.Minutes is null))
            (five, seven) = (windows[0].Window, windows[1].Window);
        return (five, seven);
    }

    private static async Task WriteAsync(Process process, object message, CancellationToken token)
    {
        await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(message).AsMemory(), token);
        await process.StandardInput.FlushAsync(token);
    }

    private static ProcessStartInfo BuildStartInfo(string executable)
    {
        ProcessStartInfo info;
        if (executable.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase))
        {
            var commandInterpreter = Environment.GetEnvironmentVariable("ComSpec")
                ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe");
            info = new ProcessStartInfo(commandInterpreter) {
                Arguments = $"/d /s /c \"\"{executable}\" app-server\""
            };
        }
        else
        {
            info = new ProcessStartInfo(executable);
            info.ArgumentList.Add("app-server");
        }
        info.UseShellExecute = false;
        info.CreateNoWindow = true;
        info.RedirectStandardInput = true;
        info.RedirectStandardOutput = true;
        info.RedirectStandardError = true;
        return info;
    }

    private static string? FindCodex()
    {
        var candidates = new List<string>();
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? string.Empty)
                     .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            candidates.Add(Path.Combine(directory.Trim('"'), "codex.exe"));
            candidates.Add(Path.Combine(directory.Trim('"'), "codex.cmd"));
        }
        candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "npm", "codex.cmd"));
        candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".local", "bin", "codex.exe"));
        return candidates.FirstOrDefault(path => !path.Contains('"') && File.Exists(path));
    }
}
