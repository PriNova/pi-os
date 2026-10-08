using System.Security.Cryptography;
using System.Text;

namespace WindowsHarness.Host.Http;

internal static class LocalAuthentication
{
    internal static string SessionToken(string? configured, bool supervised, bool insecureDev)
    {
        if (!string.IsNullOrWhiteSpace(configured)) return configured;
        if (supervised) return Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
        if (insecureDev) return "";
        throw new InvalidOperationException("Split development requires PI_OS_TOKEN in both processes (or explicit PI_OS_INSECURE_DEV=1).");
    }

    internal static bool Authorized(string? supplied, string expected, bool insecureDev)
    {
        if (string.IsNullOrEmpty(expected)) return insecureDev;
        if (supplied is null) return false;
        return CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(supplied), Encoding.UTF8.GetBytes(expected));
    }
}
