using System;
using System.Threading;
using PX.Data.ReducedMode;

namespace PerfDBBenchmark.Core.Scenarios;

/// <summary>
/// Throttler passed to every benchmark ProcessItemsParallel call (SPEC §0.3 #19, §2.1 F30, review-api C1).
/// Benchmarks are never throttled. ProcessItemsParallel calls Reduce() after every item without a null check,
/// so a real instance is always passed.
/// </summary>
internal sealed class PerfNoOpThrottler : IReducedModeThrottler
{
    public static readonly PerfNoOpThrottler Instance = new PerfNoOpThrottler();

    private PerfNoOpThrottler()
    {
    }

    public System.Threading.Tasks.Task ReduceAsync(TimeSpan requestDuration, CancellationToken cancellationToken) =>
        System.Threading.Tasks.Task.CompletedTask;

    public void Reduce(TimeSpan requestDuration, CancellationToken cancellationToken)
    {
    }
}
