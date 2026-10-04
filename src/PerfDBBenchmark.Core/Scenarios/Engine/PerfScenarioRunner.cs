using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.ExceptionServices;
using System.Threading;
using PX.Data;
using PerfDBBenchmark.Core.Support;

namespace PerfDBBenchmark.Core.Scenarios;

/// <summary>
/// Runs one benchmark test (SPEC §4.2–§4.5). Only IPerfScenario.ExecuteOperation is inside a timer; every other phase is
/// timed separately for ResultJson.phasesMs. Never throws for Invalid or Capped runs; an exception escaping CreatePlan,
/// Prepare, CreateWorkerState, BeforePass, AfterPass, Verify or the engine itself propagates (the run is Failed and writes
/// no result row). Cleanup always runs once Prepare was attempted.
/// </summary>
public static class PerfScenarioRunner
{
    private static readonly ConditionalWeakTable<PerfRunMetrics, PerfRunDetail> Details = new ConditionalWeakTable<PerfRunMetrics, PerfRunDetail>();

    private static readonly Lazy<FieldInfo> ParallelThreadsCountField = new Lazy<FieldInfo>(() =>
        typeof(PXParallelProcessingOptions).GetField("ParallelThreadsCount", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public));

    public static PerfRunMetrics Run(PerfRunRequest request)
    {
        if (request == null) throw new ArgumentNullException(nameof(request));

        var descriptor = PerfScenarioRegistry.Get(request.TestCode);
        var scenario = PerfScenarioRegistry.Create(request.TestCode);
        var plan = scenario.CreatePlan(request) ?? throw new PXException("CreatePlan returned no plan for " + descriptor.TestCode + ".");

        var engine = new PerfRunEngine(request, descriptor, scenario, plan);
        var metrics = engine.Execute();
        Details.Add(metrics, engine.Detail);
        return metrics;
    }

    /// <summary>The engine-side details of a run (ResultJson sections); available for metrics returned by Run.</summary>
    internal static bool TryGetDetail(PerfRunMetrics metrics, out PerfRunDetail detail)
    {
        detail = null;
        return metrics != null && Details.TryGetValue(metrics, out detail);
    }

    /// <summary>Sets the internal PXParallelProcessingOptions.ParallelThreadsCount; throws when the field does not exist
    /// (SPEC §2.1 F7: a silent failure would cap concurrency at the web.config value).</summary>
    internal static void SetParallelThreadsOrThrow(PXParallelProcessingOptions options, int threads)
    {
        if (options == null) throw new ArgumentNullException(nameof(options));
        var field = ParallelThreadsCountField.Value
                    ?? throw new InvalidOperationException("PXParallelProcessingOptions.ParallelThreadsCount was not found: the engine cannot guarantee the requested number of parallel workers.");
        field.SetValue(options, (int?)Math.Max(1, threads));
    }

    /// <summary>Untimed helper behind PerfScenarioContext.RunUntimedParallel (SPEC §4.3): 'slots' platform batches, slot s
    /// processes items i with i mod slots = s. No gate, never timed. Exceptions are collected and the first is rethrown.</summary>
    internal static void RunUntimedParallel(PXGraph factoryGraph, int slots, int itemCount, Action<int, int> body)
    {
        if (body == null) throw new ArgumentNullException(nameof(body));
        if (itemCount <= 0) return;
        slots = Math.Max(1, Math.Min(slots, itemCount));

        if (slots == 1 || PX.Common.WebConfig.ParallelProcessingDisabled)
        {
            for (var i = 0; i < itemCount; i++) body(i % slots, i);
            return;
        }

        var items = new List<PerfBenchmarkTask>(slots);
        for (var s = 0; s < slots; s++)
        {
            items.Add(new PerfBenchmarkTask { TaskID = s + 1, Selected = true, TestCode = "UNTIMED", StartIndex = s });
        }

        var options = new PXParallelProcessingOptions { IsEnabled = true, AutoBatchSize = false, BatchSize = 1 };
        SetParallelThreadsOrThrow(options, slots);

        var errors = new ConcurrentQueue<Exception>();
        var hadErrors = PXProcessing.ProcessItemsParallel<PXGraph, PerfBenchmarkTask>(
            items,
            (graph, task, token) =>
            {
                var slot = task.StartIndex ?? 0;
                for (var i = slot; i < itemCount; i += slots)
                {
                    try
                    {
                        body(slot, i);
                    }
                    catch (Exception ex)
                    {
                        errors.Enqueue(ex);
                    }
                }
            },
            () => factoryGraph,
            options,
            PerfNoOpThrottler.Instance,
            CancellationToken.None);

        if (errors.TryPeek(out var first)) ExceptionDispatchInfo.Capture(first).Throw();
        if (hadErrors) throw new PXException("An untimed parallel batch failed.");
    }
}

/// <summary>Timings and counts of one pass (measured, warm-up, or the per-worker warm-up operations).</summary>
internal sealed class PerfPassRecord
{
    public int Pass;
    public double WallMs;
    public double WallInclResetsMs;
    public int Ops;
    public int OkOps;
    public int Errors;
    public double P50Ms;
    public double P95Ms;
    public double MaxMs;
    public double? SteadyOpsPerMin;
    public string Digest;
    public bool Interrupted;
    public bool GateOpened = true;
    public int ActivePeak;
    public int InFlightPeak;
    public double GateWaitMs;
    public bool LowOverlap;
    public bool Gated;
}

/// <summary>Everything the engine knows about a run beyond PerfRunMetrics; PerfResultWriter turns it into ResultJson.</summary>
internal sealed class PerfRunDetail
{
    public PerfRunPlan Plan;
    public PerfTestDescriptor Descriptor;
    public string ParamsJson;
    public string ParamsHash;
    public int RunBudgetSec;
    public string RunBudgetSource;

    public double PrepareMs;
    public double CreateWorkersMs;
    public double WarmupOpsMs;
    public double WarmupPassesMs;
    public double MeasuredMs;
    public double VerifyMs;
    public double CleanupMs;
    public double TotalMs;

    public readonly List<PerfPassRecord> MeasuredPasses = new List<PerfPassRecord>();
    public readonly List<PerfPassRecord> WarmupPasses = new List<PerfPassRecord>();
    public PerfPassRecord WarmupOps;

