using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;
using PX.Data;
using PX.Data.BQL;
using PX.Data.BQL.Fluent;
using PerfDBBenchmark.Core.DAC;
using PerfDBBenchmark.Core.Support;

namespace PerfDBBenchmark.Core.Scenarios;

/// <summary>
/// Writes one PerfTestResult row with ResultJson v1 (SPEC §3.2, §3.7) and refreshes the snapshot v2 (SPEC §3.8).
/// Metric doubles go through a guard that writes null for NaN and ±∞ (review-api m8). The snapshot write can never fail
/// the run: its error is kept in LastSnapshotError for the caller's message.
/// </summary>
public static class PerfResultWriter
{
    /// <summary>ResultJson must stay under 64 KB (UTF-8).</summary>
    public const int MaxResultJsonBytes = 64 * 1024;

    private const string CreatedBy = "Created by AcuPower LTD (acupowererp.com). ";

    [ThreadStatic] private static string _lastSnapshotError;

    /// <summary>The snapshot error of the last Persist call on this thread (null when the snapshot was written).</summary>
    public static string LastSnapshotError => _lastSnapshotError;

    public static PerfTestResult Persist(PXGraph graph, PerfRunRequest request, PerfTestDescriptor d, PerfRunMetrics m)
    {
        if (graph == null) throw new ArgumentNullException(nameof(graph));
        if (request == null) throw new ArgumentNullException(nameof(request));
        if (d == null) throw new ArgumentNullException(nameof(d));
        if (m == null) throw new ArgumentNullException(nameof(m));

        PerfScenarioRunner.TryGetDetail(m, out var detail);
        var resultJson = BuildResultJson(request, d, m, detail);

        var users = Math.Max(1, m.UserCount > 0 ? m.UserCount : d.Users);
        var isCore = string.Equals(d.Family, PerfFamilies.Core, StringComparison.Ordinal);
        var opsPerPass = detail?.OpsPerPass ?? d.DefaultOpsPerPass;
        var passes = detail?.MeasuredPassesPlanned ?? d.DefaultPasses;
        var countersEnabled = detail?.CountersEnabled ?? PerfExceptionCounter.Enabled;
        var elapsed = Dec(m.ElapsedMsPrecise, 3);

        var row = new PerfTestResult
        {
            InstanceName = Cut(request.InstanceName, 64),
            DatabaseType = Cut(request.DatabaseType, 64),
            TestCode = Cut(d.TestCode, 64),
            TestCategory = Cut(d.Category, 64),
            ExecutionMode = Cut(d.ExecutionMode, 24),
            DisplayName = Cut(d.DisplayName, 128),
            RunID = request.RequestID,
            RequestedAtUtc = request.RequestedAtUtc,
            RecordsCount = isCore ? request.NumberOfRecords : opsPerPass,
            Iterations = passes,
            BatchSize = isCore ? request.BatchSize : 0,
            MaxThreads = users,
            ElapsedMs = elapsed == null ? 0 : (int)Math.Min(int.MaxValue, Math.Round(elapsed.Value, MidpointRounding.AwayFromZero)),
            Notes = Cut(CreatedBy + StatusSummary(d, m), 1024),
            CapturedAtUtc = StorageUtcNow(),

            CampaignID = request.CampaignID,
            RepetitionNo = request.RepetitionNo,
            IsWarmup = request.IsWarmup,
            RunBlock = Cut(request.RunBlock ?? d.RunBlock, 8),
            OrderPosition = request.OrderPosition,
            Family = Cut(d.Family, 32),
            MethodologyVersion = PerfMethodology.Version,
            ParamsHash = Cut(m.ParamsHash, 16),
            UserCount = users,
            ElapsedMsPrecise = elapsed,
            HeadlineValue = Dec(m.HeadlineValue, 4),
            HeadlineUnit = Cut(d.HeadlineUnit, 16),
            HigherIsBetter = d.HigherIsBetter,
            OpsCount = m.OpsCount,
            OpsPerSec = Dec(m.OpsPerSec, 3),
            P50Ms = Dec(m.P50Ms, 3),
            P95Ms = Dec(m.P95Ms, 3),
            P99Ms = m.P99Ms.HasValue ? Dec(m.P99Ms.Value, 3) : null,
            MaxOpMs = Dec(m.MaxOpMs, 3),
            RowsReturned = m.RowsReturned,
            Checksum = Cut(m.Checksum, 40),
            ErrorCount = m.ErrorCount,
            DeadlockCount = countersEnabled ? m.DeadlockCount : (int?)null,
            RetryCount = countersEnabled ? m.RetryCount : (int?)null,
            LockViolationCount = countersEnabled ? m.LockViolationCount : (int?)null,
            TimeoutCount = countersEnabled ? m.TimeoutCount : (int?)null,
            WorkersObservedPeak = m.WorkersObservedPeak,
            Status = Cut(m.Status ?? PerfRunStatuses.Completed, 16),
            InvalidReason = Cut(m.InvalidReason, 256),
            DllSha256 = Cut(PerfRuntimeInfo.DllSha256, 64),
            AppDomainStartUtc = Cut(PerfRuntimeInfo.AppDomainStartUtc, 40),
            ResultJson = resultJson
        };

        var cache = graph.Caches[typeof(PerfTestResult)];
        var inserted = (PerfTestResult)cache.Insert(row) ?? throw new PXException("The benchmark result row could not be inserted.");
        graph.Persist();
        cache.Clear();
        cache.ClearQueryCache();

        _lastSnapshotError = null;
        try
        {
            WriteSnapshot(graph, request.InstanceName, request.DatabaseType);
        }
        catch (Exception ex)
        {
            _lastSnapshotError = ex.GetType().Name + ": " + ex.Message;
        }

        return inserted;
    }

