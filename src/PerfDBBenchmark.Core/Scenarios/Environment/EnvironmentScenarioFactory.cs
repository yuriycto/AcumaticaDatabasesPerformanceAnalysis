using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Threading;
using PX.Data;
using PX.Data.BQL;
using PX.Data.BQL.Fluent;
using PX.Data.SQLTree;
using PX.Objects.AR;
using PX.Objects.CR;
using PX.Objects.GL;
using PX.Objects.IN;
using PX.Objects.SO;
using PerfDBBenchmark.Core.DAC;

using GLAccount = PX.Objects.GL.Account;
using GLBranch = PX.Objects.GL.Branch;
using GLLedger = PX.Objects.GL.Ledger;
using GLSub = PX.Objects.GL.Sub;
using SMPerformanceSettings = PX.SM.PerformanceMonitorMaint.SMPerformanceSettings;

namespace PerfDBBenchmark.Core.Scenarios.Environment;

/// <summary>
/// ENV_CAPTURE (read-only gate run before every block repetition, SPEC §1.8) and the ENV_WORKERS_PROBE diagnostic.
/// No database access in the constructor or in Descriptors.
/// </summary>
public sealed class EnvironmentScenarioFactory : IPerfScenarioFactory
{
    /// <summary>The diagnostic code lives here, not in P0 (SPEC §1.8).</summary>
    public const string WorkersProbeCode = "ENV_WORKERS_PROBE";

    internal static readonly PerfTestDescriptor CaptureDescriptor = new PerfTestDescriptor
    {
        TestCode = PerfScenarioCodes.EnvironmentCapture,
        LegacyTestCode = null,
        Family = PerfFamilies.Environment,
        RunBlock = PerfBlocks.Gate,
        Category = "Environment",
        DisplayName = "Environment capture",
        ShortLabel = "Env",
        ShortDescription = "Read-only capture of build, web.config and database settings, data and master-data fingerprints and leftovers. Never compared.",
        Question = "–",
        WhatItSimulates = "Nothing is timed. A read-only snapshot of the application build, the web.config flags, the database settings and client connection, fingerprints of the data and master data, and a count of leftovers from earlier runs.",
        WhyItMatters = "The suite runs it on every instance before every block repetition and compares the fingerprints, so every database is tested on identical data and settings.",
        ReaderUnit = "–",
        SortOrder = 900,
        Users = 1,
        HeadlineKind = PerfHeadlineKinds.None,
        OpsUnit = "–",
        ParityExpected = false,
        OrderedChecksum = false,
        IsDestructive = false,
        IsOptional = false,
        ExcludeFromComparison = true,
        ScenarioVersion = 1,
        DefaultOpsPerPass = 0,
        DefaultPasses = 1,
        DefaultWarmUpPasses = 0,
        DefaultWarmUpOpsPerWorker = 0,
        OperationCapMs = 0,
        ErrorsInvalidate = true
    };

    internal static readonly PerfTestDescriptor WorkersProbeDescriptor = new PerfTestDescriptor
    {
        TestCode = WorkersProbeCode,
        LegacyTestCode = null,
        Family = PerfFamilies.Environment,
        RunBlock = PerfBlocks.Gate,
        Category = "Environment",
        DisplayName = "Worker concurrency probe (16 workers)",
        ShortLabel = "Workers probe",
        ShortDescription = "Diagnostic: 16 workers each read the control row and wait 500 ms, proving that 16 workers can run at the same time.",
        Question = "–",
        WhatItSimulates = "Diagnostic only: 16 parallel workers each read the benchmark control row once and then wait 500 ms, so all 16 operations overlap.",
        WhyItMatters = "Proves that the configured ThreadPoolSize lets 16 workers run concurrently (dry-run step 3g) without running a full 16-worker order-entry test.",
        ReaderUnit = "–",
        SortOrder = 910,
        Users = 16,
        HeadlineKind = PerfHeadlineKinds.None,
        OpsUnit = "–",
        ParityExpected = false,
        OrderedChecksum = false,
        IsDestructive = false,
        IsOptional = false,
        ExcludeFromComparison = true,
        ScenarioVersion = 1,
        DefaultOpsPerPass = 16,
        DefaultPasses = 1,
        DefaultWarmUpPasses = 0,
        DefaultWarmUpOpsPerWorker = 0,
        OperationCapMs = 0,
        ErrorsInvalidate = true
    };

    public IEnumerable<PerfTestDescriptor> Descriptors => new[] { CaptureDescriptor, WorkersProbeDescriptor };

    public IPerfScenario Create(string testCode)
    {
        if (string.Equals(testCode, PerfScenarioCodes.EnvironmentCapture, StringComparison.OrdinalIgnoreCase)) return new EnvCaptureScenario(CaptureDescriptor);
        if (string.Equals(testCode, WorkersProbeCode, StringComparison.OrdinalIgnoreCase)) return new EnvWorkersProbeScenario(WorkersProbeDescriptor);
        return null;
    }
}

