using WindowsHarness.Contracts;

namespace WindowsHarness.Host.Automation;

/// <summary>Small fail-closed policy for first-party pinned-window input.</summary>
public static class ComputerUsePolicy
{
    private static readonly HashSet<string> BlockedProcesses = new(StringComparer.OrdinalIgnoreCase)
    {
        "WindowsHarness.Host", "pi", "pi-android", "ChatGPT", "Codex",
        "WindowsTerminal", "wt", "cmd", "powershell", "pwsh", "conhost", "mintty", "bash", "wsl",
        "1Password", "Bitwarden", "KeePass", "KeePassXC",
        "SecHealthUI", "SecurityHealthSystray", "MsMpEng", "NisSrv",
        "CredentialUIBroker", "consent", "LogonUI", "NgcIso", "UserOOBEBroker",
        "StartMenuExperienceHost", "SearchHost", "SearchApp",
    };

    private static readonly HashSet<string> BlockedClasses = new(StringComparer.OrdinalIgnoreCase)
    {
        "Credential Dialog Xaml Host",
    };

    public static void EnsureAllowed(WindowContext target)
    {
        if (target.IsElevated is not false)
        {
            throw new ComputerUseException("target_elevated", "Pinned target integrity could not be verified as non-elevated.");
        }

        var process = target.ProcessName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
            ? target.ProcessName[..^4]
            : target.ProcessName;
        if (BlockedProcesses.Contains(process)
            || (!string.IsNullOrEmpty(target.ClassName) && BlockedClasses.Contains(target.ClassName))
            || IsRunDialog(target))
        {
            throw new ComputerUseException("policy_blocked", "Computer Use is blocked for this target.");
        }
    }


    private static bool IsRunDialog(WindowContext target) =>
        string.Equals(target.ProcessName, "explorer", StringComparison.OrdinalIgnoreCase)
        && string.Equals(target.ClassName, "#32770", StringComparison.OrdinalIgnoreCase)
        && string.Equals(target.Title, "Run", StringComparison.OrdinalIgnoreCase);
}

public sealed class ComputerUseException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}