    /// <summary>Rewrites the local snapshot v2: latest Completed, non-warm-up row per (TestCode, ParamsHash), by ResultID
    /// descending; unknown and non-comparable codes are skipped (SPEC §3.8, F17, F18, F28).</summary>
    internal static void WriteSnapshot(PXGraph graph, string instanceName, string databaseType)
    {
        graph.Clear(PXClearOption.ClearQueriesOnly);
        var rows = SelectFrom<PerfTestResultSlim>
            .Where<PerfTestResultSlim.status.IsEqual<@P.AsString>>
            .OrderBy<PerfTestResultSlim.resultID.Desc>
            .View.ReadOnly.Select(graph, PerfRunStatuses.Completed)
            .RowCast<PerfTestResultSlim>()
            .ToList();

        var latest = new List<(PerfTestResultSlim Row, PerfTestDescriptor Descriptor)>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var r in rows)
        {
            if (r.IsWarmup == true) continue;
            if (!PerfScenarioRegistry.TryGet(r.TestCode, out var dd) || dd.ExcludeFromComparison) continue;
            var key = dd.TestCode + "|" + (r.ParamsHash ?? string.Empty);
            if (!seen.Add(key)) continue;
            latest.Add((r, dd));
        }

        var items = latest
            .OrderBy(x => x.Descriptor.SortOrder)
            .ThenByDescending(x => x.Row.ResultID ?? 0)
            .Select(x => new PerfSnapshotItem
            {
                ResultID = x.Row.ResultID ?? 0,
                TestCode = x.Descriptor.TestCode,
                TestCategory = x.Row.TestCategory,
                ExecutionMode = x.Row.ExecutionMode,
                DisplayName = x.Row.DisplayName,
                RecordsCount = x.Row.RecordsCount ?? 0,
                Iterations = x.Row.Iterations ?? 0,
                BatchSize = x.Row.BatchSize ?? 0,
                MaxThreads = x.Row.MaxThreads ?? 0,
                ElapsedMs = x.Row.ElapsedMs ?? 0,
                Notes = x.Row.Notes,
                CapturedAtUtc = DateTime.SpecifyKind(x.Row.CapturedAtUtc ?? DateTime.UtcNow, DateTimeKind.Utc),
                Family = x.Row.Family ?? x.Descriptor.Family,
                ShortLabel = x.Descriptor.ShortLabel,
                Status = x.Row.Status,
                IsWarmup = x.Row.IsWarmup ?? false,
                RepetitionNo = x.Row.RepetitionNo,
                CampaignID = x.Row.CampaignID,
                UserCount = x.Row.UserCount ?? 0,
                ElapsedMsPrecise = x.Row.ElapsedMsPrecise,
                HeadlineValue = x.Row.HeadlineValue,
                HeadlineUnit = x.Row.HeadlineUnit,
                HigherIsBetter = x.Row.HigherIsBetter ?? false,
                OpsPerSec = x.Row.OpsPerSec,
                P95Ms = x.Row.P95Ms,
                ErrorCount = x.Row.ErrorCount ?? 0,
                RowsReturned = x.Row.RowsReturned ?? 0,
                Checksum = x.Row.Checksum,
                ParamsHash = x.Row.ParamsHash,
                DllSha256 = x.Row.DllSha256
            })
            .ToList();

