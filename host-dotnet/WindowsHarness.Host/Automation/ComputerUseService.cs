using System.Diagnostics;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.UI.Input.KeyboardAndMouse;
using WindowsHarness.Contracts;
using WindowsHarness.Host.Context;
using WindowsHarness.Host.Diagnostics;

namespace WindowsHarness.Host.Automation;

/// <summary>Serialized native input for the one window pinned by contextId.</summary>
public sealed class ComputerUseService(ContextStore store, WindowInfoService windows)
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private long _nextTraceId;

    private static readonly HashSet<ushort> ExtendedKeys =
    [
        0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2E,
    ];

    /// <summary>Delay between injected keystrokes. Fast bursts overwhelm slow
    /// text pipelines (UWP/TSF editors) and degenerate into repeated characters,
    /// so characters are paced. Override with PI_OS_TYPE_INTERVAL_MS (milliseconds; 0 disables).
    /// Measured default: 20 ms per character types reliably into the modern Notepad.</summary>
    private static readonly TimeSpan TypeInterval = TypeIntervalFromEnvironment();

    private static TimeSpan TypeIntervalFromEnvironment()
    {
        if (int.TryParse(Environment.GetEnvironmentVariable("PI_OS_TYPE_INTERVAL_MS"),
                out var ms) && ms >= 0)
        {
            return TimeSpan.FromMilliseconds(ms);
        }
        return TimeSpan.FromMilliseconds(20);
    }

    private static readonly IReadOnlyDictionary<string, ushort> NamedKeys = new Dictionary<string, ushort>(StringComparer.OrdinalIgnoreCase)
    {
        ["enter"] = 0x0D, ["tab"] = 0x09, ["escape"] = 0x1B, ["backspace"] = 0x08,
        ["delete"] = 0x2E, ["home"] = 0x24, ["end"] = 0x23, ["pageup"] = 0x21,
        ["pagedown"] = 0x22, ["arrowup"] = 0x26, ["arrowdown"] = 0x28,
        ["arrowleft"] = 0x25, ["arrowright"] = 0x27,
        ["f1"] = 0x70, ["f2"] = 0x71, ["f3"] = 0x72, ["f4"] = 0x73,
        ["f5"] = 0x74, ["f6"] = 0x75, ["f7"] = 0x76, ["f8"] = 0x77,
        ["f9"] = 0x78, ["f10"] = 0x79, ["f11"] = 0x7A, ["f12"] = 0x7B,
    };

    public Task<object> FocusAsync(string contextId, CancellationToken cancellationToken) =>
        RunAsync(contextId, "focus", "", focus: false, async (target, token, _) =>
        {
            await FocusTargetAsync(target, token);
            return new { action = "focus" };
        }, cancellationToken);

    public Task<object> ClickAsync(string contextId, double x, double y, CancellationToken cancellationToken) =>
        RunAsync(contextId, "click", $"point=({x:0.##},{y:0.##})", focus: true, (target, _, traceId) =>
        {
            var (screenX, screenY) = ToScreenPoint(target.Bounds, x, y);
            MovePointer(screenX, screenY, contextId, traceId, "click");

            var downSent = false;
            try
            {
                SendMouse(MOUSE_EVENT_FLAGS.MOUSEEVENTF_LEFTDOWN);
                downSent = true;
            }
            finally
            {
                if (downSent)
                {
                    SendMouse(MOUSE_EVENT_FLAGS.MOUSEEVENTF_LEFTUP);
                }
            }

            return Task.FromResult<object>(new { action = "click", x, y });
        }, cancellationToken);

    public Task<object> TypeTextAsync(string contextId, string text, CancellationToken cancellationToken)
    {
        if (string.IsNullOrEmpty(text))
        {
            throw new ComputerUseException("invalid_arguments", "text must be non-empty.");
        }

        return RunAsync(contextId, "typeText", $"characters={text.Length}", focus: true, async (_target, token, _) =>
        {
            for (var i = 0; i < text.Length; i++)
            {
                token.ThrowIfCancellationRequested();
                SendUnicodeKeystroke(text[i]);
                if (i < text.Length - 1)
                {
                    await Task.Delay(TypeInterval, token);
                }
            }
            return new { action = "typeText", characters = text.Length };
        }, cancellationToken);
    }

    public Task<object> PressKeyAsync(string contextId, string key, CancellationToken cancellationToken) =>
        RunAsync(contextId, "pressKey", $"key={SafeLogToken(key)}", focus: true, (_target, _token, _) =>
        {
            var vk = ParseKey(key);
            PressAndRelease(vk);
            return Task.FromResult<object>(new { action = "pressKey", key = key.ToLowerInvariant() });
        }, cancellationToken);

    public Task<object> KeyChordAsync(string contextId, string key, IReadOnlyList<string> modifiers,
        CancellationToken cancellationToken)
    {
        if (modifiers.Count == 0)
        {
            throw new ComputerUseException("invalid_arguments", "At least one modifier is required.");
        }

        return RunAsync(contextId, "keyChord",
            $"key={SafeLogToken(key)} modifiers={string.Join('+', modifiers.Select(SafeLogToken))}",
            focus: true, (_target, _, _) =>
        {
            var keyVk = ParseKey(key);
            var modifierVks = modifiers.Select(ParseModifier).Distinct().ToArray();
            var pressed = new List<ushort>();
            try
            {
                foreach (var modifier in modifierVks)
                {
                    SendVirtualKey(modifier, keyUp: false);
                    pressed.Add(modifier);
                }
                SendVirtualKey(keyVk, keyUp: false);
                pressed.Add(keyVk);
            }
            finally
            {
                Exception? releaseFailure = null;
                for (var i = pressed.Count - 1; i >= 0; i--)
                {
                    try { SendVirtualKey(pressed[i], keyUp: true); }
                    catch (Exception ex) { releaseFailure ??= ex; }
                }
                if (releaseFailure is not null)
                    throw new ComputerUseException("input_failed", "Windows did not release all chord keys.");
            }
            return Task.FromResult<object>(new { action = "keyChord", key = key.ToLowerInvariant() });
        }, cancellationToken);
    }

    public Task<object> ScrollAsync(string contextId, double deltaX, double deltaY, double? x, double? y,
        CancellationToken cancellationToken) =>
        RunAsync(contextId, "scroll",
            $"notches=({deltaX:0.##},{deltaY:0.##}) point={(x is null ? "center" : $"({x:0.##},{y:0.##})")}",
            focus: true, (target, _, traceId) =>
        {
            if (!double.IsFinite(deltaX) || !double.IsFinite(deltaY) || (deltaX == 0 && deltaY == 0))
            {
                throw new ComputerUseException("invalid_arguments", "Scroll movement must be finite and non-zero.");
            }

            var relativeX = x ?? target.Bounds.Width / 2;
            var relativeY = y ?? target.Bounds.Height / 2;
            var (screenX, screenY) = ResolveScrollPoint(target.Bounds, x, y);
            MovePointer(screenX, screenY, contextId, traceId, "scroll");

            var wheelDeltaY = deltaY == 0 ? 0 : WheelDeltaFromNotches(deltaY);
            var wheelDeltaX = deltaX == 0 ? 0 : WheelDeltaFromNotches(deltaX);
            Log.Info($"Computer Use trace={traceId} action=scroll wheelData=({wheelDeltaX},{wheelDeltaY}).");
            if (wheelDeltaY != 0) SendMouse(MOUSE_EVENT_FLAGS.MOUSEEVENTF_WHEEL, wheelDeltaY);
            if (wheelDeltaX != 0) SendMouse(MOUSE_EVENT_FLAGS.MOUSEEVENTF_HWHEEL, wheelDeltaX);
            return Task.FromResult<object>(new
            {
                action = "scroll", deltaX, deltaY, x = relativeX, y = relativeY, wheelDeltaX, wheelDeltaY,
            });
        }, cancellationToken);

    private async Task<object> RunAsync(string contextId, string action, string details, bool focus,
        Func<WindowContext, CancellationToken, long, Task<object>> operation, CancellationToken cancellationToken)
    {
        var traceId = Interlocked.Increment(ref _nextTraceId);
        var timer = Stopwatch.StartNew();
        Log.Info($"Computer Use trace={traceId} action={action} requested context={contextId}" +
            (details.Length == 0 ? "." : $" {details}."));
        try
        {
            await _gate.WaitAsync(cancellationToken);
            try
            {
                cancellationToken.ThrowIfCancellationRequested();
                var target = ReloadAndValidateTarget(contextId);
                Log.Info($"Computer Use trace={traceId} target={target.ProcessName}/{target.Hwnd} " +
                    $"bounds=({target.Bounds.X:0.##},{target.Bounds.Y:0.##},{target.Bounds.Width:0.##},{target.Bounds.Height:0.##}).");
                if (focus) await FocusTargetAsync(target, cancellationToken);
                var result = await operation(target, cancellationToken, traceId);
                Log.Info($"Computer Use trace={traceId} action={action} completed durationMs={timer.ElapsedMilliseconds}.");
                return result;
            }
            finally
            {
                _gate.Release();
            }
        }
        catch (Exception ex)
        {
            var outcome = ex is ComputerUseException domain ? domain.Code
                : ex is OperationCanceledException ? "cancelled"
                : ex.GetType().Name;
            Log.Warn($"Computer Use trace={traceId} action={action} failed outcome={outcome} durationMs={timer.ElapsedMilliseconds}.");
            throw;
        }
    }

    internal static bool TargetStillValid(WindowContext? target)
    {
        if (target is null) return false;
        var hwnd = WindowInfoService.ParseHwndSafe(target.Hwnd);
        if (hwnd is null || !PInvoke.IsWindow(hwnd.Value)) return false;
        _ = PInvoke.GetWindowThreadProcessId(hwnd.Value, out var pid);
        return pid == (uint)target.ProcessId;
    }

    internal WindowContext ReloadAndValidateTarget(string contextId)
    {
        var snapshot = store.Get(contextId)
            ?? throw new ComputerUseException("unknown_context", $"Unknown or expired context '{contextId}'.");
        var pinned = snapshot.TargetWindow
            ?? throw new ComputerUseException("target_gone", "Pinned context has no target window.");
        if (!TargetStillValid(pinned))
            throw new ComputerUseException("target_gone", $"HWND {pinned.Hwnd} no longer exists or changed process.");
        var hwnd = WindowInfoService.ParseHwnd(pinned.Hwnd);
        var current = windows.FromHwnd(hwnd);
        if (current is null || current.ProcessId != pinned.ProcessId)
            throw new ComputerUseException("target_gone", $"HWND {pinned.Hwnd} could not be refreshed.");
        ComputerUsePolicy.EnsureAllowed(current);
        return current;
    }

    private static async Task FocusTargetAsync(WindowContext target, CancellationToken cancellationToken)
    {
        var hwnd = WindowInfoService.ParseHwnd(target.Hwnd);
        if (PInvoke.GetForegroundWindow() != hwnd && !PInvoke.SetForegroundWindow(hwnd))
            throw new ComputerUseException("focus_failed", "Windows declined focus for the pinned target.");
        await Task.Delay(40, cancellationToken);
        if (PInvoke.GetForegroundWindow() != hwnd)
            throw new ComputerUseException("focus_failed", "Pinned target did not become the foreground window.");
    }

    internal static (int X, int Y) ToScreenPoint(Rect bounds, double x, double y)
    {
        if (!double.IsFinite(x) || !double.IsFinite(y)
            || x < 0 || y < 0 || x >= bounds.Width || y >= bounds.Height)
            throw new ComputerUseException("invalid_arguments", "Coordinates are outside current target bounds.");
        return (checked((int)Math.Floor(bounds.X + x)), checked((int)Math.Floor(bounds.Y + y)));
    }

    internal static (int X, int Y) ResolveScrollPoint(Rect bounds, double? x, double? y)
    {
        if (x.HasValue != y.HasValue)
            throw new ComputerUseException("invalid_arguments", "Scroll x and y must be supplied together.");
        return ToScreenPoint(bounds, x ?? bounds.Width / 2, y ?? bounds.Height / 2);
    }

    internal static ushort ParseKey(string key)
    {
        if (NamedKeys.TryGetValue(key, out var named)) return named;
        if (key.Length == 1)
        {
            var c = char.ToUpperInvariant(key[0]);
            if (c is >= 'A' and <= 'Z' or >= '0' and <= '9') return c;
        }
        throw new ComputerUseException("invalid_arguments", $"Unsupported key '{key}'.");
    }

    internal static int WheelDeltaFromNotches(double notches)
    {
        var rounded = Math.Round(notches * 120, MidpointRounding.AwayFromZero);
        if (rounded is < int.MinValue or > int.MaxValue || (notches != 0 && rounded == 0))
            throw new ComputerUseException("invalid_arguments", "Scroll notch delta is outside the supported range or too small.");
        return (int)rounded;
    }

    private static string SafeLogToken(string value) =>
        new(value.Take(32).Select(character => char.IsAsciiLetterOrDigit(character) ? character : '_').ToArray());

    private void MovePointer(int screenX, int screenY, string contextId, long traceId, string action)
    {
        if (!PInvoke.SetCursorPos(screenX, screenY))
            throw new ComputerUseException("input_failed", "Could not move the pointer into the pinned target.");

        var actual = PInvoke.GetCursorPos(out var point) ? $"({point.X},{point.Y})" : "unknown";
        var underPointer = PInvoke.GetCursorPos(out point)
            ? windows.FromHwnd(PInvoke.WindowFromPoint(point))
            : null;
        Log.Info($"Computer Use trace={traceId} action={action} pointerTarget=({screenX},{screenY}) " +
            $"pointerActual={actual} underPointer={underPointer?.ProcessName ?? "unknown"}/{underPointer?.ClassName ?? "unknown"} " +
            $"context={contextId}.");
    }

    private static ushort ParseModifier(string modifier) => modifier.ToLowerInvariant() switch
    {
        "ctrl" => 0x11, "alt" => 0x12, "shift" => 0x10,
        _ => throw new ComputerUseException("invalid_arguments", $"Unsupported modifier '{modifier}'."),
    };

    private static void PressAndRelease(ushort vk)
    {
        var down = false;
        try { SendVirtualKey(vk, keyUp: false); down = true; }
        finally { if (down) SendVirtualKey(vk, keyUp: true); }
    }

    private static void SendVirtualKey(ushort vk, bool keyUp)
    {
        var flags = keyUp ? KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP : 0;
        if (ExtendedKeys.Contains(vk)) flags |= KEYBD_EVENT_FLAGS.KEYEVENTF_EXTENDEDKEY;
        SendKeyboard(vk, 0, flags);
    }

    private static void SendUnicode(char character, bool keyUp) => SendKeyboard(0, character,
        KEYBD_EVENT_FLAGS.KEYEVENTF_UNICODE | (keyUp ? KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP : 0));

    /// <summary>One Unicode keystroke as a single atomic Windows call.
    /// Down and up travel in the same SendInput batch, so a late key-up can
    /// never leave the key stuck down for auto-repeat to fill.</summary>
    private static void SendUnicodeKeystroke(char character)
    {
        INPUT[] inputs = [UnicodeInput(character, keyUp: false), UnicodeInput(character, keyUp: true)];
        var sent = PInvoke.SendInput(inputs, System.Runtime.InteropServices.Marshal.SizeOf<INPUT>());
        if (sent == inputs.Length)
        {
            return;
        }
        if (sent == 1)
        {
            // Down landed without its up: rescue the stuck key best-effort.
            TryReleaseUnicode(character);
        }
        throw new ComputerUseException("input_failed", "Windows did not accept the input event.");
    }

    private static INPUT UnicodeInput(char character, bool keyUp) => new()
    {
        type = INPUT_TYPE.INPUT_KEYBOARD,
        Anonymous = new INPUT._Anonymous_e__Union
        {
            ki = new KEYBDINPUT
            {
                wVk = 0,
                wScan = character,
                dwFlags = KEYBD_EVENT_FLAGS.KEYEVENTF_UNICODE | (keyUp ? KEYBD_EVENT_FLAGS.KEYEVENTF_KEYUP : 0),
            },
        },
    };

    private static void TryReleaseUnicode(char character)
    {
        try { SendUnicode(character, keyUp: true); } catch { }
    }

    private static void SendKeyboard(ushort vk, ushort scan, KEYBD_EVENT_FLAGS flags)
    {
        var input = new INPUT
        {
            type = INPUT_TYPE.INPUT_KEYBOARD,
            Anonymous = new INPUT._Anonymous_e__Union
            {
                ki = new KEYBDINPUT { wVk = (VIRTUAL_KEY)vk, wScan = scan, dwFlags = flags },
            },
        };
        Send(input);
    }

    private static void SendMouse(MOUSE_EVENT_FLAGS flags, int data = 0)
    {
        var input = new INPUT
        {
            type = INPUT_TYPE.INPUT_MOUSE,
            Anonymous = new INPUT._Anonymous_e__Union
            {
                mi = new MOUSEINPUT { dwFlags = flags, mouseData = unchecked((uint)data) },
            },
        };
        Send(input);
    }

    private static void Send(INPUT input)
    {
        INPUT[] inputs = [input];
        if (PInvoke.SendInput(inputs, System.Runtime.InteropServices.Marshal.SizeOf<INPUT>()) != 1)
            throw new ComputerUseException("input_failed", "Windows did not accept the input event.");
    }
}