    public int WorkersRequested;
    public int WorkersObservedPeak;
    public int OpsInFlightPeak;
    public bool LowOverlap;
    public int DistinctThreads;
    public readonly List<int> PerWorkerOkOps = new List<int>();
    public double GateWaitMs;
    public int ThreadPoolSizeConfigured;

    public int ErrorCount;
    public int WarmupErrorCount;
    /// <summary>Failed operations (warm-up included) caused by a deadlock, lock violation, time-out or serialization failure.</summary>
    public int ContentionErrorCount;
    /// <summary>Every other failed operation (validation, PXRowPersistingException, …): ErrorCount − ContentionErrorCount.</summary>
    public int NonContentionErrorCount;
    /// <summary>
    /// Of NonContentionErrorCount: operations that met a contention exception before they failed for another reason
    /// (PerfExceptionCounter.ClassifyFailure, masked). Diagnostic only.
    /// </summary>
    public int NonContentionWithContentionSeenCount;
    public bool CountersEnabled;
    public readonly List<string> ErrorSamples = new List<string>();
    public readonly List<string> FailedOps = new List<string>();
    public int FailedOpsTotal;

    public string CappedKind;
    public int? CappedAtPass;
    public int? CappedAtOpIndex;
    public double? CappedLimitMs;
    public bool Aborted;
    public bool InvariantsOk = true;
    public bool InvariantsApplied = true;

    public readonly SortedDictionary<string, string> Parity = new SortedDictionary<string, string>(StringComparer.Ordinal);
    public readonly SortedDictionary<string, string> InvariantChecks = new SortedDictionary<string, string>(StringComparer.Ordinal);
    public readonly SortedDictionary<string, string> Notes = new SortedDictionary<string, string>(StringComparer.Ordinal);
    public readonly SortedDictionary<string, Dictionary<string, object>> SubPhases = new SortedDictionary<string, Dictionary<string, object>>(StringComparer.Ordinal);
    public readonly List<string> AdditionalReasons = new List<string>();
    public int OpsPerPass;
    public int MeasuredPassesPlanned;
}

/// <summary>Per-run engine state (one instance per run; never shared).</summary>
internal sealed class PerfRunEngine
{
    private const int MaxFailedOpsKept = 200;
    private const int MaxSamples = 5;
    private const int MaxSampleLength = 400;

    private static readonly bool CountersEnabled = PerfExceptionCounter.Enabled;

    private readonly PerfRunRequest _request;
    private readonly PerfTestDescriptor _d;
    private readonly IPerfScenario _scenario;
    private readonly PerfRunPlan _plan;
    private readonly int _users;
    private readonly PerfRunMetrics _metrics = new PerfRunMetrics();
    private readonly ConcurrentDictionary<int, byte> _threads = new ConcurrentDictionary<int, byte>();
    private readonly object _interruptSync = new object();

    private PerfScenarioContext _ctx;
    private WorkerPass[] _workerPass;
    private List<PerfOpInfo>[] _opsByWorker;
    private PerfExceptionCounter.RunCounters _counters;

    private int _active;
    private int _passActivePeak;
    private int _inFlight;
    private int _passInFlightPeak;
    private int _warmupErrors;
    private int _contentionErrors;
    private int _nonContentionErrors;
    private int _nonContentionWithContentionSeen;
    private volatile bool _engineStop;

    private string _interruptKind;
    private int? _interruptPass;
    private int? _interruptOpIndex;
    private double? _interruptLimitMs;

    private string _gateFailure;      // WorkersNotStarted(k/W)
    private string _crashReason;      // WorkerCrashed / ItemsShortfall:...
    private bool _measuredReached;

    public PerfRunEngine(PerfRunRequest request, PerfTestDescriptor descriptor, IPerfScenario scenario, PerfRunPlan plan)
    {
        _request = request;
        _d = descriptor;
        _scenario = scenario;
        _plan = plan;
        _users = Math.Max(1, plan.Users);
        Detail = new PerfRunDetail
        {
            Plan = plan,
            Descriptor = descriptor,
            WorkersRequested = _users,
            CountersEnabled = CountersEnabled,
            ThreadPoolSizeConfigured = PerfRuntimeInfo.ConfiguredThreadPoolSize,
            OpsPerPass = Math.Max(0, plan.OpsPerPass),
            MeasuredPassesPlanned = Math.Max(0, plan.Passes)
        };
    }

    public PerfRunDetail Detail { get; }

    private sealed class WorkerPass
    {
        public readonly List<double> Latencies = new List<double>();
        public readonly List<long> OkEndTicks = new List<long>();
        public readonly List<string> FailedOps = new List<string>();
        public int FailedOpsDropped;
        public int Ops;
        public int Ok;
        public int Errors;
        public int Assigned;
        public double SumMs;
        public long FirstStart;
        public long LastEnd;

        public void ResetPass(int assigned)
        {
            Latencies.Clear();
            OkEndTicks.Clear();
            Ops = 0;
            Ok = 0;
            Errors = 0;
            SumMs = 0;
            FirstStart = 0;
            LastEnd = 0;
            Assigned = assigned;
        }
    }

