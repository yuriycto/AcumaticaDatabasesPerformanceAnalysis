using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using PX.SM;

namespace PerfDBBenchmark.Core.Scenarios;

/// <summary>The state of Acumatica's Request Profiler (PX.SM.PXPerformanceMonitor, PX.Data) at one moment.</summary>
internal sealed class PerfProfilerState
{
    /// <summary>PXPerformanceMonitor.IsEnabled (= _IsEnabled || SaveRequestsToDb).</summary>
    public bool IsEnabled;
    /// <summary>PXPerformanceMonitor.SqlProfilerEnabled (= _SqlProfilerEnabled || SaveSqlToDb).</summary>
    public bool SqlProfilerEnabled;
    public bool TraceEnabled;
    public bool TraceExceptionsEnabled;
    /// <summary>Request logging of the user profiler / "Log Requests (Apply Filter)".</summary>
    public bool SaveRequestsToDb;
    /// <summary>SQL logging of the user profiler / "Log SQL (Apply Filter)".</summary>
    public bool SaveSqlToDb;
    public bool SqlProfilerStackTraceEnabled;
    public bool IsLongOperationCollectMemory;
    public bool ProfilerAutoTurnOff;
    /// <summary>Set when the state could not be read; the flags are then meaningless.</summary>
    public string Error;

    /// <summary>The profiler collects requests, SQL statements or trace events.</summary>
    public bool IsCollecting => Error == null && (IsEnabled || SqlProfilerEnabled || TraceEnabled || SaveRequestsToDb || SaveSqlToDb);

    /// <summary>ResultJson.notes text, e.g. "IsEnabled=false; SqlProfilerEnabled=false; TraceEnabled=false; …".</summary>
    public string ToNote()
    {
        if (Error != null) return "unavailable: " + Error;
        return "IsEnabled=" + B(IsEnabled) +
               "; SqlProfilerEnabled=" + B(SqlProfilerEnabled) +
               "; TraceEnabled=" + B(TraceEnabled) +
               "; SaveRequestsToDb=" + B(SaveRequestsToDb) +
               "; SaveSqlToDb=" + B(SaveSqlToDb) +
               "; SqlProfilerStackTraceEnabled=" + B(SqlProfilerStackTraceEnabled);
    }

    /// <summary>The ENV_CAPTURE shape: the keys of env.db.requestProfiler plus the user-profiler and stack-trace flags.</summary>
    public Dictionary<string, object> ToJson(string source)
    {
        var map = new Dictionary<string, object>(StringComparer.Ordinal) { ["source"] = source };
        if (Error != null)
        {
            map["source"] = PerfRuntimeInfo.Unavailable;
            map["error"] = Error;
            return map;
        }

        map["IsEnabled"] = IsEnabled;
        map["SqlProfilerEnabled"] = SqlProfilerEnabled;
        map["TraceEnabled"] = TraceEnabled;
        map["TraceExceptionsEnabled"] = TraceExceptionsEnabled;
        map["IsLongOperationCollectMemory"] = IsLongOperationCollectMemory;
        map["ProfilerAutoTurnOff"] = ProfilerAutoTurnOff;
        map["SaveRequestsToDb"] = SaveRequestsToDb;
        map["SaveSqlToDb"] = SaveSqlToDb;
        map["SqlProfilerStackTraceEnabled"] = SqlProfilerStackTraceEnabled;
        return map;
    }

    private static string B(bool value) => value ? "true" : "false";
}

/// <summary>What PerfProfilerGuard.Apply found, did and left.</summary>
internal sealed class PerfProfilerGuardResult
{
    public PerfProfilerState Found;
    /// <summary>True when at least one profiler setting was switched off.</summary>
    public bool Applied;
    /// <summary>The PXPerformanceMonitor properties that were set to false, in order.</summary>
    public readonly List<string> Changed = new List<string>();
    public PerfProfilerState After;
    public string Error;

    /// <summary>Notes: profilerFound, profilerGuardApplied, profilerAfter (+ profilerGuardChanged, profilerGuardError,
    /// profilerGuardWarning when they apply).</summary>
    public void WriteNotes(IDictionary<string, string> notes)
    {
        if (notes == null) return;
        try
        {
            notes["profilerFound"] = Found?.ToNote() ?? PerfRuntimeInfo.Unavailable;
            notes["profilerGuardApplied"] = Applied ? "true" : "false";
            notes["profilerAfter"] = After?.ToNote() ?? PerfRuntimeInfo.Unavailable;
            if (Changed.Count > 0) notes["profilerGuardChanged"] = string.Join(", ", Changed);
            if (Error != null) notes["profilerGuardError"] = PerfRunEngine.Truncate(Error, 400);
            if (After != null && After.IsCollecting)
            {
                notes["profilerGuardWarning"] = "Acumatica's Request Profiler was still on after the guard.";
            }
        }
        catch
        {
            // Notes are evidence only; never fail a run for them.
        }
    }
}

