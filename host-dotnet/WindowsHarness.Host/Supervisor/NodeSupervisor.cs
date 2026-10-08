using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using WindowsHarness.Host.Http;
using WindowsHarness.Host.Diagnostics;

namespace WindowsHarness.Host.Supervisor;

/// <summary>
/// Spawns the node harness as a supervised child process (O.3, handoff §18
/// topology): one launch covers C# host + node harness.
/// - Generates a per-host-session auth token and passes it via PI_OS_TOKEN.
/// - The child runs inside a job object with KILL_ON_JOB_CLOSE, so it dies
///   even if the host crashes or is force-killed.
/// - Opt out with PI_OS_SUPERVISOR=0 when running the harness manually
///   during development; point at a custom entry with PI_OS_NODE_ENTRY.
/// </summary>
internal sealed class NodeSupervisor : IDisposable
{
    private readonly IntPtr _job;
    private Process? _child;
    private bool _disposed;

    /// <summary>Token the child must send as X-Harness-Token (protocol.md).</summary>
    public string Token { get; } = LocalAuthentication.SessionToken(
        Environment.GetEnvironmentVariable("PI_OS_TOKEN"),
        Environment.GetEnvironmentVariable("PI_OS_SUPERVISOR") != "0",
        Environment.GetEnvironmentVariable("PI_OS_INSECURE_DEV") == "1");

    public NodeSupervisor()
    {
        _job = JobNative.CreateJobObjectW(IntPtr.Zero, null);
        var limits = new JobNative.JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        limits.BasicLimitInformation.LimitFlags =
            JobNative.JOB_OBJECT_LIMIT_KILL_ON_JOB_ON_CLOSE;
        _ = JobNative.SetInformationJobObject(
            _job,
            JobNative.JobObjectExtendedLimitInformationClass,
            ref limits,
            Marshal.SizeOf<JobNative.JOBOBJECT_EXTENDED_LIMIT_INFORMATION>());
    }

    public bool Start()
    {
        if ("0".Equals(Environment.GetEnvironmentVariable("PI_OS_SUPERVISOR"), StringComparison.OrdinalIgnoreCase))
        {
            Log.Info("Node supervisor disabled via PI_OS_SUPERVISOR=0");
            return false;
        }

        var entry = ResolveEntryScript();
        if (entry is null)
        {
            Log.Error(
                "Node harness entry not found. Build it once with 'npm run build' in " +
                "<repo>/node-harness (or set PI_OS_NODE_ENTRY to dist/index.js). " +
                "Continuing without agent invocations.");
            return false;
        }

        var startInfo = new ProcessStartInfo("node.exe", $"\"{entry}\"")
        {
            WorkingDirectory = Path.GetDirectoryName(entry)!,
            UseShellExecute = false,
            CreateNoWindow = true,
            // Pipe child logs into the host log: a silent harness is
            // undiagnosable (e.g. missing node_modules crashes instantly).
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        startInfo.Environment["PI_OS_TOKEN"] = Token;

        try
        {
            _child = Process.Start(startInfo);
        }
        catch (Win32Exception ex)
        {
            Log.Error($"Could not spawn node.exe ({ex.Message}). Is Node on PATH? Continuing without agent invocations.");
            return false;
        }

        if (_child is null)
        {
            Log.Error("Process.Start returned null for the node harness.");
            return false;
        }

        var pid = _child.Id;
        _ = JobNative.AssignProcessToJobObject(_job, _child.Handle);
        _child.EnableRaisingEvents = true;
        _child.Exited += (_, _) => Log.Warn($"Node harness exited unexpectedly (pid={pid})");
        _child.OutputDataReceived += (_, e) => { if (e.Data is not null) { Log.Info($"[node] {e.Data}"); } };
        _child.ErrorDataReceived += (_, e) => { if (e.Data is not null) { Log.Info($"[node] {e.Data}"); } };
        _child.BeginOutputReadLine();
        _child.BeginErrorReadLine();

        Log.Info($"Node harness spawned as child (pid={pid}, entry={entry})");
        return true;
    }

    private static string? ResolveEntryScript()
    {
        var overridden = Environment.GetEnvironmentVariable("PI_OS_NODE_ENTRY");
        if (!string.IsNullOrWhiteSpace(overridden))
        {
            return File.Exists(overridden) ? Path.GetFullPath(overridden) : null;
        }

        // Prefer a candidate whose package imports can actually resolve.
        // A bare dist copy without node_modules (e.g. the build output
        // beside the exe during development) crashes instantly on
        // ERR_MODULE_NOT_FOUND, so it must lose to the provisioned source.
        string? fallback = null;
        foreach (var candidate in EnumerateCandidateEntries())
        {
            if (!File.Exists(candidate))
            {
                continue;
            }

            fallback ??= candidate;
            if (HarnessDepsResolvable(candidate))
            {
                return candidate;
            }
            Log.Warn($"Skipping harness candidate without node_modules: {candidate}");
        }

        return fallback; // Surface the dep error via the piped child logs.
    }

    /// <summary>Entry candidates in priority order: exe-adjacent copy
    /// (installed layout), then the dev walk-up to the repo root.</summary>
    private static IEnumerable<string> EnumerateCandidateEntries()
    {
        var baseDir = AppContext.BaseDirectory;
        yield return Path.Combine(baseDir, "node-harness", "dist", "index.js");

        // Walk-up starts at the parent: BaseDirectory itself is already
        // covered by the exe-adjacent candidate above.
        var dir = new DirectoryInfo(baseDir).Parent;
        while (dir is not null)
        {
            yield return Path.Combine(dir.FullName, "node-harness", "dist", "index.js");
            dir = dir.Parent;
        }
    }

    /// <summary>True when the pi SDK package resolves from the entry's
    /// node-harness directory (marker: node_modules/@earendil-works/...).</summary>
    private static bool HarnessDepsResolvable(string entry)
    {
        // ...\node-harness\dist\index.js -> ...\node-harness
        var harnessDir = Path.GetDirectoryName(Path.GetDirectoryName(entry));
        if (harnessDir is null)
        {
            return false;
        }

        var marker = Path.Combine(harnessDir, "node_modules", "@earendil-works", "pi-coding-agent");
        return Directory.Exists(marker);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;

        if (_child is { HasExited: false } child)
        {
            try
            {
                child.Kill(entireProcessTree: true);
                Log.Info("Node harness stopped");
            }
            catch (Exception ex)
            {
                Log.Error($"Failed to stop node harness: {ex.Message}");
            }
        }
        _child?.Dispose();

        // Closing the last job handle kills assigned processes even if the
        // graceful Kill above failed (or never ran because of a crash path).
        _ = JobNative.CloseHandle(_job);
    }

    /// <summary>
    /// Minimal kernel32 job-object interop. Deliberately classic DllImport:
    /// CsWin32's friendly overloads differ (SafeFileHandle returns) without
    /// adding value for this narrow use.
    /// </summary>
    private static class JobNative
    {
        internal const int JobObjectExtendedLimitInformationClass = 9; // JOBOBJECTINFOCLASS
        internal const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_ON_CLOSE = 0x00002000;

        [StructLayout(LayoutKind.Sequential)]
        internal struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern IntPtr CreateJobObjectW(IntPtr lpJobAttributes, string? lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool SetInformationJobObject(
            IntPtr hJob,
            int jobObjectInfoClass,
            ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION lpJobObjectInformation,
            int cbJobObjectInformationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool CloseHandle(IntPtr hObject);
    }
}
