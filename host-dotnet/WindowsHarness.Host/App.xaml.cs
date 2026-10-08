using System.Windows;
using System.Windows.Threading;
using WindowsHarness.Contracts;
using WindowsHarness.Host.Context;
using WindowsHarness.Host.Diagnostics;
using WindowsHarness.Host.Http;
using WindowsHarness.Host.Hotkeys;
using WindowsHarness.Host.Interop;
using WindowsHarness.Host.Overlay;
using WindowsHarness.Host.Settings;
using WindowsHarness.Host.Supervisor;
using WindowsHarness.Host.Tray;

namespace WindowsHarness.Host;

public partial class App : Application
{
    private HotkeyService? _hotkey;
    private CapturePipeline? _pipeline;
    private ContextStore? _store;
    private NodeInvoker? _nodeInvoker;
    private TrayService? _tray;
    private NodeSupervisor? _supervisor;
    private Task? _apiServerTask;
    private Dispatcher? _dispatcher;
    /// <summary>Settings page singleton (tray menu); null when never opened.</summary>
    private SettingsWindow? _settingsWindow;

    /// <summary>Hotkey → prompt phase (capture + overlay input).</summary>
    private volatile bool _capturing;
    /// <summary>Pill phase (invocation running / result pending).</summary>
    private volatile bool _invocationActive;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _dispatcher = Dispatcher.CurrentDispatcher;

