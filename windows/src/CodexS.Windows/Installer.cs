using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32;

namespace CodexS.Windows;

internal static class Installer
{
    private const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\CodexS";
    private const int MoveFileDelayUntilReboot = 0x4;

    internal static bool Install(bool startAfterInstall)
    {
        try
        {
            var source = Environment.ProcessPath ?? throw new InvalidOperationException("无法确定安装文件路径");
            Directory.CreateDirectory(AppPaths.InstallDirectory);
            var staged = AppPaths.InstalledExecutable + ".new";
            File.Copy(source, staged, true);
            if (!CryptographicOperations.FixedTimeEquals(
                    SHA256.HashData(File.ReadAllBytes(source)),
                    SHA256.HashData(File.ReadAllBytes(staged))))
                throw new IOException("安装文件校验失败");

            File.Move(staged, AppPaths.InstalledExecutable, true);
            CreateShortcut(AppPaths.StartMenuShortcut, AppPaths.InstalledExecutable);
            using (var key = Registry.CurrentUser.CreateSubKey(UninstallKey))
            {
                key.SetValue("DisplayName", "CodexS");
                key.SetValue("DisplayVersion", "0.4.1");
                key.SetValue("Publisher", "Ustinian-J");
                key.SetValue("InstallLocation", AppPaths.InstallDirectory);
                key.SetValue("DisplayIcon", AppPaths.InstalledExecutable);
                key.SetValue("UninstallString", $"\"{AppPaths.InstalledExecutable}\" --uninstall");
                key.SetValue("NoModify", 1, RegistryValueKind.DWord);
                key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            }

            if (startAfterInstall)
                Process.Start(new ProcessStartInfo(AppPaths.InstalledExecutable) { UseShellExecute = true });
            return true;
        }
        catch (Exception error)
        {
            MessageBox.Show($"安装失败：{error.Message}", "CodexS", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return false;
        }
    }

    internal static bool BeginUninstall()
    {
        try
        {
            if (MessageBox.Show("卸载 CodexS？本地统计与已读状态将保留。", "卸载 CodexS",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes)
                return true;

            var temporary = Path.Combine(Path.GetTempPath(), $"CodexS-uninstall-{Guid.NewGuid():N}.exe");
            File.Copy(Environment.ProcessPath!, temporary, true);
            Process.Start(new ProcessStartInfo(temporary, "--complete-uninstall") {
                UseShellExecute = false,
                CreateNoWindow = true
            });
            return true;
        }
        catch (Exception error)
        {
            MessageBox.Show($"无法启动卸载：{error.Message}", "CodexS", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return false;
        }
    }

    internal static bool CompleteUninstall()
    {
        try
        {
            Thread.Sleep(1200);
            if (Directory.Exists(AppPaths.InstallDirectory))
                Directory.Delete(AppPaths.InstallDirectory, true);
            if (File.Exists(AppPaths.StartMenuShortcut))
                File.Delete(AppPaths.StartMenuShortcut);
            Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false);
            using (var run = Registry.CurrentUser.OpenSubKey(
                       @"Software\Microsoft\Windows\CurrentVersion\Run", writable: true))
                run?.DeleteValue("CodexS", false);
            MoveFileEx(Environment.ProcessPath!, null, MoveFileDelayUntilReboot);
            return true;
        }
        catch
        {
            return false;
        }
    }

    internal static void SetRunAtLogin(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if (enabled)
            key.SetValue("CodexS", $"\"{AppPaths.InstalledExecutable}\"");
        else
            key.DeleteValue("CodexS", false);
    }

    internal static bool IsRunAtLoginEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        return key?.GetValue("CodexS") is string;
    }

    private static void CreateShortcut(string path, string target)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var link = (IShellLinkW)(object)new ShellLink();
        link.SetPath(target);
        link.SetWorkingDirectory(Path.GetDirectoryName(target)!);
        link.SetDescription("CodexS - Codex Secretary");
        ((IPersistFile)link).Save(path, true);
        Marshal.FinalReleaseComObject(link);
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool MoveFileEx(string existingFile, string? newFile, int flags);

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    private sealed class ShellLink { }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
    private interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] string file, int maxPath, IntPtr data, int flags);
        void GetIDList(out IntPtr idList);
        void SetIDList(IntPtr idList);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] string name, int maxName);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] string directory, int maxPath);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string directory);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] string args, int maxPath);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
        void GetHotkey(out short hotkey);
        void SetHotkey(short hotkey);
        void GetShowCmd(out int showCommand);
        void SetShowCmd(int showCommand);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] string iconPath, int iconPathLength, out int iconIndex);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string iconPath, int iconIndex);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, int reserved);
        void Resolve(IntPtr window, int flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("0000010b-0000-0000-C000-000000000046")]
    private interface IPersistFile
    {
        void GetClassID(out Guid classId);
        [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string fileName, uint mode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string fileName, bool remember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string fileName);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string fileName);
    }
}
