using System.Drawing.Drawing2D;

namespace CodexS.Windows;

internal sealed class DashboardForm : Form
{
    private static readonly Color Background = Color.FromArgb(20, 24, 33);
    private static readonly Color Card = Color.FromArgb(31, 37, 49);
    private static readonly Color Muted = Color.FromArgb(158, 169, 185);
    private readonly QuotaGauge fiveGauge = new("5h", Color.FromArgb(67, 156, 255));
    private readonly QuotaGauge sevenGauge = new("7d", Color.FromArgb(177, 116, 255));
    private readonly Label todayValue = ValueLabel();
    private readonly Label weekValue = ValueLabel();
    private readonly Label lifetimeValue = ValueLabel();
    private readonly Label taskState = new() { AutoSize = true, ForeColor = Color.White, Font = new Font("Segoe UI", 11, FontStyle.Bold) };
    private readonly Label taskCounts = new() { AutoSize = true, ForeColor = Muted, Font = new Font("Segoe UI", 9) };
    private readonly FlowLayoutPanel resultList = new() { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true };
    private readonly Label footerStatus = new() { AutoSize = true, ForeColor = Muted, Font = new Font("Segoe UI", 8.5f), Anchor = AnchorStyles.Left };
    private readonly TextBox remoteHosts = new() { Width = 220, BorderStyle = BorderStyle.FixedSingle, BackColor = Color.FromArgb(25, 30, 40), ForeColor = Color.White };
    private UsageSnapshot snapshot = UsageSnapshot.Starting;

    internal event Action? MarkAllReadRequested;
    internal event Action? RefreshRequested;
    internal event Action<string>? ResultOpened;
    internal event Action<string>? RemoteHostsSaved;

    internal DashboardForm()
    {
        Text = "CodexS · Codex Secretary";
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(430, 610);
        MinimumSize = MaximumSize = new Size(446, 649);
        BackColor = Background;
        ForeColor = Color.White;
        Font = new Font("Segoe UI", 9);
        ShowInTaskbar = false;
        BuildLayout();
    }

    internal void UpdateSnapshot(UsageSnapshot value)
    {
        snapshot = value;
        fiveGauge.SetValue(value.FiveHour);
        sevenGauge.SetValue(value.SevenDay);
        todayValue.Text = FormatTokens(value.TodayTokens);
        weekValue.Text = FormatTokens(value.SevenDayTokens);
        lifetimeValue.Text = FormatTokens(value.LifetimeTokens);
        taskState.Text = !value.TaskMonitorReady ? "— 任务监控不可用"
            : value.Running.Count > 0 ? "● Codex 正在执行" : "✓ Codex 当前空闲";
        taskState.ForeColor = !value.TaskMonitorReady ? Muted
            : value.Running.Count > 0 ? Color.FromArgb(244, 74, 90) : Color.FromArgb(55, 196, 123);
        if (!value.TaskMonitorReady && !string.IsNullOrWhiteSpace(value.TaskMonitorMessage))
            taskState.Text = $"— {value.TaskMonitorMessage}";
        taskCounts.Text = $"{value.Running.Count} 个执行中  ·  {value.UnreadCount} 条未读  ·  今日进度 {value.TodayCompletedCount}/{value.TodayTaskCount}  ·  {value.RemoteHosts.Count} 台远程配置";
        if (!remoteHosts.Focused) remoteHosts.Text = string.Join(", ", value.RemoteHosts);
        footerStatus.Text = value.QuotaStale
            ? $"额度等待刷新 · {value.StatusMessage ?? "保留上次可信值"}"
            : $"额度已刷新 · {DateTime.Now:HH:mm:ss}";
        RebuildResults();
    }

    internal void ShowPanel()
    {
        if (!Visible) Show();
        WindowState = FormWindowState.Normal;
        Activate();
        BringToFront();
    }

