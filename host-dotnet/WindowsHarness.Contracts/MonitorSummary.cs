namespace WindowsHarness.Contracts;

/// <summary>Summary of one display monitor. Supports negative coordinates and per-monitor DPI.</summary>
public sealed record MonitorSummary
{
    public required string Id { get; init; }
    public string? DeviceName { get; init; }
    public required bool IsPrimary { get; init; }

    /// <summary>Full monitor bounds, may start at negative coordinates on multi-monitor setups.</summary>
    public required Rect Bounds { get; init; }

    /// <summary>Usable work area excluding the taskbar.</summary>
    public required Rect WorkArea { get; init; }

    public double? Dpi { get; init; }
}
