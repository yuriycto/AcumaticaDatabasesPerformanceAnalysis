using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using PX.Data;

namespace PerfDBBenchmark.Core.Scenarios;

/// <summary>Identifies one operation. Pass &lt; 0 means warm-up (never in statistics).</summary>
public readonly struct PerfOpInfo
{
    /// <summary>Pass number used for the per-worker warm-up operations that run before the start gate.</summary>
    public const int WarmUpOpsPass = -1000;

    public PerfOpInfo(int pass, int opIndex, int workerOpIndex, int workerIndex)
    {
        Pass = pass;
        OpIndex = opIndex;
        WorkerOpIndex = workerOpIndex;
        WorkerIndex = workerIndex;
    }

    /// <summary>-WarmUpPasses..-1 = warm-up passes; WarmUpOpsPass = per-worker warm-up ops; 0..Passes-1 = measured passes.</summary>
    public int Pass { get; }
    /// <summary>Index within the pass (0..OpsPerPass-1), or within the worker's warm-up ops.</summary>
    public int OpIndex { get; }
    /// <summary>Index among this worker's ops in this pass ("order j" in SPEC §1.4 ORD).</summary>
    public int WorkerOpIndex { get; }
    public int WorkerIndex { get; }
    public bool IsWarmUp => Pass < 0;
}

/// <summary>Execution plan produced by IPerfScenario.CreatePlan. Pure data; no DB access.</summary>
public sealed class PerfRunPlan
{
    public int Users { get; init; } = 1;
    public int OpsPerPass { get; init; }
    public int Passes { get; init; } = 1;
    public int WarmUpPasses { get; init; }
    public int WarmUpOpsPerWorker { get; init; }
    /// <summary>(opIndex, opsPerPass, users) =&gt; worker index. Null = contiguous blocks (PerfDeterministic.ContiguousWorker).</summary>
    public Func<int, int, int, int> AssignWorker { get; init; }
    /// <summary>Engine calls worker.ClearQueryCaches() (PXClearOption.ClearQueriesOnly on every registered graph) before each op, untimed.</summary>
    public bool ClearQueriesBeforeEachOp { get; init; } = true;
    public int OperationCapMs { get; init; }
    /// <summary>True: any operation error makes the run Invalid. False: errors are a reported result (ORD_*).</summary>
    public bool ErrorsInvalidate { get; init; } = true;
    public TimeSpan StartGateTimeout { get; init; } = TimeSpan.FromSeconds(60);
    /// <summary>Default per-run time budget (SPEC §1.3.4).</summary>
    public static readonly TimeSpan DefaultRunBudget = TimeSpan.FromMinutes(15);
    /// <summary>Checked by the engine before every operation; used up =&gt; Capped("runBudget"). Not part of Params / ParamsHash.</summary>
    public TimeSpan RunBudget { get; init; } = DefaultRunBudget;
    /// <summary>Canonical parameters; the engine serializes them with PerfJson.Canonical and hashes them into ParamsHash.</summary>
    public IDictionary<string, object> Params { get; init; } = new Dictionary<string, object>(StringComparer.Ordinal);
}

/// <summary>
/// One benchmark test. A new instance is created per run. Only ExecuteOperation is timed.
/// Engine call order (SPEC §4.2): CreatePlan → Prepare → CreateWorkerState(each worker) →
/// [warm-up ops → AfterPass(WarmUpOpsPass)] → for each pass (warm-up passes first):
/// BeforePass → (engine: RefreshTimeStamps, new per-pass checksums) → per op {ClearQueryCaches, BeforeOperation, ExecuteOperation(timed)} →
/// (engine: pass digest) → AfterPass → Verify → Cleanup (always, in finally, also after a failed Prepare).
/// </summary>
public interface IPerfScenario
{
    PerfTestDescriptor Descriptor { get; }
    PerfRunPlan CreatePlan(PerfRunRequest request);
    void Prepare(PerfScenarioContext context);
    void CreateWorkerState(PerfWorkerContext worker);
    void BeforePass(PerfScenarioContext context, int pass);
    void BeforeOperation(PerfWorkerContext worker, PerfOpInfo op);
    void ExecuteOperation(PerfWorkerContext worker, PerfOpInfo op);
    void AfterPass(PerfScenarioContext context, int pass);
    void Verify(PerfScenarioContext context, PerfRunMetrics metrics);
    void Cleanup(PerfScenarioContext context);
}

