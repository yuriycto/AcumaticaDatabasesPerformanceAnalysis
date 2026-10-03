using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Management;
using System.Net;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using PX.Data;
using PerfDBBenchmark.Core.DAC;
using PerfDBBenchmark.Core.Scenarios;

namespace PerfDBBenchmark.Core.Support;

/// <summary>The 12 legacy test codes (SPEC §2.3). They are aliases of the CORE_* codes (PerfLegacyAliases).</summary>
public static class PerfBenchmarkTestCodes
{
    public const string SequentialRead = "SEQ_READ";
    public const string SequentialWrite = "SEQ_WRITE";
    public const string SequentialUpdate = "SEQ_UPDATE";
    public const string SequentialDelete = "SEQ_DELETE";
    public const string SequentialComplexJoin = "SEQ_COMPLEX";
    public const string SequentialProjection = "SEQ_PROJECTION";
    public const string ParallelRead = "PAR_READ";
    public const string ParallelWrite = "PAR_WRITE";
    public const string ParallelUpdate = "PAR_UPDATE";
    public const string ParallelDelete = "PAR_DELETE";
    public const string ParallelComplexJoin = "PAR_COMPLEX";
    public const string ParallelProjection = "PAR_PROJECTION";
}

public static class PerfBenchmarkActionNames
{
    public const string RefreshStatus = "RefreshStatus";
    public const string RunSequentialRead = "RunSequentialRead";
    public const string RunSequentialWrite = "RunSequentialWrite";
    public const string RunSequentialUpdate = "RunSequentialUpdate";
    public const string RunSequentialDelete = "RunSequentialDelete";
    public const string RunSequentialComplexJoin = "RunSequentialComplexJoin";
    public const string RunSequentialProjection = "RunSequentialProjection";
    public const string RunParallelRead = "RunParallelRead";
    public const string RunParallelWrite = "RunParallelWrite";
    public const string RunParallelUpdate = "RunParallelUpdate";
    public const string RunParallelDelete = "RunParallelDelete";
    public const string RunParallelComplexJoin = "RunParallelComplexJoin";
    public const string RunParallelProjection = "RunParallelProjection";
    public const string RunBenchmark = PerfScenarioCodes.RunBenchmarkAction;
    public const string ClearTestRecords = PerfScenarioCodes.ClearTestRecordsAction;
    public const string AbortBenchmark = PerfScenarioCodes.AbortBenchmarkAction;
}

public static class PerfBenchmarkDescriptions
{
    public const string SequentialRead = "Legacy button: runs CORE_READ_1U (load 10,000 records, 1 worker).";
    public const string SequentialWrite = "Legacy button: runs CORE_INSERT_1U (save 10,000 new records, 1 worker).";
    public const string SequentialUpdate = "Legacy button: runs CORE_UPDATE_1U (change 10,000 records, 1 worker).";
    public const string SequentialDelete = "Legacy button: runs CORE_DELETE_1U (delete 10,000 records, 1 worker).";
    public const string SequentialComplexJoin = "Legacy button: runs CORE_JOIN_FULL_1U (stock availability list, all columns, 1 worker).";
    public const string SequentialProjection = "Legacy button: runs CORE_JOIN_SLIM_1U (stock availability list, only the needed columns, 1 worker).";
    public const string ParallelRead = "Legacy button: runs CORE_READ_8U (load 10,000 records, one job shared by 8 parallel workers).";
    public const string ParallelWrite = "Legacy button: runs CORE_INSERT_8U (save 10,000 new records, one job shared by 8 parallel workers).";
    public const string ParallelUpdate = "Legacy button: runs CORE_UPDATE_8U (change 10,000 records, one job shared by 8 parallel workers).";
    public const string ParallelDelete = "Legacy button: runs CORE_DELETE_8U (delete 10,000 records, one job shared by 8 parallel workers).";
    public const string ParallelComplexJoin = "Legacy button: runs CORE_JOIN_FULL_8U (stock availability list, all columns, 8 parallel workers).";
    public const string ParallelProjection = "Legacy button: runs CORE_JOIN_SLIM_8U (stock availability list, only the needed columns, 8 parallel workers).";
    public const string RefreshStatus = "Reloads snapshot and pending-analysis status so you can validate current benchmark coverage.";
    public const string RunBenchmark = "Runs the test selected in 'Test to Run' with the parameters on this form.";
    public const string ClearTestRecords = "Deletes benchmark work records other than the READ-SEED and UPDATE-SEED batches and removes leftover PERFBENCH documents. Results are kept.";
    public const string AbortBenchmark = "Asks the run in progress on this instance to stop after its current operations. The run is stored as Invalid (Aborted).";
}