    public PerfRunMetrics Execute()
    {
        var total = Stopwatch.StartNew();
        var m = _metrics;
        m.UserCount = _users;

        m.ParamsJson = PerfJson.Canonical(_plan.Params ?? new Dictionary<string, object>(StringComparer.Ordinal));
        m.ParamsHash = PerfJson.Hash(_plan.Params ?? new Dictionary<string, object>(StringComparer.Ordinal));
        Detail.ParamsJson = m.ParamsJson;
        Detail.ParamsHash = m.ParamsHash;
        Detail.RunBudgetSec = (int)Math.Round(_plan.RunBudget.TotalSeconds);
        Detail.RunBudgetSource = _request.RunBudgetSec is int b && b > 0 ? "control" : "default";

        ValidatePlan();

        // Pre-checks (SPEC §4.2): nothing runs, a result row is still written.
        if (_users > 1 && PX.Common.WebConfig.ParallelProcessingDisabled)
        {
            return FinishPrecheckInvalid(total, PerfInvalidReasons.ParallelDisabled);
        }

        var pool = PerfRuntimeInfo.ConfiguredThreadPoolSize;
        if (_users > 1 && pool < _users + 1)
        {
            return FinishPrecheckInvalid(total, PerfInvalidReasons.WorkersNotStarted + "(threadPool=" +
                                                pool.ToString(CultureInfo.InvariantCulture) + "<" +
                                                (_users + 1).ToString(CultureInfo.InvariantCulture) + ")");
        }

        BuildAssignment();

        _ctx = new PerfScenarioContext(_request, _d, PXGraph.CreateInstance<PerfWorkerGraph>()) { Plan = _plan };
        var mainGraph = _ctx.MainGraph;
        _ctx.UntimedParallelRunner = (slots, count, body) => PerfScenarioRunner.RunUntimedParallel(mainGraph, slots, count, body);

        ExceptionDispatchInfo failure = null;
        var cleanupFailed = false;
        var runChecksum = new PerfChecksum();
        var runOrdered = new PerfOrderedChecksum();
        var cpuStart = TimeSpan.Zero;
        var cpuMeasured = false;
        var sw = new Stopwatch();

        try
        {
            // [Prepare] untimed
            sw.Restart();
            Q();
            _scenario.Prepare(_ctx);
            Detail.PrepareMs = m.PrepareMs = Ms(sw);

            // [CreateWorkers] untimed, coordinating thread
            sw.Restart();
            _workerPass = new WorkerPass[_users];
            for (var w = 0; w < _users; w++)
            {
                var worker = new PerfWorkerContext(_ctx, w, PXGraph.CreateInstance<PerfWorkerGraph>());
                _ctx.WorkersInternal.Add(worker);
                _workerPass[w] = new WorkerPass();
                _scenario.CreateWorkerState(worker);
            }

            Detail.CreateWorkersMs = Ms(sw);

            PerfRunControl.StartBudgetClock(_plan.RunBudget);

            // [Warm-up ops] per worker, before the gate, one ungated parallel call (W > 1)
            if (_plan.WarmUpOpsPerWorker > 0)
            {
                sw.Restart();
                if (PerfRunControl.ShouldStop)
                {
                    RecordInterruption(PerfRunControl.StopReason, PerfOpInfo.WarmUpOpsPass, 0, null);
                }
                else
                {
                    NewPassChecksums();
                    var record = RunWarmUpOps();
                    record.Digest = PassDigest();
                    _ctx.PassDigestsInternal[PerfOpInfo.WarmUpOpsPass] = record.Digest;
                    Detail.WarmupOps = record;
                    Q();
                    _scenario.AfterPass(_ctx, PerfOpInfo.WarmUpOpsPass);
                }

                Detail.WarmupOpsMs = m.WarmupMs = Ms(sw);
            }

            // Passes: warm-up passes first (negative numbers), then measured passes 0..Passes-1
            for (var pass = -_plan.WarmUpPasses; pass < _plan.Passes; pass++)
            {
                if (_engineStop) break;
                if (PerfRunControl.ShouldStop)
                {
                    RecordInterruption(PerfRunControl.StopReason, pass, 0, null);
                    break;
                }

                sw.Restart();
                Q();
                _scenario.BeforePass(_ctx, pass);
                foreach (var worker in _ctx.WorkersInternal) worker.RefreshTimeStamps();
                NewPassChecksums();

                if (pass == 0)
                {
                    _measuredReached = true;
                    foreach (var worker in _ctx.WorkersInternal)
                    {
                        worker.RowsReturned = 0;
                        worker.OpLatenciesMs.Clear();
                        worker.OkOps = 0;
                    }

                    if (CountersEnabled) _counters = PerfExceptionCounter.Begin();
                    cpuStart = ProcessCpu();
                    cpuMeasured = true;
                }

                var record = RunPass(pass);
                record.Digest = PassDigest();
                _ctx.PassDigestsInternal[pass] = record.Digest;

                if (pass >= 0)
                {
                    foreach (var worker in _ctx.WorkersInternal) runChecksum.Merge(worker.Checksum);
                    runOrdered.Append(_ctx.WorkersInternal[0].OrderedChecksum);
                    Detail.MeasuredPasses.Add(record);
                }
                else
                {
                    Detail.WarmupPasses.Add(record);
                }

                Q();
                _scenario.AfterPass(_ctx, pass);   // also for an interrupted pass, so created documents are cleaned up

                if (pass >= 0) Detail.MeasuredMs += Ms(sw);
                else Detail.WarmupPassesMs += Ms(sw);
            }

            m.WarmupMs = Detail.WarmupOpsMs + Detail.WarmupPassesMs;

            if (_counters != null) PerfExceptionCounter.End(_counters);
            if (cpuMeasured) m.AppCpuMs = (ProcessCpu() - cpuStart).TotalMilliseconds;

            FillMetrics(runChecksum, runOrdered);

            // [Verify] untimed; counters are already in metrics (SPEC §4.5)
            sw.Restart();
            Q();
            _scenario.Verify(_ctx, m);
            Detail.VerifyMs = m.VerifyMs = Ms(sw);
        }
        catch (Exception ex)
        {
            failure = ExceptionDispatchInfo.Capture(ex);
        }
        finally
        {
            if (_counters != null) PerfExceptionCounter.End(_counters);
            PerfExceptionCounter.UnmarkThread();

            // [Cleanup] untimed, always (also after a failed Prepare)
            sw.Restart();
            try
            {
                Q();
                _scenario.Cleanup(_ctx);
            }
            catch (Exception ex)
            {
                cleanupFailed = true;
                Detail.Notes["cleanupError"] = Truncate(ex.GetType().Name + ": " + ex.Message, MaxSampleLength);
            }

            Detail.CleanupMs = m.CleanupMs = Ms(sw);
        }

        if (failure != null)
        {
            if (cleanupFailed && Detail.Notes.TryGetValue("cleanupError", out var ce))
            {
                PXTrace.WriteWarning("PerfDBBenchmark cleanup after a failed run also failed: " + ce);
            }

            failure.Throw();
        }

        Detail.TotalMs = m.TotalMs = Ms(total);
        CopyContextSections();
        ApplyStatus(cleanupFailed);
        return m;
    }

