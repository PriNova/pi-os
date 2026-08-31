using System.ComponentModel;
using System.IO;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32.System.Threading;
using Windows.Win32.UI.WindowsAndMessaging;
using WindowsHarness.Contracts;
using WindowsHarness.Host.Diagnostics;

namespace WindowsHarness.Host.Context;

/// <summary>
/// Captures window metadata (handoff section 4.2, layer 1): HWND, process,
/// title, class, bounds, DPI, monitor and cursor info.
/// Runs before the overlay appears so the popup is never the target.
/// </summary>
public sealed class WindowInfoService
{
    public WindowContext? CaptureForeground() => FromHwnd(PInvoke.GetForegroundWindow());

    public WindowContext? CaptureWindowAt(Point2D point) =>
        FromHwnd(PInvoke.WindowFromPoint(new System.Drawing.Point((int)point.X, (int)point.Y)));

    /// <summary>Physical-pixel cursor position.</summary>
    public Point2D CaptureCursor() =>
        PInvoke.GetCursorPos(out var point)
            ? new Point2D { X = point.X, Y = point.Y }
            : new Point2D { X = 0, Y = 0 };

    internal double? CaptureDpi(HWND hwnd)
    {
        try
        {
            return PInvoke.GetDpiForWindow(hwnd);
        }
        catch
        {
            return null;
        }
    }

    private enum MonitorDpiType { Effective = 0 }

    [System.Runtime.InteropServices.DllImport("Shcore.dll")]
    private static extern int GetDpiForMonitor(
        HMONITOR monitor, MonitorDpiType dpiType, out uint dpiX, out uint dpiY);

    /// <summary>All active displays in physical desktop coordinates.</summary>
    public IReadOnlyList<MonitorSummary> CaptureMonitors()
    {
        try
        {
            return System.Windows.Forms.Screen.AllScreens
                .Select(screen =>
                {
                    var bounds = ToRect(screen.Bounds);
                    var center = new System.Drawing.Point(
                        screen.Bounds.Left + screen.Bounds.Width / 2,
                        screen.Bounds.Top + screen.Bounds.Height / 2);
                    var handle = PInvoke.MonitorFromPoint(
                        center, MONITOR_FROM_FLAGS.MONITOR_DEFAULTTONEAREST);

                    return new MonitorSummary
                    {
                        Id = screen.DeviceName,
                        DeviceName = screen.DeviceName,
                        IsPrimary = screen.Primary,
                        Bounds = bounds,
                        WorkArea = ToRect(screen.WorkingArea),
                        Dpi = TryGetMonitorDpi(handle),
                    };
                })
                .OrderByDescending(monitor => monitor.IsPrimary)
                .ThenBy(monitor => monitor.Bounds.X)
                .ThenBy(monitor => monitor.Bounds.Y)
                .ToArray();
        }
        catch (Exception ex)
        {
            Log.Warn($"Monitor enumeration failed: {ex.Message}");
            return [];
        }
    }

    private static double? TryGetMonitorDpi(HMONITOR monitor)
    {
        try
        {
            return monitor != HMONITOR.Null
                && GetDpiForMonitor(monitor, MonitorDpiType.Effective, out var dpiX, out _) >= 0
                    ? dpiX
                    : null;
        }
        catch
        {
            return null;
        }
    }

    internal static string? MonitorIdAt(Point2D point, IReadOnlyList<MonitorSummary> monitors) =>
        monitors.FirstOrDefault(monitor => PointIsInside(monitor.Bounds, point))?.Id;

    internal static string? MonitorIdFor(WindowContext window, IReadOnlyList<MonitorSummary> monitors)
    {
        if (monitors.Count == 0)
        {
            return null;
        }

        var bestOverlap = monitors
            .Select(monitor => (monitor.Id, Area: IntersectionArea(window.Bounds, monitor.Bounds)))
            .OrderByDescending(candidate => candidate.Area)
            .First();
        if (bestOverlap.Area > 0)
        {
            return bestOverlap.Id;
        }

        var centerX = window.Bounds.X + window.Bounds.Width / 2;
        var centerY = window.Bounds.Y + window.Bounds.Height / 2;
        return monitors.OrderBy(monitor => DistanceSquaredToRect(centerX, centerY, monitor.Bounds)).First().Id;
    }

