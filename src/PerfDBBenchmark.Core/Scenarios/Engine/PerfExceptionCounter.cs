using System;
using System.Runtime.CompilerServices;
using System.Runtime.ExceptionServices;
using System.Threading;
using PX.Data;

namespace PerfDBBenchmark.Core.Scenarios;

/// <summary>
/// Counts deadlocks, time-outs, lock violations and retries raised inside measured operations (SPEC §1.3.5, §4.6).
/// One FirstChanceException subscription per AppDomain; a [ThreadStatic] marker set by the engine around each measured
/// operation points at the run's counters, so only worker threads of the current run count, and concurrent runs cannot
/// cross-count. Each exception object is counted once per run (the CLR raises FirstChanceException again on every rethrow).
/// The handler never throws and allocates only for the first sighting of a counted exception.
/// </summary>
public static class PerfExceptionCounter
{
    /// <summary>Compile-time switch (SPEC §8 R19). When false, the counts are written as null and errors.countersEnabled = false.</summary>
    internal const bool Enabled = true;

    private static readonly object Seen = new object();
    private static int _subscribed;

    [ThreadStatic] private static RunCounters _marker;
    [ThreadStatic] private static bool _inHandler;

    /// <summary>Per-run counters (one instance per run).</summary>
    internal sealed class RunCounters
    {
        internal int Deadlocks;
        internal int Timeouts;
        internal int LockViolations;
        internal int Retries;
        internal readonly ConditionalWeakTable<Exception, object> SeenExceptions = new ConditionalWeakTable<Exception, object>();
        internal volatile bool Closed;
    }

    /// <summary>Creates the counters of one run and makes sure the handler is subscribed.</summary>
    internal static RunCounters Begin()
    {
        if (Enabled && Interlocked.Exchange(ref _subscribed, 1) == 0)
        {
            AppDomain.CurrentDomain.FirstChanceException += OnFirstChanceException;
        }

        return new RunCounters();
    }

    /// <summary>Marks the current thread as running a measured operation of the given run (null = not measuring).</summary>
    internal static void MarkThread(RunCounters run) => _marker = run;

    internal static void UnmarkThread() => _marker = null;

    /// <summary>Closes the run: later first-chance exceptions on still-marked threads are ignored.</summary>
    internal static void End(RunCounters run)
    {
        if (run != null) run.Closed = true;
    }

    private static void OnFirstChanceException(object sender, FirstChanceExceptionEventArgs e)
    {
        var run = _marker;
        if (run == null || run.Closed || _inHandler) return;

        _inHandler = true;
        try
        {
            var ex = e.Exception;
            bool deadlock = false, timeout = false, lockViolation = false, retry = false;

            if (ex is PXDatabaseException dbe)
            {
                if (dbe.ErrorCode == PXDbExceptions.Deadlock) deadlock = true;
                else if (dbe.ErrorCode == PXDbExceptions.Timeout) timeout = true;
                else return;
                retry = dbe.Retry;
            }
            else if (ex is PXLockViolationException lve)
            {
                lockViolation = true;
                retry = lve.Retry;
            }
            else
            {
                return;
            }

            lock (Seen)
            {
                if (run.SeenExceptions.TryGetValue(ex, out _)) return;
                run.SeenExceptions.Add(ex, Seen);
            }

            if (deadlock) Interlocked.Increment(ref run.Deadlocks);
            if (timeout) Interlocked.Increment(ref run.Timeouts);
            if (lockViolation) Interlocked.Increment(ref run.LockViolations);
            if (retry) Interlocked.Increment(ref run.Retries);
        }
        catch
        {
            // The handler must never throw.
        }
        finally
        {
            _inHandler = false;
        }
    }
}
