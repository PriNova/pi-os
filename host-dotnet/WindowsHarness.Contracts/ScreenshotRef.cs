using System.Text.Json.Serialization;

namespace WindowsHarness.Contracts;

/// <summary>What region a screenshot covers.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<ScreenshotKind>))]
public enum ScreenshotKind
{
    Window,
    Monitor,
    Region,
}

/// <summary>Reference to one captured image. The image bytes live outside this schema.</summary>
public sealed record ScreenshotRef
{
    public required ScreenshotKind Kind { get; init; }

    /// <summary>Path to the captured file, when written to disk.</summary>
    public string? FilePath { get; init; }

    /// <summary>Stable id for lookup in the host's short-lived capture store.</summary>
    public string? ImageId { get; init; }

    public Rect? Bounds { get; init; }

    /// <summary>Optional actual delivered image dimensions (macOS capture transform).</summary>
    public int? ImageWidth { get; init; }
    public int? ImageHeight { get; init; }
}
