using System.Diagnostics;
using System.Text.Json;
using System.Text;
using System.Security.Cryptography;

namespace CodexS.Windows;

internal sealed record QuotaReadResult(QuotaWindow? FiveHour, QuotaWindow? SevenDay, string? Error, string? AccountContext = null, bool Authoritative = false)
{
    internal bool Succeeded => Error is null && Authoritative;
}

internal sealed class CodexAppServerClient
{
    private const string QuotaOnlyFeatureFlagText =
        "--disable plugins --disable recommended_plugins --disable remote_plugin --disable apps";
    private static readonly string[] DisabledUnrelatedFeatures =
        ["plugins", "recommended_plugins", "remote_plugin", "apps"];

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

        _ = DrainErrorAsync(process.StandardError, cancellationToken);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(45));
        try
        {
            await WriteAsync(process, new {
                id = 1,
                method = "initialize",
                @params = new {
                    clientInfo = new { name = "codexs", title = "CodexS", version = "0.5.0" },
                    capabilities = new { experimentalApi = true, optOutNotificationMethods = Array.Empty<string>() }
                }
            }, timeout.Token);

            string? accountContext = null;
            while (!timeout.IsCancellationRequested)
            {
                var line = await process.StandardOutput.ReadLineAsync(timeout.Token);
                if (line is null) break;
                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;
                if (!root.TryGetProperty("id", out var idElement) || !idElement.TryGetInt32(out var id)) continue;
                if (id == 1)
                {
                    if (!InitializationSucceeded(root))
                        return new QuotaReadResult(null, null, "Codex 初始化失败");
                    await WriteAsync(process, new { method = "initialized" }, timeout.Token);
                    await WriteAsync(process, new { id = 2, method = "account/read" }, timeout.Token);
                    continue;
                }
                if (id == 2)
                {
                    if (root.TryGetProperty("error", out _)
                        || !root.TryGetProperty("result", out var accountResult)
                        || (accountContext = AccountContext(accountResult)) is null)
                        return new QuotaReadResult(null, null, "Codex 登录账户无法确认");
                    await WriteAsync(process, new { id = 3, method = "account/rateLimits/read" }, timeout.Token);
                    continue;
                }
                if (id != 3) continue;
                if (root.TryGetProperty("error", out _))
                    return new QuotaReadResult(null, null, "Codex 额度读取失败", accountContext);
                if (!root.TryGetProperty("result", out var result))
                    return new QuotaReadResult(null, null, "Codex 额度响应不完整", accountContext);
                var parsed = ParseWindows(result);
                return !parsed.Valid
                    ? new QuotaReadResult(null, null, "Codex 额度窗口无法识别", accountContext)
                    : new QuotaReadResult(parsed.Five, parsed.Seven, null, accountContext, Authoritative: true);
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

    internal static bool InitializationSucceeded(JsonElement root) =>
        root.ValueKind == JsonValueKind.Object
        && !root.TryGetProperty("error", out _)
        && root.TryGetProperty("result", out var result)
        && result.ValueKind == JsonValueKind.Object;

    internal static (QuotaWindow? Five, QuotaWindow? Seven, bool Valid) ParseWindows(JsonElement result)
    {
        if (result.ValueKind != JsonValueKind.Object) return (null, null, false);
        JsonElement limits;
        if (result.TryGetProperty("rateLimitsByLimitId", out var byId))
        {
            if (byId.ValueKind != JsonValueKind.Object
                || !byId.TryGetProperty("codex", out limits)) return (null, null, false);
        }
        else if (!result.TryGetProperty("rateLimits", out limits))
            return (null, null, false);
        if (limits.ValueKind != JsonValueKind.Object) return (null, null, false);

        QuotaWindow? five = null;
        QuotaWindow? seven = null;
        var hasWindow = false;
        foreach (var name in new[] { "primary", "secondary" })
        {
            if (!limits.TryGetProperty(name, out var value)) continue;
            hasWindow = true;
            if (value.ValueKind == JsonValueKind.Null) continue;
            if (value.ValueKind != JsonValueKind.Object
                || !value.TryGetProperty("usedPercent", out var usedElement)
                || usedElement.ValueKind != JsonValueKind.Number
                || !usedElement.TryGetDouble(out var used) || !double.IsFinite(used)
                || !value.TryGetProperty("windowDurationMins", out var duration)
                || duration.ValueKind != JsonValueKind.Number
                || !duration.TryGetInt32(out var minutes)
                || (minutes != 300 && minutes != 10080)) return (null, null, false);
            DateTimeOffset? reset = null;
            if (value.TryGetProperty("resetsAt", out var resetElement)
                && resetElement.ValueKind != JsonValueKind.Null)
            {
                if (resetElement.ValueKind != JsonValueKind.Number
                    || !resetElement.TryGetInt64(out var epoch)
                    || epoch < -62135596800 || epoch > 253402300799) return (null, null, false);
                reset = DateTimeOffset.FromUnixTimeSeconds(epoch);
            }
            var window = new QuotaWindow(Math.Clamp(100 - used, 0, 100), reset);
            if (minutes == 300)
            {
                if (five is not null) return (null, null, false);
                five = window;
            }
            else
            {
                if (seven is not null) return (null, null, false);
                seven = window;
            }
        }
        // Explicitly null windows are an authoritative unlimited/absent-window response.
        return (five, seven, hasWindow);
    }

    // Keep only a digest in memory; never persist the account response or email.
    internal static string? AccountContext(JsonElement result)
    {
        if (!result.TryGetProperty("account", out var account)
            || account.ValueKind != JsonValueKind.Object
            || !account.TryGetProperty("type", out var type)
            || type.ValueKind != JsonValueKind.String
            || type.GetString() != "chatgpt"
            || !account.TryGetProperty("email", out var email)
            || email.ValueKind != JsonValueKind.String
            || string.IsNullOrWhiteSpace(email.GetString())) return null;
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes("chatgpt\n" + email.GetString()!.Trim().ToLowerInvariant())));
    }

    private static async Task DrainErrorAsync(StreamReader reader, CancellationToken token)
    {
        var buffer = new char[4096];
        try
        {
            while (await reader.ReadAsync(buffer.AsMemory(), token) != 0) { }
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or ObjectDisposedException) { }
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
                Arguments = $"/d /s /c \"\"{executable}\" app-server {QuotaOnlyFeatureFlagText}\""
            };
        }
        else
        {
            info = new ProcessStartInfo(executable);
            info.ArgumentList.Add("app-server");
            AddQuotaOnlyFeatureFlags(info.ArgumentList);
        }
        info.UseShellExecute = false;
        info.CreateNoWindow = true;
        info.RedirectStandardInput = true;
        info.RedirectStandardOutput = true;
        info.RedirectStandardError = true;
        return info;
    }

    private static void AddQuotaOnlyFeatureFlags(ICollection<string> arguments)
    {
        foreach (var feature in DisabledUnrelatedFeatures)
        {
            arguments.Add("--disable");
            arguments.Add(feature);
        }
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