    private void ValidatePlan()
    {
        if (_plan.OpsPerPass < 0) throw new PXException("Invalid plan for " + _d.TestCode + ": OpsPerPass < 0.");
        if (_plan.Passes < 0) throw new PXException("Invalid plan for " + _d.TestCode + ": Passes < 0.");
        if (_plan.WarmUpPasses < 0) throw new PXException("Invalid plan for " + _d.TestCode + ": WarmUpPasses < 0.");
        if (_plan.WarmUpOpsPerWorker < 0) throw new PXException("Invalid plan for " + _d.TestCode + ": WarmUpOpsPerWorker < 0.");
        if (_d.OrderedChecksum && _users > 1) throw new PXException("Invalid plan for " + _d.TestCode + ": OrderedChecksum requires one user.");
    }

    private void BuildAssignment()
    {
        var n = Math.Max(0, _plan.OpsPerPass);
        var assign = _plan.AssignWorker ?? PerfDeterministic.ContiguousWorker;
        _opsByWorker = new List<PerfOpInfo>[_users];
        var perWorker = new List<int>[_users];
        for (var w = 0; w < _users; w++) perWorker[w] = new List<int>();
        for (var op = 0; op < n; op++)
        {
            var w = _users == 1 ? 0 : assign(op, n, _users);
            if (w < 0 || w >= _users)
            {
                throw new PXException("AssignWorker returned worker " + w.ToString(CultureInfo.InvariantCulture) + " for operation " +
                                      op.ToString(CultureInfo.InvariantCulture) + " of " + _d.TestCode + ".");
            }

            perWorker[w].Add(op);
        }

        for (var w = 0; w < _users; w++)
        {
            // Placeholder pass number; RunPass builds the PerfOpInfo per pass.
            _opsByWorker[w] = perWorker[w].Select((op, j) => new PerfOpInfo(0, op, j, w)).ToList();
        }
    }

    private PerfRunMetrics FinishPrecheckInvalid(Stopwatch total, string reason)
    {
        _metrics.Status = PerfRunStatuses.Invalid;
        _metrics.InvalidReason = Truncate(reason, 256);
        _metrics.HeadlineValue = double.NaN;
        _metrics.TotalMs = Detail.TotalMs = Ms(total);
        Detail.InvariantsApplied = false;
        Detail.Notes["precheck"] = "Nothing ran: " + reason;
        for (var w = 0; w < _users; w++) Detail.PerWorkerOkOps.Add(0);
        return _metrics;
    }

    private void Q()
    {
        _ctx.MainGraph.Clear(PXClearOption.ClearQueriesOnly);
    }

    private void NewPassChecksums()
    {
        foreach (var worker in _ctx.WorkersInternal)
        {
            worker.Checksum = new PerfChecksum();
            worker.OrderedChecksum = new PerfOrderedChecksum();
        }
    }

    private string PassDigest()
    {
        if (_d.OrderedChecksum) return _ctx.WorkersInternal[0].OrderedChecksum.ToString();
        var merged = new PerfChecksum();
        foreach (var worker in _ctx.WorkersInternal) merged.Merge(worker.Checksum);
        return merged.ToString();
    }

    // ------------------------------------------------------------------ passes

    private PerfPassRecord RunWarmUpOps()
    {
        var k = _plan.WarmUpOpsPerWorker;
        var opsByWorker = new List<PerfOpInfo>[_users];
        for (var w = 0; w < _users; w++)
        {
            opsByWorker[w] = new List<PerfOpInfo>(k);
            for (var j = 0; j < k; j++) opsByWorker[w].Add(new PerfOpInfo(PerfOpInfo.WarmUpOpsPass, j, j, w));
        }

        return ExecutePass(PerfOpInfo.WarmUpOpsPass, opsByWorker, gated: false);
    }

    private PerfPassRecord RunPass(int pass)
    {
        var opsByWorker = new List<PerfOpInfo>[_users];
        for (var w = 0; w < _users; w++)
        {
            opsByWorker[w] = _opsByWorker[w].Select(o => new PerfOpInfo(pass, o.OpIndex, o.WorkerOpIndex, w)).ToList();
        }

        return ExecutePass(pass, opsByWorker, gated: _users > 1);
    }

