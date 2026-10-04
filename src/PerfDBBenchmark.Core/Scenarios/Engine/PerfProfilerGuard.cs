using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
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

    /// <summary>
    /// SQL capture, stack traces, trace events or user-profiler logging is on. IsEnabled alone is not counted: PX.Telemetry
    /// sets it with every HTTP request (stock baseline; a per-statement counter and timer only).
    /// </summary>
    public bool IsCollecting => Error == null && (SqlProfilerEnabled || SqlProfilerStackTraceEnabled || TraceEnabled || SaveRequestsToDb || SaveSqlToDb);

    /// <summary>ResultJson profiler text, e.g. "IsEnabled=true; SqlProfilerEnabled=false; TraceEnabled=false; …".</summary>
    public string ToNote()
    {
        if (Error != null) return "unavailable: " + Error;
        return "IsEnabled=" + B(IsEnabled) +
               "; SqlProfilerEnabled=" + B(SqlProfilerEnabled) +
               "; SqlProfilerStackTraceEnabled=" + B(SqlProfilerStackTraceEnabled) +
               "; TraceEnabled=" + B(TraceEnabled) +
               "; SaveRequestsToDb=" + B(SaveRequestsToDb) +
               "; SaveSqlToDb=" + B(SaveSqlToDb);
    }

    /// <summary>The ENV_CAPTURE env.db.requestProfiler shape: source, the six original keys and when the state was read.</summary>
    public Dictionary<string, object> ToEnvJson(string source, string readAt)
    {
        var map = new Dictionary<string, object>(StringComparer.Ordinal) { ["source"] = source };
        if (Error != null)
        {
            map["source"] = PerfRuntimeInfo.Unavailable;
            map["error"] = Error;
            map["readAt"] = readAt;
            return map;
        }

        map["IsEnabled"] = IsEnabled;
        map["SqlProfilerEnabled"] = SqlProfilerEnabled;
        map["TraceEnabled"] = TraceEnabled;
        map["TraceExceptionsEnabled"] = TraceExceptionsEnabled;
        map["IsLongOperationCollectMemory"] = IsLongOperationCollectMemory;
        map["ProfilerAutoTurnOff"] = ProfilerAutoTurnOff;
        map["readAt"] = readAt;
        return map;
    }

    /// <summary>The ENV_CAPTURE shape plus the user-profiler and stack-trace flags.</summary>
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

    internal static string B(bool value) => value ? "true" : "false";
}

/// <summary>
/// The PX.Telemetry settings that decide whether the Request Profiler comes back on. PX.Telemetry's App_BeginRequest calls
/// AdapterUtils.EnableProfiler(LogSQL) on every HTTP request: it sets PXPerformanceMonitor._IsEnabled and, when LogSQL is
/// true, also _SqlProfilerEnabled and _SqlProfilerStackTraceEnabled. The settings come from
/// App_Data\RuntimeConfig\PX.Telemetry.config when that file exists, otherwise from Bin\PX.Telemetry.config (not merged).
/// Read by reflection (TelemetryConfig is internal), with App_Data\LogTelemetryConfig.txt as fallback. Never throws.
/// </summary>
internal sealed class PerfTelemetryState
{
    private const BindingFlags StaticAny = BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic;
    private static readonly Regex LogLine = new Regex(@"^\s*(\w+)\s*=\s*'(.*)'\s*$", RegexOptions.CultureInvariant);

    /// <summary>The PX.Telemetry assembly is loaded in this AppDomain.</summary>
    public bool Loaded;
    /// <summary>TelemetryConfigPublic.ConfigCreated: PX.Telemetry has built its configuration (its first request does).</summary>
    public bool? ConfigCreated;
    public bool? LogSql;
    public bool? IsTimelineEnabled;
    public bool? SqlPlanEnabled;
    /// <summary>The config file PX.Telemetry loaded, relative to the site folder.</summary>
    public string ConfigFile;
    /// <summary>App_Data\RuntimeConfig\PX.Telemetry.config exists (it then replaces Bin\PX.Telemetry.config).</summary>
    public bool RuntimeConfigFile;
    public string Source;
    public string Error;

    /// <summary>PX.Telemetry sets _IsEnabled again with every HTTP request.</summary>
    public bool ReenablesIsEnabled => Loaded && ConfigCreated != false;