        PerfSnapshotService.WriteLocalSnapshot(items, instanceName, databaseType);
    }

    // ------------------------------------------------------------------ ResultJson v1

    internal static string BuildResultJson(PerfRunRequest request, PerfTestDescriptor d, PerfRunMetrics m, PerfRunDetail detail)
    {
        var serializer = new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 64 };
        var doc = BuildDocument(request, d, m, detail, serializer);

        var json = serializer.Serialize(doc);
        if (Encoding.UTF8.GetByteCount(json) <= MaxResultJsonBytes) return json;

        // Shrink step by step until the document fits (SPEC §3.7: lists truncated with "…+N more").
        var steps = new List<Action>
        {
            () => TruncateList(doc, "errors", "failedOps", 20),
            () => TruncateMap(doc, "invariants", "checks", 20),
            () => TruncateTopMap(doc, "notes", 20, 200),
            () => TruncateTopMap(doc, "parity", 50, 200),
            () => doc.Remove("extra"),
            () => TruncatePasses(doc, "passes", 12),
            () => TruncatePasses(doc, "warmupPasses", 4),
            () => ShrinkEnv(doc),
            () => doc.Remove("env")
        };

        foreach (var step in steps)
        {
            step();
            doc["truncated"] = true;
            json = serializer.Serialize(doc);
            if (Encoding.UTF8.GetByteCount(json) <= MaxResultJsonBytes) return json;
        }

        var minimal = new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["v"] = PerfMethodology.ResultJsonVersion,
            ["methodologyVersion"] = PerfMethodology.Version,
            ["testCode"] = d.TestCode,
            ["status"] = m.Status,
            ["invalidReason"] = m.InvalidReason,
            ["paramsHash"] = m.ParamsHash,
            ["truncated"] = true,
            ["note"] = "ResultJson exceeded 64 KB after truncation; only the identity is kept."
        };
        return serializer.Serialize(minimal);
    }

    private static Dictionary<string, object> BuildDocument(PerfRunRequest request, PerfTestDescriptor d, PerfRunMetrics m, PerfRunDetail detail, JavaScriptSerializer serializer)
    {
        var doc = new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["v"] = PerfMethodology.ResultJsonVersion,
            ["methodologyVersion"] = PerfMethodology.Version,
            ["testCode"] = d.TestCode,
            ["legacyTestCode"] = d.LegacyTestCode,
            ["scenarioVersion"] = d.ScenarioVersion,
            ["status"] = m.Status,
            ["invalidReason"] = m.InvalidReason
        };

        object prms;
        try
        {
            prms = string.IsNullOrEmpty(m.ParamsJson) ? new Dictionary<string, object>() : serializer.DeserializeObject(m.ParamsJson);
        }
        catch
        {
            prms = null;
        }

        doc["params"] = prms;
        doc["paramsJson"] = m.ParamsJson;
        doc["paramsHash"] = m.ParamsHash;
        doc["budget"] = new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["runBudgetSec"] = detail?.RunBudgetSec ?? (request.RunBudgetSec is int b && b > 0 ? b : (int)PerfRunPlan.DefaultRunBudget.TotalSeconds),
            ["source"] = detail?.RunBudgetSource ?? (request.RunBudgetSec is int b2 && b2 > 0 ? "control" : "default")
        };

        doc["phasesMs"] = new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["prepare"] = J(detail?.PrepareMs ?? m.PrepareMs),
            ["createWorkers"] = J(detail?.CreateWorkersMs ?? 0),
            ["warmupOps"] = J(detail?.WarmupOpsMs ?? 0),
            ["warmupPasses"] = J(detail?.WarmupPassesMs ?? 0),
            ["measured"] = J(detail?.MeasuredMs ?? m.ElapsedMsPrecise),
            ["verify"] = J(detail?.VerifyMs ?? m.VerifyMs),
            ["cleanup"] = J(detail?.CleanupMs ?? m.CleanupMs),
            ["total"] = J(detail?.TotalMs ?? m.TotalMs)
        };

        var gated = (detail?.WorkersRequested ?? m.UserCount) > 1;
        doc["passes"] = detail == null
            ? (object)m.PassWallMs.Select((w, i) => new Dictionary<string, object> { ["pass"] = i, ["wallMs"] = J(w) }).ToList()
            : detail.MeasuredPasses.Select(p => PassJson(p, gated)).ToList();
        doc["warmupPasses"] = detail == null
            ? new List<object>()
            : detail.WarmupPasses.Select(p => (object)new Dictionary<string, object>(StringComparer.Ordinal)
            {
                ["pass"] = p.Pass,
                ["wallMs"] = J(p.WallMs),
                ["ops"] = p.Ops,
                ["okOps"] = p.OkOps,
                ["errors"] = p.Errors,
                ["digest"] = p.Digest
            }).ToList();

        if (detail?.WarmupOps != null)
        {
            var w = detail.WarmupOps;
            doc["warmupOps"] = new Dictionary<string, object>(StringComparer.Ordinal)
            {
                ["pass"] = w.Pass,
                ["wallMs"] = J(w.WallMs),
                ["ops"] = w.Ops,
                ["okOps"] = w.OkOps,
                ["errors"] = w.Errors,
                ["digest"] = w.Digest
            };
        }

        var subPhases = new Dictionary<string, object>(StringComparer.Ordinal);
        if (detail != null)
        {
            foreach (var kv in detail.SubPhases)
            {
                subPhases[kv.Key] = new Dictionary<string, object>(StringComparer.Ordinal)
                {
                    ["n"] = kv.Value.TryGetValue("n", out var n) ? n : 0,
                    ["p50Ms"] = kv.Value.TryGetValue("p50Ms", out var p50) && p50 is double d50 ? J(d50) : null,
                    ["p95Ms"] = kv.Value.TryGetValue("p95Ms", out var p95) && p95 is double d95 ? J(d95) : null
                };
            }
        }

        doc["subPhases"] = subPhases;

        doc["workers"] = new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["requested"] = detail?.WorkersRequested ?? m.UserCount,
            ["observedPeak"] = m.WorkersObservedPeak,
            ["opsInFlightPeak"] = m.OpsInFlightPeak,
            ["lowOverlap"] = detail?.LowOverlap ?? false,
            ["distinctThreads"] = m.DistinctThreads,
            ["perWorkerOkOps"] = detail?.PerWorkerOkOps.ToList() ?? new List<int>(),
            ["gateWaitMs"] = J(detail?.GateWaitMs ?? 0),
            ["threadPoolSizeConfigured"] = detail?.ThreadPoolSizeConfigured ?? PerfRuntimeInfo.ConfiguredThreadPoolSize
        };

        var countersEnabled = detail?.CountersEnabled ?? PerfExceptionCounter.Enabled;
        var failedOps = detail?.FailedOps.Cast<object>().ToList() ?? new List<object>();
        var failedTotal = detail?.FailedOpsTotal ?? 0;
        if (failedTotal > failedOps.Count) failedOps.Add("…+" + (failedTotal - failedOps.Count).ToString(CultureInfo.InvariantCulture) + " more");
        doc["errors"] = new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["count"] = m.ErrorCount,
            ["warmup"] = detail?.WarmupErrorCount ?? 0,
            ["contention"] = detail?.ContentionErrorCount ?? 0,         // failed operations: deadlock, lock violation, time-out, serialization failure
            ["nonContention"] = detail?.NonContentionErrorCount ?? 0,   // every other failed operation (status rule 7b)
            ["nonContentionWithContentionSeen"] = detail?.NonContentionWithContentionSeenCount ?? 0,   // of nonContention: met a contention exception first
            ["deadlocks"] = countersEnabled ? m.DeadlockCount : (object)null,
            ["retries"] = countersEnabled ? m.RetryCount : (object)null,
            ["lockViolations"] = countersEnabled ? m.LockViolationCount : (object)null,
            ["timeouts"] = countersEnabled ? m.TimeoutCount : (object)null,
            ["countersEnabled"] = countersEnabled,
            ["countedOncePerException"] = true,
            ["samples"] = detail?.ErrorSamples.ToList() ?? new List<string>(),
            ["failedOps"] = failedOps
        };

        doc["parity"] = detail != null ? ToObjectMap(detail.Parity) : new Dictionary<string, object>();
        doc["invariants"] = new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["ok"] = detail?.InvariantsOk ?? true,
            ["appliedToStatus"] = detail?.InvariantsApplied ?? true,
            ["checks"] = detail != null ? ToObjectMap(detail.InvariantChecks) : new Dictionary<string, object>()
        };

        if (detail?.CappedKind != null)
        {
            doc["capped"] = new Dictionary<string, object>(StringComparer.Ordinal)
            {
                ["kind"] = detail.CappedKind,
                ["atPass"] = detail.CappedAtPass,
                ["atOpIndex"] = detail.CappedAtOpIndex,
                ["limitMs"] = detail.CappedLimitMs.HasValue ? J(detail.CappedLimitMs.Value) : null
            };
        }
        else
        {
            doc["capped"] = null;
        }

        doc["aborted"] = detail?.Aborted ?? false;
        doc["appCpuMs"] = J(m.AppCpuMs);
        doc["notes"] = detail != null ? ToObjectMap(detail.Notes) : new Dictionary<string, object>();
        doc["server"] = new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["instance"] = request.InstanceName,
            ["dbEngine"] = request.DatabaseType,
            ["dbmsVersion"] = PerfRuntimeInfo.DbmsVersionLabel,
            ["acumaticaBuild"] = PerfRuntimeInfo.AcumaticaBuild,
            ["dllSha256"] = PerfRuntimeInfo.DllSha256,
            ["appDomainStartUtc"] = PerfRuntimeInfo.AppDomainStartUtc,
            ["throttler"] = "none"
        };

        // Scenario-provided entries (PerfRunMetrics.Result): "env" is ENV_CAPTURE's section; anything else goes to "extra".
        if (m.Result.Count > 0)
        {
            var extra = new Dictionary<string, object>(StringComparer.Ordinal);
            foreach (var kv in m.Result.OrderBy(k => k.Key, StringComparer.Ordinal))
            {
                if (string.Equals(kv.Key, "env", StringComparison.Ordinal)) doc["env"] = Sanitize(kv.Value, 0);
                else extra[kv.Key] = Sanitize(kv.Value, 0);
            }

            if (extra.Count > 0) doc["extra"] = extra;
        }

        return doc;
    }

    private static Dictionary<string, object> PassJson(PerfPassRecord p, bool gated)
    {
        var map = new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["pass"] = p.Pass,
            ["wallMs"] = J(p.WallMs),
            ["wallInclResetsMs"] = J(p.WallInclResetsMs),
            ["ops"] = p.Ops,
            ["okOps"] = p.OkOps,
            ["errors"] = p.Errors,
            ["p50Ms"] = J(p.P50Ms),
            ["p95Ms"] = J(p.P95Ms),
            ["maxMs"] = J(p.MaxMs),
            ["steadyOpsPerMin"] = p.SteadyOpsPerMin.HasValue ? J(p.SteadyOpsPerMin.Value) : null,
            ["digest"] = p.Digest
        };
        if (gated)
        {
            map["workersActivePeak"] = p.ActivePeak;
            map["opsInFlightPeak"] = p.InFlightPeak;
            map["gateOpened"] = p.GateOpened;
        }

        if (p.Interrupted) map["interrupted"] = true;
        return map;
    }

    private static string StatusSummary(PerfTestDescriptor d, PerfRunMetrics m)
    {
        var sb = new StringBuilder();
        sb.Append(m.Status ?? PerfRunStatuses.Completed);
        if (!string.IsNullOrEmpty(m.InvalidReason)) sb.Append(" (").Append(m.InvalidReason).Append(')');
        sb.Append('.');
        if (d.HeadlineKind != PerfHeadlineKinds.None)
        {
            var hv = Dec(m.HeadlineValue, 3);
            sb.Append(" Headline ").Append(hv.HasValue ? hv.Value.ToString("0.###", CultureInfo.InvariantCulture) + " " + d.HeadlineUnit : "n/a");
            sb.Append(" (").Append(d.HeadlineKind).Append(");");
            sb.Append(" measured ops ").Append(m.OpsCount.ToString(CultureInfo.InvariantCulture));
            sb.Append("; passes ").Append(m.PassWallMs.Count.ToString(CultureInfo.InvariantCulture));
            sb.Append("; errors ").Append(m.ErrorCount.ToString(CultureInfo.InvariantCulture));
            if (!string.IsNullOrEmpty(m.Checksum)) sb.Append("; checksum ").Append(m.Checksum);
            sb.Append('.');
        }

        if (!string.IsNullOrWhiteSpace(m.Notes)) sb.Append(' ').Append(m.Notes.Trim());
        return sb.ToString();
    }

    // ------------------------------------------------------------------ guards and helpers

    /// <summary>double → decimal with the NaN/∞ guard (null) and rounding; null when outside the decimal range.</summary>
    internal static decimal? Dec(double value, int decimals)
    {
        if (double.IsNaN(value) || double.IsInfinity(value)) return null;
        if (Math.Abs(value) >= 1e15) return null;
        try
        {
            return Math.Round((decimal)value, decimals, MidpointRounding.AwayFromZero);
        }
        catch (OverflowException)
        {
            return null;
        }
    }

    /// <summary>JSON number: null for NaN/∞, otherwise rounded to 3 decimals.</summary>
    internal static object J(double value)
    {
        if (double.IsNaN(value) || double.IsInfinity(value)) return null;
        return Math.Round(value, 3, MidpointRounding.AwayFromZero);
    }

    private static string Cut(string value, int max)
    {
        if (value == null) return null;
        return value.Length <= max ? value : value.Substring(0, max);
    }

    private static DateTime StorageUtcNow() => DateTime.SpecifyKind(DateTime.UtcNow, DateTimeKind.Unspecified);

    private static Dictionary<string, object> ToObjectMap(IEnumerable<KeyValuePair<string, string>> source)
    {
        var map = new Dictionary<string, object>(StringComparer.Ordinal);
        foreach (var kv in source.OrderBy(k => k.Key, StringComparer.Ordinal)) map[kv.Key] = kv.Value;
        return map;
    }

    /// <summary>Makes scenario-provided values JSON-safe: NaN/∞ become null, DateTime becomes ISO text, nesting is limited.</summary>
    private static object Sanitize(object value, int depth)
    {
        if (depth > 12) return "(nested too deep)";
        switch (value)
        {
            case null: return null;
            case string s: return s;
            case bool b: return b;
            case double x: return J(x);
            case float f: return J(f);
            case decimal dm: return dm;
            case int or long or short or byte or uint or ulong or ushort or sbyte: return value;
            case DateTime dt: return (dt.Kind == DateTimeKind.Unspecified ? DateTime.SpecifyKind(dt, DateTimeKind.Utc) : dt.ToUniversalTime()).ToString("o", CultureInfo.InvariantCulture);
            case Guid g: return g.ToString("D");
            case IDictionary<string, object> map:
                var copy = new Dictionary<string, object>(StringComparer.Ordinal);
                foreach (var kv in map) copy[kv.Key] = Sanitize(kv.Value, depth + 1);
                return copy;
            case IDictionary<string, string> smap:
                var scopy = new Dictionary<string, object>(StringComparer.Ordinal);
                foreach (var kv in smap) scopy[kv.Key] = kv.Value;
                return scopy;
            case IEnumerable seq:
                var list = new List<object>();
                foreach (var item in seq) list.Add(Sanitize(item, depth + 1));
                return list;
            default:
                return Convert.ToString(value, CultureInfo.InvariantCulture);
        }
    }

    private static void TruncateList(Dictionary<string, object> doc, string section, string key, int keep)
    {
        if (!(doc.TryGetValue(section, out var s) && s is Dictionary<string, object> map)) return;
        if (!(map.TryGetValue(key, out var v) && v is IList list) || list.Count <= keep) return;
        var items = list.Cast<object>().ToList();
        var kept = items.Take(keep).ToList();
        kept.Add("…+" + (items.Count - keep).ToString(CultureInfo.InvariantCulture) + " more");
        map[key] = kept;
    }

    private static void TruncateMap(Dictionary<string, object> doc, string section, string key, int keep)
    {
        if (!(doc.TryGetValue(section, out var s) && s is Dictionary<string, object> map)) return;
        if (!(map.TryGetValue(key, out var v) && v is Dictionary<string, object> inner) || inner.Count <= keep) return;
        var kept = new Dictionary<string, object>(StringComparer.Ordinal);
        foreach (var kv in inner.Take(keep)) kept[kv.Key] = kv.Value;
        kept["…"] = "+" + (inner.Count - keep).ToString(CultureInfo.InvariantCulture) + " more";
        map[key] = kept;
    }

    private static void TruncateTopMap(Dictionary<string, object> doc, string key, int keep, int maxValueLength)
    {
        if (!(doc.TryGetValue(key, out var v) && v is Dictionary<string, object> map)) return;
        var kept = new Dictionary<string, object>(StringComparer.Ordinal);
        foreach (var kv in map.Take(keep))
        {
            kept[kv.Key] = kv.Value is string s && s.Length > maxValueLength ? s.Substring(0, maxValueLength) + "…" : kv.Value;
        }

        if (map.Count > keep) kept["…"] = "+" + (map.Count - keep).ToString(CultureInfo.InvariantCulture) + " more";
        doc[key] = kept;
    }

    private static void TruncatePasses(Dictionary<string, object> doc, string key, int keep)
    {
        if (!(doc.TryGetValue(key, out var v) && v is IList list) || list.Count <= keep) return;
        var items = list.Cast<object>().ToList();
        var kept = items.Take(keep).ToList();
        kept.Add("…+" + (items.Count - keep).ToString(CultureInfo.InvariantCulture) + " more");
        doc[key] = kept;
    }

    private static void ShrinkEnv(Dictionary<string, object> doc)
    {
        if (!(doc.TryGetValue("env", out var v) && v is Dictionary<string, object> env)) return;
        foreach (var key in env.Keys.ToList())
        {
            if (env[key] is Dictionary<string, object> section)
            {
                foreach (var inner in section.Keys.ToList())
                {
                    if (section[inner] is string s && s.Length > 256) section[inner] = s.Substring(0, 256) + "…";
                    if (section[inner] is IList l && l.Count > 40)
                    {
                        var items = l.Cast<object>().Take(40).ToList();
                        items.Add("…+" + (l.Count - 40).ToString(CultureInfo.InvariantCulture) + " more");
                        section[inner] = items;
                    }
                }
            }
        }
    }
}