/// <summary>One per family. Discovered by PerfScenarioRegistry via reflection (public, non-abstract, parameterless ctor). No DB access in ctor/Descriptors.</summary>
public interface IPerfScenarioFactory
{
    IEnumerable<PerfTestDescriptor> Descriptors { get; }
    /// <summary>Returns a new scenario for one of this factory's codes, or null if the code is not this factory's.</summary>
    IPerfScenario Create(string testCode);
}

/// <summary>Contributes one named hash to ENV_CAPTURE's master-data fingerprint (discovered by reflection like factories).
/// Implementations must be read-only, deterministic, and sort in C# with StringComparer.Ordinal after TrimEnd().</summary>
public interface IPerfFingerprintContributor
{
    string Name { get; }
    /// <summary>Returns "count:hash16" (see PerfChecksum / PerfOrderedChecksum ToString()).</summary>
    string Compute(PXGraph graph);
}

/// <summary>Removes leftovers of crashed runs (e.g. PERFBENCH sales orders, unreleased PERFBENCH invoices).
/// Called by the ClearTestRecords action; discovered by reflection. Must never touch SalesDemo data that is not tagged PERFBENCH.</summary>
public interface IPerfLeftoverCleaner
{
    string Name { get; }
    /// <summary>Returns the number of records removed.</summary>
    int Clean(PXGraph graph);
}

public abstract class PerfScenarioBase : IPerfScenario
{
    protected PerfScenarioBase(PerfTestDescriptor descriptor)
    {
        Descriptor = descriptor ?? throw new ArgumentNullException(nameof(descriptor));
    }

    public PerfTestDescriptor Descriptor { get; }

    public virtual PerfRunPlan CreatePlan(PerfRunRequest request) => DefaultPlan(request);
    public virtual void Prepare(PerfScenarioContext context) { }
    public virtual void CreateWorkerState(PerfWorkerContext worker) { }
    public virtual void BeforePass(PerfScenarioContext context, int pass) { }
    public virtual void BeforeOperation(PerfWorkerContext worker, PerfOpInfo op) { }
    public abstract void ExecuteOperation(PerfWorkerContext worker, PerfOpInfo op);
    public virtual void AfterPass(PerfScenarioContext context, int pass) { }
    public virtual void Verify(PerfScenarioContext context, PerfRunMetrics metrics) { }
    public virtual void Cleanup(PerfScenarioContext context) { }

    /// <param name="measuredPassesFallback">Used when PassesOverride is not set (CORE passes request.Iterations here).</param>
    protected PerfRunPlan DefaultPlan(
        PerfRunRequest request,
        int? opsPerPass = null,
        IDictionary<string, object> extraParams = null,
        Func<int, int, int, int> assignWorker = null,
        bool clearQueriesBeforeEachOp = true,
        int? measuredPassesFallback = null)
    {
        if (request == null) throw new ArgumentNullException(nameof(request));
        var users = Math.Max(1, Descriptor.Users);
        var ops = ScaleOps(opsPerPass ?? Descriptor.DefaultOpsPerPass, request.WorkScale, users);
        var passes = request.PassesOverride is int p && p > 0
            ? p
            : (measuredPassesFallback is int f && f > 0 ? f : Math.Max(1, Descriptor.DefaultPasses));
        var warmPasses = request.WarmUpPassesOverride is int w && w >= 0 ? w : Math.Max(0, Descriptor.DefaultWarmUpPasses);
        var warmOps = ScaleWarmUpOps(Math.Max(0, Descriptor.DefaultWarmUpOpsPerWorker), request.WorkScale);

        var prms = new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["methodologyVersion"] = PerfMethodology.Version,
            ["testCode"] = Descriptor.TestCode,
            ["scenarioVersion"] = Descriptor.ScenarioVersion,
            ["users"] = users,
            ["opsPerPass"] = ops,
            ["passes"] = passes,
            ["warmUpPasses"] = warmPasses,
            ["warmUpOpsPerWorker"] = warmOps,
            ["workScale"] = request.WorkScale.ToString("0.####", CultureInfo.InvariantCulture),
            ["operationCapMs"] = Descriptor.OperationCapMs
        };
        if (extraParams != null)
        {
            foreach (var kv in extraParams) prms[kv.Key] = kv.Value;
        }

