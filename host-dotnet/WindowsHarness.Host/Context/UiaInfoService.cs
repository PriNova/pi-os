using System.IO;
using FlaUI.Core.AutomationElements;
using FlaUI.UIA3;
using WindowsHarness.Contracts;
using WindowsHarness.Host.Diagnostics;

namespace WindowsHarness.Host.Context;

internal sealed record DesktopSelectionCapture(
    IReadOnlyList<UiaElementSummary> Items, int TotalCount);

/// <summary>
/// Layer 2 context: UI Automation summaries of the focused element and the
/// element under the cursor (handoff section 6). Returns bounded summaries,
/// never a raw UIA tree. Any failure degrades to null, not an error.
/// </summary>
public sealed class UiaInfoService
{
    private const int MaxAncestors = 8;
    private const int MaxSelectedItems = 32;
    private const int MaxValueLength = 256;

    public UiaElementSummary? CaptureFocused() => TryWithAutomation(automation =>
        Summarize(automation.FocusedElement(), automation));

    public UiaElementSummary? CaptureElementUnderCursor(Point2D cursor) => TryWithAutomation(automation =>
        Summarize(automation.FromPoint(new System.Drawing.Point((int)cursor.X, (int)cursor.Y)), automation));

    /// <summary>
    /// Reads the desktop list's actual UIA Selection pattern. The selected
    /// array is bounded; no child-tree enumeration is performed. An empty
    /// Items list is meaningful (selection checked, no selected icons), while
    /// null means the desktop provider did not expose a usable pattern.
    /// </summary>
    internal DesktopSelectionCapture? CaptureDesktopSelection(Point2D cursor) =>
        TryWithAutomation<DesktopSelectionCapture>(automation =>
        {
            var current = automation.FromPoint(new System.Drawing.Point((int)cursor.X, (int)cursor.Y));
            var walker = automation.TreeWalkerFactory.GetControlViewWalker();

            for (var depth = 0; current is not null && depth <= MaxAncestors; depth++)
            {
                var selection = current.Patterns.Selection;
                if (selection.IsSupported)
                {
                    var selected = TryGet(() => selection.Pattern.Selection.Value);
                    if (selected is null)
                    {
                        return null;
                    }

                    var items = selected.Take(MaxSelectedItems)
                        .Select(element => Summarize(element, automation))
                        .OfType<UiaElementSummary>()
                        .ToArray();
                    return new DesktopSelectionCapture(items, selected.Length);
                }

                current = walker.GetParent(current);
            }

            return null;
        });

    private static T? TryWithAutomation<T>(Func<UIA3Automation, T?> action) where T : class
    {
        try
        {
            using var automation = new UIA3Automation();
            return action(automation);
        }
        catch (Exception ex)
        {
            Log.Warn($"UIA capture failed: {ex.Message}");
            return null;
        }
    }

    private static UiaElementSummary? Summarize(AutomationElement element, UIA3Automation automation)
    {
        if (element is null)
        {
            return null;
        }

        var walker = automation.TreeWalkerFactory.GetControlViewWalker();

        // Nearest ancestor first.
        var parentPath = new List<UiaElementPathEntry>();
        try
        {
            var current = element;
            for (var depth = 0; depth < MaxAncestors; depth++)
            {
                var parent = walker.GetParent(current);
                if (parent is null || parent.FrameworkAutomationElement is null)
                {
                    break;
                }

                parentPath.Add(new UiaElementPathEntry
                {
                    Name = TryGet(() => parent.Properties.Name.Value)?.Truncate(MaxValueLength),
                    ControlType = TryGet(() => parent.Properties.ControlType.Value.ToString()),
                    AutomationId = TryGet(() => parent.Properties.AutomationId.Value),
                });
                current = parent;
            }
        }
        catch
        {
            // Partial ancestry is fine.
        }

        Rect? bounds = null;
        var rect = TryGet(() => element.Properties.BoundingRectangle.Value);
        if (!rect.IsEmpty)
        {
            bounds = new Rect
            {
                X = rect.X,
                Y = rect.Y,
                Width = rect.Width,
                Height = rect.Height,
            };
        }

        string? value = TryGet(() =>
        {
            var pattern = element.Patterns.Value;
            return pattern.IsSupported ? pattern.Pattern.Value.Value?.Truncate(MaxValueLength) : null;
        });

        return new UiaElementSummary
        {
            Name = TryGet(() => element.Properties.Name.Value)?.Truncate(MaxValueLength),
            ControlType = TryGet(() => element.Properties.ControlType.Value.ToString()),
            AutomationId = TryGet(() => element.Properties.AutomationId.Value),
            ClassName = TryGet(() => element.Properties.ClassName.Value),
            Bounds = bounds,
            IsEnabled = TryGet(() => element.Properties.IsEnabled.Value),
            IsKeyboardFocusable = TryGet(() => element.Properties.IsKeyboardFocusable.Value),
            Value = value,
            ParentPath = parentPath.Count > 0 ? parentPath : null,
        };
    }

    private static T? TryGet<T>(Func<T?> getter)
    {
        try
        {
            return getter();
        }
        catch
        {
            return default;
        }
    }
}

file static class StringExtensions
{
    public static string? Truncate(this string? text, int max) =>
        text is null || text.Length <= max ? text : text[..max];
}
