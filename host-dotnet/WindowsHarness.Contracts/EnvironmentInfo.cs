namespace WindowsHarness.Contracts;

/// <summary>Optional session environment details captured with the snapshot.</summary>
public sealed record EnvironmentInfo
{
    public string? KeyboardLayout { get; init; }
    public string? DesktopName { get; init; }
    public int? SessionId { get; init; }
}
