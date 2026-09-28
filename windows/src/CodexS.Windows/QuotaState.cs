namespace CodexS.Windows;

// The monitor holds its lock while updating or reading this state.
internal sealed class QuotaState
{
    internal static readonly TimeSpan MaximumAge = TimeSpan.FromMinutes(15);
    internal QuotaWindow? FiveHour { get; private set; }
    internal QuotaWindow? SevenDay { get; private set; }
    internal bool Stale { get; private set; } = true;
    internal string? Message { get; private set; } = "正在读取 Codex 本地数据";
    private DateTimeOffset? fetchedAt;
    private string? context;

    internal void Update(QuotaWindow? five, QuotaWindow? seven, bool stale,
        string? message, string? accountContext, DateTimeOffset now)
    {
        if (!stale)
        {
            // A missing window in an authoritative response removes the old window.
            FiveHour = five;
            SevenDay = seven;
            fetchedAt = now;
            context = accountContext;
        }
        else if (accountContext is null || accountContext != context)
        {
            FiveHour = null;
            SevenDay = null;
            fetchedAt = null;
            context = null;
        }
        Stale = stale;
        Message = message;
        Expire(now);
    }

    internal void Expire(DateTimeOffset now)
    {
        var tooOld = fetchedAt is null || now < fetchedAt
            || now - fetchedAt >= MaximumAge;
        var expired = false;
        if (FiveHour is not null && (tooOld || FiveHour.ResetsAt <= now || (Stale && FiveHour.ResetsAt is null)))
        {
            FiveHour = null;
            expired = true;
        }
        if (SevenDay is not null && (tooOld || SevenDay.ResetsAt <= now || (Stale && SevenDay.ResetsAt is null)))
        {
            SevenDay = null;
            expired = true;
        }
        if (expired || (tooOld && fetchedAt is not null))
        {
            Stale = true;
            Message ??= "额度快照已过期，等待刷新";
        }
    }
}

// Timer ticks never queue work. Repeated manual clicks queue one follow-up read.
internal sealed class QuotaRefreshGate
{
    private readonly object gate = new();
    private bool running;
    private bool pendingManual;

    internal bool TryBegin(bool manual)
    {
        lock (gate)
        {
            if (running)
            {
                pendingManual |= manual;
                return false;
            }
            running = true;
            return true;
        }
    }

    internal bool Finish(bool cancelled = false)
    {
        lock (gate)
        {
            if (!cancelled && pendingManual)
            {
                pendingManual = false;
                return true;
            }
            running = false;
            pendingManual = false;
            return false;
        }
    }
}
