using System.Collections.Concurrent;
using WindowsHarness.Contracts;
using WindowsHarness.Host.Diagnostics;

namespace WindowsHarness.Host.Context;

/// <summary>
/// Short-lived in-memory store of pinned context snapshots (handoff section 4.2).
/// Snapshots expire so stale captures cannot be acted on much later.
/// </summary>
public sealed class ContextStore : IDisposable
{
    private static readonly TimeSpan TimeToLive = TimeSpan.FromMinutes(30);
    private static readonly TimeSpan SweepInterval = TimeSpan.FromMinutes(5);

    private readonly ConcurrentDictionary<string, (DesktopContextSnapshot Snapshot, DateTimeOffset CreatedAt)> _snapshots = new();
    private readonly Timer _sweeper;

    public ContextStore()
    {
        _sweeper = new Timer(_ => SweepExpired(), null, SweepInterval, SweepInterval);
    }

    public string NewId() => $"ctx-{Guid.NewGuid():N}";

    public void Put(DesktopContextSnapshot snapshot) =>
        _snapshots[snapshot.Id] = (snapshot, DateTimeOffset.UtcNow);

    public DesktopContextSnapshot? Get(string id)
    {
        if (!_snapshots.TryGetValue(id, out var entry))
        {
            return null;
        }

        if (DateTimeOffset.UtcNow - entry.CreatedAt > TimeToLive)
        {
            _snapshots.TryRemove(id, out _);
            Log.Warn($"Context {id} expired");
            return null;
        }

        return entry.Snapshot;
    }

    private void SweepExpired()
    {
        foreach (var (id, entry) in _snapshots)
        {
            if (DateTimeOffset.UtcNow - entry.CreatedAt > TimeToLive)
            {
                _snapshots.TryRemove(id, out _);
            }
        }
    }

    public void Dispose() => _sweeper.Dispose();
}