    private PerfPassRecord ExecutePass(int pass, List<PerfOpInfo>[] opsByWorker, bool gated)
    {
        for (var w = 0; w < _users; w++)
        {
            _workerPass[w].ResetPass(opsByWorker[w].Count);
            _ctx.WorkersInternal[w].PassEndTicks = 0;
        }
        Volatile.Write(ref _passActivePeak, 0);
        Volatile.Write(ref _passInFlightPeak, 0);
        Volatile.Write(ref _active, 0);
        Volatile.Write(ref _inFlight, 0);

        var record = new PerfPassRecord { Pass = pass, Gated = gated };

        if (_users == 1)
        {
            // W = 1: inline on the long-operation thread; pass time = Σ operation latencies.
            var worker = _ctx.WorkersInternal[0];
            WorkerLoop(worker, _workerPass[0], opsByWorker[0], gate: null);
            var wp = _workerPass[0];
            record.WallMs = wp.SumMs;
            record.WallInclResetsMs = wp.LastEnd > wp.FirstStart ? PerfStatistics.TicksToMs(wp.LastEnd - wp.FirstStart) : 0;
            record.ActivePeak = wp.Ops > 0 ? 1 : 0;
            record.InFlightPeak = Volatile.Read(ref _passInFlightPeak);
        }
        else
        {
            var gate = gated ? new PerfStartGate(_users, _plan.StartGateTimeout) : null;
            var processed = RunParallelBatch(pass, w => WorkerLoop(_ctx.WorkersInternal[w], _workerPass[w], opsByWorker[w], gate), out var hadErrors, out var batchError);

            if (hadErrors || batchError != null)
            {
                _crashReason ??= PerfInvalidReasons.WorkerCrashed;
                Detail.Notes["workerCrashed"] = Truncate("pass " + pass.ToString(CultureInfo.InvariantCulture) + ": " +
                                                         (batchError != null ? batchError.GetType().Name + ": " + batchError.Message : "a worker batch failed"), MaxSampleLength);
                _engineStop = true;
            }
            else if (processed != _users)
            {
                _crashReason ??= PerfInvalidReasons.ItemsShortfall + ":" + processed.ToString(CultureInfo.InvariantCulture) + "/" + _users.ToString(CultureInfo.InvariantCulture);
                _engineStop = true;
            }

            var endTicks = _ctx.WorkersInternal.Select(x => x.PassEndTicks).Where(t => t > 0).ToList();
            if (gate != null)
            {
                var opened = gate.OpenedAtTicks;
                record.GateOpened = opened > 0 && !gate.TimedOut;
                if (gate.TimedOut)
                {
                    _gateFailure ??= gate.Reason ?? (PerfInvalidReasons.WorkersNotStarted + "(" + gate.Arrived.ToString(CultureInfo.InvariantCulture) + "/" + _users.ToString(CultureInfo.InvariantCulture) + ")");
                    _engineStop = true;
                }

                if (opened > 0 && endTicks.Count > 0)
                {
                    var maxEnd = endTicks.Max();
                    record.WallMs = record.WallInclResetsMs = maxEnd > opened ? PerfStatistics.TicksToMs(maxEnd - opened) : 0;
                    var first = gate.FirstArrivalTicks;
                    record.GateWaitMs = first > 0 && opened > first ? PerfStatistics.TicksToMs(opened - first) : 0;

                    // steady-state throughput: operations finished while every worker with work was still active
                    var activeEnds = new List<long>();
                    for (var w = 0; w < _users; w++)
                    {
                        if (_workerPass[w].Assigned > 0 && _ctx.WorkersInternal[w].PassEndTicks > 0) activeEnds.Add(_ctx.WorkersInternal[w].PassEndTicks);
                    }

                    if (activeEnds.Count > 0)
                    {
                        var minEnd = activeEnds.Min();
                        var windowMs = minEnd > opened ? PerfStatistics.TicksToMs(minEnd - opened) : 0;
                        if (windowMs > 0)
                        {
                            var finished = _workerPass.Sum(x => x.OkEndTicks.Count(t => t <= minEnd));
                            record.SteadyOpsPerMin = finished / (windowMs / 60000.0);
                        }
                    }
                }
            }
            else
            {
                // ungated (per-worker warm-up operations): first operation start to last operation end
                var starts = _workerPass.Where(x => x.FirstStart > 0).Select(x => x.FirstStart).ToList();
                var ends = _workerPass.Where(x => x.LastEnd > 0).Select(x => x.LastEnd).ToList();
                if (starts.Count > 0 && ends.Count > 0)
                {
                    record.WallMs = record.WallInclResetsMs = PerfStatistics.TicksToMs(Math.Max(0, ends.Max() - starts.Min()));
                }
            }

            record.ActivePeak = Volatile.Read(ref _passActivePeak);
            record.InFlightPeak = Volatile.Read(ref _passInFlightPeak);
            if (gated && _workerPass.All(x => x.Ops >= 3) && record.InFlightPeak < _users)
            {
                record.LowOverlap = true;
            }
        }

        var latencies = new List<double>();
        foreach (var wp in _workerPass)
        {
            record.Ops += wp.Ops;
            record.OkOps += wp.Ok;
            record.Errors += wp.Errors;
            latencies.AddRange(wp.Latencies);
        }

        latencies.Sort();
        record.P50Ms = PerfStatistics.Percentile(latencies, 50);
        record.P95Ms = PerfStatistics.Percentile(latencies, 95);
        record.MaxMs = latencies.Count > 0 ? latencies[latencies.Count - 1] : 0;
        record.Interrupted = _workerPass.Any(x => x.Ops < x.Assigned);

        if (pass >= 0)
        {
            for (var w = 0; w < _users; w++)
            {
                var worker = _ctx.WorkersInternal[w];
                worker.OpLatenciesMs.AddRange(_workerPass[w].Latencies);
                worker.OkOps += _workerPass[w].Ok;
            }
        }

        return record;
    }

    /// <summary>One ProcessItemsParallel call with exactly W items, BatchSize 1, ParallelThreadsCount = W, factory = MainGraph
    /// (ignored by the workers) and the NoOp throttler (SPEC §4.3). Returns the number of items whose action started.</summary>
    private int RunParallelBatch(int pass, Action<int> perWorker, out bool hadErrors, out Exception batchError)
    {
        var items = new List<PerfBenchmarkTask>(_users);
        for (var w = 0; w < _users; w++)
        {
            items.Add(new PerfBenchmarkTask { TaskID = w + 1, Selected = true, TestCode = _d.TestCode, Iteration = pass, StartIndex = w });
        }

        var options = new PXParallelProcessingOptions { IsEnabled = true, AutoBatchSize = false, BatchSize = 1 };
        PerfScenarioRunner.SetParallelThreadsOrThrow(options, _users);

        var processed = 0;
        var mainGraph = _ctx.MainGraph;
        batchError = null;
        try
        {
            hadErrors = PXProcessing.ProcessItemsParallel<PXGraph, PerfBenchmarkTask>(
                items,
                (graph, task, token) =>
                {
                    Interlocked.Increment(ref processed);
                    perWorker(task.StartIndex ?? 0);   // the graph argument is ignored: each worker uses its own registered graphs
                },
                () => mainGraph,
                options,
                PerfNoOpThrottler.Instance,
                CancellationToken.None);
        }
        catch (Exception ex)
        {
            hadErrors = true;
            batchError = ex;
        }

        return Volatile.Read(ref processed);
    }

