using System.IO;
using System.Windows.Input;
using WindowsHarness.Contracts;
using WindowsHarness.Host.Capture;
using WindowsHarness.Host.Diagnostics;

namespace WindowsHarness.Host.Context;

/// <summary>
/// Composes the full pre-overlay context snapshot (handoff section 4.2).
/// Order matters: everything here runs BEFORE the prompt overlay exists,
/// so the popup can never become the captured target.
/// </summary>
public sealed class CapturePipeline
{
    private readonly WindowInfoService _windows;
    private readonly UiaInfoService _uia;
    private readonly ScreenshotService _screenshots;
    private readonly ContextStore _store;

    public CapturePipeline(WindowInfoService windows, UiaInfoService uia,
        ScreenshotService screenshots, ContextStore store)
    {
        _windows = windows;
        _uia = uia;
        _screenshots = screenshots;
        _store = store;
    }

    public async Task<DesktopContextSnapshot?> CaptureAsync()
    {
        try
        {
            var foreground = await Task.Run(() => _windows.CaptureForeground());
            if (foreground is null)
            {
                Log.Warn("Capture aborted: no foreground window");
                return null;
            }

            // Use one cursor sample for the under-pointer window, UIA element,
            // monitor selection, and stored snapshot. This prevents a quick
            // pointer movement from mixing two monitors in one invocation.
            var cursor = _windows.CaptureCursor();
            var underCursor = await Task.Run(() => _windows.CaptureWindowAt(cursor));

            // Target policy default: the foreground window (handoff section 24, test 3).
            // Both values are preserved so the policy can evolve.
            var target = foreground;
            var desktopBackground = DesktopBackgroundPolicy.IsActive(foreground, underCursor);
            var monitors = _windows.CaptureMonitors();
            var cursorMonitorId = WindowInfoService.MonitorIdAt(cursor, monitors);
            var targetMonitorId = desktopBackground
                ? cursorMonitorId
                : WindowInfoService.MonitorIdFor(target, monitors);

            var focusedElement = await Task.Run(() => _uia.CaptureFocused());
            var elementUnderCursor = underCursor is null
                ? null
                : await Task.Run(() => _uia.CaptureElementUnderCursor(cursor));
            var selectedDesktopItems = desktopBackground
                ? await Task.Run(() => _uia.CaptureDesktopSelection(cursor))
                : null;

            var screenshot = await Task.Run(() => _screenshots.CaptureWindow(target));

            var snapshot = new DesktopContextSnapshot
            {
                Id = _store.NewId(),
                CapturedAt = DateTimeOffset.Now,
                Cursor = cursor,
                ForegroundWindow = foreground with { MonitorId = targetMonitorId },
                WindowUnderCursor = underCursor is null
                    ? null
                    : underCursor with { MonitorId = cursorMonitorId },
                TargetWindow = target with { MonitorId = targetMonitorId },
                FocusedElement = focusedElement,
                ElementUnderCursor = elementUnderCursor,
                SelectedDesktopItems = selectedDesktopItems?.Items,
                SelectedDesktopItemCount = selectedDesktopItems?.TotalCount,
                SelectedDesktopItemsTruncated = selectedDesktopItems is not null
                    ? selectedDesktopItems.TotalCount > selectedDesktopItems.Items.Count
                    : null,
                Screenshot = screenshot,
                Monitors = monitors,
                Environment = new EnvironmentInfo
                {
                    KeyboardLayout = InputLanguageManager.Current.CurrentInputLanguage.Name,
                    SessionId = System.Diagnostics.Process.GetCurrentProcess().SessionId,
                },
            };

            _store.Put(snapshot);
            Log.Info($"Pinned {snapshot.Id}: target={target.ProcessName} hwnd={target.Hwnd} " +
                     $"title='{Truncate(target.Title)}' placement=" +
                     $"{(desktopBackground ? "cursor-monitor" : "target-window")} " +
                     $"monitors={monitors.Count} desktopSelection=" +
                     $"{(desktopBackground ? selectedDesktopItems?.TotalCount.ToString() ?? "unavailable" : "n/a")} " +
                     $"shot={(snapshot.Screenshot?.ImageId ?? "none")}");
            return snapshot;
        }
        catch (Exception ex)
        {
            Log.Error($"Capture failed: {ex.Message}");
            return null;
        }
    }

    private static string Truncate(string text) => text.Length <= 60 ? text : text[..60] + "…";

    /// <summary>
    /// Re-captures live window metadata (and a fresh screenshot) for the
    /// pinned target, keeping the contextId stable. Caller must have verified
    /// the HWND is still alive (HostApiServer does).
    /// </summary>
    public async Task<DesktopContextSnapshot?> RefreshAsync(DesktopContextSnapshot previous)
    {
        try
        {
            var target = previous.TargetWindow;
            if (target is null)
            {
                return null;
            }

            var hwnd = WindowInfoService.ParseHwnd(target.Hwnd);
            var refreshedTarget = await Task.Run(() => _windows.FromHwnd(hwnd));
            if (refreshedTarget is null)
            {
                return null;
            }

            var cursor = _windows.CaptureCursor();
            var underCursor = await Task.Run(() => _windows.CaptureWindowAt(cursor));
            var monitors = _windows.CaptureMonitors();
            var desktopBackground = DesktopBackgroundPolicy.IsActive(refreshedTarget, underCursor);
            var cursorMonitorId = WindowInfoService.MonitorIdAt(cursor, monitors);
            var targetMonitorId = desktopBackground
                ? cursorMonitorId
                : WindowInfoService.MonitorIdFor(refreshedTarget, monitors);

            var screenshot = await Task.Run(() => _screenshots.CaptureWindow(refreshedTarget));
            var refreshed = previous with
            {
                CapturedAt = DateTimeOffset.Now,
                Cursor = cursor,
                TargetWindow = refreshedTarget with { MonitorId = targetMonitorId },
                ForegroundWindow = refreshedTarget with { MonitorId = targetMonitorId },
                WindowUnderCursor = underCursor is null
                    ? null
                    : underCursor with { MonitorId = cursorMonitorId },
                Screenshot = screenshot ?? previous.Screenshot,
                FocusedElement = await Task.Run(() => _uia.CaptureFocused()),
                ElementUnderCursor = underCursor is null
                    ? null
                    : await Task.Run(() => _uia.CaptureElementUnderCursor(cursor)),
                SelectedDesktopItems = null,
                SelectedDesktopItemCount = null,
                SelectedDesktopItemsTruncated = null,
                Monitors = monitors,
            };

            if (desktopBackground)
            {
                var selection = await Task.Run(() => _uia.CaptureDesktopSelection(cursor));
                refreshed = refreshed with
                {
                    SelectedDesktopItems = selection?.Items,
                    SelectedDesktopItemCount = selection?.TotalCount,
                    SelectedDesktopItemsTruncated = selection is not null
                        ? selection.TotalCount > selection.Items.Count
                        : null,
                };
            }

            _store.Put(refreshed);
            Log.Info($"Refreshed {refreshed.Id}: title='{Truncate(refreshedTarget.Title)}'");
            return refreshed;
        }
        catch (Exception ex)
        {
            Log.Error($"Refresh failed: {ex.Message}");
            return null;
        }
    }

    /// <summary>Fresh screenshot of the pinned target window.</summary>
    public async Task<ScreenshotRef?> CaptureScreenshotAsync(DesktopContextSnapshot snapshot)
    {
        var target = snapshot.TargetWindow;
        if (target is null)
        {
            return null;
        }

        return await Task.Run(() => _screenshots.CaptureWindow(target));
    }
}