        // Silent deaths are undiagnosable (host.log showed a stall with zero
        // error output); route every failure channel into the log.
        DispatcherUnhandledException += (_, args) =>
        {
            Log.Error($"UI thread crash: {args.Exception}");
            args.Handled = true; // Keep the host alive; the hotkey stays usable.
        };
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
            Log.Error($"Fatal domain exception: {args.ExceptionObject}");
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            Log.Error($"Unobserved task exception: {args.Exception}");
            args.SetObserved();
        };

        Log.Info("Windows harness host starting");

        try
        {
            _store = new ContextStore();
            _pipeline = new CapturePipeline(
                new WindowInfoService(), new UiaInfoService(),
                new Capture.ScreenshotService(), _store);

            _hotkey = new HotkeyService(HotkeyOptions.FromEnvironment());
            _hotkey.Pressed += () => _ = OnHotkeyAsync();
            _hotkey.Start();

            // The supervisor generates the per-session token; invoker must
            // send the same one or the harness answers 401 (O.3).
            _supervisor = new NodeSupervisor();
            _nodeInvoker = new NodeInvoker(_supervisor.Token);

            _tray = new TrayService();
            _tray.SettingsRequested += (_, _) => _dispatcher?.BeginInvoke(ShowSettings);

            var apiServer = new HostApiServer(_store, _pipeline, _supervisor.Token);
            _apiServerTask = Task.Run(apiServer.Run);

            // O.3: one launch covers C# + node; the child dies with us.
            _supervisor.Start();
        }
        catch (Exception ex)
        {
            Log.Error($"Fatal during startup: {ex.Message}");
            Shutdown(1);
        }
    }

    private async Task OnHotkeyAsync()
    {
        if (_capturing || _invocationActive || _pipeline is null)
        {
            Log.Info("Hotkey ignored: an invocation is already in flight.");
            return;
        }

        _capturing = true;
        try
        {
            var snapshot = await _pipeline.CaptureAsync();
            if (snapshot is null)
            {
                return;
            }

            // Show the overlay only AFTER the snapshot is pinned.
            Log.Info("Showing prompt overlay");
            var overlay = OverlayWindow.ShowFor(snapshot);
            var submitTcs = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
            var closedTcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            overlay.PromptSubmitted += text => submitTcs.TrySetResult(text);
            overlay.Closed += (_, _) => closedTcs.TrySetResult();

            // Resumes on prompt submission OR Escape-cancel, whichever first.
            var winner = await Task.WhenAny(submitTcs.Task, closedTcs.Task);

            // Return focus to the original target in both paths (handoff 4.4).
            FocusService.TryRestore(snapshot.TargetWindow);

            if (winner != submitTcs.Task)
            {
                Log.Info($"Invocation cancelled ({snapshot.Id})");
                return;
            }

            // The overlay persists as the status pill while the agent runs.
            overlay.EnterPillMode();
            _invocationActive = true;
            _ = TrackInvocationAsync(overlay, snapshot, submitTcs.Task.Result);
        }
        finally
        {
            _capturing = false;
        }
    }

    /// <summary>Drives one invocation through the pill: submit, poll live
    /// activity into the pill label, then surface the terminal result
    /// (reader popup inline, or toast when the user dismissed the pill).</summary>
    private async Task TrackInvocationAsync(
        OverlayWindow overlay, DesktopContextSnapshot snapshot, string prompt)
    {
        var dismissed = false;
        try
        {
            var invoker = _nodeInvoker;
            if (invoker is null)
            {
                overlay.Close();
                return;
            }

            overlay.DismissRequested += () => dismissed = true;

            var invocationId = await invoker.SendInvocationAsync(snapshot, prompt);
            if (invocationId is null)
            {
                _tray?.ShowToast("pi-os — harness unreachable", "Could not submit the invocation.");
                overlay.Close();
                return;
            }

            overlay.CancelRequested += () => _ = invoker.CancelAsync(invocationId);
            // Live session dies with the reader window (sequential follow-ups
            // reuse it until then). Close is idempotent on the harness.
            overlay.Closed += (_, _) => _ = invoker.CloseAsync(invocationId);
            overlay.FollowupSubmitted += text => _ = HandleFollowupAsync(overlay, invocationId, text);

            var status = await invoker.PollUntilTerminalAsync(invocationId,
                s => _dispatcher?.InvokeAsync(() => overlay.SetActivity(s.Activity)));

            // Result handling runs on the UI thread; the invocation slot frees
            // once the result is shown, not when the reader popup closes.
            // Follow-up runs deliberately leave the global slot alone: the
            // harness keys live sessions per window, so a follow-up and a new
            // hotkey can each make progress without a global race.
            _dispatcher?.Invoke(() => SurfaceResult(overlay, status, dismissed));
        }
        catch (Exception ex)
        {
            Log.Error($"Invocation tracking failed: {ex.Message}");
            _dispatcher?.Invoke(overlay.Close);
        }
        finally
        {
            _invocationActive = false;
        }
    }

    /// <summary>Sequential follow-up on the idle live session (same window).
    /// The reader shrinks back to the pill so agent focus changes cannot
    /// deactivate/auto-close the window mid-run (which would dispose the
    /// session via Closed -&gt; CloseAsync).</summary>
    private async Task HandleFollowupAsync(OverlayWindow overlay, string invocationId, string prompt)
    {
        var invoker = _nodeInvoker;
        if (invoker is null)
        {
            return;
        }

        _dispatcher?.Invoke(overlay.EnterFollowupPill);
        var accepted = await invoker.SendFollowupAsync(invocationId, prompt);
        if (!accepted)
        {
            _dispatcher?.Invoke(() => overlay.ReenterReaderAfterFailedFollowup("follow-up rejected — try again"));
            return;
        }

        var status = await invoker.PollUntilTerminalAsync(invocationId,
            s => _dispatcher?.InvokeAsync(() => overlay.SetActivity(s.Activity)));

        _dispatcher?.Invoke(() =>
        {
            if (!overlay.IsVisible)
            {
                // Dismissed mid-follow-up: surface via toast like the first run.
                if (status.State == "completed")
                {
                    var done = string.IsNullOrEmpty(status.ResponseText) ? "(no response text)" : status.ResponseText!;
                    _tray?.ShowToast("pi-os — done", FirstLine(done),
                        () => overlay.ReopenReader(done, failure: false, status.FollowupAvailable));
                }
                else
                {
                    var reason = status.FailureMessage ?? $"follow-up {status.State}";
                    _tray?.ShowToast($"pi-os — {status.State}", FirstLine(reason),
                        () => overlay.ReopenReader(reason, failure: true));
                }
                return;
            }
            if (status.State == "completed")
            {
                var answer = string.IsNullOrEmpty(status.ResponseText)
                    ? "(no response text)"
                    : status.ResponseText!;
                overlay.ShowAnswer(answer, status.FollowupAvailable);
            }
            else if (status.State == "aborted" || status.State == "timed_out")
            {
                overlay.ReenterReaderAfterFailedFollowup(status.State == "aborted" ? "canceled — start a new task" : "timed out — start a new task", status.FollowupAvailable);
            }
            else
            {
                overlay.ReenterReaderAfterFailedFollowup(FirstLine(status.FailureMessage ?? "follow-up failed — try again"), status.FollowupAvailable);
            }
        });
    }

    private void SurfaceResult(OverlayWindow overlay, InvocationStatus status, bool dismissed)
    {
        switch (status.State)
        {
            case "completed":
                var answer = string.IsNullOrEmpty(status.ResponseText)
                    ? "(no response text)"
                    : status.ResponseText!;
                if (dismissed)
                {
                    _tray?.ShowToast("pi-os — done", FirstLine(answer),
                        () => overlay.ReopenReader(answer, failure: false, status.FollowupAvailable));
                }
                else
                {
                    overlay.ShowAnswer(answer, status.FollowupAvailable);
                }
                break;

            case "aborted":
                // Aborted == the pill ✕ was pressed (timeouts end as timed_out).
                if (dismissed)
                {
                    _tray?.ShowToast("pi-os — canceled", FirstLine(status.FailureMessage ?? "canceled"));
                }
                else
                {
                    overlay.ShowCanceled(); // Fades out and closes itself.
                }
                break;

            default: // failed | timed_out
                var reason = status.FailureMessage ?? $"invocation {status.State}";
                if (dismissed)
                {
                    _tray?.ShowToast($"pi-os — {status.State}", FirstLine(reason),
                        () => overlay.ReopenReader(reason, failure: true));
                }
                else
                {
                    overlay.ShowFailure(reason);
                }
                break;
        }
    }

    /// <summary>Opens the model/effort settings page, one instance at a
    /// time. Modeless so the tray and hotkey stay responsive.</summary>
    private void ShowSettings()
    {
        var invoker = _nodeInvoker;
        if (invoker is null)
        {
            return;
        }

        if (_settingsWindow is { IsLoaded: true })
        {
            _settingsWindow.Activate();
            return;
        }

        Log.Info("Opening settings window from tray");
        _settingsWindow = new SettingsWindow(invoker);
        _settingsWindow.Show();
    }

    private static string FirstLine(string text)
    {
        var line = text.Split('\n', 2)[0].TrimEnd('\r');
        return line.Length <= 120 ? line : line[..120] + "…";
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _supervisor?.Dispose();
        _tray?.Dispose();
        _hotkey?.Dispose();
        _store?.Dispose();
        Log.Info("Host exited");
        base.OnExit(e);
    }
}
