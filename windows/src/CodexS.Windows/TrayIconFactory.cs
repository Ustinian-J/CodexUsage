using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace CodexS.Windows;

internal static class TrayIconFactory
{
    internal static Icon Create(UsageSnapshot snapshot, bool attentionBright)
    {
        using var bitmap = new Bitmap(32, 32, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.Clear(Color.Transparent);

        DrawMeter(graphics, 2, 8, snapshot.FiveHour?.RemainingPercent, Color.FromArgb(67, 156, 255));
        DrawMeter(graphics, 2, 20, snapshot.SevenDay?.RemainingPercent, Color.FromArgb(177, 116, 255));

        var stateColor = !snapshot.TaskMonitorReady
            ? Color.FromArgb(135, 145, 160)
            : snapshot.Running.Count > 0 ? Color.FromArgb(244, 74, 90) : Color.FromArgb(55, 196, 123);
        using (var brush = new SolidBrush(stateColor)) graphics.FillEllipse(21, 11, 10, 10, brush);
        using (var pen = new Pen(Color.White, 1.6f) { StartCap = LineCap.Round, EndCap = LineCap.Round })
        {
            if (!snapshot.TaskMonitorReady)
                graphics.DrawLine(pen, 24, 16, 28, 16);
            else if (snapshot.Running.Count == 0)
                graphics.DrawLines(pen, [new PointF(23.5f, 16), new PointF(25.5f, 18), new PointF(29, 13.8f)]);
        }
        if (snapshot.TaskMonitorReady && snapshot.Running.Count > 0)
        {
            using var brush = new SolidBrush(Color.White);
            graphics.FillPolygon(brush, [new PointF(25, 14), new PointF(29, 16), new PointF(25, 18)]);
        }

        if (snapshot.UnreadCount > 0)
        {
            var alpha = attentionBright ? 255 : 105;
            using var brush = new SolidBrush(Color.FromArgb(alpha, 255, 190, 46));
            graphics.FillPolygon(brush, [new PointF(27, 2), new PointF(32, 7), new PointF(27, 12), new PointF(22, 7)]);
        }

        var handle = bitmap.GetHicon();
        try
        {
            using var temporary = Icon.FromHandle(handle);
            return (Icon)temporary.Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    private static void DrawMeter(Graphics graphics, int x, int y, double? percent, Color color)
    {
        using var track = new Pen(Color.FromArgb(120, 130, 145), 3) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        graphics.DrawLine(track, x, y, x + 16, y);
        if (percent is null) return;
        using var fill = new Pen(color, 3) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        graphics.DrawLine(fill, x, y, x + 16 * (float)Math.Clamp(percent.Value / 100, 0, 1), y);
    }

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr handle);
}