    private void WorkerLoop(PerfWorkerContext worker, WorkerPass wp, List<PerfOpInfo> ops, PerfStartGate gate)
    {
        if (gate != null)
        {
            // Active from gate arrival to the last operation (SPEC §1.3.3).
            UpdateMax(ref _passActivePeak, Interlocked.Increment(ref _active));
            if (!gate.ArriveAndWait())
            {
                Interlocked.Decrement(ref _active);
                if (!gate.TimedOut)
                {
                    RecordInterruption(PerfRunControl.StopReason, ops.Count > 0 ? ops[0].Pass : 0, ops.Count > 0 ? ops[0].OpIndex : 0, null);
                }

                worker.PassEndTicks = Stopwatch.GetTimestamp();
                return;
            }
        }

        try
        {
            foreach (var op in ops)
            {
                if (_engineStop || (gate != null && gate.Aborted) || PerfRunControl.ShouldStop)
                {
                    if (!_engineStop && (gate == null || !gate.TimedOut))
                    {
                        RecordInterruption(PerfRunControl.StopReason, op.Pass, op.OpIndex, null);
                    }

                    break;
                }

                wp.Ops++;   // attempted (an exception in ClearQueryCaches or BeforeOperation is an operation error)
                if (_plan.ClearQueriesBeforeEachOp)
                {
                    try
                    {
                        worker.ClearQueryCaches();
                    }
                    catch (Exception ex)
                    {
                        RecordOpError(worker, wp, op, ex, PerfExceptionCounter.IsContention(ex));
                        continue;
                    }
                }

                try
                {
                    _scenario.BeforeOperation(worker, op);
                }
                catch (Exception ex)
                {
                    RecordOpError(worker, wp, op, ex, PerfExceptionCounter.IsContention(ex));
                    continue;
                }

                var measuring = !op.IsWarmUp;
                worker.IsMeasuring = measuring;
                if (measuring)
                {
                    _threads.TryAdd(Thread.CurrentThread.ManagedThreadId, 0);
                    if (_counters != null) PerfExceptionCounter.MarkThread(_counters);
                }

                UpdateMax(ref _passInFlightPeak, Interlocked.Increment(ref _inFlight));
                Exception error = null;

                PerfExceptionCounter.BeginOperation();
                var t0 = Stopwatch.GetTimestamp();
                try
                {
                    _scenario.ExecuteOperation(worker, op);
                }
                catch (Exception ex)
                {
                    error = ex;
                }

                var t1 = Stopwatch.GetTimestamp();
                var contentionSeen = PerfExceptionCounter.EndOperation();

                Interlocked.Decrement(ref _inFlight);
                PerfExceptionCounter.UnmarkThread();
                worker.IsMeasuring = false;

                var ms = PerfStatistics.TicksToMs(t1 - t0);
                if (wp.FirstStart == 0) wp.FirstStart = t0;
                wp.LastEnd = t1;
                wp.SumMs += ms;
                if (error == null)
                {
                    wp.Ok++;
                    wp.Latencies.Add(ms);
                    wp.OkEndTicks.Add(t1);
                }
                else
                {
                    var contention = PerfExceptionCounter.ClassifyFailure(error, contentionSeen, out var masked);
                    if (masked) Interlocked.Increment(ref _nonContentionWithContentionSeen);
                    RecordOpError(worker, wp, op, error, contention);
                }

                if (_plan.OperationCapMs > 0 && ms > _plan.OperationCapMs)
                {
                    RecordInterruption(PerfCappedKinds.OperationCap, op.Pass, op.OpIndex, _plan.OperationCapMs);
                    PerfRunControl.Stop(PerfCappedKinds.OperationCap);
                }
            }
        }
        finally
        {
            PerfExceptionCounter.UnmarkThread();
            PerfExceptionCounter.EndOperation();   // pool threads are reused: never leave the operation watch on
            worker.IsMeasuring = false;
            worker.PassEndTicks = Stopwatch.GetTimestamp();
            if (gate != null) Interlocked.Decrement(ref _active);
        }
    }

    /// <summary>
    /// Records one failed operation. contention = the failure was a deadlock, lock violation, time-out or serialization failure
    /// (PerfExceptionCounter.ClassifyFailure for ExecuteOperation, PerfExceptionCounter.IsContention for the untimed resets);
    /// every other failure means the operation itself is broken (SPEC §4.4 rule 7b).
    /// </summary>
    private void RecordOpError(PerfWorkerContext worker, WorkerPass wp, PerfOpInfo op, Exception ex, bool contention)
    {
        worker.Errors++;
        wp.Errors++;
        if (op.IsWarmUp) Interlocked.Increment(ref _warmupErrors);
        if (contention) Interlocked.Increment(ref _contentionErrors);
        else Interlocked.Increment(ref _nonContentionErrors);

        var id = op.Pass.ToString(CultureInfo.InvariantCulture) + ":" + worker.Index.ToString(CultureInfo.InvariantCulture) + ":" +
                 op.WorkerOpIndex.ToString(CultureInfo.InvariantCulture);
        if (wp.FailedOps.Count < MaxFailedOpsKept) wp.FailedOps.Add(id);
        else wp.FailedOpsDropped++;

        if (worker.ErrorSamples.Count < MaxSamples)
        {
            var inner = ex is TargetInvocationException tie && tie.InnerException != null ? tie.InnerException : ex;
            worker.ErrorSamples.Add(Truncate(id + " " + inner.GetType().Name + ": " + inner.Message, MaxSampleLength));
        }
    }

    private void RecordInterruption(string kind, int pass, int opIndex, double? limitMs)
    {
        if (string.IsNullOrEmpty(kind)) return;
        lock (_interruptSync)
        {
            if (_interruptKind != null) return;
            _interruptKind = kind;
            _interruptPass = pass;
            _interruptOpIndex = opIndex;
            _interruptLimitMs = limitMs;
        }
    }

    private static void UpdateMax(ref int target, int value)
    {
        int current;
        while (value > (current = Volatile.Read(ref target)))
        {
            if (Interlocked.CompareExchange(ref target, value, current) == current) return;
        }
    }

    // ------------------------------------------------------------------ metrics and status

