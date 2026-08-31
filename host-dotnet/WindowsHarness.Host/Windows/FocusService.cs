using System.IO;
using Windows.Win32;
using Windows.Win32.Foundation;
using WindowsHarness.Contracts;
using WindowsHarness.Host.Context;
using WindowsHarness.Host.Diagnostics;

namespace WindowsHarness.Host.Interop;

/// <summary>
/// Focus restoration after the overlay closes (handoff section 4.4).
/// Never activates blindly: HWND must still exist AND belong to the same
/// process as when it was pinned, otherwise the handle may have been recycled.
/// </summary>
public static class FocusService
{
    public static bool TryRestore(WindowContext? target)
    {
        if (target is null)
        {
            return false;
        }

        var hwnd = WindowInfoService.ParseHwndSafe(target.Hwnd);
        if (hwnd is null || !PInvoke.IsWindow(hwnd.Value))
        {
            Log.Warn($"Focus restore aborted: {target.Hwnd} no longer exists ({target.ProcessName}).");
            return false;
        }

        _ = PInvoke.GetWindowThreadProcessId(hwnd.Value, out var pid);
        if (pid != (uint)target.ProcessId)
        {
            Log.Warn($"Focus restore aborted: {target.Hwnd} now belongs to PID {pid}, was {target.ProcessId}.");
            return false;
        }

        var activated = PInvoke.SetForegroundWindow(hwnd.Value);
        Log.Info($"Focus restore to {target.ProcessName}: {(activated ? "ok" : "declined by system")}");
        return activated;
    }
}
