using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using WindowsHarness.Host.Automation;
using WindowsHarness.Host.Context;
using WindowsHarness.Host.Diagnostics;

namespace WindowsHarness.Host.Http;

/// <summary>
/// Localhost tool API of the C# host (protocol.md). Uniform dispatch through
/// POST /tools/{toolName}; tool outcomes are data (ok:false), transport
/// errors are HTTP status codes. Bound to loopback only.
/// </summary>
public sealed class HostApiServer
{
    private const string Version = "0.1.0";

    private static readonly System.Diagnostics.Stopwatch StartedAt = System.Diagnostics.Stopwatch.StartNew();
    private static readonly HashSet<string> KnownTools =
    [
        "desktop.getContext", "desktop.refreshContext", "desktop.captureWindow",
        "window.focus", "input.click", "input.typeText", "input.pressKey", "input.keyChord", "input.scroll",
    ];

    private readonly ContextStore _store;
    private readonly CapturePipeline _pipeline;
    private readonly ComputerUseService _computerUse;
    private readonly string _token;
    private readonly bool _insecureDev;

    public HostApiServer(ContextStore store, CapturePipeline pipeline, string token)
    {
        _store = store;
        _pipeline = pipeline;
        _token = token;
        _insecureDev = Environment.GetEnvironmentVariable("PI_OS_INSECURE_DEV") == "1";
        _computerUse = new ComputerUseService(store, new WindowInfoService());
    }

    /// <summary>Blocks the calling thread; run on a background task.</summary>
    public void Run()
    {
        var builder = WebApplication.CreateBuilder();
        builder.WebHost.UseUrls($"http://127.0.0.1:{Port()}");

        // Keep the wire format identical to ContractsJson.Options.
        builder.Services.ConfigureHttpJsonOptions(options =>
        {
            options.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
            options.SerializerOptions.PropertyNameCaseInsensitive = true;
            options.SerializerOptions.DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull;
            options.SerializerOptions.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
        });

        var app = builder.Build();
        app.Use(async (context, next) =>
        {
            if (context.Request.Path != "/health" && !Authorized(context.Request))
            {
                await FailEnvelope("unauthorized", "Missing or wrong X-Harness-Token", 401).ExecuteAsync(context);
                return;
            }
            await next(context);
        });

        app.MapGet("/health", () => Results.Json(new
        {
            service = "windows-host",
            version = Version,
            uptimeSeconds = StartedAt.ElapsedMilliseconds / 1000,
        }));

        app.MapGet("/tools", () => Results.Json(new
        {
            tools = new object[]
            {
                Descriptor("desktop.getContext", "Returns the pinned snapshot for a contextId.", ["contextId"]),
                Descriptor("desktop.refreshContext", "Re-captures window/UIA metadata for the pinned target window.", ["contextId"]),
                Descriptor("desktop.captureWindow", "Captures a fresh screenshot of the pinned target window.", ["contextId"]),
                Descriptor("window.focus", "Focuses the pinned target window.", ["contextId"]),
                Descriptor("input.click", "Left-clicks screenshot-relative coordinates in the pinned target.", ["contextId", "x", "y"], ["x", "y"]),
                Descriptor("input.typeText", "Types Unicode text into the pinned target.", ["contextId", "text"]),
                Descriptor("input.pressKey", "Presses one supported key in the pinned target.", ["contextId", "key"]),
                Descriptor("input.keyChord", "Presses a supported key with ctrl, alt, and/or shift.", ["contextId", "key", "modifiers"], arrays: ["modifiers"]),
                Descriptor("input.scroll", "Scrolls at optional screenshot-relative x/y coordinates; deltas are wheel notches.", ["contextId"], ["deltaX", "deltaY", "x", "y"]),
            },
        }));

        app.MapPost("/tools/{toolName}", async (string toolName, HttpRequest request) =>
        {
            if (!Authorized(request))
            {
                return FailEnvelope("unauthorized", "Missing or wrong X-Harness-Token", 401);
            }

            JsonElement arguments;
            try
            {
                using var document = await JsonDocument.ParseAsync(request.Body);
                arguments = document.RootElement.Clone();
            }
            catch (JsonException)
            {
                return OkOrFailEnvelope("invalid_arguments", "Body must be JSON");
            }

            try
            {
                if (!KnownTools.Contains(toolName))
                {
                    return OkOrFailEnvelope("not_found", $"Unknown tool '{toolName}'.");
                }

                var (contextId, args) = ParseArgs(arguments);
                if (toolName.StartsWith("desktop.", StringComparison.Ordinal))
                {
                    var snapshot = _store.Get(contextId);
                    if (snapshot is null)
                    {
                        return OkOrFailEnvelope("unknown_context", $"Unknown or expired context '{contextId}'.");
                    }
                    if (!ComputerUseService.TargetStillValid(snapshot.TargetWindow))
                    {
                        return OkOrFailEnvelope("target_gone",
                            $"HWND {snapshot.TargetWindow?.Hwnd} no longer exists or changed process.");
                    }

                    return toolName switch
                    {
                        "desktop.getContext" => OkEnvelope(snapshot),
                        "desktop.refreshContext" => await WithResultAsync(() => _pipeline.RefreshAsync(snapshot)),
                        "desktop.captureWindow" => await WithResultAsync(() => _pipeline.CaptureScreenshotAsync(snapshot)),
                        _ => OkOrFailEnvelope("not_found", $"Unknown tool '{toolName}'."),
                    };
                }

                var cancellation = request.HttpContext.RequestAborted;
                var result = toolName switch
                {
                    "window.focus" => await _computerUse.FocusAsync(contextId, cancellation),
                    "input.click" => await _computerUse.ClickAsync(contextId,
                        RequiredNumber(args, "x"), RequiredNumber(args, "y"), cancellation),
                    "input.typeText" => await _computerUse.TypeTextAsync(contextId,
                        RequiredString(args, "text"), cancellation),
                    "input.pressKey" => await _computerUse.PressKeyAsync(contextId,
                        RequiredString(args, "key"), cancellation),
                    "input.keyChord" => await _computerUse.KeyChordAsync(contextId,
                        RequiredString(args, "key"), RequiredStrings(args, "modifiers"), cancellation),
                    "input.scroll" => await _computerUse.ScrollAsync(contextId,
                        OptionalNumber(args, "deltaX"), OptionalNumber(args, "deltaY"),
                        OptionalNullableNumber(args, "x"), OptionalNullableNumber(args, "y"), cancellation),
                    _ => throw new ComputerUseException("internal_error", "Unhandled tool."),
                };
                Log.Info($"Computer Use {toolName} completed ({contextId}).");
                return OkEnvelope(result);
            }
            catch (ArgumentException ex)
            {
                return OkOrFailEnvelope("invalid_arguments", ex.Message);
            }
            catch (ComputerUseException ex)
            {
                Log.Warn($"Computer Use {toolName} rejected: {ex.Code}.");
                return OkOrFailEnvelope(ex.Code, ex.Message);
            }
            catch (OperationCanceledException)
            {
                return OkOrFailEnvelope("busy", "Operation was cancelled before it could complete.");
            }
            catch (Exception ex)
            {
                Log.Error($"Tool {toolName} failed: {ex}");
                return OkOrFailEnvelope("internal_error", "Unexpected host failure.");
            }
        });

        Log.Info($"Host tool API listening on http://127.0.0.1:{Port()}");
        app.Run();
    }