public static class PerfBenchmarkRequestStatuses
{
    public const string Idle = "Idle";
    public const string Running = "Running";
    public const string Completed = "Completed";
    public const string Failed = "Failed";
}

/// <summary>Facade over PerfScenarioRegistry for existing callers (SPEC §4.7). Legacy codes are mapped.</summary>
public static class PerfBenchmarkCatalog
{
    public static PerfTestDescriptor Get(string testCode) => PerfScenarioRegistry.Get(testCode);

    public static bool TryGet(string testCode, out PerfTestDescriptor descriptor) => PerfScenarioRegistry.TryGet(testCode, out descriptor);

    /// <summary>Every comparable test (ENV_CAPTURE and other ExcludeFromComparison codes are left out), by SortOrder.</summary>
    public static IReadOnlyCollection<PerfTestDescriptor> All =>
        PerfScenarioRegistry.All.Where(d => !d.ExcludeFromComparison).ToArray();

    /// <summary>SortOrder of a code, or int.MaxValue for an unknown code (never throws; SPEC §2.1 F18).</summary>
    public static int SortOrderOf(string testCode) => TryGet(testCode, out var d) ? d.SortOrder : int.MaxValue;
}

/// <summary>Item type for PXProcessing.ProcessItemsParallel (one item per worker; StartIndex = worker index).</summary>
[Serializable]
[PXHidden]
[PXCacheName("Perf Benchmark Task")]
public sealed class PerfBenchmarkTask : PXBqlTable, IBqlTable
{
    public abstract class taskID : PX.Data.BQL.BqlInt.Field<taskID> { }
    [PXInt(IsKey = true)]
    public int? TaskID { get; set; }

    public abstract class selected : PX.Data.BQL.BqlBool.Field<selected> { }
    [PXBool]
    [PXDefault(false)]
    public bool? Selected { get; set; }

    public abstract class testCode : PX.Data.BQL.BqlString.Field<testCode> { }
    [PXString(64, IsUnicode = true)]
    public string TestCode { get; set; }

    public abstract class batchID : PX.Data.BQL.BqlString.Field<batchID> { }
    [PXString(64, IsUnicode = true)]
    public string BatchID { get; set; }

    public abstract class iteration : PX.Data.BQL.BqlInt.Field<iteration> { }
    [PXInt]
    public int? Iteration { get; set; }

    public abstract class startIndex : PX.Data.BQL.BqlInt.Field<startIndex> { }
    [PXInt]
    public int? StartIndex { get; set; }

    public abstract class endIndex : PX.Data.BQL.BqlInt.Field<endIndex> { }
    [PXInt]
    public int? EndIndex { get; set; }

    public abstract class windowOffset : PX.Data.BQL.BqlInt.Field<windowOffset> { }
    [PXInt]
    public int? WindowOffset { get; set; }

    public abstract class windowSize : PX.Data.BQL.BqlInt.Field<windowSize> { }
    [PXInt]
    public int? WindowSize { get; set; }
}

public sealed class PerfHardwareRecommendation
{
    public int CpuCores { get; init; }
    public decimal MemoryGb { get; init; }
    public int RecommendedRecords { get; init; }
    public int RecommendedIterations { get; init; }
    public int RecommendedBatchSize { get; init; }
    public int RecommendedMaxThreads { get; init; }
    public string Summary { get; init; }
}