    /// <summary>PX.Telemetry sets the SQL capture flags again with every HTTP request (LogSQL = true); null when unknown.</summary>
    public bool? ReenablesSql => ReenablesIsEnabled ? LogSql : false;

    public static PerfTelemetryState Read()
    {
        var state = new PerfTelemetryState();
        try
        {
            ReadCore(state);
        }
        catch (Exception ex)
        {
            state.Error ??= ex.GetType().Name + ": " + ex.Message;
            state.Source ??= PerfRuntimeInfo.Unavailable;
        }

        return state;
    }

    private static void ReadCore(PerfTelemetryState state)
    {
        var root = AppDomain.CurrentDomain.BaseDirectory ?? string.Empty;
        state.RuntimeConfigFile = File.Exists(Path.Combine(root, "App_Data", "RuntimeConfig", "PX.Telemetry.config"));

        Assembly asm = null;
        foreach (var a in AppDomain.CurrentDomain.GetAssemblies())
        {
            string name;
            try { name = a.GetName().Name; }
            catch { continue; }
            if (string.Equals(name, "PX.Telemetry", StringComparison.OrdinalIgnoreCase))
            {
                asm = a;
                break;
            }
        }

        if (asm == null)
        {
            state.Loaded = false;
            state.Source = "PX.Telemetry not loaded";
            return;
        }

        state.Loaded = true;
        try
        {
            var pub = asm.GetType("PX.Telemetry.TelemetryConfigPublic", throwOnError: false);
            if (pub?.GetField("ConfigCreated", StaticAny)?.GetValue(null) is bool created) state.ConfigCreated = created;

            // Only an existing configuration is read: reading a property of TelemetryConfig would otherwise build it.
            var cfg = asm.GetType("PX.Telemetry.TelemetryConfig", throwOnError: false);
            if (cfg != null && state.ConfigCreated == true)
            {
                state.LogSql = StaticBool(cfg, "LogSQL");
                state.IsTimelineEnabled = StaticBool(cfg, "IsTimelineEnabled");
                state.SqlPlanEnabled = StaticBool(cfg, "SqlPlanEnabled");
                state.ConfigFile = Relative(root, cfg.GetField("_path", StaticAny)?.GetValue(null) as string);
                if (state.LogSql != null) state.Source = "PX.Telemetry.TelemetryConfig";
            }
        }
        catch (Exception ex)
        {
            state.Error = ex.GetType().Name + ": " + ex.Message;
        }

        if (state.LogSql == null) ReadLogFile(state, root);
        if (state.Source == null)
        {
            state.Source = state.ConfigCreated == false ? "PX.Telemetry configuration not built yet" : PerfRuntimeInfo.Unavailable;
        }
    }

    /// <summary>Fallback: the "Name = 'Value'" lines PX.Telemetry writes when it builds its configuration (LogConfigToFile).</summary>
    private static void ReadLogFile(PerfTelemetryState state, string root)
    {
        var path = Path.Combine(root, "App_Data", "LogTelemetryConfig.txt");
        if (!File.Exists(path)) return;
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in File.ReadAllLines(path))
        {
            var m = LogLine.Match(line);
            if (m.Success) values[m.Groups[1].Value] = m.Groups[2].Value;
        }