        return new PerfRunPlan
        {
            Users = users,
            OpsPerPass = ops,
            Passes = passes,
            WarmUpPasses = warmPasses,
            WarmUpOpsPerWorker = warmOps,
            AssignWorker = assignWorker,
            ClearQueriesBeforeEachOp = clearQueriesBeforeEachOp,
            OperationCapMs = Descriptor.OperationCapMs,
            ErrorsInvalidate = Descriptor.ErrorsInvalidate,
            RunBudget = request.RunBudgetSec is int b && b > 0 ? TimeSpan.FromSeconds(b) : PerfRunPlan.DefaultRunBudget,
            Params = prms
        };
    }

    /// <summary>ops * scale rounded up, at least 'users'. scale &gt;= 1 or &lt;= 0 returns ops unchanged.</summary>
    protected static int ScaleOps(int ops, decimal scale, int users)
    {
        if (ops <= 0 || scale <= 0m || scale >= 1m) return ops;
        return Math.Max(users, (int)Math.Ceiling(ops * scale));
    }

    /// <summary>Per-worker warm-up ops * scale rounded up, at least 1 (0 stays 0). scale &gt;= 1 or &lt;= 0 returns ops unchanged.</summary>
    protected static int ScaleWarmUpOps(int ops, decimal scale)
    {
        if (ops <= 0 || scale <= 0m || scale >= 1m) return ops;
        return Math.Max(1, (int)Math.Ceiling(ops * scale));
    }
}

/// <summary>Per-run shared state. Created by the engine; scenarios read Request/Descriptor/Plan and use Items/CheckInvariant/Parity.</summary>
public sealed class PerfScenarioContext
{
    public PerfScenarioContext(PerfRunRequest request, PerfTestDescriptor descriptor, PXGraph mainGraph)
    {
        Request = request ?? throw new ArgumentNullException(nameof(request));
        Descriptor = descriptor ?? throw new ArgumentNullException(nameof(descriptor));
        MainGraph = mainGraph ?? throw new ArgumentNullException(nameof(mainGraph));
        DatabaseEngine = PerfDatabaseEngines.Detect();
    }

    public PerfRunRequest Request { get; }
    public PerfTestDescriptor Descriptor { get; }
    /// <summary>A PerfWorkerGraph for Prepare/BeforePass/AfterPass/Verify/Cleanup (coordinating thread only).</summary>
    public PXGraph MainGraph { get; }
    public string DatabaseEngine { get; }
    public Guid RunId => Request.RequestID;
    public string DocumentTag => PerfCampaignConstants.DocumentTag(Request.RequestID);
    public PerfRunPlan Plan { get; internal set; }
    /// <summary>What the engine's Request Profiler guard found and did before Prepare (ENV_CAPTURE reports it).</summary>
    internal PerfProfilerGuardResult ProfilerGuard { get; set; }
    public IReadOnlyList<PerfWorkerContext> Workers => WorkersInternal;
    internal List<PerfWorkerContext> WorkersInternal { get; } = new List<PerfWorkerContext>();

    /// <summary>Scenario state. Write in Prepare/BeforePass/AfterPass; read-only from workers.</summary>
    public ConcurrentDictionary<string, object> Items { get; } = new ConcurrentDictionary<string, object>(StringComparer.Ordinal);
    public T Get<T>(string key) => Items.TryGetValue(key, out var v) && v is T t ? t : default;
    public void Set(string key, object value) => Items[key] = value;

    /// <summary>Values compared across engines by the report (ResultJson.parity). Keys starting with "probe." are informational only.</summary>
    public ConcurrentDictionary<string, string> Parity { get; } = new ConcurrentDictionary<string, string>(StringComparer.Ordinal);
    public ConcurrentDictionary<string, string> Notes { get; } = new ConcurrentDictionary<string, string>(StringComparer.Ordinal);
    public ConcurrentDictionary<string, string> InvariantChecks { get; } = new ConcurrentDictionary<string, string>(StringComparer.Ordinal);
    private volatile bool _invariantsOk = true;
    public bool InvariantsOk => _invariantsOk;