/// <summary>
/// Host facts for the control screen. The recommended settings are the campaign constants (SPEC §2.1 F22), not values
/// derived from hardware. WMI runs at most once per AppDomain (cached Lazy) and never from the graph constructor (F4).
/// </summary>
public static class PerfHardwareInspector
{
    private static readonly Lazy<PerfHardwareRecommendation> Cached =
        new Lazy<PerfHardwareRecommendation>(DetectCore, LazyThreadSafetyMode.ExecutionAndPublication);

    /// <summary>Hardware facts plus the campaign constants. The first call may run one WMI query; later calls are cached.</summary>
    public static PerfHardwareRecommendation Detect() => Cached.Value;

    /// <summary>The cached result if Detect already ran in this AppDomain; never runs WMI.</summary>
    public static bool TryGetCached(out PerfHardwareRecommendation recommendation)
    {
        recommendation = Cached.IsValueCreated ? Cached.Value : null;
        return recommendation != null;
    }

    /// <summary>The campaign constants without hardware facts (no WMI).</summary>
    public static PerfHardwareRecommendation CampaignDefaults() => Build(Math.Max(System.Environment.ProcessorCount, 1), 0m);

    private static PerfHardwareRecommendation DetectCore()
    {
        var cores = Math.Max(System.Environment.ProcessorCount, 1);
        var memoryGb = 0m;

        try
        {
            using var searcher = new ManagementObjectSearcher("SELECT TotalPhysicalMemory, NumberOfLogicalProcessors FROM Win32_ComputerSystem");
            foreach (var row in searcher.Get().Cast<ManagementObject>())
            {
                cores = Math.Max(cores, Convert.ToInt32(row["NumberOfLogicalProcessors"] ?? cores, CultureInfo.InvariantCulture));
                var rawMemory = Convert.ToDecimal(row["TotalPhysicalMemory"] ?? 0m, CultureInfo.InvariantCulture);
                memoryGb = Math.Round(rawMemory / 1024m / 1024m / 1024m, 2, MidpointRounding.AwayFromZero);
                break;
            }
        }
        catch
        {
            memoryGb = 0m;
        }

        return Build(cores, memoryGb);
    }

    private static PerfHardwareRecommendation Build(int cores, decimal memoryGb) => new PerfHardwareRecommendation
    {
        CpuCores = cores,
        MemoryGb = memoryGb,
        RecommendedRecords = PerfCampaignConstants.CoreRecords,
        RecommendedIterations = PerfCampaignConstants.CoreMeasuredPasses,
        RecommendedBatchSize = PerfCampaignConstants.CoreChunkSize,
        RecommendedMaxThreads = PerfCampaignConstants.CoreParallelWorkers,
        Summary = "Campaign settings (methodology " + PerfMethodology.Version + "): " +
                  PerfCampaignConstants.CoreRecords.ToString("N0", CultureInfo.InvariantCulture) + " records, " +
                  PerfCampaignConstants.CoreMeasuredPasses.ToString(CultureInfo.InvariantCulture) + " measured passes, " +
                  PerfCampaignConstants.CoreChunkSize.ToString(CultureInfo.InvariantCulture) + " rows per chunk, " +
                  PerfCampaignConstants.CoreParallelWorkers.ToString(CultureInfo.InvariantCulture) + " parallel workers. Host: " +
                  cores.ToString(CultureInfo.InvariantCulture) + " logical cores" +
                  (memoryGb > 0 ? ", " + memoryGb.ToString("0.##", CultureInfo.InvariantCulture) + " GB RAM." : ".")
    };
}

public static class PerfEnvironmentInspector
{
    public static string GetInstanceName() => PerfRuntimeInfo.InstanceName;