        state.LogSql = ParseBool(values, "LogSQL");
        state.IsTimelineEnabled ??= ParseBool(values, "IsTimelineEnabled");
        state.SqlPlanEnabled ??= ParseBool(values, "SqlPlanEnabled");
        if (state.LogSql != null)
        {
            state.Source = @"App_Data\LogTelemetryConfig.txt (written " +
                           File.GetLastWriteTimeUtc(path).ToString("o", CultureInfo.InvariantCulture) + ")";
        }
    }

    private static bool? StaticBool(Type type, string name)
    {
        try
        {
            return type.GetProperty(name, StaticAny)?.GetValue(null) is bool b ? b : (bool?)null;
        }
        catch
        {
            return null;
        }
    }

    private static bool? ParseBool(Dictionary<string, string> values, string name) =>
        values.TryGetValue(name, out var s) && bool.TryParse(s, out var b) ? b : (bool?)null;

    private static string Relative(string root, string path)
    {
        if (string.IsNullOrEmpty(path)) return null;
        return !string.IsNullOrEmpty(root) && path.StartsWith(root, StringComparison.OrdinalIgnoreCase)
            ? path.Substring(root.Length).TrimStart('\\', '/')
            : path;
    }

    private static string N(bool? value) => value.HasValue ? (value.Value ? "True" : "False") : "unknown";

    /// <summary>ResultJson profiler text, e.g. "LogSQL=True; IsTimelineEnabled=True; SqlPlanEnabled=True; config=…".</summary>
    public string ToNote()
    {
        if (!Loaded) return Source ?? "PX.Telemetry not loaded";
        return "LogSQL=" + N(LogSql) +
               "; IsTimelineEnabled=" + N(IsTimelineEnabled) +
               "; SqlPlanEnabled=" + N(SqlPlanEnabled) +
               "; config=" + (ConfigFile ?? (RuntimeConfigFile ? @"App_Data\RuntimeConfig\PX.Telemetry.config (exists)" : "unknown")) +
               "; source=" + Source +
               (Error != null ? "; error=" + Error : string.Empty);
    }

    /// <summary>ENV_CAPTURE env.db.requestProfilerTelemetry.</summary>
    public Dictionary<string, object> ToJson()
    {
        var map = new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["source"] = Source ?? PerfRuntimeInfo.Unavailable,
            ["loaded"] = Loaded,
            ["configCreated"] = ConfigCreated,
            ["logSql"] = LogSql,
            ["isTimelineEnabled"] = IsTimelineEnabled,
            ["sqlPlanEnabled"] = SqlPlanEnabled,
            ["configFile"] = ConfigFile,
            ["runtimeConfigFile"] = RuntimeConfigFile,
            ["reenablesIsEnabled"] = ReenablesIsEnabled,
            ["reenablesSqlProfiler"] = ReenablesSql
        };
        if (Error != null) map["error"] = Error;
        return map;
    }
}

/// <summary>What PerfProfilerGuard.Apply found, did and left.</summary>
internal sealed class PerfProfilerGuardResult
{
    public PerfTelemetryState Telemetry;
    public PerfProfilerState Found;
    public PerfProfilerState After;
    /// <summary>The PXPerformanceMonitor members that were set to false, in order.</summary>
    public readonly List<string> Changed = new List<string>();
    /// <summary>Flags that were on and left on on purpose, with the reason.</summary>
    public readonly List<string> Kept = new List<string>();
    /// <summary>SMPerformanceSettings was written (only when user-profiler logging or tracing had to be switched off).</summary>
    public bool Persisted;
    public string Error;

    /// <summary>True when at least one profiler setting was switched off.</summary>
    public bool Applied => Changed.Count > 0;

    public string Mode
    {
        get
        {
            if (Found == null || Found.Error != null) return PerfRuntimeInfo.Unavailable;
            var sql = Telemetry?.ReenablesSql;
            if (sql == true) return "SQL capture left on (PX.Telemetry LogSQL=True switches it on with every HTTP request)";
            if (sql == null) return "switch-off (PX.Telemetry LogSQL unknown)";
            return "switch-off";
        }
    }

    /// <summary>
    /// Set when SQL capture will be on during the run (PX.Telemetry LogSQL = true, whatever the state right after the guard), or
    /// when SQL capture, stack traces, tracing or user-profiler logging is still on after the guard.
    /// </summary>
    public string Warning
    {
        get
        {
            if (Telemetry?.ReenablesSql == true)
            {
                return "SQL capture with stack traces is on for the whole run: PX.Telemetry LogSQL=True switches it on with every " +
                       @"HTTP request. Deploy App_Data\RuntimeConfig\PX.Telemetry.config with LogSQL=""False"" on every site.";
            }

            return After != null && After.IsCollecting ? "Acumatica's Request Profiler was still collecting after the guard." : null;
        }
    }

