using WindowsHarness.Contracts;

namespace WindowsHarness.Host.Context;

/// <summary>
/// Recognizes the standard Explorer-hosted Windows desktop without confusing
/// File Explorer folders, the taskbar, or another explorer.exe surface with it.
/// </summary>
internal static class DesktopBackgroundPolicy
{
    private static readonly HashSet<string> DesktopRootClasses =
        new(StringComparer.Ordinal) { "Progman", "WorkerW" };

    private static readonly HashSet<string> DesktopPointClasses =
        new(StringComparer.Ordinal) { "Progman", "WorkerW", "SHELLDLL_DefView", "SysListView32" };

    public static bool IsActive(WindowContext? foreground, WindowContext? underCursor) =>
        IsExplorer(foreground)
        && DesktopRootClasses.Contains(foreground!.ClassName ?? "")
        && IsExplorer(underCursor)
        && DesktopPointClasses.Contains(underCursor!.ClassName ?? "");

    private static bool IsExplorer(WindowContext? window) =>
        window is not null
        && string.Equals(window.ProcessName, "explorer", StringComparison.OrdinalIgnoreCase);
}