    /// <summary>PerfDatabaseEngines value (SQLServer, MySQL, PostgreSQL) detected from the provider type (SPEC §2.1 F20).</summary>
    public static string GetDatabaseEngine() => PerfDatabaseEngines.Detect();

    /// <summary>Reader-facing engine name, e.g. "SQL Server".</summary>
    public static string GetDatabaseDisplayName(PXGraph graph) => PerfDatabaseEngines.DisplayName(PerfDatabaseEngines.Detect());

    /// <summary>Maps old snapshot labels ("Microsoft SQL Server", "MySQL 8.0") and engine codes to a PerfDatabaseEngines value.</summary>
    public static string NormalizeEngine(string databaseType)
    {
        if (string.IsNullOrWhiteSpace(databaseType)) return PerfDatabaseEngines.Unknown;
        var t = databaseType.Trim();
        if (string.Equals(t, PerfDatabaseEngines.SqlServer, StringComparison.OrdinalIgnoreCase) ||
            t.IndexOf("SQL Server", StringComparison.OrdinalIgnoreCase) >= 0 ||
            t.IndexOf("MSSQL", StringComparison.OrdinalIgnoreCase) >= 0) return PerfDatabaseEngines.SqlServer;
        if (t.IndexOf("MySQL", StringComparison.OrdinalIgnoreCase) >= 0 || t.IndexOf("Maria", StringComparison.OrdinalIgnoreCase) >= 0) return PerfDatabaseEngines.MySql;
        if (t.IndexOf("Postgre", StringComparison.OrdinalIgnoreCase) >= 0 || t.IndexOf("PgSql", StringComparison.OrdinalIgnoreCase) >= 0) return PerfDatabaseEngines.PostgreSql;
        return PerfDatabaseEngines.Unknown;
    }
}

/// <summary>Snapshot v2 envelope (SPEC §3.8). Old files deserialize with defaults (SchemaVersion 0).</summary>
public sealed class PerfSnapshotEnvelope
{
    public string InstanceName { get; set; }
    public string DatabaseType { get; set; }
    public DateTime CapturedAtUtc { get; set; }
    public string DllSha256 { get; set; }
    public string AcumaticaVersion { get; set; }
    public string DbmsVersion { get; set; }
    public int SchemaVersion { get; set; }
    public List<PerfSnapshotItem> Results { get; set; } = new();
}

public sealed class PerfSnapshotItem
{
    public string TestCode { get; set; }
    public string TestCategory { get; set; }
    public string ExecutionMode { get; set; }
    public string DisplayName { get; set; }
    public int RecordsCount { get; set; }
    public int Iterations { get; set; }
    public int BatchSize { get; set; }
    public int MaxThreads { get; set; }
    public int ElapsedMs { get; set; }
    public string Notes { get; set; }
    public DateTime CapturedAtUtc { get; set; }

    // ---- v2 (SPEC §3.8) ----
    public int ResultID { get; set; }
    public string Family { get; set; }
    public string ShortLabel { get; set; }
    public string Status { get; set; }
    public bool IsWarmup { get; set; }
    public int? RepetitionNo { get; set; }
    public Guid? CampaignID { get; set; }
    public int UserCount { get; set; }
    public decimal? ElapsedMsPrecise { get; set; }
    public decimal? HeadlineValue { get; set; }
    public string HeadlineUnit { get; set; }
    public bool HigherIsBetter { get; set; }
    public decimal? OpsPerSec { get; set; }
    public decimal? P95Ms { get; set; }
    public int ErrorCount { get; set; }
    public long RowsReturned { get; set; }
    public string Checksum { get; set; }
    public string ParamsHash { get; set; }
    public string DllSha256 { get; set; }
}

public sealed class PerfBenchmarkCoverageStatus
{
    public string InstanceName { get; init; }
    public bool HasSnapshot { get; init; }
    public int CompletedCount { get; init; }
    public int TotalCount { get; init; }
    public IReadOnlyList<PerfTestDescriptor> MissingBenchmarks { get; init; } = Array.Empty<PerfTestDescriptor>();
}