/// <summary>Slim read of PerfTestResult without ResultJson, used to rebuild the snapshot after every run.</summary>
[Serializable]
[PXHidden]
[PXProjection(typeof(Select<PerfTestResult>), Persistent = false)]
public sealed class PerfTestResultSlim : PXBqlTable, IBqlTable
{
    public abstract class resultID : BqlInt.Field<resultID> { }
    [PXDBInt(IsKey = true, BqlField = typeof(PerfTestResult.resultID))]
    public int? ResultID { get; set; }

    public abstract class testCode : BqlString.Field<testCode> { }
    [PXDBString(64, IsUnicode = true, BqlField = typeof(PerfTestResult.testCode))]
    public string TestCode { get; set; }

    public abstract class testCategory : BqlString.Field<testCategory> { }
    [PXDBString(64, IsUnicode = true, BqlField = typeof(PerfTestResult.testCategory))]
    public string TestCategory { get; set; }

    public abstract class executionMode : BqlString.Field<executionMode> { }
    [PXDBString(24, IsUnicode = true, BqlField = typeof(PerfTestResult.executionMode))]
    public string ExecutionMode { get; set; }

    public abstract class displayName : BqlString.Field<displayName> { }
    [PXDBString(128, IsUnicode = true, BqlField = typeof(PerfTestResult.displayName))]
    public string DisplayName { get; set; }

