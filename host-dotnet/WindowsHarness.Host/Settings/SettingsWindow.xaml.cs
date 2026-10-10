using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using WindowsHarness.Host.Diagnostics;
using WindowsHarness.Host.Http;

namespace WindowsHarness.Host.Settings;

/// <summary>
/// Settings page opened from the tray icon menu (mirrors the pi model
/// picker flow: load catalog -> pick provider/model -> pick a reasoning
/// effort that THIS model supports -> apply). Applies the choice to the
/// node harness, which stores it and uses it for every NEW invocation.
/// </summary>
public partial class SettingsWindow : Window
{
    /// <summary>How long the settings page waits for a cold-started harness
    /// before surfacing the terminal "unreachable" error.</summary>
    private static readonly TimeSpan StartupTimeout = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan RetryDelay = TimeSpan.FromMilliseconds(800);

    private readonly NodeInvoker _invoker;
    private readonly CancellationTokenSource _loadCts = new();
    private IReadOnlyList<ModelInfo> _models = [];
    private ModelSelectionStatus? _current;
    /// <summary>True while combos are populated programmatically.</summary>
    private bool _populating;

    public SettingsWindow(NodeInvoker invoker)
    {
        InitializeComponent();
        _invoker = invoker;
        Closed += (_, _) => _loadCts.Cancel();
        Loaded += (_, _) => _ = LoadAsync();
    }

    /// <summary>Waits for a cold-started harness (indeterminate progress +
    /// silent health-poll retries), then prefills provider/model/effort.
    /// Empty catalogs and permanent errors are terminal; temporary failures
    /// retry until <see cref="StartupTimeout"/>. Cancel closes silently.</summary>
    private async Task LoadAsync()
    {
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(_loadCts.Token);
        timeoutCts.CancelAfter(StartupTimeout);
        var ct = timeoutCts.Token;
        SetLoading(true);
        Status("Waiting for the agent harness to start…");

        try
        {
            // Phase 1: cheap readiness probe. Avoids hammering
            // ModelRuntime.create() while node is not even listening yet.
            while (!await _invoker.CheckHealthAsync(ct))
            {
                Status("Waiting for the agent harness to start…");
                await Task.Delay(RetryDelay, ct);
            }

            Status("Loading models from the agent harness…");
            while (true)
            {
                ct.ThrowIfCancellationRequested();
                var result = await _invoker.GetModelCatalogAsync(ct);
                ct.ThrowIfCancellationRequested();
                var catalog = result.Catalog;
                if (catalog is not null)
                {
                    if (catalog.Models.Count == 0)
                    {
                        Fail("No models available. Configure provider authentication first "
                            + "(pi /login or a provider API key), then reopen settings.");
                        return;
                    }
                    PopulateFromCatalog(catalog);
                    return;
                }
                if (!result.CanRetry)
                {
                    Fail(result.Error ?? "Could not load the model catalog.");
                    return;
                }
                Status("Waiting for the agent harness to start…");
                await Task.Delay(RetryDelay, ct);
            }
        }
        catch (OperationCanceledException) when (_loadCts.IsCancellationRequested)
        {
            // Window closed mid-load: nothing to report.
        }
        catch (OperationCanceledException) when (timeoutCts.IsCancellationRequested)
        {
            Fail("The agent harness did not finish loading models within 60 seconds. "
                + "Make sure pi-os is running, then reopen settings.");
        }
    }

    private void PopulateFromCatalog(ModelCatalog catalog)
    {
        _models = catalog.Models;
        _current = catalog.Current;

        _populating = true;
        ProviderBox.ItemsSource = _models.Select(m => m.Provider).Distinct().ToList();
        // Prefer the stored selection; otherwise start at the first provider.
        ProviderBox.SelectedItem = _current is not null
            && _models.Any(m => m.Provider == _current.Provider)
                ? _current.Provider
                : _models[0].Provider;
        _populating = false;

        // SelectionChanged was suppressed above, so fill the dependent
        // combos directly (provider -> models -> efforts).
        PopulateModels();

        SetLoading(false);
        ProviderBox.IsEnabled = true;
        ModelBox.IsEnabled = true;
        EffortBox.IsEnabled = true;
        Status($"{_models.Count} models with configured authentication.");
        SaveButton.IsEnabled = true;
    }

    /// <summary>Terminal failure: hide the spinner, keep combos disabled.</summary>
    private void Fail(string message)
    {
        SetLoading(false);
        Status(message, error: true);
    }

    private void SetLoading(bool loading)
    {
        LoadingBar.Visibility = loading ? Visibility.Visible : Visibility.Collapsed;
        if (loading)
        {
            ProviderBox.IsEnabled = false;
            ModelBox.IsEnabled = false;
            EffortBox.IsEnabled = false;
            SaveButton.IsEnabled = false;
        }
        // loading=false only hides the spinner; the caller enables
        // combos + Save on success, or leaves them disabled on failure.
    }

    private void OnProviderChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_populating) return;
        PopulateModels();
    }

    /// <summary>Fills the model combo for the selected provider and keeps
    /// the stored model selected when it lives in this provider.</summary>
    private void PopulateModels()
    {
        if (ProviderBox.SelectedItem is not string provider) return;

        var previousModelId = _current?.ModelId;
        _populating = true;
        var providerModels = _models.Where(m => m.Provider == provider)
            .OrderBy(m => m.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();
        ModelBox.ItemsSource = providerModels;
        // Keep showing the stored model when it lives in this provider.
        ModelBox.SelectedItem = providerModels.FirstOrDefault(m => m.Id == previousModelId)
            ?? providerModels.FirstOrDefault();
        _populating = false;

        PopulateEfforts();
    }

    private void OnModelChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_populating) return;
        PopulateEfforts();
    }

    /// <summary>Effort options come from the selected model itself
    /// (harness reports each model's supported thinking levels).</summary>
    private void PopulateEfforts()
    {
        if (ModelBox.SelectedItem is not ModelInfo model) return;

        ImageSupportLabel.Text = model.SupportsImages ? "Image input: supported" : "Image input: not supported";
        _populating = true;
        EffortBox.ItemsSource = model.ThinkingLevels;
        var stored = _current?.ThinkingLevel;
        EffortBox.SelectedItem = stored is not null && model.ThinkingLevels.Contains(stored)
            ? stored
            : model.ThinkingLevels.FirstOrDefault(); // "off" first — explicit choice.
        _populating = false;
    }

    private async void OnSaveClick(object sender, RoutedEventArgs e)
    {
        if (ProviderBox.SelectedItem is not string provider
            || ModelBox.SelectedItem is not ModelInfo model
            || EffortBox.SelectedItem is not string effort)
        {
            return;
        }

        SaveButton.IsEnabled = false;
        Status("Applying…");

        var error = await _invoker.SetModelAsync(provider, model.Id, effort);
        if (error is not null)
        {
            Status($"Not applied: {error}", error: true);
            SaveButton.IsEnabled = true; // Let the user correct or cancel.
            return;
        }

        Log.Info($"Settings page applied model {provider}/{model.Id} effort={effort}");
        Close();
    }

    /// <summary>Cancel = close without applying. Selections only take
    /// effect on Save, so nothing needs reverting.</summary>
    private void OnCancelClick(object sender, RoutedEventArgs e) => Close();

    private void Status(string message, bool error = false)
    {
        StatusText.Text = message;
        StatusText.Foreground = error
            ? System.Windows.Media.Brushes.IndianRed
            : new System.Windows.Media.SolidColorBrush(
                System.Windows.Media.Color.FromRgb(0x9E, 0x9E, 0x9E));
    }
}
