using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Interop;
using System.Windows.Threading;
using Windows.Win32;
using Windows.Win32.Foundation;
using WindowsHarness.Host.Context;
using WindowsHarness.Host.Diagnostics;

// Captured geometry and overlay placement are physical pixels throughout.
// WPF still sizes content in DIPs; placement reads the final HWND pixel size
// after PerMonitorV2 scaling because mixed-DPI Left/Top math is unreliable.
using PhysRect = WindowsHarness.Contracts.Rect;

namespace WindowsHarness.Host.Overlay;

/// <summary>
/// The single invocation surface (ux-design-notes.md "Result surfacing"):
/// prompt mode (capture happened before this window existed), pill mode
/// (tiny live-status surface after submit, never focus-stealing), and
/// reader mode (final answer / failure report). One lifecycle:
/// prompt shrinks to pill, pill expands to reader.
/// </summary>
public partial class OverlayWindow : Window
{
    private const int MinActivityDisplayMs = 800;
    private const int MaxMergedActivities = 3;

    private static readonly TimeSpan CanceledDisplayTime = TimeSpan.FromMilliseconds(1200);

    private readonly HWND _hwnd;
    /// <summary>Target window or cursor-monitor bounds, in physical pixels.</summary>
    private readonly PhysRect _anchorBounds;
    /// <summary>Work area holding the placement anchor, in physical pixels.</summary>
    private readonly PhysRect? _workArea;
    /// <summary>Captured anchor DPI fallback used before the HWND reaches its monitor.</summary>
    private readonly double _capturedDpiScale;
    private bool _pillMode;
    private bool _canceled;
    private bool _closeRequested;

