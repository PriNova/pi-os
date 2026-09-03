using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using WindowsHarness.Contracts;
using WindowsHarness.Host.Diagnostics;

namespace WindowsHarness.Host.Http;

/// <summary>Parsed snapshot of one invocation record (protocol.md GET /invocations/{id}).</summary>
public sealed record InvocationStatus(string State, string? Activity, string? ResponseText, string? FailureMessage)
{
    public bool IsTerminal => State is "completed" or "failed" or "aborted" or "timed_out";
}

/// <summary>One model entry of the harness catalog (protocol.md GET /models).</summary>
public sealed record ModelInfo(
    string Provider, string Id, string Name, bool Reasoning, IReadOnlyList<string> ThinkingLevels);

/// <summary>Currently stored model preference; null when pi picks its default.</summary>
public sealed record ModelSelectionStatus(string Provider, string ModelId, string ThinkingLevel);

/// <summary>GET /models response.</summary>
public sealed record ModelCatalog(IReadOnlyList<ModelInfo> Models, ModelSelectionStatus? Current);

/// <summary>
/// Sends hotkey invocations to the local TypeScript agent harness
/// (protocol.md: POST /invoke on the node service), then polls the
/// invocation record until a terminal state so the overlay pill can show
/// live progress and the final result (ux-design-notes.md). Transport
/// failures are logged and reported as status values, never thrown into
/// the UI.
/// </summary>
public sealed class NodeInvoker
{
    public const string TokenEnvironmentVariable = "PI_OS_TOKEN";

    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(700);
    private const int MaxConsecutivePollErrors = 5;

    private readonly HttpClient _client;
    private readonly string? _token;

    /// <param name="token">Shared harness auth token. In production the
    /// supervisor passes its per-session token here; when omitted the host
    /// process environment (PI_OS_TOKEN) is consulted.</param>
    public NodeInvoker(string? token = null)
    {
        _token = string.IsNullOrEmpty(token)
            ? Environment.GetEnvironmentVariable(TokenEnvironmentVariable)
            : token;
        if (string.IsNullOrEmpty(_token))
        {
            Log.Warn("NodeInvoker has no auth token; the harness will reject invocations with HTTP 401.");
        }

        var baseUrl = Environment.GetEnvironmentVariable("PI_OS_NODE_URL")
            ?? "http://127.0.0.1:17832";
        _client = new HttpClient { BaseAddress = new Uri(baseUrl) };
    }

    /// <summary>Submits the invocation. Returns the invocation id on
    /// acceptance, null when the harness rejected or could not be reached.</summary>
    public async Task<string?> SendInvocationAsync(DesktopContextSnapshot snapshot, string prompt)
    {
        var payload = new
        {
            invocationId = $"inv-{Guid.NewGuid():N}",
            contextId = snapshot.Id,
            prompt,
            invokedAt = DateTimeOffset.UtcNow,
        };

        using var request = new HttpRequestMessage(HttpMethod.Post, "/invoke")
        {
            Content = new StringContent(JsonSerializer.Serialize(payload, ContractsJson.Options),
                Encoding.UTF8, "application/json"),
        };
        AddToken(request);

        try
        {
            using var response = await _client.SendAsync(request);
            if (response.IsSuccessStatusCode)
            {
                Log.Info($"Invocation {payload.invocationId} accepted by harness ({payload.contextId})");
                return payload.invocationId;
            }

            Log.Warn($"Harness rejected invocation: HTTP {(int)response.StatusCode}");
            return null;
        }
        catch (Exception ex)
        {
            Log.Error($"Failed to reach harness at {_client.BaseAddress}: {ex.Message}");
            return null;
        }
    }

