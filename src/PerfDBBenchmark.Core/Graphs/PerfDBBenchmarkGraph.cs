using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Reflection;
using System.Threading;
using PX.Data;
using PX.Data.BQL;
using PX.Data.BQL.Fluent;
using PX.Objects.GL;
using PX.Objects.IN;
using PerfDBBenchmark.Core.DAC;
using PerfDBBenchmark.Core.Support;

using GLBranch = PX.Objects.GL.Branch;

namespace PerfDBBenchmark.Core.Graphs;

/// <summary>
/// PerfDBBenchmark was created by AcuPower LTD for Acumatica database performance analysis.
/// </summary>
public class PerfDBBenchmarkGraph : PXGraph<PerfDBBenchmarkGraph>
{
    private const string ReadSeedBatch = "READ-SEED";
    private const int BenchmarkControlID = 1;

    public PXSave<PerfBenchmarkFilter> Save;
    public PXCancel<PerfBenchmarkFilter> Cancel;

    public SelectFrom<PerfBenchmarkFilter>.View Filter;
    public SelectFrom<PerfBenchmarkDefinition>.View BenchmarkCatalog;
    public SelectFrom<PerfTestRecord>.View Records;
    public SelectFrom<PerfTestResult>.OrderBy<Desc<PerfTestResult.capturedAtUtc>>.View LocalResults;
    public SelectFrom<PerfComparisonResult>.View ComparisonResults;

    public override bool IsDirty => Filter.Cache.IsDirty || Records.Cache.IsDirty || LocalResults.Cache.IsDirty;

    public PerfDBBenchmarkGraph()
    {
        EnsureFilterContext(GetControlRow());
    }

    public IEnumerable benchmarkCatalog()
    {
        foreach (var descriptor in PerfBenchmarkCatalog.All)
        {
            yield return new PerfBenchmarkDefinition
            {
                TestCode = descriptor.TestCode,
                DisplayName = descriptor.DisplayName,
                ActionName = descriptor.ActionName,
                Category = descriptor.Category,
                ExecutionMode = descriptor.ExecutionMode,
                ShortDescription = descriptor.ShortDescription,
                SortOrder = descriptor.SortOrder
            };
        }
    }

    public IEnumerable comparisonResults()
    {
        EnsureFilterContext(GetControlRow());
        return BuildComparisonRows();
    }

    #region Actions

