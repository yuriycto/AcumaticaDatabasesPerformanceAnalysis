using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Management;
using System.Net;
using System.Text;
using System.Web.Script.Serialization;
using PX.Data;
using PX.Objects.GL;
using PerfDBBenchmark.Core.DAC;

namespace PerfDBBenchmark.Core.Support;

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
}

public static class PerfBenchmarkDescriptions
{
    public const string SequentialRead = "Reads the seeded benchmark records through Acumatica BQL in a single-threaded loop.";
    public const string SequentialWrite = "Inserts benchmark records through the Acumatica cache one batch at a time.";
    public const string SequentialUpdate = "Updates seeded benchmark records sequentially to measure single-threaded update throughput.";
    public const string SequentialDelete = "Deletes prepared benchmark records sequentially to measure cleanup throughput.";
    public const string SequentialComplexJoin = "Runs a realistic multi-table inventory BQL join sequentially for analytical workload comparison.";
    public const string SequentialProjection = "Queries the benchmark PXProjection sequentially to measure analytical projection performance.";
    public const string ParallelRead = "Splits seeded record reads across Acumatica processing workers.";
    public const string ParallelWrite = "Splits record inserts across Acumatica processing workers.";
    public const string ParallelUpdate = "Splits record updates across Acumatica processing workers.";
    public const string ParallelDelete = "Splits delete work across Acumatica processing workers after seeding delete batches.";
    public const string ParallelComplexJoin = "Runs the multi-table analytical BQL join in parallel windows.";
    public const string ParallelProjection = "Runs the PXProjection analytical workload in parallel windows.";
    public const string RefreshStatus = "Reloads snapshot and pending-analysis status so you can validate current benchmark coverage.";
}

public static class PerfBenchmarkRequestStatuses
{
    public const string Idle = "Idle";
    public const string Running = "Running";
    public const string Completed = "Completed";
    public const string Failed = "Failed";
}

public sealed class PerfBenchmarkDescriptor
{
    public string TestCode { get; init; }
    public string Category { get; init; }
    public string ExecutionMode { get; init; }
    public string DisplayName { get; init; }
    public string ActionName { get; init; }
    public string ShortDescription { get; init; }
    public int SortOrder { get; init; }
}

