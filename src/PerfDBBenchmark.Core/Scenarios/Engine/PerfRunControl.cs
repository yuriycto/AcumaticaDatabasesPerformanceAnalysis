using System;
using System.Diagnostics;
using System.Threading;
using PX.Data;

namespace PerfDBBenchmark.Core.Scenarios;

/// <summary>
/// One benchmark run per AppDomain, plus the cooperative stop used by the run budget, the operation cap and the
/// AbortBenchmark action (SPEC §1.3.4, §4.2, §4.7). ShouldStop is a volatile read plus one Stopwatch comparison
/// and is never called inside a timed region.
/// </summary>
public static class PerfRunControl
{
    /// <summary>StopReason value set by RequestAbort.</summary>
    public const string AbortedReason = "aborted";

    /// <summary>A reservation made by the action thread that is never claimed by Begin is released after this time.</summary>
    private static readonly TimeSpan ReservationTimeout = TimeSpan.FromMinutes(2);

    private static readonly object Sync = new object();

    // Guarded by Sync (writes); read with Volatile where noted.
    private static Guid _currentId;            // Guid.Empty = nothing reserved or running
    private static bool _begun;                // true once Begin claimed the slot
    private static long _reservedAtTicks;
    private static string _abortRequestReason;

    private static volatile string _stopReason; // null | runBudget | operationCap | aborted
    private static long _budgetDeadlineTicks;    // 0 = no budget clock

    /// <summary>True while a run (or a clear action) is reserved or in progress in this AppDomain.</summary>
    public static bool IsRunning
    {
        get
        {
            lock (Sync)
            {
                ExpireStaleReservation();
                return _currentId != Guid.Empty;
            }
        }
    }

    public static Guid? CurrentRequestId
    {
        get
        {
            lock (Sync)
            {
                ExpireStaleReservation();
                return _currentId == Guid.Empty ? (Guid?)null : _currentId;
            }
        }
    }

    /// <summary>Why the run was asked to stop: null, PerfCappedKinds.RunBudget, PerfCappedKinds.OperationCap or "aborted".
    /// Reading it never evaluates the budget clock (use ShouldStop for that).</summary>
    public static string StopReason => _stopReason;

    /// <summary>The text passed to RequestAbort, for notes.</summary>
    public static string AbortRequestReason
    {
        get { lock (Sync) return _abortRequestReason; }
    }

    /// <summary>Checked before every operation and every pass. Sets StopReason = runBudget when the budget is used up.</summary>
    public static bool ShouldStop
    {
        get
        {
            if (_stopReason != null) return true;
            var deadline = Interlocked.Read(ref _budgetDeadlineTicks);
            if (deadline != 0 && Stopwatch.GetTimestamp() > deadline)
            {
                SetStopReason(PerfCappedKinds.RunBudget);
                return true;
            }

            return false;
        }
    }

    /// <summary>Reserves the run slot from the action thread before the long operation starts, so a second
    /// RunBenchmark arriving before the long operation begins is refused. Returns false when the slot is taken.</summary>
    internal static bool TryReserve(Guid requestId)
    {
        if (requestId == Guid.Empty) throw new ArgumentException("Empty request id.", nameof(requestId));
        lock (Sync)
        {
            ExpireStaleReservation();
            if (_currentId != Guid.Empty) return false;
            ResetState();
            _currentId = requestId;
            _begun = false;
            _reservedAtTicks = Stopwatch.GetTimestamp();
            return true;
        }
    }

    /// <summary>Releases a reservation whose long operation could not be started.</summary>
    internal static void CancelReservation(Guid requestId)
    {
        lock (Sync)
        {
            if (_currentId == requestId && !_begun)
            {
                _currentId = Guid.Empty;
                ResetState();
            }
        }
    }

    /// <summary>Marks the run in progress (claiming a reservation with the same id, if any).
    /// Throws PXException when another run is already in progress. Dispose clears everything.</summary>
    public static IDisposable Begin(Guid requestId)
    {
        if (requestId == Guid.Empty) throw new ArgumentException("Empty request id.", nameof(requestId));
        lock (Sync)
        {
            ExpireStaleReservation();
            if (_currentId == requestId && !_begun)
            {
                _begun = true;   // claim our own reservation; keep an abort that arrived in between
            }
            else if (_currentId == Guid.Empty)
            {
                ResetState();
                _currentId = requestId;
                _begun = true;
            }
            else
            {
                throw new PXException("A benchmark run is already in progress on this instance.");
            }

            Interlocked.Exchange(ref _budgetDeadlineTicks, 0);
        }

        return new Scope(requestId);
    }

    /// <summary>Starts the run budget clock (called by the runner after CreateWorkerState).</summary>
    public static void StartBudgetClock(TimeSpan budget)
    {
        if (budget <= TimeSpan.Zero) budget = PerfRunPlan.DefaultRunBudget;
        var ticks = (long)Math.Min(budget.TotalSeconds * Stopwatch.Frequency, long.MaxValue / 4.0);
        Interlocked.Exchange(ref _budgetDeadlineTicks, Stopwatch.GetTimestamp() + ticks);
    }

    /// <summary>AbortBenchmark action: asks the run in progress to stop after the current operations. False when nothing runs.</summary>
    public static bool RequestAbort(string reason)
    {
        lock (Sync)
        {
            ExpireStaleReservation();
            if (_currentId == Guid.Empty) return false;
            _abortRequestReason = reason;
        }

        SetStopReason(AbortedReason);
        return true;
    }

    /// <summary>Stops every worker after its current operation (operation cap).</summary>
    public static void Stop(string cappedKind)
    {
        SetStopReason(string.IsNullOrEmpty(cappedKind) ? PerfCappedKinds.OperationCap : cappedKind);
    }

    private static void SetStopReason(string reason)
    {
        // First reason wins.
        lock (Sync)
        {
            if (_stopReason == null) _stopReason = reason;
        }
    }

    private static void ResetState()
    {
        _stopReason = null;
        _abortRequestReason = null;
        Interlocked.Exchange(ref _budgetDeadlineTicks, 0);
    }

    private static void ExpireStaleReservation()
    {
        if (_currentId == Guid.Empty || _begun) return;
        var age = Stopwatch.GetTimestamp() - _reservedAtTicks;
        if (age > (long)(ReservationTimeout.TotalSeconds * Stopwatch.Frequency))
        {
            _currentId = Guid.Empty;
            ResetState();
        }
    }

    private static void End(Guid requestId)
    {
        lock (Sync)
        {
            if (_currentId != requestId) return;
            _currentId = Guid.Empty;
            _begun = false;
            ResetState();
        }
    }

    private sealed class Scope : IDisposable
    {
        private readonly Guid _id;
        private int _disposed;

        public Scope(Guid id) => _id = id;

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) == 0) End(_id);
        }
    }
}