    private static bool PointIsInside(Rect bounds, Point2D point) =>
        point.X >= bounds.X && point.X < bounds.X + bounds.Width
        && point.Y >= bounds.Y && point.Y < bounds.Y + bounds.Height;

    private static double IntersectionArea(Rect left, Rect right)
    {
        var width = Math.Max(0, Math.Min(left.X + left.Width, right.X + right.Width) - Math.Max(left.X, right.X));
        var height = Math.Max(0, Math.Min(left.Y + left.Height, right.Y + right.Height) - Math.Max(left.Y, right.Y));
        return width * height;
    }

    private static double DistanceSquaredToRect(double x, double y, Rect rect)
    {
        var dx = Math.Max(rect.X - x, Math.Max(0, x - (rect.X + rect.Width)));
        var dy = Math.Max(rect.Y - y, Math.Max(0, y - (rect.Y + rect.Height)));
        return dx * dx + dy * dy;
    }

    internal WindowContext? FromHwnd(HWND hwnd)
    {
        if (hwnd == HWND.Null)
        {
            return null;
        }

        var pid = GetProcessId(hwnd);
        var className = TryGetClassName(hwnd);

        return new WindowContext
        {
            Hwnd = FormatHwnd(hwnd),
            ProcessId = (int)pid,
            ProcessName = GetProcessName(pid),
            ExecutablePath = TryGetExecutablePath(pid),
            CommandLine = TryGetCommandLine(pid),
            Title = GetTitle(hwnd),
            ClassName = className,
            ShellFolderPath = TryGetShellFolderPath(hwnd, className),
            Bounds = GetBounds(hwnd) ?? new Rect { X = 0, Y = 0, Width = 0, Height = 0 },
            Dpi = CaptureDpi(hwnd),

            IsElevated = TryIsElevated(pid),
        };
    }

    private static uint GetProcessId(HWND hwnd)
    {
        _ = PInvoke.GetWindowThreadProcessId(hwnd, out var pid);
        return pid;
    }

    private static unsafe string GetTitle(HWND hwnd)
    {
        var length = (int)PInvoke.GetWindowTextLength(hwnd);
        if (length <= 0)
        {
            return string.Empty;
        }

        Span<char> buffer = stackalloc char[length + 1];
        fixed (char* p = buffer)
        {
            var written = (int)PInvoke.GetWindowText(hwnd, new PWSTR(p), buffer.Length);
            return written > 0 ? new string(p, 0, written) : string.Empty;
        }
    }

    private static unsafe string? TryGetClassName(HWND hwnd)
    {
        try
        {
            Span<char> buffer = stackalloc char[256];
            fixed (char* p = buffer)
            {
                var written = (int)PInvoke.GetClassName(hwnd, new PWSTR(p), buffer.Length);
                return written > 0 ? new string(p, 0, written) : null;
            }
        }
        catch
        {
            return null;
        }
    }

    private static Rect? GetBounds(HWND hwnd)
    {
        if (!PInvoke.GetWindowRect(hwnd, out var rect))
        {
            return null;
        }

        return ToRect(rect);
    }

    private static Rect ToRect(RECT rect) => new()
    {
        X = rect.left,
        Y = rect.top,
        Width = rect.right - rect.left,
        Height = rect.bottom - rect.top,
    };

    private static Rect ToRect(System.Drawing.Rectangle rect) => new()
    {
        X = rect.X,
        Y = rect.Y,
        Width = rect.Width,
        Height = rect.Height,
    };

    private static string GetProcessName(uint pid)
    {
        var path = TryGetExecutablePath(pid);
        if (!string.IsNullOrEmpty(path))
        {
            return Path.GetFileNameWithoutExtension(path);
        }

        try
        {
            return System.Diagnostics.Process.GetProcessById((int)pid).ProcessName;
        }
        catch
        {
            return string.Empty;
        }
    }

    private const int ProcessCommandLineInformation = 60; // NtQueryInformationProcess class
    private const uint TokenQuery = 0x0008;
    private const int TokenElevationInformation = 20;