public static class PerfBenchmarkCatalog
{
    private static readonly Dictionary<string, PerfBenchmarkDescriptor> Descriptors = new(StringComparer.OrdinalIgnoreCase)
    {
        [PerfBenchmarkTestCodes.SequentialRead] = new() { TestCode = PerfBenchmarkTestCodes.SequentialRead, Category = "Read", ExecutionMode = "Sequential", DisplayName = "Sequential Read", ActionName = PerfBenchmarkActionNames.RunSequentialRead, ShortDescription = PerfBenchmarkDescriptions.SequentialRead, SortOrder = 10 },
        [PerfBenchmarkTestCodes.SequentialWrite] = new() { TestCode = PerfBenchmarkTestCodes.SequentialWrite, Category = "Write", ExecutionMode = "Sequential", DisplayName = "Sequential Write", ActionName = PerfBenchmarkActionNames.RunSequentialWrite, ShortDescription = PerfBenchmarkDescriptions.SequentialWrite, SortOrder = 20 },
        [PerfBenchmarkTestCodes.SequentialUpdate] = new() { TestCode = PerfBenchmarkTestCodes.SequentialUpdate, Category = "Update", ExecutionMode = "Sequential", DisplayName = "Sequential Update", ActionName = PerfBenchmarkActionNames.RunSequentialUpdate, ShortDescription = PerfBenchmarkDescriptions.SequentialUpdate, SortOrder = 25 },
        [PerfBenchmarkTestCodes.SequentialDelete] = new() { TestCode = PerfBenchmarkTestCodes.SequentialDelete, Category = "Delete", ExecutionMode = "Sequential", DisplayName = "Sequential Delete", ActionName = PerfBenchmarkActionNames.RunSequentialDelete, ShortDescription = PerfBenchmarkDescriptions.SequentialDelete, SortOrder = 30 },
        [PerfBenchmarkTestCodes.SequentialComplexJoin] = new() { TestCode = PerfBenchmarkTestCodes.SequentialComplexJoin, Category = "Complex BQL Join", ExecutionMode = "Sequential", DisplayName = "Complex BQL Join (Sequential)", ActionName = PerfBenchmarkActionNames.RunSequentialComplexJoin, ShortDescription = PerfBenchmarkDescriptions.SequentialComplexJoin, SortOrder = 40 },
        [PerfBenchmarkTestCodes.SequentialProjection] = new() { TestCode = PerfBenchmarkTestCodes.SequentialProjection, Category = "PXProjection", ExecutionMode = "Sequential", DisplayName = "PXProjection Analysis (Sequential)", ActionName = PerfBenchmarkActionNames.RunSequentialProjection, ShortDescription = PerfBenchmarkDescriptions.SequentialProjection, SortOrder = 50 },
        [PerfBenchmarkTestCodes.ParallelRead] = new() { TestCode = PerfBenchmarkTestCodes.ParallelRead, Category = "Read", ExecutionMode = "Parallel", DisplayName = "Parallel Read", ActionName = PerfBenchmarkActionNames.RunParallelRead, ShortDescription = PerfBenchmarkDescriptions.ParallelRead, SortOrder = 60 },
        [PerfBenchmarkTestCodes.ParallelWrite] = new() { TestCode = PerfBenchmarkTestCodes.ParallelWrite, Category = "Write", ExecutionMode = "Parallel", DisplayName = "Parallel Write", ActionName = PerfBenchmarkActionNames.RunParallelWrite, ShortDescription = PerfBenchmarkDescriptions.ParallelWrite, SortOrder = 70 },
        [PerfBenchmarkTestCodes.ParallelUpdate] = new() { TestCode = PerfBenchmarkTestCodes.ParallelUpdate, Category = "Update", ExecutionMode = "Parallel", DisplayName = "Parallel Update", ActionName = PerfBenchmarkActionNames.RunParallelUpdate, ShortDescription = PerfBenchmarkDescriptions.ParallelUpdate, SortOrder = 75 },
        [PerfBenchmarkTestCodes.ParallelDelete] = new() { TestCode = PerfBenchmarkTestCodes.ParallelDelete, Category = "Delete", ExecutionMode = "Parallel", DisplayName = "Parallel Delete", ActionName = PerfBenchmarkActionNames.RunParallelDelete, ShortDescription = PerfBenchmarkDescriptions.ParallelDelete, SortOrder = 80 },
        [PerfBenchmarkTestCodes.ParallelComplexJoin] = new() { TestCode = PerfBenchmarkTestCodes.ParallelComplexJoin, Category = "Complex BQL Join", ExecutionMode = "Parallel", DisplayName = "Complex BQL Join (Parallel)", ActionName = PerfBenchmarkActionNames.RunParallelComplexJoin, ShortDescription = PerfBenchmarkDescriptions.ParallelComplexJoin, SortOrder = 90 },
        [PerfBenchmarkTestCodes.ParallelProjection] = new() { TestCode = PerfBenchmarkTestCodes.ParallelProjection, Category = "PXProjection", ExecutionMode = "Parallel", DisplayName = "PXProjection Analysis (Parallel)", ActionName = PerfBenchmarkActionNames.RunParallelProjection, ShortDescription = PerfBenchmarkDescriptions.ParallelProjection, SortOrder = 100 }
    };

    public static PerfBenchmarkDescriptor Get(string testCode) => Descriptors[testCode];

    public static IReadOnlyCollection<PerfBenchmarkDescriptor> All => Descriptors.Values.OrderBy(x => x.SortOrder).ToArray();
}

public sealed class PerfBenchmarkRunRequest
{
    public Guid RequestID { get; init; }
    public string TestCode { get; init; }
    public int NumberOfRecords { get; init; }
    public int Iterations { get; init; }
    public int BatchSize { get; init; }
    public int MaxThreads { get; init; }
    public string DatabaseType { get; init; }
    public string InstanceName { get; init; }
    public DateTime RequestedAtUtc { get; init; }
    public string RequestedBy { get; init; }
}

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

public static class PerfHardwareInspector
{
    public static PerfHardwareRecommendation Detect()
    {
        var cores = Math.Max(Environment.ProcessorCount, 1);
        decimal memoryGb = 0m;

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

        var recommendedMaxThreads = Math.Max(2, Math.Min(cores, 12));
        var recommendedBatchSize = cores switch
        {
            >= 16 => 250,
            >= 8 => 150,
            >= 4 => 100,
            _ => 50
        };
        var recommendedRecords = (cores, memoryGb) switch
        {
            (>= 16, >= 32m) => 15000,
            (>= 8, >= 16m) => 10000,
            (>= 4, >= 8m) => 5000,
            _ => 2000
        };
        var recommendedIterations = memoryGb switch
        {
            >= 32m => 5,
            >= 16m => 4,
            _ => 3
        };

        return new PerfHardwareRecommendation
        {
            CpuCores = cores,
            MemoryGb = memoryGb,
            RecommendedRecords = recommendedRecords,
            RecommendedIterations = recommendedIterations,
            RecommendedBatchSize = recommendedBatchSize,
            RecommendedMaxThreads = recommendedMaxThreads,
            Summary = $"AcuPower LTD recommendation based on {cores} logical cores and {memoryGb:0.##} GB RAM: " +
                      $"{recommendedRecords:N0} records, {recommendedIterations} iterations, batch size {recommendedBatchSize}, max threads {recommendedMaxThreads}."
        };
    }
}