/// <summary>
/// Turns Acumatica's Request Profiler off before a benchmark run (outside every timed region). The profiler records every
/// request and SQL statement (with stack traces) in the IIS worker, so its cost grows with the statement count.
/// Uses only public PXPerformanceMonitor members of 26 R2: the IsEnabled / SqlProfilerEnabled setters (the "Stop" button of
/// the Request Profiler screen sets IsEnabled = false), the SaveRequestsToDb / SaveSqlToDb setters (the screen's
/// "Log Requests" / "Log SQL" switches, i.e. the public stop path of StartUserProfiler; StopUserProfiler itself is
/// [PXInternalUseOnly] and only stops the profiler of the user that started it), and the TraceEnabled /
/// SqlProfilerStackTraceEnabled setters. Each setter persists SMPerformanceSettings only when its value changes, so a
/// profiler that is already off is left untouched (idempotent). Serialized by a lock; never throws.
/// </summary>
internal static class PerfProfilerGuard
{
    private const string Source = "PX.SM.PXPerformanceMonitor";
    private static readonly object Sync = new object();

    /// <summary>Reads the profiler state (never throws).</summary>
    public static PerfProfilerState Read()
    {
        try
        {
            return ReadCore();
        }
        catch (Exception ex)
        {
            // Also catches a type or member load failure of PXPerformanceMonitor, which surfaces when ReadCore is compiled.
            return new PerfProfilerState { Error = ex.GetType().Name + ": " + ex.Message };
        }
    }

    /// <summary>Switches every collecting part of the profiler off and reports before/after (never throws).</summary>
    public static PerfProfilerGuardResult Apply()
    {
        var result = new PerfProfilerGuardResult();
        try
        {
            lock (Sync)
            {
                result.Found = Read();
                if (result.Found.Error != null)
                {
                    result.Error = "Profiler state unavailable: " + result.Found.Error;
                }
                else if (result.Found.IsCollecting)
                {
                    try
                    {
                        SwitchOffCore(result.Changed);
                    }
                    catch (Exception ex)
                    {
                        result.Error = ex.GetType().Name + ": " + ex.Message;
                    }

                    result.Applied = result.Changed.Count > 0;
                }

                result.After = Read();
            }
        }
        catch (Exception ex)
        {
            result.Error ??= ex.GetType().Name + ": " + ex.Message;
        }

        return result;
    }

    /// <summary>The state as env.db.requestProfilerFound (ENV_CAPTURE): the found state plus what the guard did.</summary>
    public static Dictionary<string, object> FoundJson(PerfProfilerGuardResult guard)
    {
        if (guard?.Found == null)
        {
            return new Dictionary<string, object>(StringComparer.Ordinal)
            {
                ["source"] = PerfRuntimeInfo.Unavailable,
                ["error"] = "The profiler guard did not run for this capture."
            };
        }

        var map = guard.Found.ToJson(Source);
        map["guardApplied"] = guard.Applied;
        map["guardChanged"] = string.Join(", ", guard.Changed);
        if (guard.Error != null) map["guardError"] = guard.Error;
        return map;
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static PerfProfilerState ReadCore()
    {
        return new PerfProfilerState
        {
            IsEnabled = PXPerformanceMonitor.IsEnabled,
            SqlProfilerEnabled = PXPerformanceMonitor.SqlProfilerEnabled,
            TraceEnabled = PXPerformanceMonitor.TraceEnabled,
            TraceExceptionsEnabled = PXPerformanceMonitor.TraceExceptionsEnabled,
            SaveRequestsToDb = PXPerformanceMonitor.SaveRequestsToDb,
            SaveSqlToDb = PXPerformanceMonitor.SaveSqlToDb,
            SqlProfilerStackTraceEnabled = PXPerformanceMonitor.SqlProfilerStackTraceEnabled,
            IsLongOperationCollectMemory = PXPerformanceMonitor.IsLongOperationCollectMemory,
            ProfilerAutoTurnOff = PXPerformanceMonitor.ProfilerAutoTurnOff
        };
    }

    /// <summary>
    /// Sets each collecting flag to false, user-profiler flags first and IsEnabled last (its setter re-evaluates the profiler's
    /// logging level). SqlProfilerEnabled / IsEnabled read true while SaveSqlToDb / SaveRequestsToDb are on, so those go first.
    /// SqlProfilerStackTraceEnabled is switched off too, so SaveSettings does not persist a stack-trace flag that some other
    /// component switched on in memory.
    /// </summary>
    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void SwitchOffCore(List<string> changed)
    {
        if (PXPerformanceMonitor.SaveRequestsToDb)
        {
            PXPerformanceMonitor.SaveRequestsToDb = false;
            changed.Add("SaveRequestsToDb");
        }

        if (PXPerformanceMonitor.SaveSqlToDb)
        {
            PXPerformanceMonitor.SaveSqlToDb = false;
            changed.Add("SaveSqlToDb");
        }

        if (PXPerformanceMonitor.TraceEnabled)
        {
            PXPerformanceMonitor.TraceEnabled = false;
            changed.Add("TraceEnabled");
        }

        if (PXPerformanceMonitor.SqlProfilerStackTraceEnabled)
        {
            PXPerformanceMonitor.SqlProfilerStackTraceEnabled = false;
            changed.Add("SqlProfilerStackTraceEnabled");
        }

        if (PXPerformanceMonitor.SqlProfilerEnabled)
        {
            PXPerformanceMonitor.SqlProfilerEnabled = false;
            changed.Add("SqlProfilerEnabled");
        }

        if (PXPerformanceMonitor.IsEnabled)
        {
            PXPerformanceMonitor.IsEnabled = false;
            changed.Add("IsEnabled");
        }
    }
}
