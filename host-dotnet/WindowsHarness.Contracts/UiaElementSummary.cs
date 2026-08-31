namespace WindowsHarness.Contracts;

/// <summary>One ancestry entry of a UI Automation element path.</summary>
public sealed record UiaElementPathEntry
{
    public string? Name { get; init; }
    public string? ControlType { get; init; }
    public string? AutomationId { get; init; }
}

/// <summary>Bounded summary of a UI Automation element. Never expose the raw unbounded UIA tree.</summary>
public sealed record UiaElementSummary
{
    public string? Name { get; init; }
    public string? ControlType { get; init; }
    public string? AutomationId { get; init; }
    public string? ClassName { get; init; }
    public Rect? Bounds { get; init; }
    public bool? IsEnabled { get; init; }
    public bool? IsKeyboardFocusable { get; init; }

    /// <summary>Current value for value-pattern elements; truncate long values at the caller.</summary>
    public string? Value { get; init; }

    /// <summary>Bounded ancestry from the element towards the root, nearest ancestor first.</summary>
    public IReadOnlyList<UiaElementPathEntry>? ParentPath { get; init; }
}