public static class PerfSnapshotService
{
    public const int SchemaVersion = 2;
    private const string SnapshotFolder = "PerfDBBenchmark";
    private const string SnapshotFileName = "perfdbbenchmark-results.json";
    private const int WriteAttempts = 3;
    private static readonly TimeSpan RetryDelay = TimeSpan.FromMilliseconds(200);
    private static readonly string[] ExpectedInstances = { "PerfPG", "PerfMySQL", "PerfSQL" };
    private static readonly object WriteSync = new object();

    public static IReadOnlyList<string> ExpectedInstanceNames => ExpectedInstances;

    public static string GetSnapshotStatus()
    {
        var envelopes = LoadExpectedSnapshots().ToArray();
        var missingInstances = ExpectedInstances
            .Where(expected => envelopes.All(envelope => !string.Equals(envelope.InstanceName, expected, StringComparison.OrdinalIgnoreCase)))
            .ToArray();

        if (envelopes.Length == 0)
        {
            return $"No comparison snapshots were found yet for expected instances {string.Join(", ", ExpectedInstances)}.";
        }

        var status = $"Loaded {envelopes.Length} of {ExpectedInstances.Length} expected comparison snapshot(s).";
        if (missingInstances.Length > 0)
        {
            status += $" Missing snapshot(s): {string.Join(", ", missingInstances)}.";
        }

        var old = envelopes.Where(e => e.SchemaVersion < SchemaVersion).Select(e => e.InstanceName).ToArray();
        if (old.Length > 0)
        {
            status += $" Snapshot(s) from an older methodology are ignored: {string.Join(", ", old)}.";
        }

        return status;
    }

    public static string GetPendingAnalysisStatus()
    {
        var statuses = GetCoverageStatuses().ToArray();
        return string.Join(" | ", statuses.Select(FormatCoverageStatus));
    }

    /// <summary>Writes the local snapshot v2 atomically: temp file, then File.Replace (File.Move for a new file), 3 attempts
    /// 200 ms apart (SPEC §2.1 F19). Dates are written with Kind = Utc. Throws only after the last attempt failed.</summary>
    public static void WriteLocalSnapshot(IEnumerable<PerfSnapshotItem> latestResults, string instanceName, string databaseType)
    {
        var envelope = new PerfSnapshotEnvelope
        {
            InstanceName = instanceName,
            DatabaseType = PerfEnvironmentInspector.NormalizeEngine(databaseType) is var engine && engine != PerfDatabaseEngines.Unknown ? engine : databaseType,
            CapturedAtUtc = DateTime.SpecifyKind(DateTime.UtcNow, DateTimeKind.Utc),
            DllSha256 = PerfRuntimeInfo.DllSha256,
            AcumaticaVersion = PerfRuntimeInfo.AcumaticaBuild,
            DbmsVersion = PerfRuntimeInfo.DbmsVersionLabel,
            SchemaVersion = SchemaVersion,
            Results = (latestResults ?? Enumerable.Empty<PerfSnapshotItem>())
                .Select(x =>
                {
                    x.CapturedAtUtc = DateTime.SpecifyKind(x.CapturedAtUtc, DateTimeKind.Utc);
                    return x;
                })
                .ToList()
        };

        var serializer = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        var json = serializer.Serialize(envelope);
        var targetPath = GetLocalSnapshotPath();
        var directory = Path.GetDirectoryName(targetPath) ?? AppDomain.CurrentDomain.BaseDirectory;

        lock (WriteSync)
        {
            Exception last = null;
            for (var attempt = 1; attempt <= WriteAttempts; attempt++)
            {
                var tempPath = Path.Combine(directory, SnapshotFileName + "." + Guid.NewGuid().ToString("N") + ".tmp");
                try
                {
                    Directory.CreateDirectory(directory);
                    File.WriteAllText(tempPath, json, new UTF8Encoding(false));
                    if (File.Exists(targetPath))
                    {
                        File.Replace(tempPath, targetPath, null, ignoreMetadataErrors: true);
                    }
                    else
                    {
                        File.Move(tempPath, targetPath);
                    }

                    return;
                }
                catch (Exception ex)
                {
                    last = ex;
                    TryDelete(tempPath);
                    if (attempt < WriteAttempts) Thread.Sleep(RetryDelay);
                }
            }

            throw new IOException("The comparison snapshot could not be written after " + WriteAttempts.ToString(CultureInfo.InvariantCulture) + " attempts: " + last?.Message, last);
        }
    }