    /// <summary>Fills the ResultJson "profiler" section (one compact section, never truncated before the env section).</summary>
    public void WriteTo(IDictionary<string, string> section)
    {
        if (section == null) return;
        try
        {
            section["found"] = Found?.ToNote() ?? PerfRuntimeInfo.Unavailable;
            section["telemetry"] = Telemetry?.ToNote() ?? PerfRuntimeInfo.Unavailable;
            section["mode"] = Mode;
            section["changed"] = Changed.Count > 0 ? string.Join(", ", Changed) : "none";
            if (Kept.Count > 0) section["kept"] = string.Join("; ", Kept);
            if (Persisted) section["persisted"] = "SMPerformanceSettings written once (user-profiler logging or tracing switched off)";
            section["after"] = After?.ToNote() ?? PerfRuntimeInfo.Unavailable;
            if (Error != null) section["error"] = PerfRunEngine.Truncate(Error, 400);
            var warning = Warning;
            if (warning != null) section["warning"] = warning;
        }
        catch
        {
            // Evidence only; never fail a run for it.
        }
    }
}

/// <summary>Counts how often each profiler flag was on at the untimed points around the measured passes.</summary>
internal sealed class PerfProfilerTally
{
    private int _samples;
    private int _isEnabled;
    private int _sql;
    private int _stackTrace;
    private int _trace;
    private int _saveRequests;
    private int _saveSql;
    private string _error;

    /// <summary>Reads the static flags (a few bool reads, no allocation); never throws.</summary>
    public void Sample()
    {
        try
        {
            SampleCore();
        }
        catch (Exception ex)
        {
            _error ??= ex.GetType().Name + ": " + ex.Message;
        }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private void SampleCore()
    {
        _samples++;
        if (PXPerformanceMonitor.IsEnabled) _isEnabled++;
        if (PXPerformanceMonitor.SqlProfilerEnabled) _sql++;
        if (PXPerformanceMonitor.SqlProfilerStackTraceEnabled) _stackTrace++;
        if (PXPerformanceMonitor.TraceEnabled) _trace++;
        if (PXPerformanceMonitor.SaveRequestsToDb) _saveRequests++;
        if (PXPerformanceMonitor.SaveSqlToDb) _saveSql++;
    }

    /// <summary>e.g. "IsEnabled 6/6; SqlProfilerEnabled 0/6; …" (before and after each measured pass).</summary>
    public string ToNote()
    {
        if (_error != null) return "unavailable: " + _error;
        if (_samples == 0) return "no measured pass ran";
        var n = "/" + _samples.ToString(CultureInfo.InvariantCulture);
        string C(int v) => v.ToString(CultureInfo.InvariantCulture) + n;
        return "IsEnabled " + C(_isEnabled) +
               "; SqlProfilerEnabled " + C(_sql) +
               "; SqlProfilerStackTraceEnabled " + C(_stackTrace) +
               "; TraceEnabled " + C(_trace) +
               "; SaveRequestsToDb " + C(_saveRequests) +
               "; SaveSqlToDb " + C(_saveSql) +
               " (before and after each measured pass)";
    }
}

/// <summary>
/// Switches the collecting parts of Acumatica's Request Profiler off before a benchmark run (outside every timed region).
/// The profiler records every request and SQL statement (with stack traces) in the IIS worker, so its cost grows with the
/// statement count.
/// <para>
/// PX.Telemetry turns profiling back on with every HTTP request, including the suite's status polls during the run
/// (AdapterUtils.EnableProfiler from Module.App_BeginRequest): it always sets _IsEnabled, and with LogSQL = true also
/// _SqlProfilerEnabled and _SqlProfilerStackTraceEnabled. So:
/// </para>
/// <list type="bullet">
/// <item>IsEnabled is the stock baseline while PX.Telemetry is active and is left alone (per-statement counter and timer only).
/// Without PX.Telemetry it is switched off.</item>
/// <item>The SQL capture flags are switched off only when PX.Telemetry will not switch them on again (LogSQL = false, set by
/// App_Data\RuntimeConfig\PX.Telemetry.config, or LogSQL unknown). With LogSQL = true they are left on, so every run stays
/// in the same profiled state; switching them off would only open an unprofiled window of up to about 1 s whose share of
/// the measured work differs by engine.</item>
/// <item>These three are written as the public static fields PX.Telemetry itself writes, without SaveSettings: nothing is
/// persisted, no WatchDog row is written, and no half-finished state reaches SMPerformanceSettings.</item>
/// <item>User-profiler logging (SaveRequestsToDb, SaveSqlToDb) and tracing (TraceEnabled) are never switched on by
/// PX.Telemetry; they are switched off and persisted with one SaveSettings call (through the TraceEnabled setter when
/// tracing is on, which also lowers the trace logging level), because the Request Profiler screen persists them too.</item>
/// </list>
/// Serialized by a lock; never throws. The result records what was found, changed, kept and left.
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