    public abstract class recordsCount : BqlInt.Field<recordsCount> { }
    [PXDBInt(BqlField = typeof(PerfTestResult.recordsCount))]
    public int? RecordsCount { get; set; }

    public abstract class iterations : BqlInt.Field<iterations> { }
    [PXDBInt(BqlField = typeof(PerfTestResult.iterations))]
    public int? Iterations { get; set; }

    public abstract class batchSize : BqlInt.Field<batchSize> { }
    [PXDBInt(BqlField = typeof(PerfTestResult.batchSize))]
    public int? BatchSize { get; set; }

    public abstract class maxThreads : BqlInt.Field<maxThreads> { }
    [PXDBInt(BqlField = typeof(PerfTestResult.maxThreads))]
    public int? MaxThreads { get; set; }

    public abstract class elapsedMs : BqlInt.Field<elapsedMs> { }
    [PXDBInt(BqlField = typeof(PerfTestResult.elapsedMs))]
    public int? ElapsedMs { get; set; }

    public abstract class notes : BqlString.Field<notes> { }
    [PXDBString(1024, IsUnicode = true, BqlField = typeof(PerfTestResult.notes))]
    public string Notes { get; set; }

    public abstract class capturedAtUtc : BqlDateTime.Field<capturedAtUtc> { }
    [PXDBDateAndTime(UseTimeZone = false, PreserveTime = true, BqlField = typeof(PerfTestResult.capturedAtUtc))]
    public DateTime? CapturedAtUtc { get; set; }