public static class PerfEnvironmentInspector
{
    public static string GetInstanceName()
    {
        try
        {
            var root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            return new DirectoryInfo(root).Name;
        }
        catch
        {
            return "UnknownInstance";
        }
    }

    public static string GetDatabaseDisplayName(PXGraph graph)
    {
        var providerType = string.Empty;

        try
        {
            providerType = PXDatabase.Provider?.GetType().FullName ?? string.Empty;
        }
        catch
        {
            providerType = string.Empty;
        }

        if (providerType.IndexOf("postgres", StringComparison.OrdinalIgnoreCase) >= 0 ||
            providerType.IndexOf("npgsql", StringComparison.OrdinalIgnoreCase) >= 0)
        {
            return "PostgreSQL";
        }

        if (providerType.IndexOf("mysql", StringComparison.OrdinalIgnoreCase) >= 0 ||
            providerType.IndexOf("maria", StringComparison.OrdinalIgnoreCase) >= 0)
        {
            return "MySQL 8.0";
        }

        if (providerType.IndexOf("sqlserver", StringComparison.OrdinalIgnoreCase) >= 0 ||
            providerType.IndexOf("mssql", StringComparison.OrdinalIgnoreCase) >= 0)
        {
            return "Microsoft SQL Server";
        }

        var instanceName = GetInstanceName();
        return instanceName switch
        {
            var x when x.IndexOf("pg", StringComparison.OrdinalIgnoreCase) >= 0 => "PostgreSQL",
            var x when x.IndexOf("mysql", StringComparison.OrdinalIgnoreCase) >= 0 || x.IndexOf("maria", StringComparison.OrdinalIgnoreCase) >= 0 => "MySQL 8.0",
            var x when x.IndexOf("sql", StringComparison.OrdinalIgnoreCase) >= 0 => "Microsoft SQL Server",
            _ => "Unknown Database"
        };
    }
}

public sealed class PerfSnapshotEnvelope
{
    public string InstanceName { get; set; }
    public string DatabaseType { get; set; }
    public DateTime CapturedAtUtc { get; set; }
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
}

public sealed class PerfBenchmarkCoverageStatus
{
    public string InstanceName { get; init; }
    public bool HasSnapshot { get; init; }
    public int CompletedCount { get; init; }
    public int TotalCount { get; init; }
    public IReadOnlyList<PerfBenchmarkDescriptor> MissingBenchmarks { get; init; } = Array.Empty<PerfBenchmarkDescriptor>();
}

public static class PerfSnapshotService
{
    private const string SnapshotFolder = "PerfDBBenchmark";
    private const string SnapshotFileName = "perfdbbenchmark-results.json";
    private static readonly string[] ExpectedInstances = { "PerfPG", "PerfMySQL", "PerfSQL" };

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

