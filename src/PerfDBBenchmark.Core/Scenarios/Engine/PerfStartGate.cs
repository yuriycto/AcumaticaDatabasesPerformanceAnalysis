using System;
using System.Diagnostics;
using System.Globalization;
using System.Threading;

namespace PerfDBBenchmark.Core.Scenarios;

/// <summary>
/// Start gate for one parallel pass (SPEC §4.3). The W-th arrival records OpenedAtTicks and releases everyone.
/// Earlier arrivals wait at most the timeout; a timed-out worker aborts the gate ("WorkersNotStarted(k/W)").
/// A cooperative stop (run budget, operation cap, AbortBenchmark) also releases waiting workers.
/// </summary>
public sealed class PerfStartGate
{
    private static readonly TimeSpan WaitSlice = TimeSpan.FromMilliseconds(100);

    private readonly int _parties;
    private readonly TimeSpan _timeout;
    private readonly ManualResetEventSlim _open = new ManualResetEventSlim(false);
    private readonly object _abortSync = new object();
    private int _arrived;
    private long _openedAtTicks;
    private long _firstArrivalTicks;
    private volatile bool _aborted;
    private volatile bool _timedOut;
    private string _reason;

    public PerfStartGate(int parties, TimeSpan timeout)
    {
        if (parties < 1) throw new ArgumentOutOfRangeException(nameof(parties));
        _parties = parties;
        _timeout = timeout <= TimeSpan.Zero ? TimeSpan.FromSeconds(60) : timeout;
    }

    /// <summary>Number of workers the gate waits for.</summary>
    public int Parties => _parties;

    /// <summary>Number of workers that have arrived so far.</summary>
    public int Arrived => Volatile.Read(ref _arrived);

    public bool Aborted => _aborted;

    /// <summary>True when the gate was aborted because a worker waited longer than the timeout.</summary>
    public bool TimedOut => _timedOut;

    /// <summary>Stopwatch ticks of the moment the last worker arrived (0 while the gate is closed).</summary>
    public long OpenedAtTicks => Interlocked.Read(ref _openedAtTicks);

    /// <summary>Stopwatch ticks of the first arrival (used for ResultJson.workers.gateWaitMs).</summary>
    public long FirstArrivalTicks => Interlocked.Read(ref _firstArrivalTicks);

    public string Reason => _reason;

    /// <summary>Arrives and waits until all parties have arrived. Returns false when the gate was aborted
    /// (time-out or cooperative stop); the caller must then skip its operations.</summary>
    public bool ArriveAndWait()
    {
        if (_aborted) return false;

        var now = Stopwatch.GetTimestamp();
        var n = Interlocked.Increment(ref _arrived);
        if (n == 1) Interlocked.CompareExchange(ref _firstArrivalTicks, now, 0);

        if (n >= _parties)
        {
            // Opening and aborting are serialized, so a gate is never both opened and timed out.
            lock (_abortSync)
            {
                if (!_aborted) Interlocked.CompareExchange(ref _openedAtTicks, Stopwatch.GetTimestamp(), 0);
            }

            _open.Set();
            return !_aborted;
        }

        var deadline = Stopwatch.GetTimestamp() + (long)(_timeout.TotalSeconds * Stopwatch.Frequency);
        while (!_open.Wait(WaitSlice))
        {
            if (_aborted) return false;
            if (PerfRunControl.ShouldStop)
            {
                return !TryAbortClosed("Stopped(" + (PerfRunControl.StopReason ?? "stop") + ")", timedOut: false);
            }

            if (Stopwatch.GetTimestamp() > deadline)
            {
                return !TryAbortClosed(PerfInvalidReasons.WorkersNotStarted + "(" +
                                       Arrived.ToString(CultureInfo.InvariantCulture) + "/" + _parties.ToString(CultureInfo.InvariantCulture) + ")",
                                       timedOut: true);
            }
        }

        return !_aborted;
    }

    /// <summary>Aborts the gate only if it has not opened yet. Returns true when the gate is (now) aborted.</summary>
    private bool TryAbortClosed(string reason, bool timedOut)
    {
        lock (_abortSync)
        {
            if (Interlocked.Read(ref _openedAtTicks) != 0 && !_aborted) return false;   // the last worker arrived just now
            if (!_aborted)
            {
                _reason = reason;
                _timedOut = timedOut;
                _aborted = true;
            }
        }

        _open.Set();
        return true;
    }

    public void Abort(string reason)
    {
        lock (_abortSync)
        {
            if (!_aborted)
            {
                _reason = reason;
                _aborted = true;
            }
        }

        _open.Set();
    }
}