    private void BuildLayout()
    {
        var root = new TableLayoutPanel {
            Dock = DockStyle.Fill, Padding = new Padding(14), BackColor = Background,
            RowCount = 6, ColumnCount = 1
        };
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 46));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 166));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 86));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 50));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 46));

        var title = new Label {
            Text = "CodexS", AutoSize = true, ForeColor = Color.White,
            Font = new Font("Segoe UI", 17, FontStyle.Bold), Margin = new Padding(2, 3, 0, 0)
        };
        root.Controls.Add(title, 0, 0);

        var quotas = CardPanel();
        quotas.Padding = new Padding(10);
        var quotaFlow = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false, BackColor = Card };
        fiveGauge.Size = sevenGauge.Size = new Size(182, 140);
        quotaFlow.Controls.Add(fiveGauge);
        quotaFlow.Controls.Add(sevenGauge);
        quotas.Controls.Add(quotaFlow);
        root.Controls.Add(quotas, 0, 1);

        var tokens = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, BackColor = Background, Padding = new Padding(0, 8, 0, 8) };
        for (var index = 0; index < 3; index++) tokens.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 33.333f));
        tokens.Controls.Add(TokenCard("今日 token", todayValue), 0, 0);
        tokens.Controls.Add(TokenCard("近 7 天", weekValue), 1, 0);
        tokens.Controls.Add(TokenCard("本机累计", lifetimeValue), 2, 0);
        root.Controls.Add(tokens, 0, 2);

        var tasks = CardPanel();
        tasks.Padding = new Padding(12, 10, 12, 10);
        var taskLayout = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, BackColor = Card };
        taskLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        taskLayout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var taskHeader = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, BackColor = Card };
        taskHeader.Controls.Add(taskState);
        taskHeader.Controls.Add(taskCounts);
        taskLayout.Controls.Add(taskHeader, 0, 0);
        resultList.BackColor = Card;
        taskLayout.Controls.Add(resultList, 0, 1);
        tasks.Controls.Add(taskLayout);
        root.Controls.Add(tasks, 0, 3);

        var remote = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, BackColor = Background, Padding = new Padding(2, 10, 0, 5) };
        remote.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        remote.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        remote.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        remote.Controls.Add(new Label { Text = "SSH 远程", AutoSize = true, ForeColor = Muted, Padding = new Padding(0, 5, 8, 0) }, 0, 0);
        remoteHosts.Dock = DockStyle.Fill;
        remoteHosts.PlaceholderText = "~/.ssh/config 别名，如 codex";
        remote.Controls.Add(remoteHosts, 1, 0);
        remote.Controls.Add(ActionButton("保存", () => RemoteHostsSaved?.Invoke(remoteHosts.Text)), 2, 0);
        root.Controls.Add(remote, 0, 4);

        var footer = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 4, BackColor = Background, Padding = new Padding(0, 8, 0, 0) };
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        footer.Controls.Add(footerStatus, 0, 0);
        footer.Controls.Add(ActionButton("全部已读", () => MarkAllReadRequested?.Invoke()), 1, 0);
        footer.Controls.Add(ActionButton("刷新", () => RefreshRequested?.Invoke()), 2, 0);
        footer.Controls.Add(ActionButton("隐藏", Hide), 3, 0);
        root.Controls.Add(footer, 0, 5);
        Controls.Add(root);
    }

    private void RebuildResults()
    {
        resultList.SuspendLayout();
        resultList.Controls.Clear();
        foreach (var item in snapshot.Results.Take(3))
        {
            var row = new Button {
                Width = 370, Height = 34, FlatStyle = FlatStyle.Flat,
                TextAlign = ContentAlignment.MiddleLeft,
                Text = $"{(item.Interrupted ? "!" : "✓")}  {(item.Source is null ? "" : $"@{item.Source}  ")}{item.Project}  ·  {item.CompletedAt.LocalDateTime:HH:mm}",
                BackColor = item.ReadAt is null ? Color.FromArgb(47, 55, 70) : Color.FromArgb(38, 44, 57),
                ForeColor = item.ReadAt is null ? Color.White : Muted,
                Font = new Font("Segoe UI", 9, item.ReadAt is null ? FontStyle.Bold : FontStyle.Regular),
                Margin = new Padding(0, 0, 0, 5), Cursor = Cursors.Hand
            };
            row.FlatAppearance.BorderSize = 0;
            row.Click += (_, _) => ResultOpened?.Invoke(item.Id);
            resultList.Controls.Add(row);
        }
        if (snapshot.Results.Count == 0)
            resultList.Controls.Add(new Label { Text = "完成的任务会显示在这里", AutoSize = true, ForeColor = Muted, Padding = new Padding(2, 8, 0, 0) });
        resultList.ResumeLayout();
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            Hide();
            return;
        }
        base.OnFormClosing(e);
    }

    private static Panel CardPanel() => new() { Dock = DockStyle.Fill, BackColor = Card, Margin = new Padding(0) };
    private static Label ValueLabel() => new() { AutoSize = true, ForeColor = Color.White, Font = new Font("Segoe UI", 14, FontStyle.Bold) };
    private static Control TokenCard(string title, Label value)
    {
        var panel = CardPanel();
        panel.Margin = new Padding(0, 0, 7, 0);
        var flow = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, BackColor = Card, Padding = new Padding(10, 8, 0, 0) };
        flow.Controls.Add(new Label { Text = title, AutoSize = true, ForeColor = Muted, Font = new Font("Segoe UI", 8.5f) });
        flow.Controls.Add(value);
        panel.Controls.Add(flow);
        return panel;
    }
    private static Button ActionButton(string title, Action action)
    {
        var button = new Button { Text = title, AutoSize = true, Height = 28, FlatStyle = FlatStyle.Flat, BackColor = Card, ForeColor = Color.White, Margin = new Padding(6, 0, 0, 0) };
        button.FlatAppearance.BorderColor = Color.FromArgb(67, 76, 94);
        button.Click += (_, _) => action();
        return button;
    }
    private static string FormatTokens(long value) => value switch {
        >= 1_000_000_000 => $"{value / 1_000_000_000d:0.0}B",
        >= 1_000_000 => $"{value / 1_000_000d:0.0}M",
        >= 1_000 => $"{value / 1_000d:0.0}K",
        _ => value.ToString()
    };

    private sealed class QuotaGauge(string title, Color color) : Control
    {
        private QuotaWindow? value;
        internal void SetValue(QuotaWindow? newValue) { value = newValue; Invalidate(); }
        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.Clear(Card);
            var rect = new Rectangle(42, 13, 96, 96);
            using var track = new Pen(Color.FromArgb(64, 73, 90), 10) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            using var fill = new Pen(color, 10) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            e.Graphics.DrawArc(track, rect, -90, 360);
            if (value is not null) e.Graphics.DrawArc(fill, rect, -90, (float)(360 * value.RemainingPercent / 100));
            using var valueFont = new Font("Segoe UI", 18, FontStyle.Bold);
            using var labelFont = new Font("Segoe UI", 9, FontStyle.Bold);
            using var resetFont = new Font("Segoe UI", 8);
            DrawCentered(e.Graphics, value is null ? "--" : $"{value.RemainingPercent:0}%", valueFont, Color.White, new Rectangle(42, 43, 96, 32));
            DrawCentered(e.Graphics, $"{title} 剩余", labelFont, color, new Rectangle(0, 112, Width, 20));
            var reset = value?.ResetsAt is null ? "重置时间 --" : $"{value.ResetsAt.Value.LocalDateTime:MM-dd HH:mm} 重置";
            DrawCentered(e.Graphics, reset, resetFont, Muted, new Rectangle(0, 130, Width, 18));
        }
        private static void DrawCentered(Graphics graphics, string text, Font font, Color color, Rectangle rect)
        {
            TextRenderer.DrawText(graphics, text, font, rect, color,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        }
    }
}