    public static void ClearLocalSnapshot()
    {
        try
        {
            var targetPath = GetLocalSnapshotPath();
            if (File.Exists(targetPath))
            {
                File.Delete(targetPath);
            }
        }
        catch
        {
            // The benchmark screen should still work even when snapshot cleanup fails.
        }
    }

    public static IEnumerable<PerfSnapshotEnvelope> LoadAllSnapshots()
    {
        var serializer = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        var root = TryGetInstanceRootDirectory();
        if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))
        {
            yield break;
        }

        IEnumerable<string> folders;
        try
        {
            folders = Directory.EnumerateDirectories(root, "Perf*").ToList();
        }
        catch
        {
            yield break;
        }

        foreach (var instancePath in folders)
        {
            var snapshotPath = Path.Combine(instancePath, "App_Data", SnapshotFolder, SnapshotFileName);
            PerfSnapshotEnvelope envelope = null;
            for (var attempt = 1; attempt <= WriteAttempts && envelope == null; attempt++)
            {
                try
                {
                    if (!File.Exists(snapshotPath)) break;
                    envelope = serializer.Deserialize<PerfSnapshotEnvelope>(File.ReadAllText(snapshotPath, Encoding.UTF8));
                }
                catch
                {
                    envelope = null;
                    if (attempt < WriteAttempts) Thread.Sleep(50);
                }
            }

            if (envelope != null)
            {
                envelope.InstanceName = string.IsNullOrWhiteSpace(envelope.InstanceName)
                    ? new DirectoryInfo(instancePath).Name
                    : envelope.InstanceName;
                envelope.CapturedAtUtc = DateTime.SpecifyKind(envelope.CapturedAtUtc, DateTimeKind.Utc);
                envelope.Results ??= new List<PerfSnapshotItem>();
                yield return envelope;
            }
        }
    }

    public static IReadOnlyCollection<PerfSnapshotEnvelope> LoadExpectedSnapshots() =>
        LoadAllSnapshots()
            .Where(envelope => ExpectedInstances.Contains(envelope.InstanceName, StringComparer.OrdinalIgnoreCase))
            .GroupBy(envelope => envelope.InstanceName, StringComparer.OrdinalIgnoreCase)
            .Select(group => group.OrderByDescending(item => item.CapturedAtUtc).First())
            .OrderBy(envelope => GetExpectedInstanceOrder(envelope.InstanceName))
            .ToArray();

    public static IReadOnlyCollection<PerfBenchmarkCoverageStatus> GetCoverageStatuses()
    {
        var expectedBenchmarks = PerfBenchmarkCatalog.All.ToArray();
        var snapshotsByInstance = LoadExpectedSnapshots()
            .Where(envelope => envelope.SchemaVersion >= SchemaVersion)
            .ToDictionary(envelope => envelope.InstanceName, StringComparer.OrdinalIgnoreCase);

        return ExpectedInstances
            .Select(instanceName =>
            {
                snapshotsByInstance.TryGetValue(instanceName, out var envelope);

                var availableTests = new HashSet<string>(
                    envelope?.Results?
                        .Where(result => !string.IsNullOrWhiteSpace(result.TestCode) &&
                                         string.Equals(result.Status, PerfRunStatuses.Completed, StringComparison.OrdinalIgnoreCase))
                        .Select(result => result.TestCode)
                    ?? Enumerable.Empty<string>(),
                    StringComparer.OrdinalIgnoreCase);

                var missingBenchmarks = expectedBenchmarks
                    .Where(descriptor => !availableTests.Contains(descriptor.TestCode))
                    .ToArray();

                return new PerfBenchmarkCoverageStatus
                {
                    InstanceName = instanceName,
                    HasSnapshot = envelope != null,
                    CompletedCount = expectedBenchmarks.Length - missingBenchmarks.Length,
                    TotalCount = expectedBenchmarks.Length,
                    MissingBenchmarks = missingBenchmarks
                };
            })
            .ToArray();
    }

    private static string GetLocalSnapshotPath() =>
        Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "App_Data", SnapshotFolder, SnapshotFileName);

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path)) File.Delete(path);
        }
        catch
        {
            // best effort
        }
    }

    private static string FormatCoverageStatus(PerfBenchmarkCoverageStatus status)
    {
        if (!status.HasSnapshot)
        {
            return $"{status.InstanceName}: no current snapshot yet, missing all {status.TotalCount} tests";
        }

        if (status.MissingBenchmarks.Count == 0)
        {
            return $"{status.InstanceName}: complete ({status.CompletedCount}/{status.TotalCount})";
        }

        var missing = status.MissingBenchmarks.Select(item => item.ShortLabel ?? item.TestCode).ToArray();
        var shown = missing.Length > 12 ? string.Join(", ", missing.Take(12)) + $", … (+{missing.Length - 12})" : string.Join(", ", missing);
        return $"{status.InstanceName}: {status.CompletedCount}/{status.TotalCount} complete; missing {shown}";
    }

    private static int GetExpectedInstanceOrder(string instanceName)
    {
        for (var index = 0; index < ExpectedInstances.Length; index++)
        {
            if (string.Equals(ExpectedInstances[index], instanceName, StringComparison.OrdinalIgnoreCase))
            {
                return index;
            }
        }

        return int.MaxValue;
    }

    private static string TryGetInstanceRootDirectory()
    {
        try
        {
            var siteRoot = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            return Directory.GetParent(siteRoot)?.FullName;
        }
        catch
        {
            return null;
        }
    }
}

