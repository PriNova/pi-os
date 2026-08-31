namespace WindowsHarness.Contracts;

/// <summary>
/// Pinned desktop context captured BEFORE the prompt overlay appears.
/// See docs/windows-agent-harness-handoff.md, section 5.
/// </summary>
public sealed record DesktopContextSnapshot
{
    public required string Id { get; init; }

    public required DateTimeOffset CapturedAt { get; init; }

    public required Point2D Cursor { get; init; }

    public WindowContext? ForegroundWindow { get; init; }
    public WindowContext? WindowUnderCursor { get; init; }

    /// <summary>The window the agent should act on. Policy default: the foreground window.</summary>
    public WindowContext? TargetWindow { get; init; }

    /// <summary>Element with keyboard focus. Focus does not imply selection.</summary>
    public UiaElementSummary? FocusedElement { get; init; }

    public UiaElementSummary? ElementUnderCursor { get; init; }

    /// <summary>
    /// Actual selected Windows desktop items. Empty means selection was checked
    /// and none were selected; null means this was not a desktop capture or UIA failed.
    /// </summary>
    public IReadOnlyList<UiaElementSummary>? SelectedDesktopItems { get; init; }
    public int? SelectedDesktopItemCount { get; init; }
    public bool? SelectedDesktopItemsTruncated { get; init; }

    public ScreenshotRef? Screenshot { get; init; }

    public IReadOnlyList<MonitorSummary> Monitors { get; init; } = [];

    public EnvironmentInfo? Environment { get; init; }
}
