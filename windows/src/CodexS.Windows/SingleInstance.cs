using System.Security.Cryptography;
using System.Text;

namespace CodexS.Windows;

internal sealed class SingleInstance : IDisposable
{
    private readonly Mutex mutex;
    private readonly EventWaitHandle showEvent;
    private readonly RegisteredWaitHandle? registeredWait;

    internal bool IsPrimary { get; }
    internal event Action? ShowRequested;

    internal SingleInstance()
    {
        var user = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Environment.UserName)))[..12];
        mutex = new Mutex(true, $"Local\\CodexS-{user}", out var createdNew);
        showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, $"Local\\CodexS-Show-{user}");
        IsPrimary = createdNew;
        if (IsPrimary)
        {
            registeredWait = ThreadPool.RegisterWaitForSingleObject(
                showEvent, (_, _) => ShowRequested?.Invoke(), null, Timeout.Infinite, false);
        }
    }

    internal void SignalPrimary() => showEvent.Set();

    public void Dispose()
    {
        registeredWait?.Unregister(null);
        showEvent.Dispose();
        if (IsPrimary) mutex.ReleaseMutex();
        mutex.Dispose();
    }
}