public static class PerfExcelExporter
{
    public static byte[] BuildExcelPayload(IEnumerable<PerfComparisonResult> rows)
    {
        var builder = new StringBuilder();
        builder.AppendLine("<html><head><meta charset=\"utf-8\" />");
        builder.AppendLine("<style>");
        builder.AppendLine("table{border-collapse:collapse;font-family:Segoe UI;font-size:12px;}th,td{border:1px solid #d1d5db;padding:6px 8px;}th{background:#0f172a;color:#fff;} .winner{background:#d1fae5;}");
        builder.AppendLine("</style></head><body>");
        builder.AppendLine("<h2>PerfDBBenchmark Comparison Export</h2>");
        builder.AppendLine("<p>Generated by AcuPower LTD for performance analysis. In-app verdicts are indicative only; the published verdicts come from the report generator.</p>");
        builder.AppendLine("<table><tr><th>Family</th><th>Benchmark</th><th>Test Code</th><th>Database</th><th>Instance</th><th>Users</th><th>Headline</th><th>Unit</th><th>x Fastest</th><th>Verdict</th><th>p95 (ms)</th><th>Errors</th><th>Status</th><th>Parameters Hash</th><th>Measured (ms)</th><th>Notes</th></tr>");

        foreach (var row in rows)
        {
            var cssClass = row.IsWinner == true ? "winner" : string.Empty;
            builder.Append("<tr");
            if (!string.IsNullOrWhiteSpace(cssClass))
            {
                builder.Append($" class=\"{cssClass}\"");
            }

            builder.Append(">");
            builder.Append($"<td>{HtmlEncode(row.Family)}</td>");
            builder.Append($"<td>{HtmlEncode(row.TestDisplayName)}</td>");
            builder.Append($"<td>{HtmlEncode(row.TestCode)}</td>");
            builder.Append($"<td>{HtmlEncode(row.DatabaseType)}</td>");
            builder.Append($"<td>{HtmlEncode(row.InstanceName)}</td>");
            builder.Append($"<td>{row.UserCount ?? 0}</td>");
            builder.Append($"<td>{Num(row.HeadlineValue)}</td>");
            builder.Append($"<td>{HtmlEncode(row.HeadlineUnit)}</td>");
            builder.Append($"<td>{Num(row.RelToFastest)}</td>");
            builder.Append($"<td>{HtmlEncode(row.Verdict)}</td>");
            builder.Append($"<td>{Num(row.P95Ms)}</td>");
            builder.Append($"<td>{row.ErrorCount ?? 0}</td>");
            builder.Append($"<td>{HtmlEncode(row.Status)}</td>");
            builder.Append($"<td>{HtmlEncode(row.ParamsHash)}</td>");
            builder.Append($"<td>{row.ElapsedMs ?? 0}</td>");
            builder.Append($"<td>{HtmlEncode(row.Notes)}</td>");
            builder.AppendLine("</tr>");
        }

        builder.AppendLine("</table></body></html>");
        return Encoding.UTF8.GetPreamble().Concat(Encoding.UTF8.GetBytes(builder.ToString())).ToArray();
    }