    /// <summary>Fetches the pi model catalog for the settings page.
    /// Returns null on transport/protocol failure (reason is logged).</summary>
    public async Task<ModelCatalog?> GetModelsAsync()
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, "/models");
        AddToken(request);
        try
        {
            using var response = await _client.SendAsync(request);
            if (!response.IsSuccessStatusCode)
            {
                Log.Warn($"Model catalog rejected: HTTP {(int)response.StatusCode}");
                return null;
            }
            await using var stream = await response.Content.ReadAsStreamAsync();
            return await JsonSerializer.DeserializeAsync<ModelCatalog>(stream, ContractsJson.Options);
        }
        catch (Exception ex)
        {
            Log.Error($"Failed to fetch model catalog from {_client.BaseAddress}: {ex.Message}");
            return null;
        }
    }

    /// <summary>Applies the settings-page model choice. Returns null on
    /// success or a user-presentable failure reason.</summary>
    public async Task<string?> SetModelAsync(string provider, string modelId, string thinkingLevel)
    {
        var payload = new { provider, modelId, thinkingLevel };
        using var request = new HttpRequestMessage(HttpMethod.Post, "/settings/model")
        {
            Content = new StringContent(JsonSerializer.Serialize(payload, ContractsJson.Options),
                Encoding.UTF8, "application/json"),
        };
        AddToken(request);
        try
        {
            using var response = await _client.SendAsync(request);
            if (response.IsSuccessStatusCode)
            {
                Log.Info($"Model switch accepted by harness: {provider}/{modelId} effort={thinkingLevel}");
                return null;
            }
            var body = await response.Content.ReadAsStringAsync();
            var reason = ExtractErrorMessage(body) ?? $"HTTP {(int)response.StatusCode}";
            Log.Warn($"Model switch rejected: {reason}");
            return reason;
        }
        catch (Exception ex)
        {
            Log.Error($"Model switch failed to reach harness: {ex.Message}");
            return ex.Message;
        }
    }

    /// <summary>Pulls "error.message" out of the protocol error envelope.
    /// Responses never contain secrets or stack traces (protocol.md).</summary>
    private static string? ExtractErrorMessage(string body)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            if (document.RootElement.TryGetProperty("error", out var error) &&
                error.TryGetProperty("message", out var message) &&
                message.ValueKind == JsonValueKind.String)
            {
                return message.GetString();
            }
        }
        catch (JsonException)
        {
            // Fall through: non-JSON body.
        }
        return null;
    }

    /// <summary>Submits a sequential follow-up on the idle live session.
    /// Returns true when accepted (202); false when rejected or unreachable.</summary>
    public async Task<bool> SendFollowupAsync(string invocationId, string prompt)
    {
        var payload = new { prompt };
        using var request = new HttpRequestMessage(HttpMethod.Post, $"/invocations/{invocationId}/followup")
        {
            Content = new StringContent(JsonSerializer.Serialize(payload, ContractsJson.Options),
                Encoding.UTF8, "application/json"),
        };
        AddToken(request);
        try
        {
            using var response = await _client.SendAsync(request);
            if (!response.IsSuccessStatusCode)
            {
                Log.Warn($"Follow-up for {invocationId} rejected: HTTP {(int)response.StatusCode}");
            }
            return response.IsSuccessStatusCode;
        }
        catch (Exception ex)
        {
            Log.Error($"Follow-up for {invocationId} failed: {ex.Message}");
            return false;
        }
    }

    /// <summary>Disposes the live session (reader closed). Fire-and-forget.</summary>
    public async Task CloseAsync(string invocationId)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, $"/invocations/{invocationId}/close");
        AddToken(request);
        try
        {
            using var response = await _client.SendAsync(request);
            if (!response.IsSuccessStatusCode)
            {
                Log.Warn($"Close for {invocationId} rejected: HTTP {(int)response.StatusCode}");
            }
        }
        catch (Exception ex)
        {
            Log.Error($"Close for {invocationId} failed: {ex.Message}");
        }
    }

    /// <summary>Requests cancellation (pill ✕). Returns true when accepted.</summary>
    public async Task<bool> CancelAsync(string invocationId)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, $"/invocations/{invocationId}/cancel");
        AddToken(request);
        try
        {
            using var response = await _client.SendAsync(request);
            if (!response.IsSuccessStatusCode)
            {
                Log.Warn($"Cancel for {invocationId} rejected: HTTP {(int)response.StatusCode}");
            }
            return response.IsSuccessStatusCode;
        }
        catch (Exception ex)
        {
            Log.Error($"Cancel request for {invocationId} failed: {ex.Message}");
            return false;
        }
    }

    /// <summary>Polls GET /invocations/{id} until a terminal state, calling
    /// <paramref name="onUpdate"/> for every observed change. Returns the
    /// final status; a synthetic "failed" status is returned when the harness
    /// becomes unreachable or reports the record as unknown.</summary>
    public async Task<InvocationStatus> PollUntilTerminalAsync(
        string invocationId, Action<InvocationStatus>? onUpdate, CancellationToken cancellationToken = default)
    {
        InvocationStatus last = new("queued", null, null, null);
        var errorStreak = 0;

        while (!last.IsTerminal)
        {
            cancellationToken.ThrowIfCancellationRequested();

            InvocationStatus? current = null;
            try
            {
                current = await FetchInvocationAsync(invocationId);
                errorStreak = 0;
            }
            catch (Exception ex) when (ex is HttpRequestException or InvalidOperationException or JsonException)
            {
                errorStreak += 1;
                Log.Warn($"Poll {invocationId} failed ({errorStreak}/{MaxConsecutivePollErrors}): {ex.Message}");
                if (errorStreak >= MaxConsecutivePollErrors)
                {
                    current = Failed($"harness unreachable: {ex.Message}");
                }
            }

            if (current is not null && current != last)
            {
                last = current;
                try
                {
                    onUpdate?.Invoke(last);
                }
                catch (Exception ex)
                {
                    Log.Error($"Status callback failed: {ex.Message}");
                }
            }

            if (!last.IsTerminal)
            {
                await Task.Delay(PollInterval, cancellationToken);
            }
        }

        return last;
    }

    private async Task<InvocationStatus> FetchInvocationAsync(string invocationId)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/invocations/{invocationId}");
        AddToken(request);
        using var response = await _client.SendAsync(request);
        if (response.StatusCode == System.Net.HttpStatusCode.NotFound)
        {
            return Failed("unknown invocation (harness restarted?)");
        }
        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException($"HTTP {(int)response.StatusCode}");
        }

        await using var stream = await response.Content.ReadAsStreamAsync();
        using var document = await JsonDocument.ParseAsync(stream);
        var root = document.RootElement;

        var state = root.TryGetProperty("state", out var stateEl) && stateEl.ValueKind == JsonValueKind.String
            ? stateEl.GetString() ?? "queued"
            : "queued";
        return new InvocationStatus(
            State: state,
            Activity: OptionalString(root, "activity"),
            ResponseText: OptionalString(root, "responseText"),
            FailureMessage: OptionalString(root, "failureMessage"));
    }

    private static string? OptionalString(JsonElement element, string name)
    {
        return element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;
    }

    private static InvocationStatus Failed(string message) => new("failed", null, null, message);

    private HttpRequestMessage AddToken(HttpRequestMessage request)
    {
        if (!string.IsNullOrEmpty(_token))
        {
            request.Headers.Add("X-Harness-Token", _token);
        }

        return request;
    }
}