    /// <summary>Records expected vs actual (canonicalized); any mismatch makes the run Invalid("Invariant:&lt;name&gt;").</summary>
    public void CheckInvariant(string name, object expected, object actual)
    {
        var e = PerfChecksum.Canonical(expected);
        var a = PerfChecksum.Canonical(actual);
        InvariantChecks[name] = "expected=" + e + ";actual=" + a;
        if (!string.Equals(e, a, StringComparison.Ordinal))
        {
            _invariantsOk = false;
            Notes.TryAdd("firstFailedInvariant", name);
        }
    }

    /// <summary>Digest ("count:hash16") of every pass, recorded by the engine right after the pass ran (SPEC §1.3.7).
    /// Key = pass number (negative = warm-up pass; PerfOpInfo.WarmUpOpsPass = per-worker warm-up ops).</summary>
    public IReadOnlyDictionary<int, string> PassDigests => PassDigestsInternal;
    internal ConcurrentDictionary<int, string> PassDigestsInternal { get; } = new ConcurrentDictionary<int, string>();

    /// <summary>Invariant passDigestStable:&lt;pass&gt; for every recorded pass after the first (warm-up passes included,
    /// per-worker warm-up ops excluded). Call from Verify when every pass must return identical data.</summary>
    public void CheckPassDigestsStable()
    {
        string first = null;
        foreach (var kv in PassDigestsInternal.OrderBy(k => k.Key))
        {
            if (kv.Key == PerfOpInfo.WarmUpOpsPass) continue;
            if (first == null) { first = kv.Value; continue; }
            CheckInvariant("passDigestStable:" + kv.Key.ToString(CultureInfo.InvariantCulture), first, kv.Value);
        }
    }

    internal Action<int, int, Action<int, int>> UntimedParallelRunner { get; set; }

    /// <summary>Untimed helper (seeding, deleting created orders): runs body(slot, item) for item 0..itemCount-1 on 'slots' threads.
    /// Slot-local state (graphs) is the scenario's responsibility (e.g. a ConcurrentDictionary in Items keyed by slot).</summary>
    public void RunUntimedParallel(int slots, int itemCount, Action<int, int> body)
    {
        if (body == null) throw new ArgumentNullException(nameof(body));
        if (itemCount <= 0) return;
        if (UntimedParallelRunner == null || slots <= 1)
        {
            for (var i = 0; i < itemCount; i++) body(0, i);
            return;
        }
        UntimedParallelRunner(slots, itemCount, body);
    }
}

/// <summary>Per-worker state. One per simulated user; lives for the whole run (all passes).</summary>
public sealed class PerfWorkerContext
{
    private readonly List<PXGraph> _graphs = new List<PXGraph>();
    private readonly Dictionary<string, List<double>> _phases = new Dictionary<string, List<double>>(StringComparer.Ordinal);

    public PerfWorkerContext(PerfScenarioContext run, int index, PXGraph graph)
    {
        Run = run ?? throw new ArgumentNullException(nameof(run));
        Index = index;
        Graph = graph ?? throw new ArgumentNullException(nameof(graph));
        RegisterGraph(graph);
    }

    public PerfScenarioContext Run { get; }
    public int Index { get; }
    public int WorkerCount => Run.Plan?.Users ?? 1;
    /// <summary>A PerfWorkerGraph owned by this worker (registered for query-cache clearing).</summary>
    public PXGraph Graph { get; }
    public object State { get; set; }
    public T StateAs<T>() where T : class => State as T;

    /// <summary>Current pass only: the engine replaces it before every pass and folds measured passes into the run checksum (SPEC §1.3.7).</summary>
    public PerfChecksum Checksum { get; internal set; } = new PerfChecksum();
    /// <summary>Current pass only (Users == 1 tests with ordered results); replaced by the engine before every pass.</summary>
    public PerfOrderedChecksum OrderedChecksum { get; internal set; } = new PerfOrderedChecksum();
    public long RowsReturned { get; set; }

    public IReadOnlyList<PXGraph> Graphs => _graphs;
    public void RegisterGraph(PXGraph graph)
    {
        if (graph != null && !_graphs.Contains(graph)) _graphs.Add(graph);
    }

