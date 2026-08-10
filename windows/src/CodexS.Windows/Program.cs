namespace CodexS.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        if (args.Contains("--self-test-all", StringComparer.OrdinalIgnoreCase))
            return SelfTestRunner.Run();
        if (args.Contains("--install", StringComparer.OrdinalIgnoreCase))
            return Installer.Install(startAfterInstall: false) ? 0 : 1;
        if (args.Contains("--uninstall", StringComparer.OrdinalIgnoreCase))
            return Installer.BeginUninstall() ? 0 : 1;
        if (args.Contains("--complete-uninstall", StringComparer.OrdinalIgnoreCase))
            return Installer.CompleteUninstall() ? 0 : 1;

        if (!AppPaths.IsInstalledExecutable)
        {
            var choice = MessageBox.Show(
                "是否将 CodexS 安装到当前用户并启动？\n\n应用读取本机 Codex 用量与任务元数据；启用 SSH 远程监听后只读取任务事件，不读取登录凭据或对话正文。\n选择“否”可仅运行一次。",
                "安装 CodexS", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Information);
            if (choice == DialogResult.Cancel) return 0;
            if (choice == DialogResult.Yes)
                return Installer.Install(startAfterInstall: true) ? 0 : 1;
        }

        using var singleInstance = new SingleInstance();
        if (!singleInstance.IsPrimary)
        {
            singleInstance.SignalPrimary();
            return 0;
        }

        using var context = new TrayApplicationContext(singleInstance);
        Application.Run(context);
        return 0;
    }
}
