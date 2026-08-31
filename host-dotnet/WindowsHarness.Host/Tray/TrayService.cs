using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Windows.Forms;
using WindowsHarness.Host.Diagnostics;
using WindowsHarness.Host.Hotkeys;
using WpfApplication = System.Windows.Application;

namespace WindowsHarness.Host.Tray;

/// <summary>
/// Notification-area icon giving the hidden WPF app a visible presence:
/// tooltip shows the active hotkey, menu offers "Settings…" (model +
/// reasoning effort selection), "Open logs folder" and "Exit" (the only
/// clean shutdown path while StartupMode is OnExplicitShutdown). Disposal
/// removes the icon before shutdown so no ghost tray entry remains (O.2).
/// </summary>
internal sealed class TrayService : IDisposable
{
    private readonly NotifyIcon _icon;
    private EventHandler? _toastClick;
    private bool _disposed;

    /// <summary>Raised on the UI thread when "Settings…" is clicked.
    /// The owner (App) owns lifetime and single-instance behavior.</summary>
    public event EventHandler? SettingsRequested;

    public TrayService()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("Settings…", null, (_, _) => SettingsRequested?.Invoke(this, EventArgs.Empty));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Open logs folder", null, (_, _) => OpenLogsFolder());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Exit", null, (_, _) => Exit());

        _icon = new NotifyIcon
        {
            Icon = ExtractHostIcon() ?? SystemIcons.Application,
            Text = BuildTooltip(),
            ContextMenuStrip = menu,
            Visible = true,
        };
        // Left-click intentionally does nothing; the hotkey is the interaction.
    }

    /// <summary>Show a balloon toast (ux-design-notes.md: failures, plus
    /// completions while the pill is dismissed). Single-shot click handler
    /// reopens the result surface; auto-expires after a few seconds.</summary>
    public void ShowToast(string title, string message, Action? onClick = null)
    {
        if (_disposed)
        {
            return;
        }

        if (_toastClick is not null)
        {
            _icon.BalloonTipClicked -= _toastClick; // Replace any pending toast.
            _toastClick = null;
        }

        if (onClick is not null)
        {
            _toastClick = (_, _) =>
            {
                _icon.BalloonTipClicked -= _toastClick;
                _toastClick = null;
                onClick();
            };
            _icon.BalloonTipClicked += _toastClick;
        }

        _icon.BalloonTipTitle = title.Length <= 63 ? title : title[..63];
        _icon.BalloonTipText = message.Length <= 255 ? message : message[..255];
        _icon.BalloonTipIcon = ToolTipIcon.Info;
        _icon.ShowBalloonTip(4000);
    }

    private static string BuildTooltip()
    {
        const int MaxTooltipLength = 63; // NOTIFYICONDATA szInfo limit.
        var hotkey = HotkeyOptions.FromEnvironment();
        var hotkeyText = string.Join("+", hotkey.Modifiers) + "+"
              + (hotkey.VirtualKey == 0x20 ? "Space" : $"0x{hotkey.VirtualKey:X2}");
        var text = $"pi-os host ({hotkeyText})";
        return text.Length <= MaxTooltipLength ? text : text[..MaxTooltipLength];
    }

    private static Icon? ExtractHostIcon()
    {
        try
        {
            var exePath = Environment.ProcessPath;
            return string.IsNullOrEmpty(exePath)
                ? null
                : Icon.ExtractAssociatedIcon(exePath);
        }
        catch (Exception ex)
        {
            Log.Info($"Tray icon extraction fell back to system icon: {ex.Message}");
            return null;
        }
    }

    private static void OpenLogsFolder()
    {
        var logs = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "pi-os", "logs");
        Directory.CreateDirectory(logs);
        using var _ = Process.Start(new ProcessStartInfo("explorer.exe", $"\"{logs}\"")
        {
            UseShellExecute = true,
        });
    }

    private void Exit()
    {
        Log.Info("Exit requested from tray");
        Dispose(); // Remove the tray icon before the WPF shutdown tears down the message loop.
        WpfApplication.Current.Shutdown();
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _icon.Visible = false;
        _icon.Dispose();
    }
}