    private static string Num(decimal? value) => value.HasValue ? value.Value.ToString("0.####", CultureInfo.InvariantCulture) : string.Empty;

    private static string HtmlEncode(string value) => WebUtility.HtmlEncode(value ?? string.Empty);
}

public sealed class PerfChartPoint
{
    public string Category { get; init; }
    public float[] Values { get; init; }
    public string[] Labels { get; init; }
}

public static class PerfChartBuilder
{
    public static List<PerfChartPoint> BuildChartPoints(IEnumerable<PerfComparisonResult> source, IReadOnlyList<string> orderedDatabases, Func<PerfComparisonResult, bool> predicate)
    {
        var filtered = source
            .Where(predicate)
            .OrderBy(x => x.SortOrder ?? PerfBenchmarkCatalog.SortOrderOf(x.TestCode))
            .ToArray();

        var byBenchmark = filtered
            .GroupBy(x => x.TestDisplayName)
            .OrderBy(g => g.Min(x => x.SortOrder ?? PerfBenchmarkCatalog.SortOrderOf(x.TestCode)));
        var points = new List<PerfChartPoint>();

        foreach (var group in byBenchmark)
        {
            var values = new float[orderedDatabases.Count];
            var labels = new string[orderedDatabases.Count];

            for (var i = 0; i < orderedDatabases.Count; i++)
            {
                var match = group.FirstOrDefault(x => string.Equals(x.DatabaseType, orderedDatabases[i], StringComparison.OrdinalIgnoreCase));
                values[i] = match?.ElapsedMs ?? 0;
                labels[i] = match == null ? "n/a" : $"{match.ElapsedMs} ms";
            }

            points.Add(new PerfChartPoint
            {
                Category = group.Key,
                Values = values,
                Labels = labels
            });
        }

        return points;
    }

    public static IReadOnlyList<string> GetOrderedDatabases(IEnumerable<PerfComparisonResult> rows) =>
        rows.Select(x => x.DatabaseType).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(x => GetDatabaseColorIndex(x)).ToArray();

    /// <summary>Okabe–Ito order: SQL Server, MySQL, PostgreSQL. Accepts engine codes and older display names.</summary>
    public static int GetDatabaseColorIndex(string databaseType)
    {
        switch (PerfEnvironmentInspector.NormalizeEngine(databaseType))
        {
            case PerfDatabaseEngines.SqlServer: return 0;
            case PerfDatabaseEngines.MySql: return 1;
            case PerfDatabaseEngines.PostgreSql: return 2;
            default: return 3;
        }
    }
}