    /// <summary>Clear(ClearQueriesOnly) on every registered graph. The engine calls it before each op when Plan.ClearQueriesBeforeEachOp.</summary>
    public void ClearQueryCaches()
    {
        foreach (var g in _graphs) g.Clear(PXClearOption.ClearQueriesOnly);
    }

    /// <summary>SelectTimeStamp() on every registered graph, so rows created by other graphs or threads pass Acumatica's
    /// row-version check on update/delete. The engine calls it after every BeforePass (SPEC §1.3.3, review-api B1).</summary>
    public void RefreshTimeStamps()
    {
        foreach (var g in _graphs) g.SelectTimeStamp();
    }

    /// <summary>True only while a measured (non-warm-up) operation runs.</summary>
    public bool IsMeasuring { get; internal set; }

    /// <summary>Optional sub-timing inside ExecuteOperation (e.g. "create", "releasePost"); ignored during warm-up.</summary>
    public void RecordPhase(string name, double milliseconds)
    {
        if (!IsMeasuring || string.IsNullOrEmpty(name)) return;
        if (!_phases.TryGetValue(name, out var list)) _phases[name] = list = new List<double>();
        list.Add(milliseconds);
    }

    public IReadOnlyDictionary<string, List<double>> Phases => _phases;

    // engine-owned measurement state (do not touch from scenarios)
    internal readonly List<double> OpLatenciesMs = new List<double>();
    internal int Errors;
    internal int OkOps;
    internal long PassEndTicks;
    internal readonly List<string> ErrorSamples = new List<string>();
}

/// <summary>Everything the engine persists for one run. Verify may set Notes/Checksum/RowsReturned and add Result entries.</summary>
public sealed class PerfRunMetrics
{
    public string Status { get; set; } = PerfRunStatuses.Completed;
    public string InvalidReason { get; set; }
    /// <summary>null, PerfCappedKinds.OperationCap or PerfCappedKinds.RunBudget.</summary>
    public string CappedKind { get; set; }
    public int UserCount { get; set; }
    /// <summary>Peak number of active workers (gate arrival to last operation; SPEC §1.3.3).</summary>
    public int WorkersObservedPeak { get; set; }
    /// <summary>Peak number of operations executing at the same instant (information only).</summary>
    public int OpsInFlightPeak { get; set; }
    public int DistinctThreads { get; set; }
    public int OpsCount { get; set; }
    public int ErrorCount { get; set; }
    public int DeadlockCount { get; set; }
    public int RetryCount { get; set; }
    public int LockViolationCount { get; set; }
    public int TimeoutCount { get; set; }
    public double PrepareMs { get; set; }
    public double WarmupMs { get; set; }
    public double ElapsedMsPrecise { get; set; }
    public double VerifyMs { get; set; }
    public double CleanupMs { get; set; }
    public double TotalMs { get; set; }
    public double AppCpuMs { get; set; }
    public List<double> PassWallMs { get; } = new List<double>();
    public double HeadlineValue { get; set; }
    public double OpsPerSec { get; set; }
    public double P50Ms { get; set; }
    public double P95Ms { get; set; }
    public double? P99Ms { get; set; }
    public double MaxOpMs { get; set; }
    public long RowsReturned { get; set; }
    public string Checksum { get; set; }
    public string ParamsJson { get; set; }
    public string ParamsHash { get; set; }
    public string Notes { get; set; }
    public Dictionary<string, object> Result { get; } = new Dictionary<string, object>(StringComparer.Ordinal);
}

/// <summary>Helpers for graphs used outside ExecuteOperation (SPEC §1.3.3, §4.8 rule 14).</summary>
public static class PerfGraphs
{
    /// <summary>Clear(ClearAll) + SelectTimeStamp(). Call before a coordinating-thread graph updates or deletes rows
    /// created during the run; otherwise it carries the run-start stamp and the write fails (review-api M1).</summary>
    public static TGraph FreshForWrite<TGraph>(TGraph graph) where TGraph : PXGraph
    {
        if (graph == null) throw new ArgumentNullException(nameof(graph));
        graph.Clear(PXClearOption.ClearAll);
        graph.SelectTimeStamp();
        return graph;
    }
}
