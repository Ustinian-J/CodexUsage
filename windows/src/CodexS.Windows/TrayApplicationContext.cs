namespace CodexS.Windows;

internal sealed class TrayApplicationContext : ApplicationContext
{
    private readonly SingleInstance singleInstance;
    private readonly CodexSessionMonitor monitor = new();
    private readonly CodexAppServerClient quotaClient = new();
    private readonly DashboardForm dashboard = new();
    private readonly NotifyIcon tray = new();
    private readonly System.Windows.Forms.Timer pulseTimer = new() { Interval = 800 };
    private readonly System.Threading.Timer quotaTimer;
    private readonly CancellationTokenSource cancellation = new();
    private Icon? currentIcon;
    private bool attentionBright = true;
    private int quotaRefreshInProgress;

    internal TrayApplicationContext(SingleInstance singleInstance)
    {
        this.singleInstance = singleInstance;
        dashboard.CreateControl();
        dashboard.MarkAllReadRequested += monitor.MarkAllRead;
        dashboard.ResultOpened += id => { monitor.MarkRead(id); dashboard.ShowPanel(); };
        dashboard.RefreshRequested += () => _ = RefreshQuotaAsync();
        singleInstance.ShowRequested += ShowFromBackgroundThread;

        tray.Text = "CodexS 正在启动";
        tray.Visible = true;
        tray.DoubleClick += (_, _) => dashboard.ShowPanel();
        tray.BalloonTipClicked += (_, _) => dashboard.ShowPanel();
        tray.ContextMenuStrip = BuildMenu();

        pulseTimer.Tick += (_, _) => {
            if (monitor.Current.UnreadCount == 0) return;
            attentionBright = !attentionBright;
            UpdateTray(monitor.Current);
        };
        monitor.SnapshotChanged += SnapshotChangedFromBackgroundThread;
        monitor.CompletionArrived += CompletionArrivedFromBackgroundThread;
        monitor.Start();
        quotaTimer = new System.Threading.Timer(_ => _ = RefreshQuotaAsync(), null, TimeSpan.Zero, TimeSpan.FromMinutes(1));
        dashboard.UpdateSnapshot(monitor.Current);
        UpdateTray(monitor.Current);
    }

    private ContextMenuStrip BuildMenu()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("打开 CodexS", null, (_, _) => dashboard.ShowPanel());
        menu.Items.Add("全部标为已读", null, (_, _) => monitor.MarkAllRead());
        menu.Items.Add("立即刷新额度", null, (_, _) => _ = RefreshQuotaAsync());
        menu.Items.Add(new ToolStripSeparator());
        var startup = new ToolStripMenuItem("登录时启动") {
            Checked = AppPaths.IsInstalledExecutable && Installer.IsRunAtLoginEnabled(),
            CheckOnClick = true,
            Enabled = AppPaths.IsInstalledExecutable
        };
        startup.CheckedChanged += (_, _) => Installer.SetRunAtLogin(startup.Checked);
        menu.Items.Add(startup);
        if (AppPaths.IsInstalledExecutable)
            menu.Items.Add("卸载 CodexS", null, (_, _) => { if (Installer.BeginUninstall()) ExitThread(); });
        menu.Items.Add("退出", null, (_, _) => ExitThread());
        return menu;
    }

    private async Task RefreshQuotaAsync()
    {
        if (Interlocked.Exchange(ref quotaRefreshInProgress, 1) != 0) return;
        try
        {
            var result = await quotaClient.ReadAsync(cancellation.Token);
            monitor.SetQuota(
                result.FiveHour,
                result.SevenDay,
                stale: !result.Succeeded,
                message: result.Error);
        }
        finally
        {
            Interlocked.Exchange(ref quotaRefreshInProgress, 0);
        }
    }

    private void SnapshotChangedFromBackgroundThread(UsageSnapshot snapshot)
    {
        if (dashboard.IsDisposed || !dashboard.IsHandleCreated) return;
        dashboard.BeginInvoke((Action)(() => {
            dashboard.UpdateSnapshot(snapshot);
            UpdateTray(snapshot);
        }));
    }

    private void CompletionArrivedFromBackgroundThread(TaskResult result)
    {
        if (dashboard.IsDisposed || !dashboard.IsHandleCreated) return;
        dashboard.BeginInvoke((Action)(() => {
            tray.BalloonTipTitle = result.Interrupted ? "Codex 任务已中断" : "Codex 任务已完成";
            tray.BalloonTipText = "打开 CodexS 查看任务动态";
            tray.ShowBalloonTip(6000);
        }));
    }

    private void ShowFromBackgroundThread()
    {
        if (dashboard.IsDisposed || !dashboard.IsHandleCreated) return;
        dashboard.BeginInvoke((Action)dashboard.ShowPanel);
    }

    private void UpdateTray(UsageSnapshot snapshot)
    {
        var animate = snapshot.UnreadCount > 0
            && SystemInformation.IsMenuAnimationEnabled
            && !SystemInformation.HighContrast;
        if (animate && !pulseTimer.Enabled) pulseTimer.Start();
        if (!animate && pulseTimer.Enabled) pulseTimer.Stop();
        if (!animate) attentionBright = true;

        var icon = TrayIconFactory.Create(snapshot, attentionBright);
        tray.Icon = icon;
        currentIcon?.Dispose();
        currentIcon = icon;
        var five = snapshot.FiveHour is null ? "--" : $"{snapshot.FiveHour.RemainingPercent:0}%";
        var seven = snapshot.SevenDay is null ? "--" : $"{snapshot.SevenDay.RemainingPercent:0}%";
        tray.Text = $"CodexS  5h {five}  7d {seven}  运行 {snapshot.Running.Count}  未读 {snapshot.UnreadCount}";
    }

    protected override void ExitThreadCore()
    {
        cancellation.Cancel();
        quotaTimer.Dispose();
        pulseTimer.Stop();
        pulseTimer.Dispose();
        monitor.Dispose();
        tray.Visible = false;
        tray.Dispose();
        currentIcon?.Dispose();
        dashboard.Dispose();
        singleInstance.ShowRequested -= ShowFromBackgroundThread;
        cancellation.Dispose();
        base.ExitThreadCore();
    }
}