/// <summary>ENV_WORKERS_PROBE: each of the 16 workers reads the control row and sleeps 500 ms (the only scenario allowed to sleep).</summary>
internal sealed class EnvWorkersProbeScenario : PerfScenarioBase
{
    private const int SleepMs = 500;

    public EnvWorkersProbeScenario(PerfTestDescriptor descriptor) : base(descriptor)
    {
    }

    public override void ExecuteOperation(PerfWorkerContext worker, PerfOpInfo op)
    {
        var rows = SelectFrom<PerfBenchmarkFilter>
            .Where<PerfBenchmarkFilter.setupID.IsEqual<@P.AsInt>>
            .View.ReadOnly.Select(worker.Graph, 1)
            .Count;
        worker.RowsReturned += rows;
        worker.Checksum.Add(op.OpIndex, rows);
        Thread.Sleep(SleepMs);
    }

    public override void Verify(PerfScenarioContext context, PerfRunMetrics metrics)
    {
        var w = context.Plan?.Users ?? Descriptor.Users;
        context.Parity["probe.workersObservedPeak"] = metrics.WorkersObservedPeak.ToString(CultureInfo.InvariantCulture);
        context.Parity["probe.opsInFlightPeak"] = metrics.OpsInFlightPeak.ToString(CultureInfo.InvariantCulture);
        context.Parity["probe.distinctThreads"] = metrics.DistinctThreads.ToString(CultureInfo.InvariantCulture);
        context.Parity["probe.threadPoolSizeConfigured"] = PerfRuntimeInfo.ConfiguredThreadPoolSize.ToString(CultureInfo.InvariantCulture);
        context.CheckInvariant("workersObservedPeak", w, metrics.WorkersObservedPeak);
        context.CheckInvariant("opsInFlightPeak", w, metrics.OpsInFlightPeak);
        metrics.Notes = "Workers probe: observed peak " + metrics.WorkersObservedPeak.ToString(CultureInfo.InvariantCulture) +
                        ", operations in flight peak " + metrics.OpsInFlightPeak.ToString(CultureInfo.InvariantCulture) +
                        " of " + w.ToString(CultureInfo.InvariantCulture) + "; ThreadPoolSize " +
                        PerfRuntimeInfo.ConfiguredThreadPoolSize.ToString(CultureInfo.InvariantCulture) + ".";
    }
}

/// <summary>ENV_CAPTURE: fills ResultJson.env in Prepare (read-only). No timed operations; Status Completed, HeadlineValue null.</summary>
internal sealed class EnvCaptureScenario : PerfScenarioBase
{
    private const string EnvKey = "env";

    public EnvCaptureScenario(PerfTestDescriptor descriptor) : base(descriptor)
    {
    }

    public override void Prepare(PerfScenarioContext context)
    {
        context.Set(EnvKey, EnvCaptureCollector.Collect(context.MainGraph, context.ProfilerGuard));
    }

    public override void ExecuteOperation(PerfWorkerContext worker, PerfOpInfo op)
    {
        // ENV_CAPTURE has no operations (DefaultOpsPerPass = 0).
    }

    public override void Verify(PerfScenarioContext context, PerfRunMetrics metrics)
    {
        var env = context.Get<Dictionary<string, object>>(EnvKey);
        if (env == null) return;
        metrics.Result["env"] = env;
        metrics.Notes = "masterDataHash " + Text(env, "masterDataHash") +
                        "; dataFingerprintHash " + Text(env, "dataFingerprintHash") +
                        "; dataFingerprintStaticHash " + Text(env, "dataFingerprintStaticHash") +
                        "; leftovers " + Text(env, "leftoversTotal") +
                        "; archived SOOrder " + Text(env, "archivedSoOrders") + ".";
    }

    private static string Text(Dictionary<string, object> env, string key) =>
        env.TryGetValue(key, out var v) && v != null ? Convert.ToString(v, CultureInfo.InvariantCulture) : "n/a";
}

/// <summary>Builds the ENV_CAPTURE env object. Every item is best effort: a failure is recorded as "unavailable" with the
/// message in an errors map (never hashed), and never fails the run.</summary>
internal static class EnvCaptureCollector
{
    private const string Unavailable = "unavailable";

    /// <summary>Data-fingerprint keys that Block D does not change (SPEC §1.8, review-fairness B1).</summary>
    internal static readonly string[] StaticKeys =
    {
        "count.SOOrder", "count.SOLine", "count.INSiteStatusByCostCenter", "count.BAccount", "count.Customer", "count.InventoryItem",
        "sum.SOOrder.CuryOrderTotal", "sum.INSiteStatusByCostCenter.QtyOnHand", "sum.INSiteStatusByCostCenter.QtyAvail",
        "perfTestRecord.READ-SEED", "perfTestRecord.UPDATE-SEED", "perfTestRecord.other",
        "archived.SOOrder"
    };