    private void FillMetrics(PerfChecksum runChecksum, PerfOrderedChecksum runOrdered)
    {
        var m = _metrics;
        var workers = _ctx.WorkersInternal;

        m.ErrorCount = workers.Sum(w => w.Errors);
        Detail.ErrorCount = m.ErrorCount;
        Detail.WarmupErrorCount = Volatile.Read(ref _warmupErrors);
        Detail.ContentionErrorCount = Volatile.Read(ref _contentionErrors);
        Detail.NonContentionErrorCount = Volatile.Read(ref _nonContentionErrors);
        Detail.NonContentionWithContentionSeenCount = Volatile.Read(ref _nonContentionWithContentionSeen);
        if (_counters != null)
        {
            m.DeadlockCount = Volatile.Read(ref _counters.Deadlocks);
            m.TimeoutCount = Volatile.Read(ref _counters.Timeouts);
            m.LockViolationCount = Volatile.Read(ref _counters.LockViolations);
            m.RetryCount = Volatile.Read(ref _counters.Retries);
        }

        var measured = Detail.MeasuredPasses;
        if (_users == 1)
        {
            m.WorkersObservedPeak = measured.Count > 0 ? 1 : 0;
        }
        else
        {
            m.WorkersObservedPeak = measured.Count > 0 ? measured.Max(p => p.ActivePeak) : 0;
        }

        m.OpsInFlightPeak = measured.Count > 0 ? measured.Max(p => p.InFlightPeak) : 0;
        m.DistinctThreads = _threads.Count;
        Detail.WorkersObservedPeak = m.WorkersObservedPeak;
        Detail.OpsInFlightPeak = m.OpsInFlightPeak;
        Detail.DistinctThreads = m.DistinctThreads;
        Detail.LowOverlap = measured.Any(p => p.LowOverlap);
        Detail.GateWaitMs = measured.Count > 0 ? measured.Max(p => p.GateWaitMs) : 0;
        foreach (var w in workers) Detail.PerWorkerOkOps.Add(_measuredReached ? w.OkOps : 0);
        if (Detail.LowOverlap)
        {
            Detail.Notes["lowOverlap"] = "Every worker had at least 3 operations in a pass but at most " +
                                         m.OpsInFlightPeak.ToString(CultureInfo.InvariantCulture) + " of " +
                                         _users.ToString(CultureInfo.InvariantCulture) + " operations overlapped (information only).";
        }

        // Interruption (cooperative stop) => Capped or Aborted
        lock (_interruptSync)
        {
            if (_interruptKind == PerfCappedKinds.RunBudget || _interruptKind == PerfCappedKinds.OperationCap)
            {
                m.CappedKind = _interruptKind;
                Detail.CappedKind = _interruptKind;
                Detail.CappedAtPass = _interruptPass;
                Detail.CappedAtOpIndex = _interruptOpIndex;
                Detail.CappedLimitMs = _interruptKind == PerfCappedKinds.OperationCap
                    ? _interruptLimitMs ?? _plan.OperationCapMs
                    : _plan.RunBudget.TotalMilliseconds;
            }
            else if (_interruptKind == PerfRunControl.AbortedReason)
            {
                Detail.Aborted = true;
                Detail.Notes["aborted"] = "Stopped by " + (PerfRunControl.AbortRequestReason ?? "AbortBenchmark") +
                                          " at pass " + (_interruptPass ?? 0).ToString(CultureInfo.InvariantCulture) +
                                          ", operation " + (_interruptOpIndex ?? 0).ToString(CultureInfo.InvariantCulture) + ".";
            }
        }

        // Failed operations (warm-up included), in pass/worker/index order of recording per worker
        var failed = new List<string>();
        var dropped = 0;
        foreach (var wp in _workerPass)
        {
            failed.AddRange(wp.FailedOps);
            dropped += wp.FailedOpsDropped;
        }

        Detail.FailedOpsTotal = failed.Count + dropped;
        Detail.FailedOps.AddRange(failed);
        foreach (var w in workers)
        {
            foreach (var s in w.ErrorSamples)
            {
                if (Detail.ErrorSamples.Count < MaxSamples) Detail.ErrorSamples.Add(s);
            }
        }

        // Rows and checksum (Verify may override both)
        m.RowsReturned = _measuredReached ? workers.Sum(w => w.RowsReturned) : 0;
        if (_d.HeadlineKind == PerfHeadlineKinds.None)
        {
            m.Checksum = null;
        }
        else
        {
            m.Checksum = _d.OrderedChecksum ? runOrdered.ToString() : runChecksum.ToString();
        }

        // Timings (SPEC §1.3.4)
        foreach (var p in measured) m.PassWallMs.Add(p.WallMs);
        m.ElapsedMsPrecise = measured.Sum(p => p.WallMs);

        var pooled = new List<double>();
        foreach (var w in workers) pooled.AddRange(w.OpLatenciesMs);
        pooled.Sort();
        m.OpsCount = pooled.Count;
        m.P50Ms = pooled.Count > 0 ? PerfStatistics.Percentile(pooled, 50) : double.NaN;
        m.P95Ms = pooled.Count > 0 ? PerfStatistics.Percentile(pooled, 95) : double.NaN;
        m.P99Ms = pooled.Count >= 100 ? PerfStatistics.Percentile(pooled, 99) : (double?)null;
        m.MaxOpMs = pooled.Count > 0 ? pooled[pooled.Count - 1] : double.NaN;
        m.OpsPerSec = m.ElapsedMsPrecise > 0 ? m.OpsCount / (m.ElapsedMsPrecise / 1000.0) : double.NaN;

        var complete = measured.Where(p => !p.Interrupted).ToList();
        switch (_d.HeadlineKind)
        {
            case PerfHeadlineKinds.MedianOpMs:
                m.HeadlineValue = pooled.Count > 0 ? PerfStatistics.Percentile(pooled, 50) : double.NaN;
                break;
            case PerfHeadlineKinds.MedianPassMs:
                m.HeadlineValue = complete.Count > 0 && m.OpsCount > 0 ? PerfStatistics.Median(complete.Select(p => p.WallMs)) : double.NaN;
                break;
            case PerfHeadlineKinds.OpsPerMin:
                var rates = complete.Where(p => p.WallMs > 0).Select(p => p.OkOps / (p.WallMs / 60000.0)).ToList();
                m.HeadlineValue = rates.Count > 0 && m.OpsCount > 0 ? PerfStatistics.Median(rates) : double.NaN;
                break;
            default:
                m.HeadlineValue = double.NaN;
                break;
        }

        // Sub-phase timings recorded by scenarios inside ExecuteOperation (measured operations only)
        var phases = new Dictionary<string, List<double>>(StringComparer.Ordinal);
        foreach (var w in workers)
        {
            foreach (var kv in w.Phases)
            {
                if (!phases.TryGetValue(kv.Key, out var list)) phases[kv.Key] = list = new List<double>();
                list.AddRange(kv.Value);
            }
        }

        foreach (var kv in phases)
        {
            var values = kv.Value.OrderBy(x => x).ToList();
            Detail.SubPhases[kv.Key] = new Dictionary<string, object>(StringComparer.Ordinal)
            {
                ["n"] = values.Count,
                ["p50Ms"] = PerfStatistics.Percentile(values, 50),
                ["p95Ms"] = PerfStatistics.Percentile(values, 95)
            };
        }
    }

