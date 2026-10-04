using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using PX.Data;
using PX.Data.BQL;
using PX.Data.BQL.Fluent;
using PerfDBBenchmark.Core.DAC;
using PerfDBBenchmark.Core.Scenarios;
using PerfDBBenchmark.Core.Support;

namespace PerfDBBenchmark.Core.Graphs;

/// <summary>
/// PerfDBBenchmark was created by AcuPower LTD for Acumatica database performance analysis.
/// The constructor only reads the control row (no WMI, no snapshot reads; SPEC §2.1 F4/F15). Runs go through
/// PerfScenarioRunner and PerfResultWriter (SPEC §4.2); one run per instance at a time (PerfRunControl).
/// </summary>
public class PerfDBBenchmarkGraph : PXGraph<PerfDBBenchmarkGraph>
{
    private const int BenchmarkControlID = 1;
    private const string LoadErrorsPrefix = "[Catalog load errors: ";
    private const string LoadErrorsSeparator = "] || ";
    private const decimal VerdictBand = 0.05m;

    public PXSave<PerfBenchmarkFilter> Save;
    public PXCancel<PerfBenchmarkFilter> Cancel;

    public SelectFrom<PerfBenchmarkFilter>.View Filter;
    public SelectFrom<PerfBenchmarkDefinition>.View BenchmarkCatalog;
    public SelectFrom<PerfTestRecord>.View Records;
    public SelectFrom<PerfTestResult>.OrderBy<Desc<PerfTestResult.resultID>>.View LocalResults;
    public SelectFrom<PerfComparisonResult>.View ComparisonResults;

    public override bool IsDirty => Filter.Cache.IsDirty || Records.Cache.IsDirty || LocalResults.Cache.IsDirty;

    public PerfDBBenchmarkGraph()
    {
        ConfigureTestCodeList();
        GetControlRow();
    }

    public IEnumerable benchmarkCatalog()
    {
        IReadOnlyList<PerfTestDescriptor> all;
        try
        {
            all = PerfScenarioRegistry.All;
        }
        catch
        {
            yield break;
        }

        foreach (var d in all)
        {
            yield return new PerfBenchmarkDefinition
            {
                TestCode = d.TestCode,
                DisplayName = d.DisplayName,
                ActionName = d.ActionName,
                Category = d.Category,
                ExecutionMode = d.ExecutionMode,
                ShortDescription = d.ShortDescription,
                SortOrder = d.SortOrder,
                Family = d.Family,
                RunBlock = d.RunBlock,
                ShortLabel = d.ShortLabel,
                Question = d.Question,
                WhatItSimulates = d.WhatItSimulates,
                WhyItMatters = d.WhyItMatters,
                ReaderUnit = d.ReaderUnit,
                UserCount = d.Users,
                HeadlineKind = d.HeadlineKind,
                HeadlineUnit = d.HeadlineUnit,
                HigherIsBetter = d.HigherIsBetter,
                OpsUnit = d.OpsUnit,
                ParityExpected = d.ParityExpected,
                IsDestructive = d.IsDestructive,
                IsOptional = d.IsOptional,
                ExcludeFromComparison = d.ExcludeFromComparison,
                LegacyTestCode = d.LegacyTestCode,
                ScenarioVersion = d.ScenarioVersion,
                DefaultOpsPerPass = d.DefaultOpsPerPass,
                DefaultPasses = d.DefaultPasses,
                DefaultWarmUpPasses = d.DefaultWarmUpPasses
            };
        }
    }

    public IEnumerable comparisonResults()
    {
        var row = GetControlRow();
        ApplySnapshotStatus(row);
        return BuildComparisonRows();
    }

    protected virtual void _(Events.RowSelected<PerfBenchmarkFilter> e)
    {
        if (e.Row == null) return;
        ApplyServerFields(e.Row);
    }

    #region Actions