    /// <summary>Keys that Block D (invoice release) changes; compared and logged by gate G2d, never an abort.</summary>
    internal static readonly string[] DAffectedKeys =
    {
        "count.GLTran", "count.GLHistory", "count.ARTran", "count.ARRegister",
        "sum.GLTran.DebitAmt", "sum.GLTran.CreditAmt", "sum.ARTran.TranAmt"
    };

    /// <param name="profilerGuard">What the engine's Request Profiler guard found and did before Prepare (null: it did not run).</param>
    public static Dictionary<string, object> Collect(PXGraph graph, PerfProfilerGuardResult profilerGuard = null)
    {
        var env = new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["capturedAtUtc"] = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture)
        };

        var engine = PerfDatabaseEngines.Detect();
        env["app"] = App(engine);
        env["webConfig"] = PerfRuntimeInfo.WebConfigFacts.ToJson();
        env["db"] = Db(engine, profilerGuard);

        var data = DataFingerprint(graph);
        env["dataFingerprint"] = data;
        var master = MasterData(graph);
        env["masterDataFingerprint"] = master;
        var leftovers = Leftovers(graph, data);
        env["leftovers"] = leftovers;

        // Convenience copies for the suite's gates (G1, G2, G2d, G3, G5).
        env["masterDataHash"] = master["masterDataHash"];
        env["dataFingerprintHash"] = data["dataFingerprintHash"];
        env["dataFingerprintStaticHash"] = data["dataFingerprintStaticHash"];
        env["leftoversTotal"] = leftovers["total"];
        env["archivedSoOrders"] = data["soOrderArchived"];
        return env;
    }

    // ------------------------------------------------------------------ app

    private static Dictionary<string, object> App(string engine)
    {
        var registry = new List<object>();
        try
        {
            foreach (var d in PerfScenarioRegistry.All)
            {
                registry.Add(new Dictionary<string, object>(StringComparer.Ordinal)
                {
                    ["code"] = d.TestCode,
                    ["scenarioVersion"] = d.ScenarioVersion
                });
            }
        }
        catch (Exception ex)
        {
            registry.Add(Unavailable + ": " + ex.Message);
        }

        return new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["pxDataFileVersion"] = PerfRuntimeInfo.AcumaticaBuild,
            ["dllSha256"] = PerfRuntimeInfo.DllSha256,
            ["appDomainStartUtc"] = PerfRuntimeInfo.AppDomainStartUtc,
            ["providerType"] = PerfRuntimeInfo.ProviderTypeName,
            ["dbEngine"] = engine,
            ["instance"] = PerfRuntimeInfo.InstanceName,
            ["methodologyVersion"] = PerfMethodology.Version,
            ["registry"] = registry,
            ["registryLoadErrors"] = SafeLoadErrors(),
            // Contract C1 (E14): the SQL throttle setting in effect in this app domain. The campaign and dry-run checks take
            // optionsEnabled == false on all three sites as the runtime proof that the unlicensed throttle is off.
            ["sqlThrottling"] = SafeProbe(EnvRuntimeProbes.SqlThrottling, "configValue", "optionsEnabled", "started", "source"),
            // Contract C1, informational: this w3wp's affinity at capture time (kept as shipped, disclosed only). A snapshot, not a
            // run's core count: 2 bits steady, 4 bits for up to 60 s (licence observer), all CPUs in the first 2 min of a new w3wp
            // (see EnvRuntimeProbes.ProcessAffinity; read with appDomainStartUtc above and env.capturedAtUtc).
            ["processAffinity"] = SafeProbe(EnvRuntimeProbes.ProcessAffinity, "maskHex", "bits", "processorCount")
        };
    }

    /// <summary>Runs a C1 probe; the probes never throw, but a failure here must not lose the rest of env.app either.</summary>
    private static Dictionary<string, object> SafeProbe(Func<Dictionary<string, object>> probe, params string[] keys)
    {
        try
        {
            return probe();
        }
        catch (Exception ex)
        {
            var map = new Dictionary<string, object>(StringComparer.Ordinal);
            foreach (var k in keys) map[k] = null;
            map["error"] = ex.GetType().Name + ": " + ex.Message;
            return map;
        }
    }

    private static List<object> SafeLoadErrors()
    {
        try { return PerfScenarioRegistry.LoadErrors.Cast<object>().ToList(); }
        catch (Exception ex) { return new List<object> { Unavailable + ": " + ex.Message }; }
    }

    // ------------------------------------------------------------------ db

    private static Dictionary<string, object> Db(string engine, PerfProfilerGuardResult profilerGuard)
    {
        var errors = new Dictionary<string, object>(StringComparer.Ordinal);
        var settings = new Dictionary<string, object>(StringComparer.Ordinal);
        var database = new Dictionary<string, object>(StringComparer.Ordinal);
        var connection = new Dictionary<string, object>(StringComparer.Ordinal);

        switch (engine)
        {
            case PerfDatabaseEngines.SqlServer:
                ReadPairs(settings, errors, "sys.configurations",
                    "SELECT name, CONVERT(nvarchar(64), value_in_use) FROM sys.configurations WHERE name IN (N'max server memory (MB)',N'min server memory (MB)',N'max degree of parallelism',N'cost threshold for parallelism')");
                ReadRow(database, errors, "sys.databases",
                    "SELECT recovery_model_desc, CONVERT(nvarchar(8), is_read_committed_snapshot_on), collation_name, CONVERT(nvarchar(8), compatibility_level) FROM sys.databases WHERE database_id = DB_ID()",
                    "recovery_model_desc", "is_read_committed_snapshot_on", "collation_name", "compatibility_level");
                ReadRow(connection, errors, "connection",
                    "SELECT CONVERT(nvarchar(40), CONNECTIONPROPERTY('net_transport')), CONVERT(nvarchar(40), CONNECTIONPROPERTY('protocol_type')), (SELECT CONVERT(nvarchar(8), transaction_isolation_level) FROM sys.dm_exec_sessions WHERE session_id = @@SPID)",
                    "net_transport", "protocol_type", "transaction_isolation_level");
                if (connection.TryGetValue("transaction_isolation_level", out var lvl)) connection["isolation"] = SqlServerIsolation(lvl as string);
                break;

            case PerfDatabaseEngines.MySql:
                ReadPairs(settings, errors, "globalVariables",
                    "SHOW GLOBAL VARIABLES WHERE Variable_name IN ('version','innodb_buffer_pool_size','innodb_flush_log_at_trx_commit','log_bin','sync_binlog','transaction_isolation','innodb_redo_log_capacity','collation_server')");
                ReadRow(connection, errors, "connection",
                    "SELECT @@session.transaction_isolation, (SELECT VARIABLE_VALUE FROM performance_schema.session_status WHERE VARIABLE_NAME = 'Ssl_cipher')",
                    "isolation", "ssl_cipher");
                if (connection.TryGetValue("ssl_cipher", out var cipher) && !(cipher is string cs && cs == Unavailable))
                {
                    connection["tls"] = cipher is string c && !string.IsNullOrWhiteSpace(c) ? "yes" : "no";
                }

                break;

            case PerfDatabaseEngines.PostgreSql:
                ReadPgSettings(settings, errors,
                    "SELECT name, setting, COALESCE(unit,'') FROM pg_settings WHERE name IN ('server_version','shared_buffers','effective_cache_size','work_mem','synchronous_commit','wal_level','max_wal_size','default_transaction_isolation','jit','random_page_cost','max_parallel_workers_per_gather')");
                ReadRow(connection, errors, "connection",
                    "SELECT current_setting('transaction_isolation'), COALESCE((SELECT ssl::text FROM pg_stat_ssl WHERE pid = pg_backend_pid()), 'unknown')",
                    "isolation", "ssl");
                break;

            default:
                errors["engine"] = "Unknown database engine; no settings read.";
                break;
        }

        var db = new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["dbmsVersionLabel"] = PerfRuntimeInfo.DbmsVersionLabel,
            ["settings"] = settings,
            ["connection"] = connection,
            // The state the run found (before the engine's profiler guard acted; a live read when the guard did not run).
            ["requestProfiler"] = profilerGuard?.Found != null
                ? profilerGuard.Found.ToEnvJson("PX.SM.PXPerformanceMonitor", "beforeGuard")
                : RequestProfiler("live"),
            // Read now (Prepare, after the guard). It depends on whether a status poll already switched profiling on again,
            // and says nothing about the timed passes: ResultJson.profiler.duringMeasuredPasses does.
            ["requestProfilerAfterGuard"] = RequestProfiler(profilerGuard != null ? "afterGuard" : "live"),
            ["requestProfilerFound"] = PerfProfilerGuard.FoundJson(profilerGuard),
            ["requestProfilerTelemetry"] = (profilerGuard?.Telemetry ?? PerfTelemetryState.Read()).ToJson(),
            ["requestProfilerSettingsRow"] = ProfilerSettingsRow(errors, profilerGuard != null ? "afterGuard" : "live")
        };
        if (database.Count > 0) db["database"] = database;
        if (errors.Count > 0) db["errors"] = errors;
        return db;
    }

    private static string SqlServerIsolation(string level) => level?.Trim() switch
    {
        "0" => "unspecified",
        "1" => "read uncommitted",
        "2" => "read committed",
        "3" => "repeatable read",
        "4" => "serializable",
        "5" => "snapshot",
        null => Unavailable,
        _ => level
    };

    /// <summary>Runs one read-only statement through PX.DbServices (point.__executeReader). The enumeration is lazy, so the
    /// try/catch is around the enumeration itself; the point is disposed when it is IDisposable (review-api m6).</summary>
    private static List<object[]> Query(string sql, out string error)
    {
        error = null;
        try
        {
            return QueryCore(sql);
        }
        catch (Exception ex)
        {
            // Also catches type-load failures of PX.DbServices, which surface when QueryCore is compiled.
            error = ex.GetType().Name + ": " + ex.Message;
            return null;
        }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static List<object[]> QueryCore(string sql)
    {
        var rows = new List<object[]>();
        var point = ((PXDatabaseProvider)PXDatabase.Provider).CreateDbServicesPoint(null);
        try
        {
            // __executeReader is lazy: the statement runs (and fails) while enumerating, so the enumeration is inside
            // the caller's try/catch (review-api m6).
            foreach (var reader in point.__executeReader(sql))
            {
                var values = new object[reader.FieldCount];
                for (var i = 0; i < values.Length; i++) values[i] = reader.IsDBNull(i) ? null : reader.GetValue(i);
                rows.Add(values);
                if (rows.Count >= 500) break;
            }

            return rows;
        }
        finally
        {
            try { (point as IDisposable)?.Dispose(); }
            catch { /* best effort */ }
        }
    }

    private static string Str(object value) =>
        value == null ? null : Convert.ToString(value, CultureInfo.InvariantCulture)?.Trim();

    private static void ReadPairs(Dictionary<string, object> target, Dictionary<string, object> errors, string label, string sql)
    {
        var rows = Query(sql, out var error);
        if (rows == null)
        {
            target[label] = Unavailable;
            errors[label] = error;
            return;
        }

        foreach (var r in rows)
        {
            if (r.Length < 2 || r[0] == null) continue;
            target[Str(r[0])] = Str(r[1]);
        }
    }

    private static void ReadPgSettings(Dictionary<string, object> target, Dictionary<string, object> errors, string sql)
    {
        var rows = Query(sql, out var error);
        if (rows == null)
        {
            target["pg_settings"] = Unavailable;
            errors["pg_settings"] = error;
            return;
        }

        foreach (var r in rows)
        {
            if (r.Length < 2 || r[0] == null) continue;
            var unit = r.Length > 2 ? Str(r[2]) : null;
            target[Str(r[0])] = string.IsNullOrEmpty(unit) ? Str(r[1]) : Str(r[1]) + " " + unit;
        }
    }

    private static void ReadRow(Dictionary<string, object> target, Dictionary<string, object> errors, string label, string sql, params string[] names)
    {
        var rows = Query(sql, out var error);
        if (rows == null || rows.Count == 0)
        {
            foreach (var n in names) target[n] = Unavailable;
            errors[label] = error ?? "no rows";
            return;
        }

        var row = rows[0];
        for (var i = 0; i < names.Length; i++) target[names[i]] = i < row.Length ? Str(row[i]) : null;
    }

    /// <summary>Request Profiler state (review-api m9): PX.SM.PXPerformanceMonitor static members, read by reflection now.</summary>
    private static Dictionary<string, object> RequestProfiler(string readAt)
    {
        var result = new Dictionary<string, object>(StringComparer.Ordinal);
        try
        {
            var type = typeof(PXGraph).Assembly.GetType("PX.SM.PXPerformanceMonitor", throwOnError: false);
            if (type == null)
            {
                result["source"] = Unavailable;
                result["readAt"] = readAt;
                return result;
            }

            result["source"] = "PX.SM.PXPerformanceMonitor";
            foreach (var name in new[] { "IsEnabled", "SqlProfilerEnabled", "TraceEnabled", "TraceExceptionsEnabled", "IsLongOperationCollectMemory", "ProfilerAutoTurnOff",
                         "SqlProfilerStackTraceEnabled", "SaveRequestsToDb", "SaveSqlToDb" })
            {
                result[name] = ReadStatic(type, name);
            }
        }
        catch (Exception ex)
        {
            result["source"] = Unavailable;
            result["error"] = ex.Message;
        }

        result["readAt"] = readAt;
        return result;
    }

    /// <summary>
    /// The persisted Request Profiler settings (SMPerformanceSettings, a system table without CompanyID), read the way
    /// PXPerformanceMonitor.LoadSettings reads them. LoadSettings(true) applies this row when the site starts, before
    /// PX.Telemetry's first request.
    /// </summary>
    private static Dictionary<string, object> ProfilerSettingsRow(Dictionary<string, object> errors, string readAt)
    {
        var map = new Dictionary<string, object>(StringComparer.Ordinal) { ["source"] = "SMPerformanceSettings", ["readAt"] = readAt };
        var names = new[] { "ProfilerEnabled", "SqlProfiler", "SqlProfilerStackTrace", "TraceEnabled", "TraceExceptionsEnabled", "SaveRequestsToDb", "SaveSqlToDb" };
        var countErrors = new Dictionary<string, object>(StringComparer.Ordinal);
        CountRows<SMPerformanceSettings>(map, countErrors, "rows");
        foreach (var kv in countErrors) errors["requestProfilerSettingsRow." + kv.Key] = kv.Value;
        try
        {
            using (PXDataRecord rec = PXDatabase.SelectSingle<SMPerformanceSettings>(names.Select(n => new PXDataField(n)).ToArray()))
            {
                if (rec == null)
                {
                    map["row"] = "none";
                    return map;
                }

                for (var i = 0; i < names.Length; i++) map[names[i]] = rec.GetBoolean(i);
            }
        }
        catch (Exception ex)
        {
            map["source"] = Unavailable;
            errors["requestProfilerSettingsRow"] = ex.GetType().Name + ": " + ex.Message;
        }

        return map;
    }

    private static object ReadStatic(Type type, string name)
    {
        const BindingFlags flags = BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic;
        try
        {
            var prop = type.GetProperty(name, flags);
            if (prop != null && prop.GetIndexParameters().Length == 0) return Normalize(prop.GetValue(null));
            var field = type.GetField(name, flags);
            if (field != null) return Normalize(field.GetValue(null));
            return Unavailable;
        }
        catch
        {
            return Unavailable;
        }
    }

    private static object Normalize(object value) => value is bool b ? b : Str(value);

    // ------------------------------------------------------------------ data fingerprint

    private static Dictionary<string, object> DataFingerprint(PXGraph graph)
    {
        var values = new SortedDictionary<string, object>(StringComparer.Ordinal);
        var errors = new Dictionary<string, object>(StringComparer.Ordinal);

        CountRows<GLTran>(values, errors, "count.GLTran");
        CountRows<GLHistory>(values, errors, "count.GLHistory");
        CountRows<ARTran>(values, errors, "count.ARTran");
        CountRows<ARRegister>(values, errors, "count.ARRegister");
        CountRows<SOOrder>(values, errors, "count.SOOrder");
        CountRows<SOLine>(values, errors, "count.SOLine");
        CountRows<INSiteStatusByCostCenter>(values, errors, "count.INSiteStatusByCostCenter");
        CountRows<BAccount>(values, errors, "count.BAccount");
        CountRows<Customer>(values, errors, "count.Customer");
        CountRows<InventoryItem>(values, errors, "count.InventoryItem");

        Try(errors, "sum.GLTran", () =>
        {
            var r = SelectFrom<EnvGLTranSums>
                .AggregateTo<Sum<EnvGLTranSums.debitAmt>, Sum<EnvGLTranSums.creditAmt>, Count>
                .View.ReadOnly.Select(graph).RowCast<EnvGLTranSums>().FirstOrDefault();
            values["sum.GLTran.DebitAmt"] = r?.DebitAmt ?? 0m;
            values["sum.GLTran.CreditAmt"] = r?.CreditAmt ?? 0m;
        }, () =>
        {
            values["sum.GLTran.DebitAmt"] = Unavailable;
            values["sum.GLTran.CreditAmt"] = Unavailable;
        });

        Try(errors, "sum.ARTran", () =>
        {
            var r = SelectFrom<EnvARTranSums>
                .AggregateTo<Sum<EnvARTranSums.tranAmt>, Count>
                .View.ReadOnly.Select(graph).RowCast<EnvARTranSums>().FirstOrDefault();
            values["sum.ARTran.TranAmt"] = r?.TranAmt ?? 0m;
        }, () => values["sum.ARTran.TranAmt"] = Unavailable);

        Try(errors, "sum.SOOrder", () =>
        {
            var r = SelectFrom<EnvSOOrderSums>
                .AggregateTo<Sum<EnvSOOrderSums.curyOrderTotal>, Count>
                .View.ReadOnly.Select(graph).RowCast<EnvSOOrderSums>().FirstOrDefault();
            values["sum.SOOrder.CuryOrderTotal"] = r?.CuryOrderTotal ?? 0m;
        }, () => values["sum.SOOrder.CuryOrderTotal"] = Unavailable);

        Try(errors, "sum.INSiteStatusByCostCenter", () =>
        {
            var r = SelectFrom<EnvSiteStatusSums>
                .AggregateTo<Sum<EnvSiteStatusSums.qtyOnHand>, Sum<EnvSiteStatusSums.qtyAvail>, Count>
                .View.ReadOnly.Select(graph).RowCast<EnvSiteStatusSums>().FirstOrDefault();
            values["sum.INSiteStatusByCostCenter.QtyOnHand"] = r?.QtyOnHand ?? 0m;
            values["sum.INSiteStatusByCostCenter.QtyAvail"] = r?.QtyAvail ?? 0m;
        }, () =>
        {
            values["sum.INSiteStatusByCostCenter.QtyOnHand"] = Unavailable;
            values["sum.INSiteStatusByCostCenter.QtyAvail"] = Unavailable;
        });

        // PerfTestRecord batches
        CountRows<PerfTestRecord>(values, errors, "perfTestRecord.total");
        CountRows<PerfTestRecord>(values, errors, "perfTestRecord.READ-SEED",
            new PXDataFieldValue<PerfTestRecord.batchID>(PXDbType.NVarChar, 64, PerfCampaignConstants.ReadSeedBatch));
        CountRows<PerfTestRecord>(values, errors, "perfTestRecord.UPDATE-SEED",
            new PXDataFieldValue<PerfTestRecord.batchID>(PXDbType.NVarChar, 64, PerfCampaignConstants.UpdateSeedBatch));
        values["perfTestRecord.other"] =
            values["perfTestRecord.total"] is long t && values["perfTestRecord.READ-SEED"] is long rs && values["perfTestRecord.UPDATE-SEED"] is long us
                ? t - rs - us
                : (object)Unavailable;
        values.Remove("perfTestRecord.total");

        // Archived SOOrder rows: raw column, because DatabaseRecordStatus is not a DAC field (review-api m3)
        CountRows<SOOrder>(values, errors, "archived.SOOrder",
            new PXDataFieldValue("DatabaseRecordStatus", PXDbType.Int, 4, 0, PXComp.NE));

        var all = new Dictionary<string, object>(StringComparer.Ordinal);
        foreach (var kv in values) all[kv.Key] = kv.Value;

        var dAffected = new Dictionary<string, object>(StringComparer.Ordinal);
        foreach (var key in DAffectedKeys)
        {
            if (values.TryGetValue(key, out var v)) dAffected[key] = v;
        }

        var result = new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["values"] = all,
            ["soOrderArchived"] = values.TryGetValue("archived.SOOrder", out var archived) ? archived : Unavailable,
            ["dataFingerprintHash"] = Hash(values),
            ["dataFingerprintStaticHash"] = Hash(values.Where(kv => StaticKeys.Contains(kv.Key, StringComparer.Ordinal))),
            ["staticKeys"] = StaticKeys.Cast<object>().ToList(),
            ["dAffectedKeys"] = DAffectedKeys.Cast<object>().ToList(),
            ["dAffected"] = dAffected,
            ["perfTestRecord"] = new Dictionary<string, object>(StringComparer.Ordinal)
            {
                ["READ-SEED"] = values.TryGetValue("perfTestRecord.READ-SEED", out var a) ? a : Unavailable,
                ["UPDATE-SEED"] = values.TryGetValue("perfTestRecord.UPDATE-SEED", out var b) ? b : Unavailable,
                ["other"] = values.TryGetValue("perfTestRecord.other", out var c) ? c : Unavailable
            },
            ["note"] = "Soft-deleted ARRegister and Batch rows are not visible here; Get-PerfEnvironment.ps1 -TableCounts counts them."
        };
        if (errors.Count > 0) result["errors"] = errors;
        return result;
    }

    private static void CountRows<T>(IDictionary<string, object> values, IDictionary<string, object> errors, string key, params PXDataField[] restrictions)
        where T : IBqlTable
    {
        try
        {
            var fields = new List<PXDataField> { new PXDataField(SQLExpression.Count()) };
            fields.AddRange(restrictions);
            using (PXDataRecord rec = PXDatabase.SelectSingle<T>(fields.ToArray()))
            {
                var raw = rec?.GetValue(0);
                values[key] = raw == null || raw is DBNull ? 0L : Convert.ToInt64(raw, CultureInfo.InvariantCulture);
            }
        }
        catch (Exception ex)
        {
            values[key] = Unavailable;
            errors[key] = ex.GetType().Name + ": " + ex.Message;
        }
    }

    private static void Try(IDictionary<string, object> errors, string key, Action action, Action onError)
    {
        try
        {
            action();
        }
        catch (Exception ex)
        {
            errors[key] = ex.GetType().Name + ": " + ex.Message;
            onError();
        }
    }

    /// <summary>Canonical hash over (key, value) pairs sorted ordinally by key: "count:16hex".</summary>
    private static string Hash(IEnumerable<KeyValuePair<string, object>> pairs)
    {
        var oc = new PerfOrderedChecksum();
        foreach (var kv in pairs.OrderBy(p => p.Key, StringComparer.Ordinal)) oc.Add(kv.Key, kv.Value);
        return oc.ToString();
    }

    // ------------------------------------------------------------------ master data

    private static Dictionary<string, object> MasterData(PXGraph graph)
    {
        var hashes = new SortedDictionary<string, object>(StringComparer.Ordinal);
        var errors = new Dictionary<string, object>(StringComparer.Ordinal);

        Pairs(hashes, errors, "inventoryItem", () =>
            SelectFrom<InventoryItem>.View.ReadOnly.Select(graph).RowCast<InventoryItem>()
                .Select(r => new KeyValuePair<int, string>(r.InventoryID ?? 0, r.InventoryCD)));
        Pairs(hashes, errors, "customer", () =>
            SelectFrom<Customer>.View.ReadOnly.Select(graph).RowCast<Customer>()
                .Select(r => new KeyValuePair<int, string>(r.BAccountID ?? 0, r.AcctCD)));
        Pairs(hashes, errors, "account", () =>
            SelectFrom<GLAccount>.View.ReadOnly.Select(graph).RowCast<GLAccount>()
                .Select(r => new KeyValuePair<int, string>(r.AccountID ?? 0, r.AccountCD)));
        Pairs(hashes, errors, "sub", () =>
            SelectFrom<GLSub>.View.ReadOnly.Select(graph).RowCast<GLSub>()
                .Select(r => new KeyValuePair<int, string>(r.SubID ?? 0, r.SubCD)));
        Pairs(hashes, errors, "ledger", () =>
            SelectFrom<GLLedger>.View.ReadOnly.Select(graph).RowCast<GLLedger>()
                .Select(r => new KeyValuePair<int, string>(r.LedgerID ?? 0, r.LedgerCD)));
        Pairs(hashes, errors, "branch", () =>
            SelectFrom<GLBranch>.View.ReadOnly.Select(graph).RowCast<GLBranch>()
                .Select(r => new KeyValuePair<int, string>(r.BranchID ?? 0, r.BranchCD)));
        Pairs(hashes, errors, "inSite", () =>
            SelectFrom<INSite>.View.ReadOnly.Select(graph).RowCast<INSite>()
                .Select(r => new KeyValuePair<int, string>(r.SiteID ?? 0, r.SiteCD)));

        var contributors = new SortedDictionary<string, object>(StringComparer.Ordinal);
        try
        {
            foreach (var c in PerfScenarioRegistry.FingerprintContributors)
            {
                string name;
                try { name = c.Name ?? c.GetType().FullName; }
                catch { name = c.GetType().FullName; }

                try
                {
                    graph.Clear(PXClearOption.ClearQueriesOnly);
                    contributors[name] = c.Compute(graph) ?? "null";
                }
                catch (Exception ex)
                {
                    contributors[name] = Unavailable;
                    errors["contributor." + name] = ex.GetType().Name + ": " + ex.Message;
                }
            }
        }
        catch (Exception ex)
        {
            errors["contributors"] = ex.GetType().Name + ": " + ex.Message;
        }

        var combined = new List<KeyValuePair<string, object>>(hashes);
        combined.AddRange(contributors.Select(kv => new KeyValuePair<string, object>("contributor." + kv.Key, kv.Value)));

        var result = new Dictionary<string, object>(StringComparer.Ordinal);
        foreach (var kv in hashes) result[kv.Key] = kv.Value;
        var contributorMap = new Dictionary<string, object>(StringComparer.Ordinal);
        foreach (var kv in contributors) contributorMap[kv.Key] = kv.Value;
        result["contributors"] = contributorMap;
        result["masterDataHash"] = Hash(combined);
        if (errors.Count > 0) result["errors"] = errors;
        return result;
    }

    private static void Pairs(IDictionary<string, object> hashes, IDictionary<string, object> errors, string key, Func<IEnumerable<KeyValuePair<int, string>>> read)
    {
        try
        {
            hashes[key] = PerfDeterministic.PairsFingerprint(read().ToList());
        }
        catch (Exception ex)
        {
            hashes[key] = Unavailable;
            errors[key] = ex.GetType().Name + ": " + ex.Message;
        }
    }

    // ------------------------------------------------------------------ leftovers

    private static Dictionary<string, object> Leftovers(PXGraph graph, Dictionary<string, object> data)
    {
        var errors = new Dictionary<string, object>(StringComparer.Ordinal);
        object orders, invoices;

        try
        {
            orders = (long)SelectFrom<SOOrder>
                .Where<SOOrder.orderDesc.StartsWith<@P.AsString>>
                .View.ReadOnly.Select(graph, PerfCampaignConstants.DocumentTagPrefix.TrimEnd())
                .Count;
        }
        catch (Exception ex)
        {
            orders = Unavailable;
            errors["soOrders"] = ex.GetType().Name + ": " + ex.Message;
        }

        try
        {
            invoices = (long)SelectFrom<ARInvoice>
                .Where<ARInvoice.docDesc.StartsWith<@P.AsString>
                    .And<ARInvoice.released.IsEqual<False>>>
                .View.ReadOnly.Select(graph, PerfCampaignConstants.DocumentTagPrefix.TrimEnd())
                .Count;
        }
        catch (Exception ex)
        {
            invoices = Unavailable;
            errors["arInvoices"] = ex.GetType().Name + ": " + ex.Message;
        }

        object records = Unavailable;
        if (data.TryGetValue("perfTestRecord", out var p) && p is Dictionary<string, object> map && map.TryGetValue("other", out var other))
        {
            records = other;
        }

        object total = orders is long o && invoices is long i && records is long r ? o + i + r : (object)Unavailable;
        var result = new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["soOrdersTagged"] = orders,
            ["arInvoicesUnreleasedTagged"] = invoices,
            ["perfTestRecordOther"] = records,
            ["total"] = total
        };
        if (errors.Count > 0) result["errors"] = errors;
        return result;
    }
}
