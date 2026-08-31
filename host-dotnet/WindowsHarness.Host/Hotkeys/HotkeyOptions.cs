namespace WindowsHarness.Host.Hotkeys;

/// <summary>
/// Global hotkey configuration. Default: Ctrl+Alt+Space.
/// Override via environment variable PI_OS_HOTKEY, for example
/// "Ctrl+Alt+Space", "Ctrl+Shift+F9", "Win+A".
/// </summary>
public sealed record HotkeyOptions
{
    public const string EnvironmentVariable = "PI_OS_HOTKEY";

    public IReadOnlyList<string> Modifiers { get; init; } = ["Ctrl", "Alt"];
    public ushort VirtualKey { get; init; } = 0x20; // VK_SPACE

    public static HotkeyOptions FromEnvironment()
    {
        var raw = Environment.GetEnvironmentVariable(EnvironmentVariable);
        if (string.IsNullOrWhiteSpace(raw))
        {
            return new HotkeyOptions();
        }

        return Parse(raw);
    }

    public static HotkeyOptions Parse(string raw)
    {
        var parts = raw.Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2)
        {
            throw new FormatException($"Hotkey '{raw}' needs at least one modifier and one key, e.g. Ctrl+Alt+Space.");
        }

        var modifiers = new List<string>();
        for (var i = 0; i < parts.Length - 1; i++)
        {
            var mod = NormalizeModifier(parts[i])
                ?? throw new FormatException($"Unknown hotkey modifier '{parts[i]}' in '{raw}'.");
            modifiers.Add(mod);
        }

        var keyName = parts[^1];
        var vk = LookupVirtualKey(keyName)
            ?? throw new FormatException($"Unknown hotkey key '{keyName}' in '{raw}'.");

        return new HotkeyOptions { Modifiers = modifiers, VirtualKey = vk };
    }

    private static string? NormalizeModifier(string token) => token.ToLowerInvariant() switch
    {
        "ctrl" or "control" => "Ctrl",
        "alt" or "menu" => "Alt",
        "shift" => "Shift",
        "win" or "windows" or "meta" => "Win",
        _ => null,
    };

    private static ushort? LookupVirtualKey(string token)
    {
        var t = token.ToUpperInvariant();

        if (t.Length == 1 && t[0] is >= 'A' and <= 'Z')
        {
            return (ushort)t[0]; // VK codes 0x41-0x5A match 'A'-'Z'
        }

        if (t.Length == 1 && t[0] is >= '0' and <= '9')
        {
            return (ushort)t[0]; // VK codes 0x30-0x39 match '0'-'9'
        }

        if (t.Length is 2 or 3 && t[0] == 'F' && ushort.TryParse(t[1..], out var f) && f is >= 1 and <= 24)
        {
            return (ushort)(0x70 + f - 1); // VK_F1 = 0x70
        }

        return t switch
        {
            "SPACE" or "SPACEBAR" => (ushort)0x20,
            "ESC" or "ESCAPE" => (ushort)0x1B,
            "TAB" => (ushort)0x09,
            "ENTER" or "RETURN" => (ushort)0x0D,
            "BACKSPACE" or "BACK" => (ushort)0x08,
            "DELETE" or "DEL" => (ushort)0x2E,
            "INSERT" or "INS" => (ushort)0x2D,
            "HOME" => (ushort)0x24,
            "END" => (ushort)0x23,
            "PAGEUP" or "PGUP" => (ushort)0x21,
            "PAGEDOWN" or "PGDN" => (ushort)0x22,
            "LEFT" => (ushort)0x25,
            "UP" => (ushort)0x26,
            "RIGHT" => (ushort)0x27,
            "DOWN" => (ushort)0x28,
            _ => null,
        };
    }
}
