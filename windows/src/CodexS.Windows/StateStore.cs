using System.Text.Json;

namespace CodexS.Windows;

internal sealed class StateStore
{
    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    internal PersistedState Load()
    {
        try
        {
            if (!File.Exists(AppPaths.StateFile)) return new PersistedState();
            var state = JsonSerializer.Deserialize<PersistedState>(File.ReadAllText(AppPaths.StateFile), Options);
            return state?.SchemaVersion == 1 ? state : new PersistedState();
        }
        catch
        {
            return new PersistedState();
        }
    }

    internal void Save(PersistedState state)
    {
        Directory.CreateDirectory(AppPaths.DataDirectory);
        var temporary = AppPaths.StateFile + ".new";
        File.WriteAllText(temporary, JsonSerializer.Serialize(state, Options));
        File.Move(temporary, AppPaths.StateFile, true);
    }
}
