namespace CodexS.Windows;

internal static class AppPaths
{
    internal static readonly string InstallDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Programs", "CodexS");
    internal static readonly string InstalledExecutable = Path.Combine(InstallDirectory, "CodexS.exe");
    internal static readonly string DataDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "CodexS", "data");
    internal static readonly string StateFile = Path.Combine(DataDirectory, "state-v1.json");
    internal static readonly string StartMenuShortcut = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.StartMenu),
        "Programs", "CodexS.lnk");
    internal static readonly string CodexHome = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");

    internal static bool IsInstalledExecutable => string.Equals(
        Path.GetFullPath(Environment.ProcessPath ?? string.Empty),
        Path.GetFullPath(InstalledExecutable),
        StringComparison.OrdinalIgnoreCase);
}