    private void CopyContextSections()
    {
        foreach (var kv in _ctx.Parity) Detail.Parity[kv.Key] = kv.Value;
        foreach (var kv in _ctx.InvariantChecks) Detail.InvariantChecks[kv.Key] = kv.Value;
        foreach (var kv in _ctx.Notes)
        {
            if (!Detail.Notes.ContainsKey(kv.Key)) Detail.Notes[kv.Key] = kv.Value;
        }

        if (!string.IsNullOrWhiteSpace(_metrics.Notes) && !Detail.Notes.ContainsKey("scenario"))
        {
            Detail.Notes["scenario"] = _metrics.Notes;
        }

        Detail.InvariantsOk = _ctx.InvariantsOk;
    }

    /// <summary>
    /// Status rules, first match wins; further reasons go to notes.additionalReasons (SPEC §4.4, plus rules 7b NonContentionErrors
    /// and 7c NoSuccessfulOps, PerfEngineInvalidReasons).
    /// </summary>
    private void ApplyStatus(bool cleanupFailed)
    {
        var m = _metrics;
        var reasons = new List<(string Status, string Reason)>();

        if (_gateFailure != null) reasons.Add((PerfRunStatuses.Invalid, _gateFailure));
        if (_crashReason != null) reasons.Add((PerfRunStatuses.Invalid, _crashReason));
        if (Detail.Aborted) reasons.Add((PerfRunStatuses.Invalid, PerfInvalidReasons.Aborted));

        if (_users > 1 && _gateFailure == null && Detail.MeasuredPasses.Count > 0)
        {
            // Only passes whose gate opened: a gate released by a cooperative stop is a Capped/Aborted run, not a defect.
            var lowest = Detail.MeasuredPasses.Where(p => p.Gated && p.GateOpened).Select(p => p.ActivePeak).DefaultIfEmpty(_users).Min();
            if (lowest < _users)
            {
                reasons.Add((PerfRunStatuses.Invalid, PerfInvalidReasons.WorkersNotStarted + "(" +
                                                      lowest.ToString(CultureInfo.InvariantCulture) + "/" + _users.ToString(CultureInfo.InvariantCulture) + ")"));
            }
        }

        if (_plan.ErrorsInvalidate && m.ErrorCount > 0)
        {
            reasons.Add((PerfRunStatuses.Invalid, PerfInvalidReasons.Errors + ":" + m.ErrorCount.ToString(CultureInfo.InvariantCulture)));
        }

        // 7b. ErrorsInvalidate = false (many-users families): deadlocks, lock violations, time-outs and serialization failures
        //     are part of the result and stay reported; any other failed operation (validation, PXRowPersistingException, …)
        //     means the operation itself is broken, so the run is neither Completed nor Capped.
        if (!_plan.ErrorsInvalidate && Detail.NonContentionErrorCount > 0)
        {
            reasons.Add((PerfRunStatuses.Invalid, PerfEngineInvalidReasons.NonContentionErrors + ":" +
                                                  Detail.NonContentionErrorCount.ToString(CultureInfo.InvariantCulture)));
        }

        // 7c. Nothing was measured: measured operations were planned but none succeeded. A cooperative stop (run budget,
        //     operation cap, AbortBenchmark) that came before the first measured operation keeps its own status.
        var interrupted = m.CappedKind != null || Detail.Aborted;
        var plannedMeasured = (long)Math.Max(0, _plan.OpsPerPass) * Math.Max(0, _plan.Passes);
        var attemptedMeasured = Detail.MeasuredPasses.Sum(p => p.Ops);
        var okMeasured = Detail.MeasuredPasses.Sum(p => p.OkOps);
        if (plannedMeasured > 0 && okMeasured == 0 && (attemptedMeasured > 0 || !interrupted))
        {
            reasons.Add((PerfRunStatuses.Invalid, PerfEngineInvalidReasons.NoSuccessfulOps + "(0/" +
                                                  attemptedMeasured.ToString(CultureInfo.InvariantCulture) + ")"));
        }

        if (m.CappedKind != null) reasons.Add((PerfRunStatuses.Capped, m.CappedKind));

        Detail.InvariantsApplied = !interrupted;
        if (!interrupted && !_ctx.InvariantsOk)
        {
            _ctx.Notes.TryGetValue("firstFailedInvariant", out var name);
            if (string.IsNullOrEmpty(name))
            {
                name = _ctx.InvariantChecks.Keys.OrderBy(k => k, StringComparer.Ordinal).FirstOrDefault() ?? "unknown";
            }

            reasons.Add((PerfRunStatuses.Invalid, PerfInvalidReasons.Invariant + ":" + name));
        }

        if (cleanupFailed) reasons.Add((PerfRunStatuses.Invalid, PerfInvalidReasons.Cleanup));

        if (reasons.Count == 0)
        {
            m.Status = PerfRunStatuses.Completed;
            m.InvalidReason = null;
        }
        else
        {
            m.Status = reasons[0].Status;
            m.InvalidReason = Truncate(reasons[0].Reason, 256);
            for (var i = 1; i < reasons.Count; i++) Detail.AdditionalReasons.Add(reasons[i].Status + ":" + reasons[i].Reason);
            if (Detail.AdditionalReasons.Count > 0) Detail.Notes["additionalReasons"] = string.Join("; ", Detail.AdditionalReasons);
        }
    }

    // ------------------------------------------------------------------ helpers

    private static double Ms(Stopwatch sw) => sw.Elapsed.TotalMilliseconds;

    private static TimeSpan ProcessCpu()
    {
        try
        {
            using var p = Process.GetCurrentProcess();
            return p.TotalProcessorTime;
        }
        catch
        {
            return TimeSpan.Zero;
        }
    }

    internal static string Truncate(string text, int max)
    {
        if (string.IsNullOrEmpty(text) || text.Length <= max) return text;
        return text.Substring(0, Math.Max(0, max - 1)) + "…";
    }
}
