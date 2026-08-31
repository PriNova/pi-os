using WindowsHarness.Contracts;
using WindowsHarness.Host.Automation;

namespace WindowsHarness.Host.Tests;

public sealed class ComputerUseTests
{
    [Fact]
    public void ScreenshotCoordinatesConvertToPhysicalScreenPixels()
    {
        var bounds = new Rect { X = -100, Y = 40, Width = 800, Height = 600 };
        Assert.Equal((23, 496), ComputerUseService.ToScreenPoint(bounds, 123, 456));
    }

    [Theory]
    [InlineData(1, 120)]
    [InlineData(-2, -240)]
    [InlineData(0.5, 60)]
    public void ScrollNotchesConvertToWindowsWheelData(double notches, int expected)
    {
        Assert.Equal(expected, ComputerUseService.WheelDeltaFromNotches(notches));
    }

    [Fact]
    public void ScrollPointDefaultsToCenterOrUsesSuppliedCoordinates()
    {
        var bounds = new Rect { X = -100, Y = 40, Width = 800, Height = 600 };
        Assert.Equal((300, 340), ComputerUseService.ResolveScrollPoint(bounds, null, null));
        Assert.Equal((23, 496), ComputerUseService.ResolveScrollPoint(bounds, 123, 456));
        Assert.Throws<ComputerUseException>(() => ComputerUseService.ResolveScrollPoint(bounds, 123, null));
    }

    [Theory]
    [InlineData(-1, 0)]
    [InlineData(0, -1)]
    [InlineData(800, 10)]
    [InlineData(10, 600)]
    public void OutOfBoundsCoordinatesAreRejected(double x, double y)
    {
        var bounds = new Rect { X = 0, Y = 0, Width = 800, Height = 600 };
        var error = Assert.Throws<ComputerUseException>(() => ComputerUseService.ToScreenPoint(bounds, x, y));
        Assert.Equal("invalid_arguments", error.Code);
    }

    [Theory]
    [InlineData("enter", 0x0D)]
    [InlineData("a", 0x41)]
    [InlineData("7", 0x37)]
    [InlineData("f12", 0x7B)]
    public void SupportedKeysParseStrictly(string key, int expected)
    {
        Assert.Equal((ushort)expected, ComputerUseService.ParseKey(key));
    }

    [Fact]
    public void WindowsModifierIsRejected()
    {
        Assert.Throws<ComputerUseException>(() => ComputerUseService.ParseKey("meta"));
    }

    [Theory]
    [InlineData("WindowsTerminal", "CASCADIA_HOSTING_WINDOW_CLASS", "Terminal")]
    [InlineData("Bitwarden", "Chrome_WidgetWin_1", "Bitwarden")]
    [InlineData("WindowsHarness.Host", "HwndWrapper", "pi-os")]
    [InlineData("consent", "#32770", "User Account Control")]
    public void UnsafeTargetsAreBlocked(string process, string className, string title)
    {
        var error = Assert.Throws<ComputerUseException>(() =>
            ComputerUsePolicy.EnsureAllowed(Window(process, className, title)));
        Assert.Equal("policy_blocked", error.Code);
    }

    [Fact]
    public void ElevatedTargetsAreBlockedBeforeInput()
    {
        var error = Assert.Throws<ComputerUseException>(() =>
            ComputerUsePolicy.EnsureAllowed(Window("Notepad", "Notepad", "note", elevated: true)));
        Assert.Equal("target_elevated", error.Code);
    }

    [Fact]
    public void OrdinaryNotepadTargetIsAllowed()
    {
        ComputerUsePolicy.EnsureAllowed(Window("Notepad", "Notepad", "note", elevated: false));
    }

    [Theory]
    [InlineData("chrome", "ChatGPT/Codex discussion on X")]
    [InlineData("msedge", "Sign in to example.com")]
    [InlineData("firefox", "Password settings")]
    [InlineData("brave", "pi agent documentation")]
    [InlineData("opera", "Windows Hello help")]
    public void BrowserTargetsAreAllowedRegardlessOfTitle(string process, string title)
    {
        ComputerUsePolicy.EnsureAllowed(Window(process, "Chrome_WidgetWin_1", title, elevated: false));
    }

    private static WindowContext Window(string process, string className, string title, bool elevated = false) => new()
    {
        Hwnd = "0x1234",
        ProcessId = 42,
        ProcessName = process,
        Title = title,
        ClassName = className,
        Bounds = new Rect { X = 0, Y = 0, Width = 800, Height = 600 },
        IsElevated = elevated,
    };
}