    public PXAction<PerfBenchmarkFilter> ApplyRecommendedSettings;
    [PXButton(CommitChanges = true)]
    [PXUIField(DisplayName = "Apply Recommended Settings", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable applyRecommendedSettings(PXAdapter adapter)
    {
        var row = GetControlRow();
        var recommendation = PerfHardwareInspector.Detect();

        row.NumberOfRecords = recommendation.RecommendedRecords;
        row.Iterations = recommendation.RecommendedIterations;
        row.ParallelBatchSize = recommendation.RecommendedBatchSize;
        row.ParallelMaxThreads = recommendation.RecommendedMaxThreads;
        EnsureFilterContext(row);
        PersistControlRow(row);
        return adapter.Get();
    }

    public PXAction<PerfBenchmarkFilter> RefreshStatus;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.RefreshStatus)]
    [PXUIField(DisplayName = "Refresh Status", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable refreshStatus(PXAdapter adapter)
    {
        var row = GetControlRow();
        EnsureFilterContext(row);
        PersistControlRow(row);
        return adapter.Get();
    }

    public PXAction<PerfBenchmarkFilter> RunSequentialRead;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.SequentialRead)]
    [PXUIField(DisplayName = "Sequential Read", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable runSequentialRead(PXAdapter adapter) => StartBenchmark(adapter, PerfBenchmarkTestCodes.SequentialRead);

    public PXAction<PerfBenchmarkFilter> RunSequentialWrite;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.SequentialWrite)]
    [PXUIField(DisplayName = "Sequential Write", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable runSequentialWrite(PXAdapter adapter) => StartBenchmark(adapter, PerfBenchmarkTestCodes.SequentialWrite);

    public PXAction<PerfBenchmarkFilter> RunSequentialDelete;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.SequentialDelete)]
    [PXUIField(DisplayName = "Sequential Delete", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable runSequentialDelete(PXAdapter adapter) => StartBenchmark(adapter, PerfBenchmarkTestCodes.SequentialDelete);

    public PXAction<PerfBenchmarkFilter> RunSequentialComplexJoin;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.SequentialComplexJoin)]
    [PXUIField(DisplayName = "Complex BQL Join (Sequential)", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable runSequentialComplexJoin(PXAdapter adapter) => StartBenchmark(adapter, PerfBenchmarkTestCodes.SequentialComplexJoin);

    public PXAction<PerfBenchmarkFilter> RunSequentialProjection;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.SequentialProjection)]
    [PXUIField(DisplayName = "PXProjection Analysis (Sequential)", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable runSequentialProjection(PXAdapter adapter) => StartBenchmark(adapter, PerfBenchmarkTestCodes.SequentialProjection);

    public PXAction<PerfBenchmarkFilter> RunParallelRead;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.ParallelRead)]
    [PXUIField(DisplayName = "Parallel Read", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable runParallelRead(PXAdapter adapter) => StartBenchmark(adapter, PerfBenchmarkTestCodes.ParallelRead);

    public PXAction<PerfBenchmarkFilter> RunParallelWrite;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.ParallelWrite)]
    [PXUIField(DisplayName = "Parallel Write", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable runParallelWrite(PXAdapter adapter) => StartBenchmark(adapter, PerfBenchmarkTestCodes.ParallelWrite);

    public PXAction<PerfBenchmarkFilter> RunParallelDelete;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.ParallelDelete)]
    [PXUIField(DisplayName = "Parallel Delete", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable runParallelDelete(PXAdapter adapter) => StartBenchmark(adapter, PerfBenchmarkTestCodes.ParallelDelete);

    public PXAction<PerfBenchmarkFilter> RunParallelComplexJoin;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.ParallelComplexJoin)]
    [PXUIField(DisplayName = "Complex BQL Join (Parallel)", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable runParallelComplexJoin(PXAdapter adapter) => StartBenchmark(adapter, PerfBenchmarkTestCodes.ParallelComplexJoin);

    public PXAction<PerfBenchmarkFilter> RunParallelProjection;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.ParallelProjection)]
    [PXUIField(DisplayName = "PXProjection Analysis (Parallel)", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable runParallelProjection(PXAdapter adapter) => StartBenchmark(adapter, PerfBenchmarkTestCodes.ParallelProjection);

    public PXAction<PerfBenchmarkFilter> ExportToExcel;
    [PXButton(CommitChanges = true)]
    [PXUIField(DisplayName = "Export Comparison to Excel", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable exportToExcel(PXAdapter adapter)
    {
        var rows = BuildComparisonRows().ToArray();
        if (rows.Length == 0)
        {
            throw new PXException("No benchmark comparison rows are available for export yet.");
        }

        var payload = PerfExcelExporter.BuildExcelPayload(rows);
        var file = new PX.SM.FileInfo($"PerfDBBenchmark-{DateTime.Now:yyyyMMdd-HHmmss}.xls", null, payload)
        {
            Comment = "PerfDBBenchmark export generated by AcuPower LTD."
        };

        throw new PXRedirectToFileException(file, true);
    }

    public PXAction<PerfBenchmarkFilter> ClearTestData;
    [PXButton(CommitChanges = true)]
    [PXUIField(DisplayName = "Clear Test Data", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable clearTestData(PXAdapter adapter)
    {
        PXLongOperation.StartOperation(this, () =>
        {
            var graph = CreateInstance<PerfDBBenchmarkGraph>();
            graph.ClearAllBenchmarkData();
        });

        return adapter.Get();
    }

    #endregion

    public List<PerfComparisonResult> GetComparisonResults() => BuildComparisonRows();

    public List<PerfChartPoint> GetChartPoints(Func<PerfComparisonResult, bool> predicate)
    {
        var rows = BuildComparisonRows();
        var databases = PerfChartBuilder.GetOrderedDatabases(rows);
        return PerfChartBuilder.BuildChartPoints(rows, databases, predicate);
    }

    public IReadOnlyList<string> GetChartDatabaseOrder()
    {
        var rows = BuildComparisonRows();
        return PerfChartBuilder.GetOrderedDatabases(rows);
    }

    private IEnumerable StartBenchmark(PXAdapter adapter, string testCode)
    {
        var request = CreateRequest(testCode);
        MarkRequestRunning(request);
        PXLongOperation.StartOperation(this, () =>
        {
            var graph = CreateInstance<PerfDBBenchmarkGraph>();
            graph.ExecuteBenchmark(request);
        });

        return adapter.Get();
    }

    private PerfBenchmarkRunRequest CreateRequest(string testCode)
    {
        var row = GetControlRow();
        EnsureFilterContext(row);
        PersistControlRow(row);

        return new PerfBenchmarkRunRequest
        {
            RequestID = Guid.NewGuid(),
            TestCode = testCode,
            NumberOfRecords = Math.Max(row.NumberOfRecords ?? row.RecommendedRecords ?? 5000, 1),
            Iterations = Math.Max(row.Iterations ?? row.RecommendedIterations ?? 3, 1),
            BatchSize = Math.Max(row.ParallelBatchSize ?? row.RecommendedBatchSize ?? 100, 1),
            MaxThreads = Math.Max(row.ParallelMaxThreads ?? row.RecommendedMaxThreads ?? 4, 1),
            DatabaseType = row.CurrentDatabase ?? PerfEnvironmentInspector.GetDatabaseDisplayName(this),
            InstanceName = row.CurrentInstance ?? PerfEnvironmentInspector.GetInstanceName(),
            RequestedAtUtc = GetUtcStorageTimestamp(),
            RequestedBy = PXAccess.GetUserName()
        };
    }

    public void ExecuteBenchmark(PerfBenchmarkRunRequest request)
    {
        var descriptor = PerfBenchmarkCatalog.Get(request.TestCode);
        var timer = Stopwatch.StartNew();
        try
        {
            string notes;

            switch (request.TestCode)
            {
                case PerfBenchmarkTestCodes.SequentialRead:
                    notes = RunSequentialReadBenchmark(request);
                    break;
                case PerfBenchmarkTestCodes.SequentialWrite:
                    notes = RunSequentialWriteBenchmark(request);
                    break;
                case PerfBenchmarkTestCodes.SequentialDelete:
                    notes = RunSequentialDeleteBenchmark(request);
                    break;
                case PerfBenchmarkTestCodes.SequentialComplexJoin:
                    notes = RunSequentialComplexJoinBenchmark(request);
                    break;
                case PerfBenchmarkTestCodes.SequentialProjection:
                    notes = RunSequentialProjectionBenchmark(request);
                    break;
                case PerfBenchmarkTestCodes.ParallelRead:
                    notes = RunParallelReadBenchmark(request);
                    break;
                case PerfBenchmarkTestCodes.ParallelWrite:
                    notes = RunParallelWriteBenchmark(request);
                    break;
                case PerfBenchmarkTestCodes.ParallelDelete:
                    notes = RunParallelDeleteBenchmark(request);
                    break;
                case PerfBenchmarkTestCodes.ParallelComplexJoin:
                    notes = RunParallelComplexJoinBenchmark(request);
                    break;
                case PerfBenchmarkTestCodes.ParallelProjection:
                    notes = RunParallelProjectionBenchmark(request);
                    break;
                default:
                    throw new PXException($"Unsupported benchmark test code: {request.TestCode}.");
            }

            timer.Stop();
            PersistResult(request, descriptor, timer.Elapsed, notes);
            MarkRequestCompleted(request, descriptor, timer.Elapsed, notes);
        }
        catch (Exception ex)
        {
            timer.Stop();
            MarkRequestFailed(request, descriptor, ex, timer.Elapsed);
            throw;
        }
    }

    private void PersistResult(PerfBenchmarkRunRequest request, PerfBenchmarkDescriptor descriptor, TimeSpan elapsed, string notes)
    {
        var now = GetUtcStorageTimestamp();
        var row = new PerfTestResult
        {
            InstanceName = request.InstanceName,
            DatabaseType = request.DatabaseType,
            TestCode = descriptor.TestCode,
            TestCategory = descriptor.Category,
            ExecutionMode = descriptor.ExecutionMode,
            DisplayName = descriptor.DisplayName,
            RunID = request.RequestID,
            RequestedAtUtc = request.RequestedAtUtc,
            RecordsCount = request.NumberOfRecords,
            Iterations = request.Iterations,
            BatchSize = request.BatchSize,
            MaxThreads = request.MaxThreads,
            ElapsedMs = elapsed.TotalMilliseconds > int.MaxValue ? int.MaxValue : (int)elapsed.TotalMilliseconds,
            Notes = $"Created by AcuPower LTD (acupowererp.com). {notes}",
            CapturedAtUtc = now
        };

        LocalResults.Cache.Insert(row);
        Save.Press();
        LocalResults.Cache.Clear();
        LocalResults.Cache.ClearQueryCache();

        var latestRows = GetLatestLocalResults();
        PerfSnapshotService.WriteLocalSnapshot(latestRows, request.InstanceName, request.DatabaseType);
    }

    private List<PerfTestResult> GetLatestLocalResults()
    {
        return SelectFrom<PerfTestResult>.View.ReadOnly.Select(this)
            .RowCast<PerfTestResult>()
            .GroupBy(x => x.TestCode)
            .Select(g => g.OrderByDescending(x => x.CapturedAtUtc).First())
            .OrderBy(x => PerfBenchmarkCatalog.Get(x.TestCode).SortOrder)
            .ToList();
    }

    private string RunSequentialReadBenchmark(PerfBenchmarkRunRequest request)
    {
        EnsureSeedData(request.NumberOfRecords);
        var checksum = 0;

        for (var iteration = 1; iteration <= request.Iterations; iteration++)
        {
            checksum += ReadRecordRange(ReadSeedBatch, 1, request.NumberOfRecords);
        }

        return $"Sequential Acumatica BQL reads completed with checksum {checksum}.";
    }

    private string RunSequentialWriteBenchmark(PerfBenchmarkRunRequest request)
    {
        for (var iteration = 1; iteration <= request.Iterations; iteration++)
        {
            var batchId = BuildBatchId(request.TestCode, iteration);
            InsertRecords(batchId, "WRITE", iteration, 1, request.NumberOfRecords);
        }

        return $"Sequential Acumatica cache inserts completed for {request.Iterations} batch(es).";
    }

    private string RunSequentialDeleteBenchmark(PerfBenchmarkRunRequest request)
    {
        var batches = PrepareDeleteBatches(request, "SEQ_DELETE_PREP");
        var checksum = 0;

        foreach (var batch in batches)
        {
            checksum += DeleteRecordRange(batch, 1, request.NumberOfRecords);
        }

        return $"Sequential delete benchmark removed {batches.Count * request.NumberOfRecords:N0} rows with checksum {checksum}.";
    }

    private string RunSequentialComplexJoinBenchmark(PerfBenchmarkRunRequest request)
    {
        var checksum = 0;
        var batchSize = Math.Max(1, request.BatchSize);

        for (var iteration = 1; iteration <= request.Iterations; iteration++)
        {
            for (var offset = 0; offset < request.NumberOfRecords; offset += batchSize)
            {
                checksum += ExecuteComplexJoinWindow(offset, Math.Min(batchSize, request.NumberOfRecords - offset));
            }
        }

        return $"Sequential complex BQL join benchmark completed with analytical checksum {checksum}.";
    }

    private string RunSequentialProjectionBenchmark(PerfBenchmarkRunRequest request)
    {
        var checksum = 0;
        var batchSize = Math.Max(1, request.BatchSize);

        for (var iteration = 1; iteration <= request.Iterations; iteration++)
        {
            for (var offset = 0; offset < request.NumberOfRecords; offset += batchSize)
            {
                checksum += ExecuteProjectionWindow(offset, Math.Min(batchSize, request.NumberOfRecords - offset));
            }
        }

        return $"Sequential PXProjection benchmark completed with analytical checksum {checksum}.";
    }

    private string RunParallelReadBenchmark(PerfBenchmarkRunRequest request)
    {
        EnsureSeedData(request.NumberOfRecords);
        var tasks = BuildRecordTasks(request, ReadSeedBatch);
        ExecuteParallelTasks(request, tasks);
        return $"Parallel read benchmark completed with {tasks.Count} Acumatica processing task(s).";
    }

    private string RunParallelWriteBenchmark(PerfBenchmarkRunRequest request)
    {
        var tasks = BuildRecordTasks(request);
        ExecuteParallelTasks(request, tasks);
        return $"Parallel write benchmark completed with {tasks.Count} Acumatica processing task(s).";
    }

    private string RunParallelDeleteBenchmark(PerfBenchmarkRunRequest request)
    {
        var deleteBatches = PrepareDeleteBatches(request, "PAR_DELETE_PREP");
        var tasks = BuildRecordTasks(request, deleteBatchesByIteration: deleteBatches);
        ExecuteParallelTasks(request, tasks);
        return $"Parallel delete benchmark completed with {tasks.Count} Acumatica processing task(s).";
    }

    private string RunParallelComplexJoinBenchmark(PerfBenchmarkRunRequest request)
    {
        var tasks = BuildWindowTasks(request);
        ExecuteParallelTasks(request, tasks);
        return $"Parallel complex BQL join benchmark completed with {tasks.Count} Acumatica processing task(s).";
    }

    private string RunParallelProjectionBenchmark(PerfBenchmarkRunRequest request)
    {
        var tasks = BuildWindowTasks(request);
        ExecuteParallelTasks(request, tasks);
        return $"Parallel PXProjection benchmark completed with {tasks.Count} Acumatica processing task(s).";
    }

    private void ExecuteParallelTasks(PerfBenchmarkRunRequest request, List<PerfBenchmarkTask> tasks)
    {
        var options = new PXParallelProcessingOptions
        {
            IsEnabled = true,
            AutoBatchSize = false,
            BatchSize = Math.Max(1, request.BatchSize)
        };

        TrySetParallelThreads(options, request.MaxThreads);

        var hadErrors = PXProcessing.ProcessItemsParallel<PerfDBBenchmarkGraph, PerfBenchmarkTask>(
            tasks,
            (graph, task, token) => graph.ProcessParallelTask(task, token),
            CreateInstance<PerfDBBenchmarkGraph>,
            options,
            CancellationToken.None);

        if (hadErrors)
        {
            throw new PXException("The parallel benchmark operation did not complete successfully.");
        }
    }

    private void ProcessParallelTask(PerfBenchmarkTask task, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();

        switch (task.TestCode)
        {
            case PerfBenchmarkTestCodes.ParallelRead:
                ReadRecordRange(task.BatchID, task.StartIndex ?? 0, task.EndIndex ?? 0);
                break;
            case PerfBenchmarkTestCodes.ParallelWrite:
                InsertRecords(task.BatchID, "PAR_WRITE", task.Iteration ?? 0, task.StartIndex ?? 0, task.EndIndex ?? 0);
                break;
            case PerfBenchmarkTestCodes.ParallelDelete:
                DeleteRecordRange(task.BatchID, task.StartIndex ?? 0, task.EndIndex ?? 0);
                break;
            case PerfBenchmarkTestCodes.ParallelComplexJoin:
                ExecuteComplexJoinWindow(task.WindowOffset ?? 0, task.WindowSize ?? 0);
                break;
            case PerfBenchmarkTestCodes.ParallelProjection:
                ExecuteProjectionWindow(task.WindowOffset ?? 0, task.WindowSize ?? 0);
                break;
            default:
                throw new PXException($"Unsupported parallel task code: {task.TestCode}.");
        }
    }

    private void EnsureSeedData(int count)
    {
        var existingCount = SelectFrom<PerfTestRecord>
            .Where<PerfTestRecord.batchID.IsEqual<@P.AsString>>
            .View
            .SelectWindowed(this, 0, count, ReadSeedBatch)
            .RowCast<PerfTestRecord>()
            .Count();

        if (existingCount >= count)
        {
            return;
        }

        ClearBatch(ReadSeedBatch);
        InsertRecords(ReadSeedBatch, "SEED", 0, 1, count);
    }

    private List<string> PrepareDeleteBatches(PerfBenchmarkRunRequest request, string operationType)
    {
        var result = new List<string>();
        for (var iteration = 1; iteration <= request.Iterations; iteration++)
        {
            var batchId = BuildBatchId(request.TestCode, iteration);
            InsertRecords(batchId, operationType, iteration, 1, request.NumberOfRecords);
            result.Add(batchId);
        }

        return result;
    }

    private List<PerfBenchmarkTask> BuildRecordTasks(PerfBenchmarkRunRequest request, string sharedBatchId = null, List<string> deleteBatchesByIteration = null)
    {
        var tasks = new List<PerfBenchmarkTask>();
        var taskId = 1;
        for (var iteration = 1; iteration <= request.Iterations; iteration++)
        {
            var batchId = sharedBatchId
                ?? deleteBatchesByIteration?.ElementAtOrDefault(iteration - 1)
                ?? BuildBatchId(request.TestCode, iteration);

            for (var start = 1; start <= request.NumberOfRecords; start += request.BatchSize)
            {
                tasks.Add(new PerfBenchmarkTask
                {
                    TaskID = taskId++,
                    Selected = true,
                    TestCode = request.TestCode,
                    BatchID = batchId,
                    Iteration = iteration,
                    StartIndex = start,
                    EndIndex = Math.Min(start + request.BatchSize - 1, request.NumberOfRecords)
                });
            }
        }

        return tasks;
    }

    private List<PerfBenchmarkTask> BuildWindowTasks(PerfBenchmarkRunRequest request)
    {
        var tasks = new List<PerfBenchmarkTask>();
        var taskId = 1;
        for (var iteration = 1; iteration <= request.Iterations; iteration++)
        {
            for (var offset = 0; offset < request.NumberOfRecords; offset += request.BatchSize)
            {
                tasks.Add(new PerfBenchmarkTask
                {
                    TaskID = taskId++,
                    Selected = true,
                    TestCode = request.TestCode,
                    Iteration = iteration,
                    WindowOffset = offset,
                    WindowSize = Math.Min(request.BatchSize, request.NumberOfRecords - offset)
                });
            }
        }

        return tasks;
    }

    private string BuildBatchId(string testCode, int iteration) =>
        $"{testCode}-{PerfEnvironmentInspector.GetInstanceName()}-{iteration:000}-{Guid.NewGuid():N}".ToUpperInvariant();

    private void InsertRecords(string batchId, string operationType, int iteration, int startIndex, int endIndex)
    {
        var cache = Caches[typeof(PerfTestRecord)];
        var inserted = 0;

        for (var index = startIndex; index <= endIndex; index++)
        {
            cache.Insert(new PerfTestRecord
            {
                BatchID = batchId,
                OperationType = operationType,
                Iteration = iteration,
                Sequence = index,
                PayloadText = $"AcuPower LTD benchmark payload {batchId}-{index}",
                PayloadValue = index * 17
            });

            inserted++;
            if (inserted % 200 == 0)
            {
                Save.Press();
                cache.Clear();
            }
        }

        Save.Press();
        cache.Clear();
        cache.ClearQueryCache();
    }

    private int ReadRecordRange(string batchId, int startIndex, int endIndex)
    {
        var checksum = 0;
        foreach (PerfTestRecord row in SelectFrom<PerfTestRecord>
                     .Where<PerfTestRecord.batchID.IsEqual<@P.AsString>
                         .And<PerfTestRecord.sequence.IsGreaterEqual<@P.AsInt>>
                         .And<PerfTestRecord.sequence.IsLessEqual<@P.AsInt>>>
                     .OrderBy<PerfTestRecord.sequence.Asc>
                     .View
                     .ReadOnly
                     .Select(this, batchId, startIndex, endIndex))
        {
            checksum += row.PayloadValue ?? 0;
        }

        return checksum;
    }

    private int DeleteRecordRange(string batchId, int startIndex, int endIndex)
    {
        var checksum = 0;
        foreach (PerfTestRecord row in SelectFrom<PerfTestRecord>
                     .Where<PerfTestRecord.batchID.IsEqual<@P.AsString>
                         .And<PerfTestRecord.sequence.IsGreaterEqual<@P.AsInt>>
                         .And<PerfTestRecord.sequence.IsLessEqual<@P.AsInt>>>
                     .OrderBy<PerfTestRecord.sequence.Asc>
                     .View
                     .Select(this, batchId, startIndex, endIndex))
        {
            checksum += row.PayloadValue ?? 0;
            Records.Cache.Delete(row);
        }

        Save.Press();
        Records.Cache.Clear();
        Records.Cache.ClearQueryCache();
        return checksum;
    }

    private void ClearBatch(string batchId)
    {
        foreach (PerfTestRecord row in SelectFrom<PerfTestRecord>
                     .Where<PerfTestRecord.batchID.IsEqual<@P.AsString>>
                     .View
                     .Select(this, batchId))
        {
            Records.Cache.Delete(row);
        }

        Save.Press();
        Records.Cache.Clear();
        Records.Cache.ClearQueryCache();
    }

    private int ExecuteComplexJoinWindow(int offset, int windowSize)
    {
        var checksum = 0m;
        var inventoryIds = new HashSet<int>();

        var rows = SelectFrom<InventoryItem>
            .InnerJoin<INItemClass>.On<INItemClass.itemClassID.IsEqual<InventoryItem.itemClassID>>
            .LeftJoin<INSiteStatus>.On<INSiteStatus.inventoryID.IsEqual<InventoryItem.inventoryID>>
            .LeftJoin<INSite>.On<INSite.siteID.IsEqual<INSiteStatus.siteID>>
            .LeftJoin<GLBranch>.On<GLBranch.branchID.IsEqual<INSite.branchID>>
            .Where<InventoryItem.stkItem.IsEqual<True>.And<INSite.siteID.IsNotNull>>
            .OrderBy<InventoryItem.inventoryCD.Asc, INSite.siteCD.Asc>
            .View
            .ReadOnly
            .SelectWindowed(this, offset, windowSize);

        foreach (PXResult<InventoryItem, INItemClass, INSiteStatus, INSite, GLBranch> row in rows)
        {
            var item = (InventoryItem)row;
            var status = (INSiteStatus)row;

            if (item?.InventoryID != null)
            {
                inventoryIds.Add(item.InventoryID.Value);
            }

            checksum += (status?.QtyOnHand ?? 0m) + (status?.QtyAvail ?? 0m) + (item?.InventoryCD?.Length ?? 0);
        }

        foreach (var inventoryId in inventoryIds.Take(10))
        {
            checksum += SelectFrom<INSiteStatus>
                .Where<INSiteStatus.inventoryID.IsEqual<@P.AsInt>>
                .View
                .ReadOnly
                .SelectWindowed(this, 0, 25, inventoryId)
                .RowCast<INSiteStatus>()
                .Count();
        }

        return DecimalToChecksum(checksum) + inventoryIds.Count;
    }

    private int ExecuteProjectionWindow(int offset, int windowSize)
    {
        var checksum = 0m;
        var inventoryIds = new HashSet<int>();

        var rows = SelectFrom<PerfBenchmarkProjection>
            .Where<PerfBenchmarkProjection.siteID.IsNotNull>
            .OrderBy<PerfBenchmarkProjection.inventoryCD.Asc, PerfBenchmarkProjection.siteCD.Asc>
            .View
            .ReadOnly
            .SelectWindowed(this, offset, windowSize)
            .RowCast<PerfBenchmarkProjection>()
            .ToArray();

        foreach (var row in rows)
        {
            if (row.InventoryID != null)
            {
                inventoryIds.Add(row.InventoryID.Value);
            }

            checksum += (row.QtyOnHand ?? 0m) + (row.QtyAvail ?? 0m) + (row.InventoryCD?.Length ?? 0);
        }

        foreach (var inventoryId in inventoryIds.Take(10))
        {
            checksum += SelectFrom<PerfBenchmarkProjection>
                .Where<PerfBenchmarkProjection.inventoryID.IsEqual<@P.AsInt>>
                .View
                .ReadOnly
                .SelectWindowed(this, 0, 20, inventoryId)
                .RowCast<PerfBenchmarkProjection>()
                .Sum(x => (x.QtyOnHand ?? 0m) + (x.QtyAvail ?? 0m));
        }

        return DecimalToChecksum(checksum) + inventoryIds.Count;
    }

    private static int DecimalToChecksum(decimal value)
    {
        if (value > int.MaxValue)
        {
            return int.MaxValue;
        }

        if (value < int.MinValue)
        {
            return int.MinValue;
        }

        return decimal.ToInt32(decimal.Truncate(value));
    }

    private static void TrySetParallelThreads(PXParallelProcessingOptions options, int maxThreads)
    {
        var field = typeof(PXParallelProcessingOptions).GetField("ParallelThreadsCount", BindingFlags.Instance | BindingFlags.NonPublic);
        field?.SetValue(options, maxThreads);
    }

    private PerfBenchmarkFilter GetControlRow()
    {
        var row = SelectFrom<PerfBenchmarkFilter>
            .Where<PerfBenchmarkFilter.setupID.IsEqual<@P.AsInt>>
            .View
            .Select(this, BenchmarkControlID)
            .TopFirst;

        if (row == null)
        {
            row = InitializeControlRow();
        }

        EnsureFilterContext(row);
        Filter.Current = row;
        return row;
    }

    private PerfBenchmarkFilter InitializeControlRow()
    {
        var row = (PerfBenchmarkFilter)Filter.Cache.Insert(new PerfBenchmarkFilter
        {
            SetupID = BenchmarkControlID,
            LastRequestStatus = PerfBenchmarkRequestStatuses.Idle,
            LastRequestMessage = "Ready to run benchmarks."
        });

        Save.Press();
        Filter.Cache.Clear();
        Filter.Cache.ClearQueryCache();

        return SelectFrom<PerfBenchmarkFilter>
                   .Where<PerfBenchmarkFilter.setupID.IsEqual<@P.AsInt>>
                   .View
                   .Select(this, BenchmarkControlID)
                   .TopFirst
               ?? row;
    }

    private void PersistControlRow(PerfBenchmarkFilter row)
    {
        Filter.Cache.Update(row);
        Save.Press();
        Filter.Cache.ClearQueryCache();
        Filter.Current = row;
    }

    private void MarkRequestRunning(PerfBenchmarkRunRequest request)
    {
        var descriptor = PerfBenchmarkCatalog.Get(request.TestCode);
        var row = GetControlRow();
        row.LastRequestID = request.RequestID;
        row.LastRequestedTestCode = request.TestCode;
        row.LastRequestedBenchmark = descriptor.DisplayName;
        row.LastRequestStatus = PerfBenchmarkRequestStatuses.Running;
        row.LastRequestStartedAtUtc = request.RequestedAtUtc;
        row.LastRequestCompletedAtUtc = null;
        row.LastRequestElapsedMs = null;
        row.LastRequestMessage = TrimRequestMessage($"Running {descriptor.DisplayName} on {request.InstanceName}.");
        PersistControlRow(row);
    }

    private void MarkRequestCompleted(PerfBenchmarkRunRequest request, PerfBenchmarkDescriptor descriptor, TimeSpan elapsed, string notes)
    {
        var row = GetControlRow();
        row.LastRequestID = request.RequestID;
        row.LastRequestedTestCode = request.TestCode;
        row.LastRequestedBenchmark = descriptor.DisplayName;
        row.LastRequestStatus = PerfBenchmarkRequestStatuses.Completed;
        row.LastRequestStartedAtUtc = request.RequestedAtUtc;
        row.LastRequestCompletedAtUtc = GetUtcStorageTimestamp();
        row.LastRequestElapsedMs = elapsed.TotalMilliseconds > int.MaxValue ? int.MaxValue : (int)elapsed.TotalMilliseconds;
        row.LastRequestMessage = TrimRequestMessage($"{descriptor.DisplayName} completed in {FormatElapsed(elapsed)}. {notes}");
        EnsureFilterContext(row);
        PersistControlRow(row);
    }

    private void MarkRequestFailed(PerfBenchmarkRunRequest request, PerfBenchmarkDescriptor descriptor, Exception exception, TimeSpan elapsed)
    {
        var row = GetControlRow();
        row.LastRequestID = request.RequestID;
        row.LastRequestedTestCode = request.TestCode;
        row.LastRequestedBenchmark = descriptor.DisplayName;
        row.LastRequestStatus = PerfBenchmarkRequestStatuses.Failed;
        row.LastRequestStartedAtUtc = request.RequestedAtUtc;
        row.LastRequestCompletedAtUtc = GetUtcStorageTimestamp();
        row.LastRequestElapsedMs = elapsed.TotalMilliseconds > int.MaxValue ? int.MaxValue : (int)elapsed.TotalMilliseconds;
        row.LastRequestMessage = TrimRequestMessage($"{descriptor.DisplayName} failed: {exception.Message}");
        EnsureFilterContext(row);
        PersistControlRow(row);
    }

    private void ResetRequestState(PerfBenchmarkFilter row)
    {
        row.LastRequestID = null;
        row.LastRequestedTestCode = null;
        row.LastRequestedBenchmark = null;
        row.LastRequestStatus = PerfBenchmarkRequestStatuses.Idle;
        row.LastRequestStartedAtUtc = null;
        row.LastRequestCompletedAtUtc = null;
        row.LastRequestElapsedMs = null;
        row.LastRequestMessage = "Ready to run benchmarks.";
    }

    private static string TrimRequestMessage(string message)
    {
        if (string.IsNullOrWhiteSpace(message))
        {
            return string.Empty;
        }

        return message.Length <= 1024 ? message : message.Substring(0, 1024);
    }

    private static string FormatElapsed(TimeSpan elapsed)
    {
        if (elapsed.TotalSeconds >= 60)
        {
            return elapsed.ToString(@"hh\:mm\:ss", CultureInfo.InvariantCulture);
        }

        return $"{elapsed.TotalSeconds:0.##} sec";
    }

    private static DateTime GetUtcStorageTimestamp()
    {
        return DateTime.SpecifyKind(DateTime.UtcNow, DateTimeKind.Unspecified);
    }

    private void ClearAllBenchmarkData()
    {
        foreach (PerfTestResult result in SelectFrom<PerfTestResult>.View.Select(this))
        {
            LocalResults.Cache.Delete(result);
        }

        foreach (PerfTestRecord record in SelectFrom<PerfTestRecord>.View.Select(this))
        {
            Records.Cache.Delete(record);
        }

        Save.Press();
        PerfSnapshotService.ClearLocalSnapshot();
        var row = GetControlRow();
        ResetRequestState(row);
        EnsureFilterContext(row);
        PersistControlRow(row);
        LocalResults.Cache.Clear();
        Records.Cache.Clear();
        LocalResults.Cache.ClearQueryCache();
        Records.Cache.ClearQueryCache();
    }

    private List<PerfComparisonResult> BuildComparisonRows()
    {
        var rows = new List<PerfComparisonResult>();
        var snapshots = PerfSnapshotService.LoadAllSnapshots().ToArray();
        var lineNbr = 1;

        foreach (var envelope in snapshots)
        {
            foreach (var item in envelope.Results.OrderBy(x => PerfBenchmarkCatalog.Get(x.TestCode).SortOrder))
            {
                rows.Add(new PerfComparisonResult
                {
                    LineNbr = lineNbr++,
                    TestCode = item.TestCode,
                    TestDisplayName = item.DisplayName,
                    TestCategory = item.TestCategory,
                    ExecutionMode = item.ExecutionMode,
                    DatabaseType = envelope.DatabaseType,
                    InstanceName = envelope.InstanceName,
                    ElapsedMs = item.ElapsedMs,
                    RecordsCount = item.RecordsCount,
                    Iterations = item.Iterations,
                    BatchSize = item.BatchSize,
                    MaxThreads = item.MaxThreads,
                    CapturedAtUtc = item.CapturedAtUtc,
                    Notes = item.Notes
                });
            }
        }

        foreach (var group in rows.GroupBy(x => x.TestCode))
        {
            var minElapsed = group.Min(x => x.ElapsedMs ?? int.MaxValue);
            var winners = group.Where(x => (x.ElapsedMs ?? int.MaxValue) == minElapsed).ToArray();
            var winnerLabel = string.Join(", ", winners.Select(x => x.DatabaseType));

            foreach (var row in group)
            {
                row.IsWinner = (row.ElapsedMs ?? int.MaxValue) == minElapsed;
                row.WinnerDisplay = row.IsWinner == true ? $"{row.DatabaseType} is fastest" : $"{winnerLabel} is fastest";
            }
        }

        return rows
            .OrderBy(x => PerfBenchmarkCatalog.Get(x.TestCode).SortOrder)
            .ThenBy(x => x.DatabaseType)
            .ToList();
    }

    private void EnsureFilterContext(PerfBenchmarkFilter row)
    {
        row ??= new PerfBenchmarkFilter { SetupID = BenchmarkControlID };
        var recommendation = PerfHardwareInspector.Detect();

        row.CurrentDatabase = PerfEnvironmentInspector.GetDatabaseDisplayName(this);
        row.CurrentInstance = PerfEnvironmentInspector.GetInstanceName();
        row.DetectedCpuCores = recommendation.CpuCores;
        row.DetectedMemoryGb = recommendation.MemoryGb;
        row.RecommendedRecords = recommendation.RecommendedRecords;
        row.RecommendedIterations = recommendation.RecommendedIterations;
        row.RecommendedBatchSize = recommendation.RecommendedBatchSize;
        row.RecommendedMaxThreads = recommendation.RecommendedMaxThreads;
        row.HardwareRecommendationSummary = recommendation.Summary;
        row.SnapshotStatus = PerfSnapshotService.GetSnapshotStatus();
        row.PendingAnalysisStatus = PerfSnapshotService.GetPendingAnalysisStatus();

        row.NumberOfRecords ??= recommendation.RecommendedRecords;
        row.Iterations ??= recommendation.RecommendedIterations;
        row.ParallelBatchSize ??= recommendation.RecommendedBatchSize;
        row.ParallelMaxThreads ??= recommendation.RecommendedMaxThreads;
        row.LastRequestStatus ??= PerfBenchmarkRequestStatuses.Idle;
        row.LastRequestMessage ??= "Ready to run benchmarks.";
    }
}