    /// <summary>Switches the collecting parts of the profiler off as described on the class and reports before/after (never throws).</summary>
    public static PerfProfilerGuardResult Apply()
    {
        var result = new PerfProfilerGuardResult();
        try
        {
            lock (Sync)
            {
                result.Telemetry = PerfTelemetryState.Read();
                result.Found = Read();
                if (result.Found.Error != null)
                {
                    result.Error = "Profiler state unavailable: " + result.Found.Error;
                }
                else
                {
                    try
                    {
                        SwitchOffCore(result);
                    }
                    catch (Exception ex)
                    {
                        result.Error = ex.GetType().Name + ": " + ex.Message;
                    }
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
        map["guardMode"] = guard.Mode;
        map["guardApplied"] = guard.Applied;
        map["guardChanged"] = string.Join(", ", guard.Changed);
        map["guardKept"] = string.Join("; ", guard.Kept);
        map["guardPersisted"] = guard.Persisted;
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
    /// In-memory flags first (no persistence), then user-profiler logging and tracing with at most one SaveSettings, so that
    /// write already carries the in-memory resets.
    /// </summary>
    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void SwitchOffCore(PerfProfilerGuardResult result)
    {
        var telemetry = result.Telemetry;
        var changed = result.Changed;

        // 1. SQL capture: the fields PX.Telemetry writes, written the same way (no SaveSettings, no WatchDog row).
        var sqlOn = PXPerformanceMonitor._SqlProfilerEnabled || PXPerformanceMonitor._SqlProfilerStackTraceEnabled;
        if (telemetry?.ReenablesSql == true)
        {
            if (sqlOn)
            {
                result.Kept.Add("SqlProfilerEnabled/SqlProfilerStackTraceEnabled (PX.Telemetry LogSQL=True switches them on with every " +
                                "HTTP request; switching them off would only open an unprofiled window of up to ~1 s)");
            }
        }
        else
        {
            if (PXPerformanceMonitor._SqlProfilerStackTraceEnabled)
            {
                PXPerformanceMonitor._SqlProfilerStackTraceEnabled = false;
                changed.Add("_SqlProfilerStackTraceEnabled");
            }

            if (PXPerformanceMonitor._SqlProfilerEnabled)
            {
                PXPerformanceMonitor._SqlProfilerEnabled = false;
                changed.Add("_SqlProfilerEnabled");
            }
        }

        // 2. Request profiling: the stock baseline while PX.Telemetry is active.
        if (PXPerformanceMonitor._IsEnabled)
        {
            if (telemetry == null || telemetry.ReenablesIsEnabled)
            {
                result.Kept.Add("IsEnabled (stock baseline: PX.Telemetry switches it on with every HTTP request)");
            }
            else
            {
                PXPerformanceMonitor._IsEnabled = false;
                changed.Add("_IsEnabled");
            }
        }

        // 3. User-profiler logging and tracing: never switched on by PX.Telemetry; persisted off with one write.
        var persist = false;
        if (PXPerformanceMonitor._SaveRequestsToDb)
        {
            PXPerformanceMonitor._SaveRequestsToDb = false;
            changed.Add("SaveRequestsToDb");
            persist = true;
        }

        if (PXPerformanceMonitor._SaveSqlToDb)
        {
            PXPerformanceMonitor._SaveSqlToDb = false;
            changed.Add("SaveSqlToDb");
            persist = true;
        }

        if (PXPerformanceMonitor.TraceEnabled)
        {
            // The setter also re-evaluates the trace logging level (private AdjustLoggingLevel) and calls SaveSettings.
            PXPerformanceMonitor.TraceEnabled = false;
            changed.Add("TraceEnabled");
            result.Persisted = true;
        }
        else if (persist)
        {
            PXPerformanceMonitor.SaveSettings();
            result.Persisted = true;
        }
    }
}