        return status;
    }

    public static string GetPendingAnalysisStatus()
    {
        var statuses = GetCoverageStatuses().ToArray();
        return string.Join(" | ", statuses.Select(FormatCoverageStatus));
    }

    public static void WriteLocalSnapshot(IEnumerable<PerfTestResult> latestResults, string instanceName, string databaseType)
    {
        var envelope = new PerfSnapshotEnvelope
        {
            InstanceName = instanceName,
            DatabaseType = databaseType,
            CapturedAtUtc = DateTime.UtcNow,
            Results = latestResults
                .OrderBy(x => x.DisplayName)
                .Select(x => new PerfSnapshotItem
                {
                    TestCode = x.TestCode,
                    TestCategory = x.TestCategory,
                    ExecutionMode = x.ExecutionMode,
                    DisplayName = x.DisplayName,
                    RecordsCount = x.RecordsCount ?? 0,
                    Iterations = x.Iterations ?? 0,
                    BatchSize = x.BatchSize ?? 0,
                    MaxThreads = x.MaxThreads ?? 0,
                    ElapsedMs = x.ElapsedMs ?? 0,
                    Notes = x.Notes,
                    CapturedAtUtc = x.CapturedAtUtc ?? DateTime.UtcNow
                })
                .ToList()
        };

        var serializer = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        var targetPath = GetLocalSnapshotPath();
        Directory.CreateDirectory(Path.GetDirectoryName(targetPath) ?? AppDomain.CurrentDomain.BaseDirectory);
        File.WriteAllText(targetPath, serializer.Serialize(envelope), Encoding.UTF8);
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

        foreach (var instancePath in Directory.EnumerateDirectories(root, "Perf*"))
        {
            var snapshotPath = Path.Combine(instancePath, "App_Data", SnapshotFolder, SnapshotFileName);
            if (!File.Exists(snapshotPath))
            {
                continue;
            }

            PerfSnapshotEnvelope envelope = null;
            try
            {
                envelope = serializer.Deserialize<PerfSnapshotEnvelope>(File.ReadAllText(snapshotPath, Encoding.UTF8));
            }
            catch
            {
                envelope = null;
            }

            if (envelope != null)
            {
                envelope.InstanceName = string.IsNullOrWhiteSpace(envelope.InstanceName)
                    ? new DirectoryInfo(instancePath).Name
                    : envelope.InstanceName;
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
            .ToDictionary(envelope => envelope.InstanceName, StringComparer.OrdinalIgnoreCase);

        return ExpectedInstances
            .Select(instanceName =>
            {
                snapshotsByInstance.TryGetValue(instanceName, out var envelope);

                var availableTests = new HashSet<string>(
                    envelope?.Results?
                        .Where(result => !string.IsNullOrWhiteSpace(result.TestCode))
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

    private static string FormatCoverageStatus(PerfBenchmarkCoverageStatus status)
    {
        if (!status.HasSnapshot)
        {
            return $"{status.InstanceName}: no snapshot yet, missing all {status.TotalCount} tests";
        }

        if (status.MissingBenchmarks.Count == 0)
        {
            return $"{status.InstanceName}: complete ({status.CompletedCount}/{status.TotalCount})";
        }

        return $"{status.InstanceName}: {status.CompletedCount}/{status.TotalCount} complete; missing {string.Join(", ", status.MissingBenchmarks.Select(item => item.DisplayName))}";
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
        builder.AppendLine("table{border-collapse:collapse;font-family:Segoe UI;font-size:12px;}th,td{border:1px solid #d1d5db;padding:6px 8px;}th{background:#0f172a;color:#fff;} .winner{background:#d1fae5;} .focus{font-weight:bold;color:#0f766e;}");
        builder.AppendLine("</style></head><body>");
        builder.AppendLine("<h2>PerfDBBenchmark Comparison Export</h2>");
        builder.AppendLine("<p>Generated by AcuPower LTD for performance analysis.</p>");
        builder.AppendLine("<table><tr><th>Benchmark</th><th>Category</th><th>Mode</th><th>Database</th><th>Instance</th><th>Elapsed (ms)</th><th>Records</th><th>Iterations</th><th>Batch Size</th><th>Max Threads</th><th>Winner</th><th>Notes</th></tr>");

        foreach (var row in rows)
        {
            var cssClass = row.IsWinner == true ? "winner" : string.Empty;
            var benchmarkCss = (row.TestCategory == "Complex BQL Join" || row.TestCategory == "PXProjection") ? "focus" : string.Empty;
            builder.Append("<tr");
            if (!string.IsNullOrWhiteSpace(cssClass))
            {
                builder.Append($" class=\"{cssClass}\"");
            }

            builder.Append(">");
            builder.Append($"<td class=\"{benchmarkCss}\">{HtmlEncode(row.TestDisplayName)}</td>");
            builder.Append($"<td>{HtmlEncode(row.TestCategory)}</td>");
            builder.Append($"<td>{HtmlEncode(row.ExecutionMode)}</td>");
            builder.Append($"<td>{HtmlEncode(row.DatabaseType)}</td>");
            builder.Append($"<td>{HtmlEncode(row.InstanceName)}</td>");
            builder.Append($"<td>{row.ElapsedMs ?? 0}</td>");
            builder.Append($"<td>{row.RecordsCount ?? 0}</td>");
            builder.Append($"<td>{row.Iterations ?? 0}</td>");
            builder.Append($"<td>{row.BatchSize ?? 0}</td>");
            builder.Append($"<td>{row.MaxThreads ?? 0}</td>");
            builder.Append($"<td>{HtmlEncode(row.WinnerDisplay)}</td>");
            builder.Append($"<td>{HtmlEncode(row.Notes)}</td>");
            builder.AppendLine("</tr>");
        }

        builder.AppendLine("</table></body></html>");
        return Encoding.UTF8.GetPreamble().Concat(Encoding.UTF8.GetBytes(builder.ToString())).ToArray();
    }

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
            .OrderBy(x => PerfBenchmarkCatalog.Get(x.TestCode).SortOrder)
            .ToArray();

        var byBenchmark = filtered.GroupBy(x => x.TestDisplayName).OrderBy(g => PerfBenchmarkCatalog.Get(g.First().TestCode).SortOrder);
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

    public static int GetDatabaseColorIndex(string databaseType)
    {
        if (string.IsNullOrWhiteSpace(databaseType)) return 3;
        var name = databaseType.ToUpperInvariant();
        if (name.Contains("SQL SERVER") || name.Contains("MSSQL")) return 0;
        if (name.Contains("MYSQL")) return 1;
        if (name.Contains("POSTGRE") || name.Contains("PGSQL")) return 2;
        return 3;
    }
}
