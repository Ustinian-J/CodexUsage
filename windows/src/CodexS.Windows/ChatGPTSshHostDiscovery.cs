using System.Runtime.InteropServices;

namespace CodexS.Windows;

internal readonly record struct NativeProcessRecord(
    uint ProcessId,
    uint ParentProcessId,
    string ExecutableName,
    string? CommandLine);

internal static class ChatGPTSshHostDiscovery
{
    private const uint Th32csSnapProcess = 0x00000002;
    private const uint ProcessQueryLimitedInformation = 0x1000;
    private const int ProcessCommandLineInformation = 60;
    private const int MaximumCommandLineBytes = 1024 * 1024;
    private static readonly IntPtr InvalidHandleValue = new(-1);
    private static readonly HashSet<string> OptionsWithValues = new(StringComparer.Ordinal) {
        "-B", "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L", "-l",
        "-m", "-O", "-o", "-P", "-p", "-Q", "-R", "-S", "-W", "-w"
    };

    internal static bool TryDiscover(out IReadOnlyList<string> hosts)
    {
        hosts = [];
        if (!OperatingSystem.IsWindows()) return false;
        var snapshot = CreateToolhelp32Snapshot(Th32csSnapProcess, 0);
        if (snapshot == InvalidHandleValue) return false;
        try
        {
            var records = new List<NativeProcessRecord>();
            var entry = new ProcessEntry32 { Size = (uint)Marshal.SizeOf<ProcessEntry32>() };
            if (!Process32First(snapshot, ref entry))
            {
                return Marshal.GetLastWin32Error() == 18;
            }
            do
            {
                var executable = entry.ExecutableFile ?? string.Empty;
                records.Add(new NativeProcessRecord(
                    entry.ProcessId, entry.ParentProcessId, executable, null));
                entry.Size = (uint)Marshal.SizeOf<ProcessEntry32>();
            } while (Process32Next(snapshot, ref entry));
            var ownedSshIds = OwnedSshProcessIds(records);
            var scopedRecords = records.Select(record => ownedSshIds.Contains(record.ProcessId)
                ? record with { CommandLine = ReadCommandLine(record.ProcessId) }
                : record);
            hosts = Hosts(scopedRecords);
            return true;
        }
        finally { CloseHandle(snapshot); }
    }

