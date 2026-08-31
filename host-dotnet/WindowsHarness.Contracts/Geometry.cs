namespace WindowsHarness.Contracts;

/// <summary>2D point in physical screen pixels.</summary>
public sealed record Point2D
{
    public required double X { get; init; }
    public required double Y { get; init; }
}

/// <summary>
/// Rectangle in physical screen pixels. X/Y may be negative on multi-monitor setups.
/// Doubles keep UIA bounding rectangles lossless; window rects are whole numbers.
/// </summary>
public sealed record Rect
{
    public required double X { get; init; }
    public required double Y { get; init; }
    public required double Width { get; init; }
    public required double Height { get; init; }
}