    public abstract class campaignID : BqlGuid.Field<campaignID> { }
    [PXDBGuid(BqlField = typeof(PerfTestResult.campaignID))]
    public Guid? CampaignID { get; set; }

    public abstract class repetitionNo : BqlInt.Field<repetitionNo> { }
    [PXDBInt(BqlField = typeof(PerfTestResult.repetitionNo))]
    public int? RepetitionNo { get; set; }

    public abstract class isWarmup : BqlBool.Field<isWarmup> { }
    [PXDBBool(BqlField = typeof(PerfTestResult.isWarmup))]
    public bool? IsWarmup { get; set; }

    public abstract class family : BqlString.Field<family> { }
    [PXDBString(32, IsUnicode = true, BqlField = typeof(PerfTestResult.family))]
    public string Family { get; set; }

    public abstract class paramsHash : BqlString.Field<paramsHash> { }
    [PXDBString(16, IsUnicode = true, BqlField = typeof(PerfTestResult.paramsHash))]
    public string ParamsHash { get; set; }

    public abstract class userCount : BqlInt.Field<userCount> { }
    [PXDBInt(BqlField = typeof(PerfTestResult.userCount))]
    public int? UserCount { get; set; }

    public abstract class elapsedMsPrecise : BqlDecimal.Field<elapsedMsPrecise> { }
    [PXDBDecimal(3, BqlField = typeof(PerfTestResult.elapsedMsPrecise))]
    public decimal? ElapsedMsPrecise { get; set; }

