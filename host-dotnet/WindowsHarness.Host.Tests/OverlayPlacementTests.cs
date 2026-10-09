using WindowsHarness.Contracts;
using WindowsHarness.Host.Context;
using WindowsHarness.Host.Overlay;

namespace WindowsHarness.Host.Tests;

public sealed class OverlayPlacementTests
{
    private static readonly MonitorSummary LaptopMonitor = new()
    {
        Id = "laptop",
        IsPrimary = true,
        Bounds = new Rect { X = -1920, Y = 0, Width = 1920, Height = 1080 },
        WorkArea = new Rect { X = -1920, Y = 0, Width = 1920, Height = 1040 },
    };

    private static readonly MonitorSummary ExternalMonitor = new()
    {
        Id = "external",
        IsPrimary = false,
        Bounds = new Rect { X = 0, Y = 0, Width = 2560, Height = 1440 },
        WorkArea = new Rect { X = 0, Y = 0, Width = 2560, Height = 1400 },
    };

    [Fact]
    public void ActiveDesktopAnchorsToMonitorUnderPointer()
    {
        var desktop = Window("explorer", "Progman", ExternalMonitor.Bounds, "external", dpi: 96);
        var desktopPoint = Window("explorer", "SysListView32", LaptopMonitor.Bounds, "laptop", dpi: 120);
        var snapshot = Snapshot(desktop, desktopPoint, new Point2D { X = -400, Y = 300 });

        Assert.True(DesktopBackgroundPolicy.IsActive(desktop, desktopPoint));
        var placement = OverlayWindow.ResolvePlacement(snapshot, desktop);

        Assert.Equal(LaptopMonitor.Bounds, placement.AnchorBounds);
        Assert.Equal(LaptopMonitor.WorkArea, placement.WorkArea);
        Assert.Equal(1.25, placement.DpiScale);
    }

    [Fact]
    public void NormalForegroundWindowStillAnchorsToThatWindow()
    {
        var appBounds = new Rect { X = 200, Y = 100, Width = 1200, Height = 800 };
        var app = Window("notepad", "Notepad", appBounds, "external", dpi: 144);
        var desktopPoint = Window("explorer", "WorkerW", LaptopMonitor.Bounds, "laptop", dpi: 120);
        var snapshot = Snapshot(app, desktopPoint, new Point2D { X = -400, Y = 300 });

        Assert.False(DesktopBackgroundPolicy.IsActive(app, desktopPoint));
        var placement = OverlayWindow.ResolvePlacement(snapshot, app);

        Assert.Equal(appBounds, placement.AnchorBounds);
        Assert.Equal(ExternalMonitor.WorkArea, placement.WorkArea);
        Assert.Equal(1.5, placement.DpiScale);
    }

    [Theory]
    [InlineData(1.0, 400, 24)]
    [InlineData(1.25, 500, 30)]
    [InlineData(1.5, 600, 36)]
    [InlineData(2.0, 800, 48)]
    public void PhysicalWindowIsClampedAboveTaskbarAtAnyScaling(
        double scale, double physicalHeight, double margin)
    {
        var (left, top) = OverlayWindow.CalculatePhysicalPosition(
            LaptopMonitor.Bounds, LaptopMonitor.WorkArea,
            width: 520 * scale, height: physicalHeight, margin: margin);

        Assert.Equal((int)Math.Round(-960 - 260 * scale), left);
        Assert.True(top + physicalHeight <=
            LaptopMonitor.WorkArea.Y + LaptopMonitor.WorkArea.Height);
    }

    [Theory]
    [InlineData(1.0)]
    [InlineData(1.25)]
    [InlineData(1.5)]
    [InlineData(2.0)]
    public void GrowingPromptKeepsBottomFixedAndMovesTopUp(double scale)
    {
        var anchor = new Rect { X = 200, Y = 100, Width = 1200, Height = 800 };
        var shortHeight = 100 * scale;
        var tallHeight = 240 * scale;
        var shortPosition = OverlayWindow.CalculatePhysicalPosition(
            anchor, ExternalMonitor.WorkArea, 520 * scale, shortHeight, 24 * scale);
        var tallPosition = OverlayWindow.CalculatePhysicalPosition(
            anchor, ExternalMonitor.WorkArea, 520 * scale, tallHeight, 24 * scale);

        Assert.Equal(shortPosition.Left, tallPosition.Left);
        Assert.Equal(shortPosition.Top + shortHeight, tallPosition.Top + tallHeight);
        Assert.True(tallPosition.Top < shortPosition.Top);
    }

    [Fact]
    public void GrowingPromptKeepsBottomFixedWhenTaskbarClamped()
    {
        var shortPosition = OverlayWindow.CalculatePhysicalPosition(
            LaptopMonitor.Bounds, LaptopMonitor.WorkArea, 520, 100, 24);
        var tallPosition = OverlayWindow.CalculatePhysicalPosition(
            LaptopMonitor.Bounds, LaptopMonitor.WorkArea, 520, 300, 24);

        Assert.Equal(1040, shortPosition.Top + 100);
        Assert.Equal(1040, tallPosition.Top + 300);
    }

    [Fact]
    public void GrowingPromptClampsToTopWhenUpwardSpaceRunsOut()
    {
        var anchor = new Rect { X = 100, Y = 0, Width = 800, Height = 200 };
        var shortPosition = OverlayWindow.CalculatePhysicalPosition(
            anchor, ExternalMonitor.WorkArea, 520, 100, 24);
        var tallPosition = OverlayWindow.CalculatePhysicalPosition(
            anchor, ExternalMonitor.WorkArea, 520, 300, 24);

        Assert.Equal(76, shortPosition.Top);
        Assert.Equal(0, tallPosition.Top);
    }

    [Fact]
    public void PhysicalWindowRespectsTaskbarOnLeftEdge()
    {
        var bounds = new Rect { X = 0, Y = 0, Width = 1920, Height = 1080 };
        var work = new Rect { X = 80, Y = 0, Width = 1840, Height = 1080 };

        var (left, _) = OverlayWindow.CalculatePhysicalPosition(
            bounds, work, width: 1900, height: 200, margin: 24);

        Assert.Equal(80, left);
    }

    [Theory]
    [InlineData("Shell_TrayWnd", "explorer")]
    [InlineData("WorkerW", "another-process")]
    [InlineData("CabinetWClass", "explorer")]
    public void NonDesktopExplorerSurfacesDoNotTriggerFallback(string pointerClass, string pointerProcess)
    {
        var desktop = Window("explorer", "WorkerW", ExternalMonitor.Bounds, "external", dpi: 96);
        var pointerWindow = Window(pointerProcess, pointerClass, LaptopMonitor.Bounds, "laptop", dpi: 120);

        Assert.False(DesktopBackgroundPolicy.IsActive(desktop, pointerWindow));
    }

    private static DesktopContextSnapshot Snapshot(
        WindowContext foreground, WindowContext underCursor, Point2D cursor) => new()
    {
        Id = "ctx-test",
        CapturedAt = DateTimeOffset.UtcNow,
        Cursor = cursor,
        ForegroundWindow = foreground,
        WindowUnderCursor = underCursor,
        TargetWindow = foreground,
        Monitors = [LaptopMonitor, ExternalMonitor],
    };

    private static WindowContext Window(
        string process, string className, Rect bounds, string monitorId, double dpi) => new()
    {
        Hwnd = "0x1234",
        ProcessId = 42,
        ProcessName = process,
        Title = "",
        ClassName = className,
        Bounds = bounds,
        MonitorId = monitorId,
        Dpi = dpi,
    };
}
