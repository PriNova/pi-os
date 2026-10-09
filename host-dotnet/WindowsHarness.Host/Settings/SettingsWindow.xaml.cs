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
    private readonly NodeInvoker _invoker;
    private IReadOnlyList<ModelInfo> _models = [];
    private ModelSelectionStatus? _current;
    /// <summary>True while combos are populated programmatically.</summary>
    private bool _populating;

    public SettingsWindow(NodeInvoker invoker)
    {
        InitializeComponent();
        _invoker = invoker;
        Loaded += (_, _) => _ = LoadAsync();
    }

    private async Task LoadAsync()
    {
        Status("Loading models from the agent harness…");
        SaveButton.IsEnabled = false;

        var catalog = await _invoker.GetModelsAsync();
        if (catalog is null)
        {
            Status("Could not reach the agent harness (port 17832). "
                + "Make sure pi-os is running, then reopen settings.", error: true);
            return;
        }
        if (catalog.Models.Count == 0)
        {
            Status("No models available. Configure provider authentication first "
                + "(pi /login or a provider API key), then reopen settings.", error: true);
            return;
        }

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

        Status($"{_models.Count} models with configured authentication.");
        SaveButton.IsEnabled = true;
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
