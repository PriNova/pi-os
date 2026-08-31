using System.ComponentModel;
using System.Windows.Interop;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.Input.KeyboardAndMouse;
using WindowsHarness.Host.Diagnostics;

namespace WindowsHarness.Host.Hotkeys;

/// <summary>
/// Registers one process-wide global hotkey with a NULL hwnd, so WM_HOTKEY is
/// posted to the thread message queue. The WPF dispatcher pumps that queue;
/// ComponentDispatcher.ThreadFilterMessage lets us intercept it without
/// creating any window. Keeps the host fully background.
/// </summary>
public sealed class HotkeyService : IDisposable
{
    private readonly HotkeyOptions _options;
    private const int HotkeyId = 1;
    private bool _registered;

    /// <summary>Raised on the WPF UI thread when the hotkey is pressed.</summary>
    public event Action? Pressed;

    public HotkeyService(HotkeyOptions options) => _options = options;

    public void Start()
    {
        var modifiers = HOT_KEY_MODIFIERS.MOD_NOREPEAT;
        foreach (var mod in _options.Modifiers)
        {
            modifiers |= mod switch
            {
                "Ctrl" => HOT_KEY_MODIFIERS.MOD_CONTROL,
                "Alt" => HOT_KEY_MODIFIERS.MOD_ALT,
                "Shift" => HOT_KEY_MODIFIERS.MOD_SHIFT,
                "Win" => HOT_KEY_MODIFIERS.MOD_WIN,
                _ => throw new InvalidOperationException($"Unknown modifier '{mod}'."),
            };
        }

        if (!PInvoke.RegisterHotKey(default, HotkeyId, modifiers, _options.VirtualKey))
        {
            throw new Win32Exception($"RegisterHotKey failed (error {System.Runtime.InteropServices.Marshal.GetLastWin32Error()}). The hotkey may already be in use.");
        }

        _registered = true;
        ComponentDispatcher.ThreadFilterMessage += OnThreadFilterMessage;
        Log.Info($"Global hotkey registered: {string.Join('+', _options.Modifiers)}+0x{_options.VirtualKey:X2}");
    }

    // Signature uses the WPF mirror of MSG: message is int, wParam is IntPtr.
    private void OnThreadFilterMessage(ref MSG msg, ref bool handled)
    {
        if (msg.message == (int)PInvoke.WM_HOTKEY && msg.wParam.ToInt64() == HotkeyId)
        {
            handled = true;
            Log.Info("Hotkey pressed");
            Pressed?.Invoke();
        }
    }

    public void Dispose()
    {
        if (_registered)
        {
            ComponentDispatcher.ThreadFilterMessage -= OnThreadFilterMessage;
            PInvoke.UnregisterHotKey(default, HotkeyId);
            _registered = false;
        }
    }
}