    public abstract class headlineValue : BqlDecimal.Field<headlineValue> { }
    [PXDBDecimal(4, BqlField = typeof(PerfTestResult.headlineValue))]
    public decimal? HeadlineValue { get; set; }

    public abstract class headlineUnit : BqlString.Field<headlineUnit> { }
    [PXDBString(16, IsUnicode = true, BqlField = typeof(PerfTestResult.headlineUnit))]
    public string HeadlineUnit { get; set; }

    public abstract class higherIsBetter : BqlBool.Field<higherIsBetter> { }
    [PXDBBool(BqlField = typeof(PerfTestResult.higherIsBetter))]
    public bool? HigherIsBetter { get; set; }

    public abstract class opsPerSec : BqlDecimal.Field<opsPerSec> { }
    [PXDBDecimal(3, BqlField = typeof(PerfTestResult.opsPerSec))]
    public decimal? OpsPerSec { get; set; }

    public abstract class p95Ms : BqlDecimal.Field<p95Ms> { }
    [PXDBDecimal(3, BqlField = typeof(PerfTestResult.p95Ms))]
    public decimal? P95Ms { get; set; }

    public abstract class rowsReturned : BqlLong.Field<rowsReturned> { }
    [PXDBLong(BqlField = typeof(PerfTestResult.rowsReturned))]
    public long? RowsReturned { get; set; }

    public abstract class checksum : BqlString.Field<checksum> { }
    [PXDBString(40, IsUnicode = true, BqlField = typeof(PerfTestResult.checksum))]
    public string Checksum { get; set; }

    public abstract class errorCount : BqlInt.Field<errorCount> { }
    [PXDBInt(BqlField = typeof(PerfTestResult.errorCount))]
    public int? ErrorCount { get; set; }

    public abstract class status : BqlString.Field<status> { }
    [PXDBString(16, IsUnicode = true, BqlField = typeof(PerfTestResult.status))]
    public string Status { get; set; }

    public abstract class dllSha256 : BqlString.Field<dllSha256> { }
    [PXDBString(64, IsUnicode = true, BqlField = typeof(PerfTestResult.dllSha256))]
    public string DllSha256 { get; set; }
}
