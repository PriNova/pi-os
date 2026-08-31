using System.Text.Json;
using System.Text.Json.Serialization;

namespace WindowsHarness.Contracts;

/// <summary>
/// Serializer settings that produce the shared camelCase wire format.
/// All HTTP endpoints and sidecar channels must use these options so the
/// JSON matches shared/schemas/desktop-context.ts regardless of local config.
/// </summary>
public static class ContractsJson
{
    public static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web)
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };
}
