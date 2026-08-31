using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using Windows.Win32.Graphics.Gdi;
using Windows.Win32;
using Windows.Win32.Foundation;
using WindowsHarness.Contracts;
using WindowsHarness.Host.Context;
using WindowsHarness.Host.Diagnostics;

namespace WindowsHarness.Host.Capture;

/// <summary>
/// Layer 3 context: window screenshots. MVP uses GDI PrintWindow with the
/// full-content flag (covers most GPU-composited windows on Win10+), falling
/// back to a screen-region copy. Windows Graphics Capture is the later
/// upgrade path (research question RQ1).
/// </summary>
public sealed class ScreenshotService
{
    private const uint PW_RENDERFULLCONTENT = 0x2;

    private static readonly string CaptureDir =
        Environment.GetEnvironmentVariable("PI_OS_CAPTURES_DIR")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "pi-os", "captures");

    public ScreenshotRef? CaptureWindow(WindowContext target)
    {
        var width = (int)target.Bounds.Width;
        var height = (int)target.Bounds.Height;
        if (width <= 0 || height <= 0)
        {
            Log.Warn($"Screenshot skipped: empty bounds for {target.Hwnd} ({target.ProcessName})");
            return null;
        }

        try
        {
            var hwnd = WindowInfoService.ParseHwnd(target.Hwnd);
            using var bitmap = RenderWindow(hwnd, target.Bounds, width, height);
            Directory.CreateDirectory(CaptureDir);
            var imageId = $"shot-{Guid.NewGuid():N}";
            var filePath = Path.Combine(CaptureDir, $"{imageId}.png");
            bitmap.Save(filePath, ImageFormat.Png);

            return new ScreenshotRef
            {
                Kind = ScreenshotKind.Window,
                FilePath = filePath,
                ImageId = imageId,
                Bounds = target.Bounds,
            };
        }
        catch (Exception ex)
        {
            Log.Warn($"Screenshot failed for {target.Hwnd}: {ex.Message}");
            return null;
        }
    }

    private static Bitmap RenderWindow(HWND hwnd, Rect bounds, int width, int height)
    {
        var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        try
        {
            using (var graphics = Graphics.FromImage(bitmap))
            {
                if (!PrintContent(hwnd, graphics))
                {
                    // Fallback: copy the on-screen region. Requires the window to
                    // be visible and unoccluded at its own bounds.
                    graphics.CopyFromScreen((int)bounds.X, (int)bounds.Y, 0, 0,
                        new Size(width, height));
                }
            }

            return bitmap;
        }
        catch
        {
            bitmap.Dispose();
            throw;
        }
    }

    private static unsafe bool PrintContent(HWND hwnd, Graphics graphics)
    {
        var hdc = graphics.GetHdc();
        try
        {
            // PW_RENDERFULLCONTENT (0x2): includes GPU-composited content.
            return PInvoke.PrintWindow(hwnd, new HDC((void*)(nint)hdc),
                (Windows.Win32.Storage.Xps.PRINT_WINDOW_FLAGS)PW_RENDERFULLCONTENT);
        }
        finally
        {
            graphics.ReleaseHdc(hdc);
        }
    }
}
