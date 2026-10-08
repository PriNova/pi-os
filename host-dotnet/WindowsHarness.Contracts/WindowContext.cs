namespace WindowsHarness.Contracts;

/// <summary>Identity and state of a top-level window. HWND values can become invalid at any time.</summary>
public sealed record WindowContext
{
    /// <summary>Win32 HWND as hex string, for example "0x000A1234". Validate before use.</summary>
    public required string Hwnd { get; init; }

    public required int ProcessId { get; init; }
    public required string ProcessName { get; init; }
    public string? ExecutablePath { get; init; }

    /// <summary>Raw process command line; exposes the open-file path for arg-launched apps (Notepad, editors, terminals).</summary>
    public string? CommandLine { get; init; }

    public required string Title { get; init; }
    public string? ClassName { get; init; }
    /// <summary>Optional native surface tag, e.g. finderDesktop on macOS.</summary>
    public string? Surface { get; init; }
    public Rect? DesktopWorkArea { get; init; }

    /// <summary>Active folder path when the window hosts a Windows shell view (File Explorer); null otherwise.</summary>
    public string? ShellFolderPath { get; init; }
    public string? DocumentPath { get; init; }

    public required Rect Bounds { get; init; }
    public string? MonitorId { get; init; }
    public double? Dpi { get; init; }

    /// <summary>True when the target runs elevated; UIPI may block automation from a non-elevated host.</summary>
    public bool? IsElevated { get; init; }
}
