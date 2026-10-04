using System;
using System.Data.Common;
using System.Reflection;
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
/// Separately, BeginOperation/EndOperation tell the engine whether a failed operation (warm-up included) met a contention
/// exception, so contention errors can be told apart from broken operations (SPEC §4.4 rule 7b).
/// </summary>
public static class PerfExceptionCounter
{
    /// <summary>Compile-time switch (SPEC §8 R19). When false, the counts are written as null and errors.countersEnabled = false.</summary>
    internal const bool Enabled = true;

    private static readonly object Seen = new object();
    private static int _subscribed;

    [ThreadStatic] private static RunCounters _marker;
    [ThreadStatic] private static bool _inHandler;
    [ThreadStatic] private static bool _opTracking;
    [ThreadStatic] private static bool _opContention;

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
        EnsureSubscribed();
        return new RunCounters();
    }

    private static void EnsureSubscribed()
    {
        // Volatile read first: BeginOperation calls this for every operation on every worker, and an unconditional
        // Interlocked.Exchange would make them all write the same cache line.
        if (Enabled && Volatile.Read(ref _subscribed) == 0 && Interlocked.Exchange(ref _subscribed, 1) == 0)
        {
            AppDomain.CurrentDomain.FirstChanceException += OnFirstChanceException;
        }
    }

    /// <summary>
    /// Starts watching the operation about to run on the current thread (warm-up and measured operations alike), for the
    /// contention classification of a failed operation (SPEC §4.4 rule 7b). Call outside the timer.
    /// </summary>
    internal static void BeginOperation()
    {
        EnsureSubscribed();
        _opContention = false;
        _opTracking = true;
    }

    /// <summary>
    /// Ends the watch started by BeginOperation. True when a contention exception (IsContentionException) was raised on this
    /// thread inside the operation, even when Acumatica later rethrew the failure as a plain PXException without the inner
    /// exception (ARDocumentRelease.ReleaseDoc does: <c>throw new PXException(errorMsg)</c>). Pass it to ClassifyFailure, which
    /// uses it only for such bare rethrows. Safe to call twice.
    /// </summary>
    internal static bool EndOperation()
    {
        var seen = _opContention;
        _opTracking = false;
        _opContention = false;
        return seen;
    }

    /// <summary>
    /// Classifies one failed operation for SPEC §4.4 rule 7b; true = contention. The final exception decides first: a contention
    /// failure anywhere in its chain (IsContention) is contention. Otherwise the operation's contention watch (contentionSeen,
    /// from EndOperation) counts only when the final exception carries no cause of its own (IsBareRethrow), the case of
    /// ARDocumentRelease.ReleaseDoc's <c>throw new PXException(errorMsg)</c>. A deadlock or lock violation that Acumatica raised
    /// and recovered from earlier in the operation therefore never hides a later validation failure (PXRowPersistingException,
    /// PXSetPropertyException, PXOuterException, …). masked = contention was seen in the operation, but the failure is counted
    /// as non-contention.
    /// </summary>
    internal static bool ClassifyFailure(Exception error, bool contentionSeen, out bool masked)
    {
        masked = false;
        if (IsContention(error)) return true;
        if (!contentionSeen) return false;
        if (IsBareRethrow(error)) return true;
        masked = true;
        return false;
    }

    /// <summary>
    /// True when the exception or one of its inner exceptions is a contention failure: a deadlock, a lock or command time-out,
    /// a lock violation, or a serialization failure (IsContentionException).
    /// </summary>
    internal static bool IsContention(Exception ex) => IsContention(ex, 0);

    /// <summary>
    /// True when every exception in the chain (inner exceptions and AggregateException members) is only a carrier: exactly
    /// PXException (a message rethrown without its cause), PXMassProcessException, PXOperationCompletedWithErrorException,
    /// TargetInvocationException or AggregateException. Any other type names the cause (validation, provider error, …).
    /// </summary>
    internal static bool IsBareRethrow(Exception ex) => ex != null && IsBareRethrow(ex, 0);

    private static bool IsBareRethrow(Exception ex, int depth)
    {
        for (var e = ex; e != null; e = e.InnerException, depth++)
        {
            if (depth >= 16) return false;
            if (e is AggregateException ae)
            {
                foreach (var inner in ae.InnerExceptions)
                {
                    if (inner != null && !IsBareRethrow(inner, depth + 1)) return false;
                }

                return true;
            }

            var carrier = e.GetType() == typeof(PXException)
                          || e is PX.Objects.Common.PXMassProcessException
                          || e is PXOperationCompletedWithErrorException
                          || e is TargetInvocationException;
            if (!carrier) return false;
        }

        return true;
    }

    private static bool IsContention(Exception ex, int depth)
    {
        for (var e = ex; e != null && depth < 16; e = e.InnerException, depth++)
        {
            if (IsContentionException(e)) return true;
            if (e is AggregateException ae)
            {
                foreach (var inner in ae.InnerExceptions)
                {
                    if (IsContention(inner, depth + 1)) return true;
                }
            }
        }

        return false;
    }

    /// <summary>
    /// One exception, without its inner exceptions: PXDatabaseException Deadlock or Timeout, PXLockViolationException,
    /// TimeoutException, or a provider exception for a deadlock / lock wait / serialization failure / statement time-out that
    /// Acumatica maps to PXDbExceptions.Unknown or does not retry (SPEC §1.6): SQL Server 1205, 1222, -2; MySQL 1205, 1213;
    /// PostgreSQL 40P01, 40001, 55P03, 57014. Not contention: a Timeout that PX.PgSql made from SqlState XX000 (internal_error;
    /// PgSqlDatabaseProvider.newDatabaseException maps it to PXDbExceptions.Timeout).
    /// </summary>
    private static bool IsContentionException(Exception e)
    {
        switch (e)
        {
            case PXDatabaseException dbe:
                if (dbe.ErrorCode == PXDbExceptions.Deadlock) return true;
                return dbe.ErrorCode == PXDbExceptions.Timeout && !HasSqlState(dbe.InnerException, "XX000");
            case PXLockViolationException _:
            case TimeoutException _:
                return true;
            case DbException _:
                return IsProviderContention(e);
            default:
                return false;
        }
    }

    private static bool IsProviderContention(Exception e)
    {
        try
        {
            var type = e.GetType();
            switch (type.Name)
            {
                case "SqlException":
                {
                    var n = type.GetProperty("Number", BindingFlags.Instance | BindingFlags.Public)?.GetValue(e, null) as int?;
                    return n == 1205 || n == 1222 || n == -2;
                }
                case "MySqlException":
                {
                    var n = type.GetProperty("Number", BindingFlags.Instance | BindingFlags.Public)?.GetValue(e, null) as int?;
                    return n == 1205 || n == 1213;
                }
                default:
                {
                    var state = type.GetProperty("SqlState", BindingFlags.Instance | BindingFlags.Public)?.GetValue(e, null) as string;
                    return state == "40P01" || state == "40001" || state == "55P03" || state == "57014";
                }
            }
        }
        catch
        {
            return false;
        }
    }

    /// <summary>True when ex is a provider exception (DbException) whose SqlState property equals state.</summary>
    private static bool HasSqlState(Exception ex, string state)
    {
        if (!(ex is DbException)) return false;
        try
        {
            var value = ex.GetType().GetProperty("SqlState", BindingFlags.Instance | BindingFlags.Public)?.GetValue(ex, null) as string;
            return string.Equals(value, state, StringComparison.Ordinal);
        }
        catch
        {
            return false;
        }
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
        var tracking = _opTracking;
        if (_inHandler || (!tracking && (run == null || run.Closed))) return;

        _inHandler = true;
        try
        {
            var ex = e.Exception;
            if (tracking && !_opContention && IsContentionException(ex)) _opContention = true;
            if (run == null || run.Closed) return;

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