    /// <remarks>Local declarations instead of CsWin32: EXSTYLE fits in 32
    /// bits, so the W-variants are correct on x64 and keep the style math
    /// free of pointer-trampoline concerns.</remarks>
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
    private static extern int GetWindowLongW(HWND hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongW")]
    private static extern int SetWindowLongW(HWND hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll", EntryPoint = "SetWindowPos")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPosEx(
        HWND hWnd, HWND hWndInsertAfter,
        int x, int y, int cx, int cy, uint uFlags);

    // ------------------------------------------------------------------
    // Pill visuals — variant A "Pulse Dot" (docs/design-mocks/pill-mocks.html):
    // cyan working/thinking · violet tool running · green done flash · red failed.
    // ------------------------------------------------------------------

    private enum PillState { Working, ToolRunning, Done, Failed }

    private static readonly Color WorkingColor = Color.FromRgb(0x4C, 0xC2, 0xFF);
    private static readonly Color ToolColor = Color.FromRgb(0xA7, 0x8B, 0xFA);
    private static readonly Color DoneColor = Color.FromRgb(0x4A, 0xDE, 0x80);
    private static readonly Color AlertColor = Color.FromRgb(0xF8, 0x71, 0x71);

    /// <summary>How long the done/failed flash shows before the reader opens.</summary>
    private const int TerminalFlashMs = 600;

    private PillState _pillState;
    /// <summary>Set at the terminal outcome; freezes the live activity line.</summary>
    private bool _terminal;
    private bool _pulseRunning;
    private bool _hairlineRunning;
    private DispatcherTimer? _elapsedTimer;
    private Action? _afterFlash;
    private DateTime _pillStartedAt;

    // Anti-flicker state for the activity line.
    private readonly List<string> _mergedActivities = [];
    private DateTime _labelShownAt = DateTime.MinValue;
    private DispatcherTimer? _clearTimer;
    private DispatcherTimer? _closeTimer;

    /// <summary>Raised once when the user submits a non-empty prompt.</summary>
    public event Action<string>? PromptSubmitted;

    /// <summary>Raised each time the user submits a non-empty follow-up in reader mode.</summary>
    public event Action<string>? FollowupSubmitted;

    /// <summary>Raised when the user presses the pill ✕ (cancel invocation).</summary>
    public event Action? CancelRequested;

    /// <summary>Raised when the user presses the pill _ (dismiss; result arrives as a toast).</summary>
    public event Action? DismissRequested;

    /// <summary>True while a follow-up is in flight; blocks double-submit.</summary>
    private bool _followupWorking;

    private OverlayWindow(Contracts.DesktopContextSnapshot snapshot)
    {
        var target = snapshot.TargetWindow
            ?? throw new InvalidOperationException("Snapshot has no target window.");

        InitializeComponent();
        TargetLabel.Text = $"{target.ProcessName} — {target.Title}";

        var placement = ResolvePlacement(snapshot, target);
        _anchorBounds = placement.AnchorBounds;
        _workArea = placement.WorkArea;
        _capturedDpiScale = placement.DpiScale;

        // The hairline sweep must adapt when the pill's width changes with
        // its activity text.
        HairlineTrack.SizeChanged += (_, _) =>
        {
            if (_hairlineRunning)
            {
                RestartHairline();
            }
        };
        Closing += (_, _) =>
        {
            _closeRequested = true;
        };
        Closed += (_, _) =>
        {
            StopDotPulse();
            StopHairline();
            StopElapsedTimer();
        };

        _hwnd = (HWND)new WindowInteropHelper(this).EnsureHandle();

        // Moving between mixed-DPI monitors can finish after the first native
        // position call. Re-anchor once WPF has accepted the new monitor DPI.
        DpiChanged += (_, _) => Dispatcher.BeginInvoke(
            DispatcherPriority.Loaded, new Action(ApplyPhysicalPosition));
    }

    /// <summary>Non-null when the user submitted a prompt; null when cancelled.</summary>
    public string? SubmittedPrompt { get; private set; }

    public static OverlayWindow ShowFor(Contracts.DesktopContextSnapshot snapshot)
    {
        _ = snapshot.TargetWindow
            ?? throw new InvalidOperationException("Snapshot has no target window.");

        var overlay = new OverlayWindow(snapshot);
        overlay.RevealInPlace();
        return overlay;
    }

    /// <summary>Complete layout BEFORE showing, so the first painted frame
    /// is already at the final anchored position (no bottom-edge flash),
    /// then show + activate in legal order (Activate before Show throws).</summary>
    private void RevealInPlace()
    {
        UpdateLayout(); // Measure/arrange content now; sizes become real.
        Show();
        ApplyPhysicalPosition();
        Activate();
        PromptBox.Focus();
    }

    // ------------------------------------------------------------------
    // Mode transitions
    // ------------------------------------------------------------------

    /// <summary>Shrink to the live-status pill: tiny, transparent-ish, and
    /// click-able without ever taking focus from the user's work.</summary>
    public void EnterPillMode()
    {
        _pillMode = true;
        _terminal = false;
        PromptPanel.Visibility = Visibility.Collapsed;
        PillPanel.Visibility = Visibility.Visible;

        SetNoActivate(true);
        ShowActivated = false;

        // Explicit sizing: SizeToContent is unreliable once the window is
        // already shown, so the pill would keep stretching to the prompt-mode
        // width (520) and read as a long oval instead of a compact capsule.
        // Measure AFTER the seeded label and visible timer, so the window fits
        // the resting content exactly (buttons reserve their space too).
        _pillStartedAt = DateTime.UtcNow;
        ActivityLabel.Text = "working…"; // A specific activity replaces this fallback.
        ElapsedTimeLabel.Text = "0:00";
        ElapsedTimeLabel.Visibility = Visibility.Visible;
        StartElapsedTimer();

        ResizeToContent();
        SetPillState(PillState.Working);
    }

    /// <summary>Show/clear the live activity line with minimum-display
    /// anti-flicker; rapid sequences merge into one label ("bash, read…").</summary>
    public void SetActivity(string? activity)
    {
        if (!_pillMode || _canceled || _terminal)
        {
            return;
        }

        if (string.IsNullOrEmpty(activity))
        {
            ScheduleLabelClear();
            return;
        }

        StopClearTimer();
        var activityState = activity == "thinking"
            ? PillState.Working
            : PillState.ToolRunning;
        if (_pillState != activityState)
        {
            SetPillState(activityState);
        }
        var recentlyShown = (DateTime.UtcNow - _labelShownAt).TotalMilliseconds < MinActivityDisplayMs;
        if (_mergedActivities.Count == 0 || !recentlyShown)
        {
            _mergedActivities.Clear();
        }
        if (!_mergedActivities.Contains(activity) && _mergedActivities.Count < MaxMergedActivities)
        {
            _mergedActivities.Add(activity);
        }

        ActivityLabel.Text = string.Join(", ", _mergedActivities) + "…";
        ResizeToContent();
        if (_mergedActivities.Count == 1)
        {
            _labelShownAt = DateTime.UtcNow; // New sequence restarts the min-display clock.
        }
    }

    /// <summary>Terminal "canceled" feedback, then the window closes itself.</summary>
    public void ShowCanceled()
    {
        if (!_pillMode)
        {
            Close();
            return;
        }

        _canceled = true;
        BeginTerminal("canceled", PillState.Failed);
        _closeTimer = NewOneShotTimer(CanceledDisplayTime, Close);
    }

    /// <summary>Expand into the reader popup showing the final answer.</summary>
    public void ShowAnswer(string text, bool followupAvailable = true)
    {
        // Copy immediately: the clipboard is ready even if the user hides
        // the pill during the terminal flash.
        TryCopyToClipboard(text);
        if (!_pillMode)
        {
            SwitchToReader("pi-os", text);
            SetFollowupAvailability(followupAvailable);
            return;
        }

        BeginTerminal("done", PillState.Done);
        BeginTerminalFlash(() =>
        {
            SwitchToReader("pi-os", text);
            SetFollowupAvailability(followupAvailable);
        });
    }

    /// <summary>Expand into the reader popup reporting a failure.</summary>
    public void ShowFailure(string message)
    {
        ReaderHint.Text = "copied to clipboard · Esc or ✕ to close";
        if (!_pillMode)
        {
            SwitchToReader("pi-os — failed", message);
            DisableFollowup("follow-up unavailable after failure");
            return;
        }

        BeginTerminal("failed", PillState.Failed);
        BeginTerminalFlash(() =>
        {
            SwitchToReader("pi-os — failed", message);
            DisableFollowup("follow-up unavailable after failure");
        });
    }

    /// <summary>Follow-up box becomes usable once an answer is shown.</summary>
    public void EnableFollowup()
    {
        _followupWorking = false;
        FollowupBox.Text = string.Empty;
        FollowupBox.IsEnabled = true;
        FollowupHint.Text = "Enter: follow-up · Esc: close";
    }

    /// <summary>Follow-up box shows a busy hint and blocks double-submit.</summary>
    public void SetFollowupWorking(bool working, string? hint = null)
    {
        _followupWorking = working;
        FollowupBox.IsEnabled = !working;
        if (hint is not null)
        {
            FollowupHint.Text = hint;
        }
        else if (working)
        {
            FollowupHint.Text = "working…";
        }
    }

    private void SetFollowupAvailability(bool available)
    {
        if (available) EnableFollowup();
        else DisableFollowup("conversation ended — start a new task");
    }

    private void DisableFollowup(string hint)
    {
        _followupWorking = false;
        FollowupBox.IsEnabled = false;
        FollowupHint.Text = hint;
    }

    /// <summary>Freezes the pill into a colored one-word status: live motion
    /// stops, controls disable, nothing can overwrite the label anymore.</summary>
    private void BeginTerminal(string label, PillState state)
    {
        _terminal = true;
        StopClearTimer();
        StopElapsedTimer();
        DismissButton.IsEnabled = false;
        CancelButton.IsEnabled = false;
        PillButtons.IsHitTestVisible = false;
        ActivityLabel.Text = label;
        ElapsedTimeLabel.Visibility = Visibility.Collapsed;
        SetPillState(state);
    }

    private void BeginTerminalFlash(Action next)
    {
        _afterFlash = next;
        _closeTimer = NewOneShotTimer(
            TimeSpan.FromMilliseconds(TerminalFlashMs), RunAfterFlash);
    }

    private void RunAfterFlash()
    {
        var action = _afterFlash;
        _afterFlash = null;
        action?.Invoke();
    }


    /// <summary>Shrink back to the pill for a follow-up run.
    /// The pill never takes focus, so agent focus changes never disturb it.
    /// The reader itself stays open until the user closes it explicitly.</summary>
    public void EnterFollowupPill()
    {
        _followupWorking = true;
        FollowupBox.IsEnabled = false;
        _pillMode = true;
        _terminal = false;
        _canceled = false;
        _mergedActivities.Clear();
        StopClearTimer();
        PromptPanel.Visibility = Visibility.Collapsed;
        ReaderPanel.Visibility = Visibility.Collapsed;
        PillPanel.Visibility = Visibility.Visible;
        DismissButton.IsEnabled = true;
        CancelButton.IsEnabled = true;
        SetNoActivate(true);
        ShowActivated = false;
        _pillStartedAt = DateTime.UtcNow;
        ActivityLabel.Text = "working…";
        ElapsedTimeLabel.Text = "0:00";
        ElapsedTimeLabel.Visibility = Visibility.Visible;
        StartElapsedTimer();
        ResizeToContent();
        SetPillState(PillState.Working);
    }

    private string _lastReaderTitle = "pi-os";
    private string _lastReaderText = string.Empty;

    /// <summary>Back to the reader with the previous answer after a failed
    /// follow-up, so the user can retry. The answer box is untouched.</summary>
    public void ReenterReaderAfterFailedFollowup(string hint, bool followupAvailable = true)
    {
        SwitchToReader(_lastReaderTitle, _lastReaderText);
        SetFollowupAvailability(followupAvailable);
        FollowupHint.Text = hint;
    }

    /// <summary>Toast-click path after dismissal: resurface the reader popup
    /// (the window was hidden, never closed, so its state is intact).</summary>
    public void ReopenReader(string text, bool failure, bool followupAvailable = true)
    {
        if (failure)
        {
            ShowFailure(text);
        }
        else
        {
            ShowAnswer(text, followupAvailable); // Preserve the retained-thread availability.
        }

        if (!IsVisible)
        {
            ApplyPhysicalPosition();
            Show();
        }
    }

    private void SwitchToReader(string title, string text)
    {
        _pillMode = false;
        StopClearTimer();
        StopDotPulse();
        StopHairline();
        StopElapsedTimer();

        PromptPanel.Visibility = Visibility.Collapsed;
        PillPanel.Visibility = Visibility.Collapsed;
        ReaderPanel.Visibility = Visibility.Visible;

        SetNoActivate(false); // reader may take focus once clicked, enabling Esc.
        ShowActivated = false; // appearing must still not steal focus.

        SizeToContent = SizeToContent.Height;
        Width = 520;

        ReaderTitle.Text = title;
        AnswerBox.Text = text;
        AnswerBox.SelectAll();
        _lastReaderTitle = title;
        _lastReaderText = text;

        UpdateLayout();
        ApplyPhysicalPosition();
    }

    // ------------------------------------------------------------------
    // Prompt mode input
    // ------------------------------------------------------------------

    private void OnPromptKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            SubmittedPrompt = PromptBox.Text.Trim();
            if (SubmittedPrompt.Length == 0)
            {
                return; // Ignore empty submissions; keep the overlay open.
            }

            e.Handled = true;
            PromptSubmitted?.Invoke(SubmittedPrompt);
            // Window stays open; App transitions it into pill mode.
        }
        else if (e.Key == Key.Escape)
        {
            e.Handled = true;
            Close();
        }
    }

    // ------------------------------------------------------------------
    // Pill controls
    // ------------------------------------------------------------------

    private void OnCancelClick(object sender, RoutedEventArgs e)
    {
        CancelRequested?.Invoke();
    }

    private void OnDismissClick(object sender, RoutedEventArgs e)
    {
        DismissRequested?.Invoke();
        Hide(); // Invocation keeps running; completion arrives as a toast.
    }

    // ------------------------------------------------------------------
    // Reader mode input
    // ------------------------------------------------------------------

    private void OnReaderCloseClick(object sender, RoutedEventArgs e) => CloseOnce();

    private void OnReaderKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            e.Handled = true;
            CloseOnce();
        }
    }

    private void OnFollowupKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            if (_followupWorking || !FollowupBox.IsEnabled)
            {
                return;
            }
            var text = FollowupBox.Text.Trim();
            if (text.Length == 0)
            {
                return; // Ignore empty submissions; keep the reader open.
            }
            e.Handled = true;
            SetFollowupWorking(true);
            FollowupSubmitted?.Invoke(text);
        }
        else if (e.Key == Key.Escape)
        {
            e.Handled = true;
            CloseOnce();
        }
    }

    private void CloseOnce()
    {
        if (_closeRequested)
        {
            return;
        }

        _closeRequested = true;
        Close();
    }

    private static void TryCopyToClipboard(string text)
    {
        try
        {
            Clipboard.SetText(text);
        }
        catch (COMException ex)
        {
            Log.Warn($"Clipboard copy failed (clipboard in use?): {ex.Message}");
        }
    }

    // ------------------------------------------------------------------
    // Anti-flicker helpers
    // ------------------------------------------------------------------

    private void ScheduleLabelClear()
    {
        if (_mergedActivities.Count == 0)
        {
            return;
        }

        var elapsedMs = (DateTime.UtcNow - _labelShownAt).TotalMilliseconds;
        if (elapsedMs >= MinActivityDisplayMs)
        {
            ClearActivityLine();
            return;
        }

        if (_clearTimer is null)
        {
            _clearTimer = NewOneShotTimer(
                TimeSpan.FromMilliseconds(MinActivityDisplayMs - elapsedMs), ClearActivityLine);
        }
    }

    private void ClearActivityLine()
    {
        StopClearTimer();
        _mergedActivities.Clear();
        ActivityLabel.Text = "working…";
        ResizeToContent();

        // No specific activity is currently reported; show the generic fallback.
        if (!_terminal && _pillState != PillState.Working)
        {
            SetPillState(PillState.Working);
        }
    }

    private void StopClearTimer()
    {
        _clearTimer?.Stop();
        _clearTimer = null;
    }

    private DispatcherTimer NewOneShotTimer(TimeSpan due, Action action)
    {
        var timer = new DispatcherTimer(DispatcherPriority.Normal) { Interval = due };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            action();
        };
        timer.Start();
        return timer;
    }

    // ------------------------------------------------------------------
    // Pill visuals: pulsing dot + indeterminate bottom hairline
    // ------------------------------------------------------------------

    private void SetPillState(PillState state)
    {
        _pillState = state;
        var color = state switch
        {
            PillState.ToolRunning => ToolColor,
            PillState.Done => DoneColor,
            PillState.Failed => AlertColor,
            _ => WorkingColor,
        };

        StatusDot.Fill = new SolidColorBrush(color);
        PulseHalo.Fill = StatusDot.Fill;
        ApplyHairlineColor(color);

        var busy = state is PillState.Working or PillState.ToolRunning;
        if (busy)
        {
            HairlineTrack.Visibility = Visibility.Visible;
            StartDotPulse();
            StartHairline();
        }
        else
        {
            // A frozen hairline would read as a glitch; remove it instead.
            HairlineTrack.Visibility = Visibility.Collapsed;
            StopDotPulse();
            StopHairline();
        }
    }

    private void ApplyHairlineColor(Color color)
    {
        var brush = new LinearGradientBrush
        {
            StartPoint = new Point(0, 0),
            EndPoint = new Point(1, 0),
        };
        brush.GradientStops.Add(new GradientStop(Color.FromArgb(0, color.R, color.G, color.B), 0));
        brush.GradientStops.Add(new GradientStop(color, 0.5));
        brush.GradientStops.Add(new GradientStop(Color.FromArgb(0, color.R, color.G, color.B), 1));
        HairlineSweep.Fill = brush;
    }

    /// <summary>Scale+fade halo pulse around the status dot (1.6 s loop).
    /// Uses Animatable.BeginAnimation — the canonical path for transform
    /// animations; Storyboard targeting of the transform proved unreliable.</summary>
    private void StartDotPulse()
    {
        if (_pulseRunning)
        {
            return;
        }

        var duration = TimeSpan.FromMilliseconds(1600);
        var ease = new SineEase { EasingMode = EasingMode.EaseOut };
        var transform = (ScaleTransform)PulseHalo.RenderTransform;
        var scaleX = new DoubleAnimation(1, 3.2, duration)
        {
            EasingFunction = ease,
            RepeatBehavior = RepeatBehavior.Forever,
        };
        var scaleY = new DoubleAnimation(1, 3.2, duration)
        {
            EasingFunction = ease,
            RepeatBehavior = RepeatBehavior.Forever,
        };
        var fade = new DoubleAnimation(0.55, 0, duration)
        {
            EasingFunction = ease,
            RepeatBehavior = RepeatBehavior.Forever,
        };
        transform.BeginAnimation(ScaleTransform.ScaleXProperty, scaleX);
        transform.BeginAnimation(ScaleTransform.ScaleYProperty, scaleY);
        PulseHalo.BeginAnimation(OpacityProperty, fade);
        _pulseRunning = true;
    }

    private void StopDotPulse()
    {
        var transform = (ScaleTransform)PulseHalo.RenderTransform;
        transform.BeginAnimation(ScaleTransform.ScaleXProperty, null);
        transform.BeginAnimation(ScaleTransform.ScaleYProperty, null);
        PulseHalo.BeginAnimation(OpacityProperty, null);
        _pulseRunning = false;
    }

    private void StartHairline() => RestartHairline();

    /// <summary>Sweeps the gradient bar across the bottom edge (1.4 s loop).
    /// Rebuilt on track resize because the pill's width follows its label.</summary>
    private void RestartHairline()
    {
        StopHairline();
        if (HairlineTrack.ActualWidth <= 0)
        {
            return;
        }

        var animation = new DoubleAnimation(
            -HairlineSweep.Width,
            HairlineTrack.ActualWidth,
            TimeSpan.FromMilliseconds(1400))
        {
            RepeatBehavior = RepeatBehavior.Forever,
        };
        HairlineX.BeginAnimation(TranslateTransform.XProperty, animation);
        _hairlineRunning = true;
    }

    private void StopHairline()
    {
        HairlineX.BeginAnimation(TranslateTransform.XProperty, null);
        _hairlineRunning = false;
    }

    private void StartElapsedTimer()
    {
        StopElapsedTimer();
        UpdateElapsedLabel();
        _elapsedTimer = new DispatcherTimer(DispatcherPriority.Normal)
        {
            Interval = TimeSpan.FromSeconds(1),
        };
        _elapsedTimer.Tick += (_, _) => UpdateElapsedLabel();
        _elapsedTimer.Start();
    }

    private void UpdateElapsedLabel()
    {
        var elapsed = DateTime.UtcNow - _pillStartedAt;
        ElapsedTimeLabel.Text = $"{(int)elapsed.TotalMinutes}:{elapsed.Seconds:D2}";
    }

    private void StopElapsedTimer()
    {
        _elapsedTimer?.Stop();
        _elapsedTimer = null;
    }

    /// <summary>Sizes the window to the pill content's desired width and
    /// re-anchors it above the target. Called at pill entry and whenever the
    /// activity label changes, so the capsule always wraps its content
    /// (mock behavior) instead of clipping or leaving trailing gaps.
    /// Measures PillContent, not PillPanel: the Border's DropShadow effect
    /// adds blur padding to its desired size, which would inflate the window.</summary>
    private void ResizeToContent()
    {
        PillContent.Measure(new Size(double.PositiveInfinity, 30));
        Width = PillContent.DesiredSize.Width + 24;   // side margins (12 + 12)
        Height = PillContent.DesiredSize.Height + 16; // top/bottom margins (4 + 12)
        UpdateLayout();
        ApplyPhysicalPosition();
    }

    // Hover-revealed controls: fade AND hit-test together, so invisible
    // buttons can never swallow clicks meant for windows underneath.

    private void OnPillMouseEnter(object sender, MouseEventArgs e)
    {
        PillButtons.BeginAnimation(
            OpacityProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(150)));
        PillButtons.IsHitTestVisible = true;
    }

    private void OnPillMouseLeave(object sender, MouseEventArgs e)
    {
        PillButtons.BeginAnimation(
            OpacityProperty, new DoubleAnimation(0, TimeSpan.FromMilliseconds(150)));
        PillButtons.IsHitTestVisible = false;
    }

    // ------------------------------------------------------------------
    // Placement + activation policy
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // Placement: all math in physical pixels, applied via SetWindowPos.
    // WPF's Left/Top use DIPs and are unreliable across mixed-DPI monitors.
    // ------------------------------------------------------------------

    private void ApplyPhysicalPosition()
    {
        const uint SWP_NOSIZE = 0x0001;
        const uint SWP_NOZORDER = 0x0004;
        const uint SWP_NOACTIVATE = 0x0010;

        // SetWindowPos can synchronously move this PerMonitorV2 window onto a
        // monitor with another DPI. WPF then changes the HWND's physical size.
        // A second pass reads that final size and corrects the anchor exactly.
        for (var pass = 0; pass < 2; pass++)
        {
            var dpiScale = CurrentDpiScale();
            var (width, height) = CurrentPhysicalSize(dpiScale);
            var (left, top) = CalculatePhysicalPosition(
                _anchorBounds, _workArea, width, height, 24 * dpiScale);

            _ = SetWindowPosEx(_hwnd, default, left, top, 0, 0,
                SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
        }
    }

    /// <summary>Reads the real HWND size after WPF applies per-monitor DPI.</summary>
    private (double Width, double Height) CurrentPhysicalSize(double dpiScale)
    {
        if (PInvoke.GetWindowRect(_hwnd, out var rect))
        {
            var width = rect.right - rect.left;
            var height = rect.bottom - rect.top;
            if (width > 0 && height > 0)
            {
                return (width, height);
            }
        }

        return (ActualWidth * dpiScale, ActualHeight * dpiScale);
    }

    private double CurrentDpiScale()
    {
        var dpi = PInvoke.GetDpiForWindow(_hwnd);
        return dpi > 0 ? dpi / 96.0 : _capturedDpiScale;
    }

    internal static (int Left, int Top) CalculatePhysicalPosition(
        PhysRect anchor, PhysRect? workArea, double width, double height, double margin)
    {
        var left = anchor.X + (anchor.Width - width) / 2;
        var top = anchor.Y + anchor.Height - height - margin;

        // The work area excludes fixed taskbars. Clamp using the HWND's real
        // physical size, not a DIP estimate, so every scaling factor is safe.
        if (workArea is { } work && work.Width > 0 && work.Height > 0)
        {
            left = Math.Clamp(left, work.X, Math.Max(work.X, work.X + work.Width - width));
            top = Math.Clamp(top, work.Y, Math.Max(work.Y, work.Y + work.Height - height));
        }

        return ((int)Math.Round(left), (int)Math.Round(top));
    }

    internal readonly record struct Placement(PhysRect AnchorBounds, PhysRect? WorkArea, double DpiScale);

    /// <summary>
    /// Normal windows anchor the overlay to the pinned target. When both the
    /// foreground and pointer surfaces are the Explorer desktop, the monitor
    /// under the pointer becomes the anchor instead. Requiring both checks
    /// avoids moving an app-targeted prompt merely because the pointer happens
    /// to rest over visible wallpaper on another monitor.
    /// </summary>
    internal static Placement ResolvePlacement(
        Contracts.DesktopContextSnapshot snapshot, Contracts.WindowContext target)
    {
        if (DesktopBackgroundPolicy.IsActive(snapshot.ForegroundWindow, snapshot.WindowUnderCursor))
        {
            var cursorMonitor = snapshot.Monitors.FirstOrDefault(m => PointIsInside(m.Bounds, snapshot.Cursor))
                ?? snapshot.Monitors.FirstOrDefault();
            if (cursorMonitor is not null)
            {
                var dpi = cursorMonitor.Dpi ?? snapshot.WindowUnderCursor?.Dpi ?? target.Dpi ?? 96;
                return new Placement(cursorMonitor.Bounds, cursorMonitor.WorkArea, dpi / 96.0);
            }
        }

        Contracts.MonitorSummary? targetMonitor = null;
        if (target.MonitorId is { } id)
        {
            targetMonitor = snapshot.Monitors.FirstOrDefault(m => m.Id == id);
        }
        targetMonitor ??= snapshot.Monitors.FirstOrDefault(m => RectContains(m.Bounds, target.Bounds));

        return new Placement(target.Bounds, targetMonitor?.WorkArea, (target.Dpi ?? 96) / 96.0);
    }

    private static bool PointIsInside(PhysRect bounds, Contracts.Point2D point) =>
        point.X >= bounds.X && point.X < bounds.X + bounds.Width
        && point.Y >= bounds.Y && point.Y < bounds.Y + bounds.Height;

    private static bool RectContains(PhysRect outer, PhysRect inner)
    {
        var centerX = inner.X + inner.Width / 2;
        var centerY = inner.Y + inner.Height / 2;
        return centerX >= outer.X && centerX < outer.X + outer.Width
            && centerY >= outer.Y && centerY < outer.Y + outer.Height;
    }

    private void SetNoActivate(bool enable)
    {
        const int GWL_EXSTYLE = -20;
        const int WS_EX_NOACTIVATE = 0x0800_0000;
        try
        {
            var style = GetWindowLongW(_hwnd, GWL_EXSTYLE);
            var updated = enable ? style | WS_EX_NOACTIVATE : style & ~WS_EX_NOACTIVATE;
            _ = SetWindowLongW(_hwnd, GWL_EXSTYLE, updated);
        }
        catch (Exception ex)
        {
            Log.Warn($"WS_EX_NOACTIVATE toggle failed: {ex.Message}");
        }
    }
}
