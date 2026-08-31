using System.IO;
using System.Windows;

namespace WindowsHarness.Host.Diagnostics;

/// <summary>
/// Minimal file + console logging for development.
/// Structured per-invocation logs arrive later (tracker X.1).
/// </summary>
public static class Log
{
    private static readonly object Gate = new();
    private static readonly string LogDir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "pi-os", "logs");

    public static void Info(string message) => Write("INFO ", message);
    public static void Warn(string message) => Write("WARN ", message);
    public static void Error(string message) => Write("ERROR", message);

    private static void Write(string level, string message)
    {
        var line = $"{DateTimeOffset.Now:yyyy-MM-dd'T'HH:mm:ss.fffzzz} [{level}] {message}";
        lock (Gate)
        {
            Console.WriteLine(line);
            try
            {
                Directory.CreateDirectory(LogDir);
                File.AppendAllText(Path.Combine(LogDir, "host.log"), line + Environment.NewLine);
            }
            catch (IOException)
            {
                // Logging must never take the host down.
            }
        }
    }
}