    [System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(nint processHandle, uint desiredAccess, out nint tokenHandle);

    [System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(nint tokenHandle, int tokenInformationClass,
        out uint tokenInformation, uint tokenInformationLength, out uint returnLength);

    private static unsafe bool? TryIsElevated(uint pid)
    {
        var process = PInvoke.OpenProcess(PROCESS_ACCESS_RIGHTS.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (process == HANDLE.Null)
        {
            return null;
        }

        nint token = 0;
        try
        {
            if (!OpenProcessToken((nint)process.Value, TokenQuery, out token))
            {
                return null;
            }
            return GetTokenInformation(token, TokenElevationInformation, out var elevated,
                sizeof(uint), out _) ? elevated != 0 : null;
        }
        finally
        {
            if (token != 0) _ = PInvoke.CloseHandle(new HANDLE((void*)token));
            _ = PInvoke.CloseHandle(process);
        }
    }


    [System.Runtime.InteropServices.DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(
        HANDLE processHandle,
        int processInformationClass,
        nint processInformation,
        uint processInformationLength,
        out uint returnLength);

    /// <summary>
    /// Raw process command line via NtQueryInformationProcess class 60
    /// (ProcessCommandLineInformation). For arg-launched apps (Notepad,
    /// editors, terminals) it carries the open-file path. Returns null on
    /// access-denied (elevated target), process exit, or any other failure.
    /// </summary>
    private static unsafe string? TryGetCommandLine(uint pid)
    {
        var handle = PInvoke.OpenProcess(
            PROCESS_ACCESS_RIGHTS.PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_ACCESS_RIGHTS.PROCESS_VM_READ,
            false,
            pid);

        if (handle == HANDLE.Null)
        {
            return null;
        }

        try
        {
            Span<byte> buffer = stackalloc byte[4096];
            fixed (byte* p = buffer)
            {
                // Class 60 returns a UNICODE_STRING whose Buffer points into the
                // output buffer, followed by the UTF-16 command line itself.
                if (NtQueryInformationProcess(handle, ProcessCommandLineInformation, (nint)p,
                        (uint)buffer.Length, out _) != 0)
                {
                    return null;
                }

                var length = BitConverter.ToUInt16(buffer);
                // Buffer field sits at offset IntPtr.Size (4 on x86 targets, 8 on x64).
                var bufferPtr = IntPtr.Size == 8
                    ? (nint)BitConverter.ToInt64(buffer.Slice(8, 8))
                    : (nint)BitConverter.ToInt32(buffer.Slice(4, 4));
                var offset = (long)bufferPtr - (long)p;
                if (length == 0 || offset < 0 || offset + length > buffer.Length)
                {
                    return null;
                }

                return System.Text.Encoding.Unicode.GetString(buffer.Slice((int)offset, length));
            }
        }
        catch
        {
            return null;
        }
        finally
        {
            _ = PInvoke.CloseHandle(handle);
        }
    }

    /// <summary>
    /// Active folder for shell views (File Explorer) via the IShellWindows
    /// collection, matched by top-level HWND. Gated on CabinetWClass so other
    /// windows pay nothing. With multiple tabs sharing one HWND the active tab
    /// is picked by matching its UIA-selected tab title against each entry's
    /// LocationName (fallback: first entry). Null for special locations,
    /// non-shell windows, or any failure.
    /// </summary>
    private static unsafe string? TryGetShellFolderPath(HWND hwnd, string? className)
    {
        if (!string.Equals(className, "CabinetWClass", StringComparison.Ordinal))
        {
            return null;
        }

        try
        {
            // CLSID_ShellWindows; late-bound so no SHDocVw interop dependency.
            var type = Type.GetTypeFromCLSID(new Guid("9BA05972-F6A8-11CF-A442-00A0C90A8F39"));
            if (type is null)
            {
                return null;
            }

            dynamic? shellWindows = Activator.CreateInstance(type);
            if (shellWindows is null)
            {
                return null;
            }

            try
            {
                var target = (long)new nint(hwnd.Value);
                var count = (int)shellWindows.Count;
                var candidates = new List<(string Url, string Name)>();
                for (var i = 0; i < count; i++)
                {
                    dynamic? window = shellWindows.Item(i);
                    if (window is null)
                    {
                        continue;
                    }

                    try
                    {
                        if ((long)window.HWND != target)
                        {
                            continue;
                        }

                        var url = (string?)window.LocationURL ?? string.Empty;
                        var name = string.Empty;
                        try
                        {
                            name = (string?)window.LocationName ?? string.Empty;
                        }
                        catch
                        {
                            // Display name is optional metadata for matching.
                        }

                        candidates.Add((url, name));
                    }
                    finally
                    {
                        System.Runtime.InteropServices.Marshal.FinalReleaseComObject(window);
                    }
                }

                if (candidates.Count == 0)
                {
                    return null;
                }

                string? urlToUse = null;
                if (candidates.Count > 1)
                {
                    var selectedTab = TryGetSelectedExplorerTabName(hwnd);
                    if (!string.IsNullOrEmpty(selectedTab))
                    {
                        for (var c = 0; c < candidates.Count; c++)
                        {
                            if (string.Equals(candidates[c].Name, selectedTab, StringComparison.OrdinalIgnoreCase))
                            {
                                urlToUse = candidates[c].Url;
                                break;
                            }
                        }
                    }
                }

                urlToUse ??= candidates[0].Url;
                if (string.IsNullOrEmpty(urlToUse) ||
                    !urlToUse.StartsWith("file://", StringComparison.OrdinalIgnoreCase))
                {
                    return null;
                }

                return new Uri(urlToUse).LocalPath;
            }
            finally
            {
                System.Runtime.InteropServices.Marshal.FinalReleaseComObject(shellWindows);
            }
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// Title of the UIA-selected Explorer tab, or null. Only used when several
    /// shell-window entries share one top-level HWND (Win11 multi-tab).
    /// </summary>
    private static unsafe string? TryGetSelectedExplorerTabName(HWND hwnd)
    {
        try
        {
            var element = System.Windows.Automation.AutomationElement.FromHandle(new nint(hwnd.Value));
            var tabs = element.FindAll(
                System.Windows.Automation.TreeScope.Descendants,
                new System.Windows.Automation.PropertyCondition(
                    System.Windows.Automation.AutomationElement.ControlTypeProperty,
                    System.Windows.Automation.ControlType.TabItem));
            foreach (System.Windows.Automation.AutomationElement tab in tabs)
            {
                if (tab.TryGetCurrentPattern(System.Windows.Automation.SelectionItemPattern.Pattern,
                        out var pattern) &&
                    pattern is System.Windows.Automation.SelectionItemPattern selection &&
                    selection.Current.IsSelected)
                {
                    return tab.Current.Name;
                }
            }
        }
        catch
        {
            // Degrade to first-entry fallback.
        }

        return null;
    }

    private static unsafe string? TryGetExecutablePath(uint pid)
    {
        var handle = PInvoke.OpenProcess(
            PROCESS_ACCESS_RIGHTS.PROCESS_QUERY_LIMITED_INFORMATION,
            false,
            pid);

        if (handle == HANDLE.Null)
        {
            return null;
        }

        try
        {
            // Non-owning wrapper: lifetime stays managed by CloseHandle below.
            using var safe = new Microsoft.Win32.SafeHandles.SafeFileHandle((nint)handle.Value,
                ownsHandle: false);

            Span<char> buffer = stackalloc char[1024];
            var size = (uint)buffer.Length;
            // 0 == PROCESS_NAME_WIN32 (drive-letter style path).
            if (!PInvoke.QueryFullProcessImageName(safe, (PROCESS_NAME_FORMAT)0, buffer, ref size))
            {
                return null;
            }

            return new string(buffer[..(int)size]);
        }
        catch
        {
            return null;
        }
        finally
        {
            _ = PInvoke.CloseHandle(handle);
        }
    }

    internal static unsafe HWND ParseHwnd(string hwndString)
    {
        var raw = hwndString.StartsWith("0x", StringComparison.OrdinalIgnoreCase)
            ? hwndString[2..]
            : hwndString;
        var value = long.Parse(raw, System.Globalization.NumberStyles.HexNumber);
        return new HWND((void*)new nint(value));
    }

    internal static HWND? ParseHwndSafe(string hwndString)
    {
        try
        {
            return ParseHwnd(hwndString);
        }
        catch
        {
            return null;
        }
    }

    internal static unsafe string FormatHwnd(HWND hwnd) => $"0x{(long)new nint(hwnd.Value):X}";
}