    internal static IReadOnlyList<string> Hosts(IEnumerable<NativeProcessRecord> processRecords)
    {
        var records = processRecords.ToArray();
        var byId = records.ToDictionary(record => record.ProcessId);
        var chatGptIds = records
            .Where(record => record.ExecutableName.Equals("ChatGPT.exe", StringComparison.OrdinalIgnoreCase))
            .Select(record => record.ProcessId)
            .ToHashSet();
        if (chatGptIds.Count == 0) return [];

        var hosts = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var record in records)
        {
            if (!record.ExecutableName.Equals("ssh.exe", StringComparison.OrdinalIgnoreCase)
                || record.CommandLine is null
                || !HasAncestor(record.ParentProcessId, chatGptIds, byId)) continue;
            var host = SshHost(record.CommandLine);
            if (host is not null) hosts.Add(host);
        }
        return hosts.Order(StringComparer.OrdinalIgnoreCase).ToArray();
    }

    private static HashSet<uint> OwnedSshProcessIds(IReadOnlyList<NativeProcessRecord> records)
    {
        var byId = records.ToDictionary(record => record.ProcessId);
        var chatGptIds = records
            .Where(record => record.ExecutableName.Equals("ChatGPT.exe", StringComparison.OrdinalIgnoreCase))
            .Select(record => record.ProcessId)
            .ToHashSet();
        return records
            .Where(record => record.ExecutableName.Equals("ssh.exe", StringComparison.OrdinalIgnoreCase)
                && HasAncestor(record.ParentProcessId, chatGptIds, byId))
            .Select(record => record.ProcessId)
            .ToHashSet();
    }

    internal static string? SshHost(string commandLine)
    {
        var tokens = CommandLineArguments(commandLine);
        if (tokens.Count == 0
            || !Path.GetFileName(tokens[0]).Equals("ssh.exe", StringComparison.OrdinalIgnoreCase)) return null;
        for (var index = 1; index < tokens.Count; index++)
        {
            var token = tokens[index];
            if (token == "--")
                return ++index < tokens.Count ? RemoteHostName.Validate(tokens[index]) : null;
            if (!token.StartsWith('-') || token == "-") return RemoteHostName.Validate(token);
            if (OptionsWithValues.Contains(token)) index++;
        }
        return null;
    }

    private static bool HasAncestor(
        uint initialProcessId,
        HashSet<uint> roots,
        IReadOnlyDictionary<uint, NativeProcessRecord> records)
    {
        var processId = initialProcessId;
        var visited = new HashSet<uint>();
        while (processId != 0 && visited.Add(processId))
        {
            if (roots.Contains(processId)) return true;
            if (!records.TryGetValue(processId, out var record)) return false;
            processId = record.ParentProcessId;
        }
        return false;
    }

    private static IReadOnlyList<string> CommandLineArguments(string commandLine)
    {
        var pointer = CommandLineToArgvW(commandLine, out var count);
        if (pointer == IntPtr.Zero || count <= 0) return [];
        try
        {
            var arguments = new string[count];
            for (var index = 0; index < count; index++)
            {
                var value = Marshal.ReadIntPtr(pointer, index * IntPtr.Size);
                arguments[index] = Marshal.PtrToStringUni(value) ?? string.Empty;
            }
            return arguments;
        }
        finally { LocalFree(pointer); }
    }

    private static string? ReadCommandLine(uint processId)
    {
        var process = OpenProcess(ProcessQueryLimitedInformation, false, processId);
        if (process == IntPtr.Zero) return null;
        try
        {
            _ = NtQueryInformationProcess(
                process, ProcessCommandLineInformation, IntPtr.Zero, 0, out var requiredBytes);
            if (requiredBytes <= 0 || requiredBytes > MaximumCommandLineBytes) return null;
            var buffer = Marshal.AllocHGlobal(requiredBytes);
            try
            {
                var status = NtQueryInformationProcess(
                    process, ProcessCommandLineInformation, buffer, requiredBytes, out _);
                if (status != 0) return null;
                var commandLine = Marshal.PtrToStructure<UnicodeString>(buffer);
                if (commandLine.Buffer == IntPtr.Zero
                    || commandLine.Length == 0
                    || commandLine.Length > MaximumCommandLineBytes) return null;
                return Marshal.PtrToStringUni(commandLine.Buffer, commandLine.Length / 2);
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        finally { CloseHandle(process); }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry32
    {
        internal uint Size;
        internal uint Usage;
        internal uint ProcessId;
        internal IntPtr DefaultHeapId;
        internal uint ModuleId;
        internal uint Threads;
        internal uint ParentProcessId;
        internal int BasePriority;
        internal uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        internal string ExecutableFile;
    }

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct UnicodeString
    {
        internal readonly ushort Length;
        internal readonly ushort MaximumLength;
        internal readonly IntPtr Buffer;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);

    [DllImport("kernel32.dll", EntryPoint = "Process32FirstW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Process32First(IntPtr snapshot, ref ProcessEntry32 entry);

    [DllImport("kernel32.dll", EntryPoint = "Process32NextW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Process32Next(IntPtr snapshot, ref ProcessEntry32 entry);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, uint processId);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(
        IntPtr processHandle,
        int processInformationClass,
        IntPtr processInformation,
        int processInformationLength,
        out int returnLength);

    [DllImport("shell32.dll", SetLastError = true)]
    private static extern IntPtr CommandLineToArgvW(
        [MarshalAs(UnmanagedType.LPWStr)] string commandLine,
        out int argumentCount);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
}