    private static int Port()
    {
        return int.TryParse(Environment.GetEnvironmentVariable("PI_OS_HOST_PORT"), out var port) ? port : 17831;
    }

    private bool Authorized(HttpRequest request) =>
        LocalAuthentication.Authorized(request.Headers["X-Harness-Token"].ToString(), _token, _insecureDev);

    /// <summary>Body shape per protocol.md: {"arguments":{"contextId":"..."}}.</summary>
    private static (string ContextId, JsonElement Arguments) ParseArgs(JsonElement body)
    {
        if (body.ValueKind != JsonValueKind.Object
            || !body.TryGetProperty("arguments", out var arguments)
            || arguments.ValueKind != JsonValueKind.Object
            || !arguments.TryGetProperty("contextId", out var value)
            || value.ValueKind != JsonValueKind.String
            || value.GetString() is not { Length: > 0 } id)
        {
            throw new ArgumentException("'arguments.contextId' (string) is required.");
        }

        return (id, arguments);
    }

    private static string RequiredString(JsonElement args, string name)
    {
        if (!args.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.String)
            throw new ArgumentException($"'arguments.{name}' (string) is required.");
        return value.GetString()!;
    }

    private static double RequiredNumber(JsonElement args, string name)
    {
        if (!args.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number
            || !value.TryGetDouble(out var number) || !double.IsFinite(number))
            throw new ArgumentException($"'arguments.{name}' (finite number) is required.");
        return number;
    }

    private static double OptionalNumber(JsonElement args, string name) =>
        args.TryGetProperty(name, out var value) ? RequiredNumber(args, name) : 0;

    private static double? OptionalNullableNumber(JsonElement args, string name) =>
        args.TryGetProperty(name, out _) ? RequiredNumber(args, name) : null;

    private static IReadOnlyList<string> RequiredStrings(JsonElement args, string name)
    {
        if (!args.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Array)
            throw new ArgumentException($"'arguments.{name}' (non-empty string array) is required.");
        var result = new List<string>();
        foreach (var item in value.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String || item.GetString() is not { Length: > 0 } text)
                throw new ArgumentException($"'arguments.{name}' must contain strings.");
            result.Add(text);
        }
        if (result.Count == 0) throw new ArgumentException($"'arguments.{name}' must not be empty.");
        return result;
    }

    private static IResult OkEnvelope(object result) => Results.Json(new { ok = true, result });

    private static IResult OkOrFailEnvelope(string code, string message) =>
        Results.Json(new { ok = false, error = new { code, message } });

    private static IResult FailEnvelope(string code, string message, int status) =>
        Results.Json(new { error = new { code, message } }, statusCode: status);

    private static async Task<IResult> WithResultAsync<T>(Func<Task<T?>> action) where T : class
    {
        var result = await action();
        return result is not null
            ? OkEnvelope(result)
            : OkOrFailEnvelope("capture_failed", "Operation failed; see host log.");
    }

    private static object Descriptor(string name, string description, string[] requiredArgs,
        string[]? numbers = null, string[]? arrays = null)
    {
        numbers ??= [];
        arrays ??= [];
        var propertyNames = requiredArgs.Concat(numbers).Concat(arrays).Distinct();
        return new
        {
            name,
            description,
            inputSchema = new
            {
                type = "object",
                properties = propertyNames.ToDictionary(argument => argument, argument =>
                    arrays.Contains(argument)
                        ? (object)new { type = "array", items = new { type = "string" } }
                        : new { type = numbers.Contains(argument) ? "number" : "string" }),
                @required = requiredArgs,
            },
        };
    }
}