    public PXAction<PerfBenchmarkFilter> RunBenchmark;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.RunBenchmark)]
    [PXUIField(DisplayName = "Run Selected Test", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable runBenchmark(PXAdapter adapter)
    {
        var row = GetControlRow();
        var selected = row.SelectedTestCode?.Trim();
        if (string.IsNullOrEmpty(selected))
        {
            throw new PXException("Select a test in 'Test to Run' first.");
        }

        return StartBenchmark(adapter, selected);
    }

    public PXAction<PerfBenchmarkFilter> AbortBenchmark;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.AbortBenchmark)]
    [PXUIField(DisplayName = "Abort Run", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable abortBenchmark(PXAdapter adapter)
    {
        // Never throws (SPEC §3.1).
        string message;
        try
        {
            message = PerfRunControl.RequestAbort("AbortBenchmark action") ? "Abort requested" : "Nothing to abort";
        }
        catch (Exception ex)
        {
            message = "Abort request failed: " + ex.Message;
        }

        try
        {
            // Targeted single-column update: a run in progress owns the other control-row fields, so the row is never
            // re-saved here (a stale copy could overwrite the run's Completed status).
            PXDatabase.Update<PerfBenchmarkFilter>(
                new PXDataFieldAssign<PerfBenchmarkFilter.lastRequestMessage>(PXDbType.NVarChar, 1024, message),
                new PXDataFieldRestrict<PerfBenchmarkFilter.setupID>(PXDbType.Int, 4, BenchmarkControlID, PXComp.EQ));
            Filter.Cache.Clear();
            Filter.Cache.ClearQueryCache();
            GetControlRow();
        }
        catch
        {
            try
            {
                if (Filter.Current != null) Filter.Current.LastRequestMessage = message;
            }
            catch
            {
                // never throw from AbortBenchmark
            }
        }

        return adapter.Get();
    }

    public PXAction<PerfBenchmarkFilter> ClearTestRecords;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.ClearTestRecords)]
    [PXUIField(DisplayName = "Clear Test Records", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable clearTestRecords(PXAdapter adapter)
    {
        StartMaintenance(adapter, PerfScenarioCodes.ClearTestRecordsAction, "Clearing test records and leftovers", graph => graph.ClearTestRecordsCore());
        return adapter.Get();
    }

    public PXAction<PerfBenchmarkFilter> ApplyRecommendedSettings;
    [PXButton(CommitChanges = true)]
    [PXUIField(DisplayName = "Apply Recommended Settings", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable applyRecommendedSettings(PXAdapter adapter)
    {
        if (PerfRunControl.IsRunning)
        {
            throw new PXException("A benchmark run is already in progress on this instance.");
        }

        // Campaign constants, not hardware-derived values (SPEC §2.1 F22).
        UpdateControlRowFresh(row =>
        {
            row.NumberOfRecords = PerfCampaignConstants.CoreRecords;
            row.Iterations = PerfCampaignConstants.CoreMeasuredPasses;
            row.ParallelBatchSize = PerfCampaignConstants.CoreChunkSize;
            row.ParallelMaxThreads = PerfCampaignConstants.CoreParallelWorkers;
            ApplyHardware(row, detect: true);
        });
        return adapter.Get();
    }

    public PXAction<PerfBenchmarkFilter> RefreshStatus;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.RefreshStatus)]
    [PXUIField(DisplayName = "Refresh Status", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable refreshStatus(PXAdapter adapter)
    {
        if (PerfRunControl.IsRunning)
        {
            // Never write the control row while a run owns it; show the status in memory only.
            var current = GetControlRow();
            ApplyHardware(current, detect: true);
            ApplySnapshotStatus(current);
            return adapter.Get();
        }

        UpdateControlRowFresh(row =>
        {
            ApplyHardware(row, detect: true);
            ApplySnapshotStatus(row);
        });
        return adapter.Get();
    }

    public PXAction<PerfBenchmarkFilter> RunSequentialRead;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.SequentialRead)]
    [PXUIField(DisplayName = "Sequential Read", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable runSequentialRead(PXAdapter adapter) => StartBenchmark(adapter, PerfLegacyAliases.Map(PerfBenchmarkTestCodes.SequentialRead));

    public PXAction<PerfBenchmarkFilter> RunSequentialWrite;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.SequentialWrite)]
    [PXUIField(DisplayName = "Sequential Write", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable runSequentialWrite(PXAdapter adapter) => StartBenchmark(adapter, PerfLegacyAliases.Map(PerfBenchmarkTestCodes.SequentialWrite));

    public PXAction<PerfBenchmarkFilter> RunSequentialUpdate;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.SequentialUpdate)]
    [PXUIField(DisplayName = "Sequential Update", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable runSequentialUpdate(PXAdapter adapter) => StartBenchmark(adapter, PerfLegacyAliases.Map(PerfBenchmarkTestCodes.SequentialUpdate));

    public PXAction<PerfBenchmarkFilter> RunSequentialDelete;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.SequentialDelete)]
    [PXUIField(DisplayName = "Sequential Delete", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable runSequentialDelete(PXAdapter adapter) => StartBenchmark(adapter, PerfLegacyAliases.Map(PerfBenchmarkTestCodes.SequentialDelete));

    public PXAction<PerfBenchmarkFilter> RunSequentialComplexJoin;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.SequentialComplexJoin)]
    [PXUIField(DisplayName = "Complex BQL Join (Sequential)", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable runSequentialComplexJoin(PXAdapter adapter) => StartBenchmark(adapter, PerfLegacyAliases.Map(PerfBenchmarkTestCodes.SequentialComplexJoin));

    public PXAction<PerfBenchmarkFilter> RunSequentialProjection;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.SequentialProjection)]
    [PXUIField(DisplayName = "PXProjection Analysis (Sequential)", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable runSequentialProjection(PXAdapter adapter) => StartBenchmark(adapter, PerfLegacyAliases.Map(PerfBenchmarkTestCodes.SequentialProjection));

    public PXAction<PerfBenchmarkFilter> RunParallelRead;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.ParallelRead)]
    [PXUIField(DisplayName = "Parallel Read", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable runParallelRead(PXAdapter adapter) => StartBenchmark(adapter, PerfLegacyAliases.Map(PerfBenchmarkTestCodes.ParallelRead));

    public PXAction<PerfBenchmarkFilter> RunParallelWrite;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.ParallelWrite)]
    [PXUIField(DisplayName = "Parallel Write", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable runParallelWrite(PXAdapter adapter) => StartBenchmark(adapter, PerfLegacyAliases.Map(PerfBenchmarkTestCodes.ParallelWrite));

    public PXAction<PerfBenchmarkFilter> RunParallelUpdate;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.ParallelUpdate)]
    [PXUIField(DisplayName = "Parallel Update", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable runParallelUpdate(PXAdapter adapter) => StartBenchmark(adapter, PerfLegacyAliases.Map(PerfBenchmarkTestCodes.ParallelUpdate));

    public PXAction<PerfBenchmarkFilter> RunParallelDelete;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.ParallelDelete)]
    [PXUIField(DisplayName = "Parallel Delete", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable runParallelDelete(PXAdapter adapter) => StartBenchmark(adapter, PerfLegacyAliases.Map(PerfBenchmarkTestCodes.ParallelDelete));

    public PXAction<PerfBenchmarkFilter> RunParallelComplexJoin;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.ParallelComplexJoin)]
    [PXUIField(DisplayName = "Complex BQL Join (Parallel)", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable runParallelComplexJoin(PXAdapter adapter) => StartBenchmark(adapter, PerfLegacyAliases.Map(PerfBenchmarkTestCodes.ParallelComplexJoin));

    public PXAction<PerfBenchmarkFilter> RunParallelProjection;
    [PXButton(CommitChanges = true, Tooltip = PerfBenchmarkDescriptions.ParallelProjection)]
    [PXUIField(DisplayName = "PXProjection Analysis (Parallel)", MapEnableRights = PXCacheRights.Select, MapViewRights = PXCacheRights.Select)]
    protected virtual IEnumerable runParallelProjection(PXAdapter adapter) => StartBenchmark(adapter, PerfLegacyAliases.Map(PerfBenchmarkTestCodes.ParallelProjection));

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
        StartMaintenance(adapter, "ClearTestData", "Clearing all benchmark records and results", graph => graph.ClearAllBenchmarkData());
        return adapter.Get();
    }

    #endregion

    #region Public methods used by the classic code-behind (signatures kept, SPEC §2.3)

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

    #endregion

    #region Run lifecycle

    private IEnumerable StartBenchmark(PXAdapter adapter, string testCode)
    {
        if (PerfRunControl.IsRunning)
        {
            throw new PXException("A benchmark run is already in progress on this instance.");
        }

        var code = PerfLegacyAliases.Map(testCode?.Trim());
        if (!PerfScenarioRegistry.TryGet(code, out var descriptor))
        {
            throw new PXException("Unknown benchmark test code: " + testCode + ".");
        }

        var request = CreateRequest(descriptor.TestCode);
        if (!PerfRunControl.TryReserve(request.RequestID))
        {
            throw new PXException("A benchmark run is already in progress on this instance.");
        }

        try
        {
            MarkRequestRunning(request, descriptor);

            // The run's long operation is keyed by its RequestID, not by this graph (whose UID is the screen's per-session
            // key). The contract-based API refuses every request to the screen's entity (GET by id or list, PUT, POST action)
            // with 409 while a long operation is running under that key in the same session
            // (EntityExportContextBuilder.CheckLongOperationForGraph). With its own key the run leaves BenchmarkControl
            // readable during the run (status polling with the server facts) and AbortBenchmark callable. The graph's
            // timestamp is still applied to the work, exactly as StartOperation(this, ...) does (PXTimeStampScope).
            var timeStamp = TimeStamp;
            PXLongOperation.StartOperation(request.RequestID, () =>
            {
                using (new PXTimeStampScope(timeStamp))
                {
                    var graph = CreateInstance<PerfDBBenchmarkGraph>();
                    graph.ExecuteBenchmark(request);
                }
            });
        }
        catch
        {
            PerfRunControl.CancelReservation(request.RequestID);
            throw;
        }

        return adapter.Get();
    }

    private PerfRunRequest CreateRequest(string testCode)
    {
        var row = GetControlRow();
        ApplyContext(row);
        PersistControlRow(row);

        var workScale = row.WorkScale is decimal ws && ws > 0m && ws <= 1m ? ws : 1m;
        return new PerfRunRequest
        {
            RequestID = Guid.NewGuid(),
            TestCode = testCode,
            NumberOfRecords = Math.Max(row.NumberOfRecords ?? PerfCampaignConstants.CoreRecords, 1),
            Iterations = Math.Max(row.Iterations ?? PerfCampaignConstants.CoreMeasuredPasses, 1),
            BatchSize = Math.Max(row.ParallelBatchSize ?? PerfCampaignConstants.CoreChunkSize, 1),
            DatabaseType = PerfDatabaseEngines.Detect(),
            InstanceName = PerfRuntimeInfo.InstanceName,
            RequestedAtUtc = GetUtcStorageTimestamp(),
            RequestedBy = SafeUserName(),
            CampaignID = row.CampaignID,
            RepetitionNo = row.RepetitionNo,
            IsWarmup = row.IsWarmup == true,
            RunBlock = string.IsNullOrWhiteSpace(row.RunBlock) ? null : row.RunBlock.Trim(),
            OrderPosition = row.OrderPosition,
            WorkScale = workScale,
            PassesOverride = row.PassesOverride is int p && p > 0 ? p : (int?)null,
            WarmUpPassesOverride = row.WarmUpPassesOverride is int w && w >= 0 ? w : (int?)null,
            RunBudgetSec = row.RunBudgetSec is int b && b > 0 ? b : (int?)null
        };
    }

    /// <summary>Long-operation body: runs the test, writes the result row (not for Failed runs) and the control-row status.</summary>
    public void ExecuteBenchmark(PerfRunRequest request)
    {
        if (request == null) throw new ArgumentNullException(nameof(request));
        PerfTestDescriptor descriptor = null;
        var timer = Stopwatch.StartNew();
        PerfRunMetrics metrics;
        string snapshotError;

        try
        {
            PerfScenarioRegistry.TryGet(request.TestCode, out descriptor);
            using (PerfRunControl.Begin(request.RequestID))
            {
                descriptor ??= PerfScenarioRegistry.Get(request.TestCode);
                metrics = PerfScenarioRunner.Run(request);
                PerfResultWriter.Persist(this, request, descriptor, metrics);
                snapshotError = PerfResultWriter.LastSnapshotError;
            }
        }
        catch (Exception ex)
        {
            timer.Stop();
            try
            {
                MarkRequestFailed(request, descriptor, ex, timer.Elapsed);
            }
            catch (Exception markEx)
            {
                PXTrace.WriteError(markEx);
            }

            throw;
        }

        timer.Stop();
        MarkRequestCompleted(request, descriptor, metrics, timer.Elapsed, snapshotError);
    }

    private void MarkRequestRunning(PerfRunRequest request, PerfTestDescriptor descriptor)
    {
        UpdateControlRowFresh(row =>
        {
            row.LastRequestID = request.RequestID;
            row.LastRequestedTestCode = request.TestCode;
            row.LastRequestedBenchmark = Trim(descriptor.DisplayName, 128);
            row.LastRequestStatus = PerfBenchmarkRequestStatuses.Running;
            row.LastRequestStartedAtUtc = request.RequestedAtUtc;
            row.LastRequestCompletedAtUtc = null;
            row.LastRequestElapsedMs = null;
            row.LastRequestMessage = Trim($"Running {descriptor.DisplayName} ({descriptor.TestCode}) on {request.InstanceName}.", 1024);
        }, preserveCachedInputs: true);
    }

    private void MarkRequestCompleted(PerfRunRequest request, PerfTestDescriptor descriptor, PerfRunMetrics metrics, TimeSpan elapsed, string snapshotError)
    {
        UpdateControlRowFresh(row =>
        {
            row.LastRequestID = request.RequestID;
            row.LastRequestedTestCode = request.TestCode;
            row.LastRequestedBenchmark = Trim(descriptor?.DisplayName ?? request.TestCode, 128);
            row.LastRequestStatus = PerfBenchmarkRequestStatuses.Completed;   // also for Invalid and Capped; the message carries Status/InvalidReason
            row.LastRequestStartedAtUtc = request.RequestedAtUtc;
            row.LastRequestCompletedAtUtc = GetUtcStorageTimestamp();
            row.LastRequestElapsedMs = ToIntMs(elapsed);
            row.LastRequestMessage = Trim(CompletionMessage(descriptor, metrics, elapsed, snapshotError), 1024);
            ApplySnapshotStatus(row);
        });
    }

    private void MarkRequestFailed(PerfRunRequest request, PerfTestDescriptor descriptor, Exception exception, TimeSpan elapsed)
    {
        UpdateControlRowFresh(row =>
        {
            row.LastRequestID = request.RequestID;
            row.LastRequestedTestCode = request.TestCode;
            row.LastRequestedBenchmark = Trim(descriptor?.DisplayName ?? request.TestCode, 128);
            row.LastRequestStatus = PerfBenchmarkRequestStatuses.Failed;
            row.LastRequestStartedAtUtc = request.RequestedAtUtc;
            row.LastRequestCompletedAtUtc = GetUtcStorageTimestamp();
            row.LastRequestElapsedMs = ToIntMs(elapsed);
            row.LastRequestMessage = Trim($"{descriptor?.DisplayName ?? request.TestCode} failed: {exception.Message}", 1024);
        });
    }

    private static string CompletionMessage(PerfTestDescriptor descriptor, PerfRunMetrics metrics, TimeSpan elapsed, string snapshotError)
    {
        var name = descriptor?.DisplayName ?? "Benchmark";
        var status = metrics.Status ?? PerfRunStatuses.Completed;
        var text = $"{name} finished in {FormatElapsed(elapsed)}. Status: {status}";
        if (!string.IsNullOrEmpty(metrics.InvalidReason)) text += $" ({metrics.InvalidReason})";
        text += ".";
        if (descriptor != null && descriptor.HeadlineKind != PerfHeadlineKinds.None)
        {
            var hv = PerfResultWriter.Dec(metrics.HeadlineValue, 3);
            text += hv.HasValue
                ? $" Headline {hv.Value.ToString("0.###", CultureInfo.InvariantCulture)} {descriptor.HeadlineUnit}."
                : " Headline n/a.";
            text += $" Errors {metrics.ErrorCount.ToString(CultureInfo.InvariantCulture)}.";
        }

        if (!string.IsNullOrWhiteSpace(metrics.Notes)) text += " " + metrics.Notes.Trim();
        if (!string.IsNullOrEmpty(snapshotError)) text += " Snapshot not written: " + snapshotError;
        return text;
    }

    #endregion

    #region Maintenance actions (ClearTestData, ClearTestRecords)

    /// <summary>Runs a maintenance job as a long operation while holding the run slot, so no benchmark can start meanwhile.
    /// The control row shows Running while it works and is reset to Idle (LastRequestID empty) when it is done.</summary>
    private void StartMaintenance(PXAdapter adapter, string code, string runningText, Action<PerfDBBenchmarkGraph> work)
    {
        if (PerfRunControl.IsRunning)
        {
            throw new PXException("A benchmark run is already in progress on this instance.");
        }

        var id = Guid.NewGuid();
        if (!PerfRunControl.TryReserve(id))
        {
            throw new PXException("A benchmark run is already in progress on this instance.");
        }

        try
        {
            var started = GetUtcStorageTimestamp();
            UpdateControlRowFresh(row =>
            {
                row.LastRequestID = id;
                row.LastRequestedTestCode = code;
                row.LastRequestedBenchmark = code;
                row.LastRequestStatus = PerfBenchmarkRequestStatuses.Running;
                row.LastRequestStartedAtUtc = started;
                row.LastRequestCompletedAtUtc = null;
                row.LastRequestElapsedMs = null;
                row.LastRequestMessage = runningText + ".";
            }, preserveCachedInputs: true);

            PXLongOperation.StartOperation(this, () =>
            {
                var graph = CreateInstance<PerfDBBenchmarkGraph>();
                using (PerfRunControl.Begin(id))
                {
                    try
                    {
                        work(graph);
                    }
                    catch (Exception ex)
                    {
                        graph.UpdateControlRowFresh(row =>
                        {
                            row.LastRequestStatus = PerfBenchmarkRequestStatuses.Failed;
                            row.LastRequestCompletedAtUtc = GetUtcStorageTimestamp();
                            row.LastRequestMessage = Trim(code + " failed: " + ex.Message, 1024);
                        });
                        throw;
                    }
                }
            });
        }
        catch
        {
            PerfRunControl.CancelReservation(id);
            throw;
        }
    }

    /// <summary>Set-based delete of every PerfTestRecord and PerfTestResult row, then the local snapshot (SPEC §2.1 F21).</summary>
    private void ClearAllBenchmarkData()
    {
        var sw = Stopwatch.StartNew();
        var records = CountRows<PerfTestRecord>();
        var results = CountRows<PerfTestResult>();
        var fallback = false;

        try
        {
            PXDatabase.Delete<PerfTestRecord>(new PXDataFieldRestrict<PerfTestRecord.recordID>(PXDbType.Int, 4, 0, PXComp.GT));
            PXDatabase.Delete<PerfTestResult>(new PXDataFieldRestrict<PerfTestResult.resultID>(PXDbType.Int, 4, 0, PXComp.GT));
        }
        catch (Exception ex)
        {
            // SPEC §8 R18: fall back to row-by-row deletes through the cache.
            PXTrace.WriteWarning("PerfDBBenchmark: set-based delete failed, deleting row by row: " + ex.Message);
            fallback = true;
            DeleteRowByRow();
        }

        PerfSnapshotService.ClearLocalSnapshot();
        Records.Cache.Clear();
        LocalResults.Cache.Clear();
        Records.Cache.ClearQueryCache();
        LocalResults.Cache.ClearQueryCache();

        var message = $"Test data cleared: {records} record(s) and {results} result(s) removed{(fallback ? " (row by row)" : string.Empty)} in {FormatElapsed(sw.Elapsed)}.";
        UpdateControlRowFresh(row =>
        {
            ResetRequestState(row);
            row.LastRequestMessage = Trim(message, 1024);
            ApplySnapshotStatus(row);
        });
    }

    private void DeleteRowByRow()
    {
        Clear(PXClearOption.ClearAll);
        SelectTimeStamp();
        foreach (PerfTestResult result in SelectFrom<PerfTestResult>.View.Select(this))
        {
            LocalResults.Cache.Delete(result);
        }

        foreach (PerfTestRecord record in SelectFrom<PerfTestRecord>.View.Select(this))
        {
            Records.Cache.Delete(record);
        }

        Actions.PressSave();
    }

    /// <summary>Deletes PerfTestRecord rows other than READ-SEED and UPDATE-SEED (set-based) and runs every
    /// IPerfLeftoverCleaner. Results are kept (SPEC §2.1 F21).</summary>
    private void ClearTestRecordsCore()
    {
        var sw = Stopwatch.StartNew();
        var before = CountRows<PerfTestRecord>();
        var seeds = CountRows<PerfTestRecord>(new PXDataFieldValue<PerfTestRecord.batchID>(PXDbType.NVarChar, 64, PerfCampaignConstants.ReadSeedBatch)) +
                    CountRows<PerfTestRecord>(new PXDataFieldValue<PerfTestRecord.batchID>(PXDbType.NVarChar, 64, PerfCampaignConstants.UpdateSeedBatch));
        var problems = new List<string>();

        try
        {
            PXDatabase.Delete<PerfTestRecord>(
                new PXDataFieldRestrict<PerfTestRecord.batchID>(PXDbType.NVarChar, 64, PerfCampaignConstants.ReadSeedBatch, PXComp.NE),
                new PXDataFieldRestrict<PerfTestRecord.batchID>(PXDbType.NVarChar, 64, PerfCampaignConstants.UpdateSeedBatch, PXComp.NE));
        }
        catch (Exception ex)
        {
            PXTrace.WriteWarning("PerfDBBenchmark: set-based delete of test records failed, deleting row by row: " + ex.Message);
            Clear(PXClearOption.ClearAll);
            SelectTimeStamp();
            foreach (PerfTestRecord record in SelectFrom<PerfTestRecord>.View.Select(this))
            {
                if (record.BatchID == PerfCampaignConstants.ReadSeedBatch || record.BatchID == PerfCampaignConstants.UpdateSeedBatch) continue;
                Records.Cache.Delete(record);
            }

            Actions.PressSave();
        }

        var after = CountRows<PerfTestRecord>();
        var removedRecords = Math.Max(0, before - after);

        var removedDocuments = 0;
        foreach (var cleaner in PerfScenarioRegistry.LeftoverCleaners)
        {
            string name;
            try { name = cleaner.Name ?? cleaner.GetType().Name; }
            catch { name = cleaner.GetType().Name; }

            try
            {
                removedDocuments += cleaner.Clean(CreateInstance<PerfWorkerGraph>());
            }
            catch (Exception ex)
            {
                problems.Add(name + ": " + ex.Message);
            }
        }

        Records.Cache.Clear();
        Records.Cache.ClearQueryCache();

        var message = $"Test records cleared: {removedRecords} work record(s) removed ({seeds} seed rows kept), {removedDocuments} leftover document(s) removed by {PerfScenarioRegistry.LeftoverCleaners.Count} cleaner(s) in {FormatElapsed(sw.Elapsed)}.";
        if (problems.Count > 0) message += " Problems: " + string.Join("; ", problems);
        // Never throws for a cleaner problem: the suite waits for Idle; gate G3 re-checks the leftovers.
        UpdateControlRowFresh(row =>
        {
            ResetRequestState(row);
            row.LastRequestMessage = Trim(message, 1024);
        });
    }

    private static long CountRows<T>(params PXDataField[] restrictions) where T : IBqlTable
    {
        try
        {
            var fields = new List<PXDataField> { new PXDataField(PX.Data.SQLTree.SQLExpression.Count()) };
            fields.AddRange(restrictions);
            using (PXDataRecord rec = PXDatabase.SelectSingle<T>(fields.ToArray()))
            {
                var raw = rec?.GetValue(0);
                return raw == null || raw is DBNull ? 0L : Convert.ToInt64(raw, CultureInfo.InvariantCulture);
            }
        }
        catch
        {
            return 0L;
        }
    }

    #endregion

    #region Control row

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

        ApplyContext(row);
        Filter.Current = row;
        return row;
    }

    private PerfBenchmarkFilter InitializeControlRow()
    {
        var row = (PerfBenchmarkFilter)Filter.Cache.Insert(new PerfBenchmarkFilter
        {
            SetupID = BenchmarkControlID,
            NumberOfRecords = PerfCampaignConstants.CoreRecords,
            Iterations = PerfCampaignConstants.CoreMeasuredPasses,
            ParallelBatchSize = PerfCampaignConstants.CoreChunkSize,
            ParallelMaxThreads = PerfCampaignConstants.CoreParallelWorkers,
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

    /// <summary>Persists the cached control row (keeps values the user or REST just entered).</summary>
    private void PersistControlRow(PerfBenchmarkFilter row)
    {
        StripLoadErrorsNotice(row);
        SelectTimeStamp();
        Filter.Cache.Update(row);
        Save.Press();
        Filter.Cache.ClearQueryCache();
        Filter.Current = row;
        ApplyLoadErrorsNotice(row);
    }

    /// <summary>Re-reads the control row from the database with a fresh graph stamp, applies the change and saves it,
    /// so a row updated by another thread (long operation, AbortBenchmark) is never overwritten with stale values.</summary>
    private void UpdateControlRowFresh(Action<PerfBenchmarkFilter> change, bool preserveCachedInputs = false)
    {
        PerfBenchmarkFilter cached = preserveCachedInputs ? Filter.Current : null;
        Exception last = null;
        for (var attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                Filter.Cache.Clear();
                Filter.Cache.ClearQueryCache();
                SelectTimeStamp();
                var row = GetControlRow();
                if (cached != null) CopyInputs(cached, row);
                change(row);
                PersistControlRow(row);
                return;
            }
            catch (Exception ex)
            {
                last = ex;
            }
        }

        throw last ?? new PXException("The benchmark control row could not be updated.");
    }

    private static void CopyInputs(PerfBenchmarkFilter from, PerfBenchmarkFilter to)
    {
        to.NumberOfRecords = from.NumberOfRecords ?? to.NumberOfRecords;
        to.Iterations = from.Iterations ?? to.Iterations;
        to.ParallelBatchSize = from.ParallelBatchSize ?? to.ParallelBatchSize;
        to.ParallelMaxThreads = from.ParallelMaxThreads ?? to.ParallelMaxThreads;
        to.SelectedTestCode = from.SelectedTestCode;
        to.CampaignID = from.CampaignID;
        to.RepetitionNo = from.RepetitionNo;
        to.IsWarmup = from.IsWarmup;
        to.RunBlock = from.RunBlock;
        to.OrderPosition = from.OrderPosition;
        to.WorkScale = from.WorkScale;
        to.PassesOverride = from.PassesOverride;
        to.WarmUpPassesOverride = from.WarmUpPassesOverride;
        to.RunBudgetSec = from.RunBudgetSec;
    }

    private static void ResetRequestState(PerfBenchmarkFilter row)
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

    /// <summary>Light context for every read: engine, instance, server fields, cached hardware, defaults and registry notice.
    /// No WMI and no snapshot reads (SPEC §2.1 F4).</summary>
    private void ApplyContext(PerfBenchmarkFilter row)
    {
        if (row == null) return;
        row.CurrentDatabase = PerfDatabaseEngines.Detect();
        row.CurrentInstance = PerfRuntimeInfo.InstanceName;
        ApplyServerFields(row);
        ApplyHardware(row, detect: false);
        row.LastRequestStatus ??= PerfBenchmarkRequestStatuses.Idle;
        row.LastRequestMessage ??= "Ready to run benchmarks.";
        ApplyLoadErrorsNotice(row);
    }

    private static void ApplyServerFields(PerfBenchmarkFilter row)
    {
        row.ServerAppStartUtc = PerfRuntimeInfo.AppDomainStartUtc;
        row.ServerDllSha256 = PerfRuntimeInfo.DllSha256;
        row.ServerMethodologyVersion = PerfMethodology.Version;
    }

    private static void ApplyHardware(PerfBenchmarkFilter row, bool detect)
    {
        PerfHardwareRecommendation rec;
        if (detect)
        {
            rec = PerfHardwareInspector.Detect();
        }
        else if (!PerfHardwareInspector.TryGetCached(out rec))
        {
            rec = PerfHardwareInspector.CampaignDefaults();
            row.DetectedCpuCores ??= rec.CpuCores;
            row.RecommendedRecords = rec.RecommendedRecords;
            row.RecommendedIterations = rec.RecommendedIterations;
            row.RecommendedBatchSize = rec.RecommendedBatchSize;
            row.RecommendedMaxThreads = rec.RecommendedMaxThreads;
            row.HardwareRecommendationSummary ??= rec.Summary;
            ApplyDefaults(row);
            return;
        }

        row.DetectedCpuCores = rec.CpuCores;
        row.DetectedMemoryGb = rec.MemoryGb;
        row.RecommendedRecords = rec.RecommendedRecords;
        row.RecommendedIterations = rec.RecommendedIterations;
        row.RecommendedBatchSize = rec.RecommendedBatchSize;
        row.RecommendedMaxThreads = rec.RecommendedMaxThreads;
        row.HardwareRecommendationSummary = Trim(rec.Summary, 512);
        ApplyDefaults(row);
    }

    private static void ApplyDefaults(PerfBenchmarkFilter row)
    {
        row.NumberOfRecords ??= PerfCampaignConstants.CoreRecords;
        row.Iterations ??= PerfCampaignConstants.CoreMeasuredPasses;
        row.ParallelBatchSize ??= PerfCampaignConstants.CoreChunkSize;
        row.ParallelMaxThreads ??= PerfCampaignConstants.CoreParallelWorkers;
    }

    /// <summary>Snapshot and coverage status: only in refreshStatus, comparisonResults() and MarkRequestCompleted (F4).</summary>
    private static void ApplySnapshotStatus(PerfBenchmarkFilter row)
    {
        try
        {
            row.SnapshotStatus = Trim(PerfSnapshotService.GetSnapshotStatus(), 512);
            row.PendingAnalysisStatus = Trim(PerfSnapshotService.GetPendingAnalysisStatus(), 2048);
        }
        catch (Exception ex)
        {
            row.SnapshotStatus = Trim("Snapshot status unavailable: " + ex.Message, 512);
        }
    }

    /// <summary>Fills the SelectedTestCode list from the registry (never throws; SPEC §3.1, review-api M4).</summary>
    private void ConfigureTestCodeList()
    {
        try
        {
            var all = PerfScenarioRegistry.All;
            var values = all.Select(d => d.TestCode).ToArray();
            var labels = all.Select(d => d.TestCode + " – " + d.DisplayName).ToArray();
            PXStringListAttribute.SetList<PerfBenchmarkFilter.selectedTestCode>(Filter.Cache, null, values, labels);
        }
        catch (Exception ex)
        {
            PXTrace.WriteWarning("PerfDBBenchmark: the test list could not be built: " + ex.Message);
        }
    }

    /// <summary>Shows PerfScenarioRegistry.LoadErrors in LastRequestMessage (in memory; stripped before saving).</summary>
    private static void ApplyLoadErrorsNotice(PerfBenchmarkFilter row)
    {
        if (row == null) return;
        StripLoadErrorsNotice(row);
        IReadOnlyList<string> errors;
        try
        {
            errors = PerfScenarioRegistry.LoadErrors;
        }
        catch (Exception ex)
        {
            errors = new[] { ex.Message };
        }

        if (errors == null || errors.Count == 0) return;
        var notice = LoadErrorsPrefix + errors.Count.ToString(CultureInfo.InvariantCulture) + "; " + string.Join(" | ", errors) ;
        notice = Trim(notice, 600) + LoadErrorsSeparator;
        row.LastRequestMessage = Trim(notice + (row.LastRequestMessage ?? string.Empty), 1024);
    }

    private static void StripLoadErrorsNotice(PerfBenchmarkFilter row)
    {
        var message = row?.LastRequestMessage;
        if (string.IsNullOrEmpty(message) || !message.StartsWith(LoadErrorsPrefix, StringComparison.Ordinal)) return;
        var cut = message.IndexOf(LoadErrorsSeparator, StringComparison.Ordinal);
        row.LastRequestMessage = cut >= 0 ? message.Substring(cut + LoadErrorsSeparator.Length) : string.Empty;
    }

    #endregion

    #region Comparison (in-app, indicative; SPEC §3.4)

    private List<PerfComparisonResult> BuildComparisonRows()
    {
        var rows = new List<PerfComparisonResult>();
        var dllByLine = new Dictionary<int, string>();
        PerfSnapshotEnvelope[] snapshots;
        try
        {
            snapshots = PerfSnapshotService.LoadAllSnapshots()
                .Where(e => e.SchemaVersion >= PerfSnapshotService.SchemaVersion)
                .GroupBy(e => e.InstanceName, StringComparer.OrdinalIgnoreCase)
                .Select(g => g.OrderByDescending(e => e.CapturedAtUtc).First())
                .ToArray();
        }
        catch
        {
            snapshots = Array.Empty<PerfSnapshotEnvelope>();
        }

        var lineNbr = 1;
        foreach (var envelope in snapshots)
        {
            var engine = PerfEnvironmentInspector.NormalizeEngine(envelope.DatabaseType);
            var latestPerTest = (envelope.Results ?? new List<PerfSnapshotItem>())
                .Where(i => string.Equals(i.Status, PerfRunStatuses.Completed, StringComparison.OrdinalIgnoreCase) && !i.IsWarmup)
                .Select(i => (Item: i, Ok: PerfScenarioRegistry.TryGet(i.TestCode, out var d), Descriptor: d))
                .Where(x => x.Ok && !x.Descriptor.ExcludeFromComparison)
                .GroupBy(x => x.Descriptor.TestCode, StringComparer.OrdinalIgnoreCase)
                .Select(g => g.OrderByDescending(x => x.Item.ResultID).ThenByDescending(x => x.Item.CapturedAtUtc).First());

            foreach (var x in latestPerTest)
            {
                var item = x.Item;
                var d = x.Descriptor;
                rows.Add(new PerfComparisonResult
                {
                    LineNbr = lineNbr++,
                    TestCode = d.TestCode,
                    TestDisplayName = d.DisplayName,
                    TestCategory = d.Category,
                    ExecutionMode = d.ExecutionMode,
                    DatabaseType = engine != PerfDatabaseEngines.Unknown ? engine : envelope.DatabaseType,
                    InstanceName = envelope.InstanceName,
                    ElapsedMs = item.ElapsedMs,
                    RecordsCount = item.RecordsCount,
                    Iterations = item.Iterations,
                    BatchSize = item.BatchSize,
                    MaxThreads = item.MaxThreads,
                    CapturedAtUtc = item.CapturedAtUtc,
                    Notes = Trim(item.Notes, 1024),
                    Family = d.Family,
                    ShortLabel = d.ShortLabel,
                    SortOrder = d.SortOrder,
                    UserCount = item.UserCount > 0 ? item.UserCount : d.Users,
                    HeadlineValue = item.HeadlineValue,
                    HeadlineUnit = item.HeadlineUnit ?? d.HeadlineUnit,
                    HigherIsBetter = item.HigherIsBetter || d.HigherIsBetter,
                    P95Ms = item.P95Ms,
                    OpsPerSec = item.OpsPerSec,
                    ErrorCount = item.ErrorCount,
                    Status = item.Status,
                    ParamsHash = item.ParamsHash,
                    IsComparable = false,
                    IsWinner = false
                });

                // Remember the DLL hash for the verdict gate.
                dllByLine[rows[rows.Count - 1].LineNbr ?? 0] = item.DllSha256 ?? envelope.DllSha256;
            }
        }

        foreach (var group in rows.GroupBy(r => r.TestCode, StringComparer.OrdinalIgnoreCase))
        {
            ApplyVerdict(group.ToList(), dllByLine);
        }

        return rows
            .OrderBy(r => r.SortOrder ?? int.MaxValue)
            .ThenBy(r => PerfChartBuilder.GetDatabaseColorIndex(r.DatabaseType))
            .ThenBy(r => r.InstanceName, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    /// <summary>Indicative verdict: only when every instance has the same ParamsHash and DllSha256 and a Completed latest
    /// row; 5% band; labels "≈ tie", "x.xx× slower", "fastest (indicative)". The README never uses these labels.</summary>
    private static void ApplyVerdict(List<PerfComparisonResult> group, IReadOnlyDictionary<int, string> dllByLine)
    {
        string reason = null;
        if (group.Count < 2)
        {
            reason = "n/a: only one instance";
        }
        else if (group.Select(r => r.ParamsHash ?? string.Empty).Distinct(StringComparer.Ordinal).Count() != 1 ||
                 string.IsNullOrEmpty(group[0].ParamsHash) ||
                 group.Select(r => dllByLine.TryGetValue(r.LineNbr ?? 0, out var h) ? h ?? string.Empty : string.Empty).Distinct(StringComparer.OrdinalIgnoreCase).Count() != 1)
        {
            reason = "n/a: parameters differ";
        }
        else if (group.Any(r => !string.Equals(r.Status, PerfRunStatuses.Completed, StringComparison.OrdinalIgnoreCase) || !(r.HeadlineValue > 0m)))
        {
            reason = "n/a: parameters differ";
        }

        if (reason != null)
        {
            foreach (var r in group)
            {
                r.IsComparable = false;
                r.Verdict = reason;
                r.RelToFastest = null;
                r.IsWinner = false;
                r.WinnerDisplay = reason;
            }

            return;
        }

        // Time per unit: lower is better (OpsPerMin is inverted).
        decimal TimePerUnit(PerfComparisonResult r) => r.HigherIsBetter == true ? 1m / r.HeadlineValue.Value : r.HeadlineValue.Value;
        var fastest = group.Min(TimePerUnit);
        var ties = group.Count(r => TimePerUnit(r) / fastest <= 1m + VerdictBand);
        var leaders = group.Where(r => TimePerUnit(r) == fastest).Select(r => r.DatabaseType).ToArray();

        foreach (var r in group)
        {
            var rel = Math.Round(TimePerUnit(r) / fastest, 4, MidpointRounding.AwayFromZero);
            r.IsComparable = true;
            r.RelToFastest = rel;
            r.IsWinner = TimePerUnit(r) == fastest;
            if (rel <= 1m + VerdictBand)
            {
                r.Verdict = ties > 1 ? "≈ tie" : "fastest (indicative)";
            }
            else
            {
                r.Verdict = rel.ToString("0.00", CultureInfo.InvariantCulture) + "× slower";
            }

            r.WinnerDisplay = ties > 1
                ? "≈ tie (indicative)"
                : string.Join(", ", leaders) + " is fastest (indicative)";
        }
    }

    #endregion

    #region Helpers

    private static string Trim(string message, int max)
    {
        if (string.IsNullOrWhiteSpace(message))
        {
            return string.Empty;
        }

        return message.Length <= max ? message : message.Substring(0, max);
    }

    private static int ToIntMs(TimeSpan elapsed) =>
        elapsed.TotalMilliseconds >= int.MaxValue ? int.MaxValue : (int)Math.Round(elapsed.TotalMilliseconds, MidpointRounding.AwayFromZero);

    private static string FormatElapsed(TimeSpan elapsed)
    {
        if (elapsed.TotalSeconds >= 60)
        {
            return elapsed.ToString(@"hh\:mm\:ss", CultureInfo.InvariantCulture);
        }

        return elapsed.TotalSeconds.ToString("0.##", CultureInfo.InvariantCulture) + " sec";
    }

    private static DateTime GetUtcStorageTimestamp()
    {
        return DateTime.SpecifyKind(DateTime.UtcNow, DateTimeKind.Unspecified);
    }

    private static string SafeUserName()
    {
        try
        {
#pragma warning disable CS0618 // PXAccess.GetUserName is obsolete in 26 R2 but still the simplest accessor here.
            return PXAccess.GetUserName();
#pragma warning restore CS0618
        }
        catch
        {
            return null;
        }
    }

    #endregion
}
