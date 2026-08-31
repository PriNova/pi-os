using System.Text.Json;
using WindowsHarness.Contracts;
using WindowsHarness.Host.Context;

namespace WindowsHarness.Host.Tests;

public sealed class DesktopContextTests
{
    private static readonly MonitorSummary LeftMonitor = new()
    {
        Id = @"\\.\DISPLAY1",
        DeviceName = @"\\.\DISPLAY1",
        IsPrimary = true,
        Bounds = new Rect { X = -1920, Y = 0, Width = 1920, Height = 1080 },
        WorkArea = new Rect { X = -1920, Y = 0, Width = 1920, Height = 1040 },
        Dpi = 120,
    };

    private static readonly MonitorSummary RightMonitor = new()
    {
        Id = @"\\.\DISPLAY2",
        DeviceName = @"\\.\DISPLAY2",
        IsPrimary = false,
        Bounds = new Rect { X = 0, Y = 0, Width = 2560, Height = 1440 },
        WorkArea = new Rect { X = 0, Y = 0, Width = 2560, Height = 1400 },
        Dpi = 96,
    };

    [Fact]
    public void LiveMonitorEnumerationReturnsUniquePhysicalDisplays()
    {
        var monitors = new WindowInfoService().CaptureMonitors();

        Assert.NotEmpty(monitors);
        Assert.Single(monitors, monitor => monitor.IsPrimary);
        Assert.Equal(monitors.Count, monitors.Select(monitor => monitor.Id).Distinct().Count());
        Assert.All(monitors, monitor =>
        {
            Assert.False(string.IsNullOrWhiteSpace(monitor.DeviceName));
            Assert.True(monitor.Bounds.Width > 0 && monitor.Bounds.Height > 0);
            Assert.True(monitor.WorkArea.Width > 0 && monitor.WorkArea.Height > 0);
            Assert.True(monitor.Dpi > 0);
        });
    }

    [Fact]
    public void CursorAndWindowResolveToStableMonitorIds()
    {
        MonitorSummary[] monitors = [LeftMonitor, RightMonitor];
        var cursor = new Point2D { X = -100, Y = 500 };
        var window = Window(new Rect { X = -200, Y = 100, Width = 600, Height = 700 });

        Assert.Equal(LeftMonitor.Id, WindowInfoService.MonitorIdAt(cursor, monitors));
        Assert.Equal(RightMonitor.Id, WindowInfoService.MonitorIdFor(window, monitors));
    }

    [Fact]
    public void OffscreenWindowUsesNearestMonitor()
    {
        MonitorSummary[] monitors = [LeftMonitor, RightMonitor];
        var window = Window(new Rect { X = 3000, Y = 100, Width = 400, Height = 400 });

        Assert.Equal(RightMonitor.Id, WindowInfoService.MonitorIdFor(window, monitors));
    }

    [Fact]
    public void EmptyDesktopSelectionIsSerializedButUnavailableSelectionIsOmitted()
    {
        var checkedSnapshot = Snapshot([]);
        var unavailableSnapshot = Snapshot(null);

        var checkedJson = JsonSerializer.Serialize(checkedSnapshot, ContractsJson.Options);
        var unavailableJson = JsonSerializer.Serialize(unavailableSnapshot, ContractsJson.Options);

        Assert.Contains("\"selectedDesktopItems\":[]", checkedJson);
        Assert.DoesNotContain("selectedDesktopItems", unavailableJson);
    }

    private static DesktopContextSnapshot Snapshot(IReadOnlyList<UiaElementSummary>? selected) => new()
    {
        Id = "ctx-test",
        CapturedAt = DateTimeOffset.UtcNow,
        Cursor = new Point2D { X = 0, Y = 0 },
        SelectedDesktopItems = selected,
        Monitors = [LeftMonitor, RightMonitor],
    };

    private static WindowContext Window(Rect bounds) => new()
    {
        Hwnd = "0x1234",
        ProcessId = 42,
        ProcessName = "test",
        Title = "test",
        Bounds = bounds,
    };
}
