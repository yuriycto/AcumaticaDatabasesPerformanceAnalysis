using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using PX.Data;

namespace PerfDBBenchmark.Core.Scenarios.Core;

/// <summary>
/// The 12 CORE_* tests (SPEC §1.4): the original 12 benchmarks, fixed and re-baselined.
/// Discovered by PerfScenarioRegistry through reflection. No database access in the constructor or in Descriptors.
/// </summary>
public sealed class CoreScenarioFactory : IPerfScenarioFactory
{
    public IEnumerable<PerfTestDescriptor> Descriptors => CoreDescriptors.All;

    public IPerfScenario Create(string testCode)
    {
        if (string.IsNullOrWhiteSpace(testCode) || !CoreDescriptors.TryGet(testCode.Trim(), out var d)) return null;

        switch (d.TestCode)
        {
            case PerfScenarioCodes.CoreRead1U:
            case PerfScenarioCodes.CoreRead8U:
                return new CoreReadScenario(d);
            case PerfScenarioCodes.CoreInsert1U:
            case PerfScenarioCodes.CoreInsert8U:
                return new CoreInsertScenario(d);
            case PerfScenarioCodes.CoreUpdate1U:
            case PerfScenarioCodes.CoreUpdate8U:
                return new CoreUpdateScenario(d);
            case PerfScenarioCodes.CoreDelete1U:
            case PerfScenarioCodes.CoreDelete8U:
                return new CoreDeleteScenario(d);
            case PerfScenarioCodes.CoreJoinFull1U:
            case PerfScenarioCodes.CoreJoinFull8U:
                return new CoreJoinFullScenario(d);
            case PerfScenarioCodes.CoreJoinSlim1U:
            case PerfScenarioCodes.CoreJoinSlim8U:
                return new CoreJoinSlimScenario(d);
            default:
                return null;
        }
    }
}

/// <summary>The 12 CORE descriptors, exactly as SPEC §1.2, with the reader texts of the §1.4 cards.</summary>
internal static class CoreDescriptors
{
    private const string OneWorker = " – 1 worker";
    private const string EightWorkers = " – one job shared by 8 parallel workers";
    private const string RecordReaderUnit = "s per 10,000-record job";
    private const string JoinReaderUnit = "ms per list page";

    // ---- Card CORE_READ_1U / CORE_READ_8U ----
    private const string ReadName = "Load 10,000 records";
    private const string ReadQuestion = "How fast does Acumatica pull plain records out of the database and turn them into objects?";
    private const string ReadWhat = "The data layer under every screen, report and import: a BQL query reads records in chunks of 250 and Acumatica builds an object for each row. No business logic runs.";
    private const string ReadWhy = "This is the raw cost of moving data from the database into Acumatica. Every screen, report and import pays it.";
    private const string ReadWhy8UAppendix = " Eight workers share one job, so the 1-worker/8-worker pair shows how well reads scale on this machine.";
    private const string ReadShort = "40 ReadOnly BQL selects of 250 READ-SEED records (10,000 records per pass)";

    // ---- Card CORE_INSERT_1U / _8U ----
    private const string InsertName = "Save 10,000 new records";
    private const string InsertQuestion = "How quickly can Acumatica save brand-new records (imports, integrations, bulk entry)?";
    private const string InsertWhat = "The import and API create path without business logic: records go through Acumatica's cache with audit fields and are committed 250 at a time.";
    private const string InsertWhy = "Imports, integrations and nightly syncs are mostly 'save many new records'. The 1-worker/8-worker pair also shows whether a database lets several writers work at once or makes them queue, which matters if you run heavy integrations next to interactive users.";
    private const string InsertShort = "40 x (250 cache inserts + Save) into a new batch; the batch is deleted set-based after each pass";

    // ---- Card CORE_UPDATE_1U / _8U ----
    private const string UpdateName = "Change 10,000 records";
    private const string UpdateQuestion = "How quickly can Acumatica change existing records?";
    private const string UpdateWhat = "Mass updates and API updates: read 250 records, change two fields, save them through the cache with Acumatica's concurrency check, repeat.";
    private const string UpdateWhy = "Most ERP writes change existing data: statuses, quantities, balances. The databases keep the previous version of a changed record in different ways and clean it up at different times. This test shows what that costs once Acumatica's own work is included.";
    private const string UpdateShort = "40 x (select 250 UPDATE-SEED records, set 2 fields to absolute values, Save)";

    // ---- Card CORE_DELETE_1U / _8U ----
    private const string DeleteName = "Delete 10,000 records";
    private const string DeleteQuestion = "How quickly can Acumatica delete records?";
    private const string DeleteWhat = "Deleting through the cache, as screens and cleanup processes do, 250 records per save. Acumatica also checks every deleted record for attached files, as it does for every document.";
    private const string DeleteWhy = "Deleting in Acumatica is not one SQL statement: it is a lookup and a delete per record, plus attachment housekeeping. This shows how each database copes with many small statements in one transaction. Cleanup jobs and 'delete and re-import' integrations depend on it.";
    private const string DeleteShort = "40 x (select 250 records, cache delete, Save) on a batch prepared untimed before each pass";

    // ---- Card CORE_JOIN_FULL_1U / _8U ----
    private const string JoinFullName = "Stock availability list, all columns";
    private const string JoinFullQuestion = "How fast does a typical multi-table list (items × warehouses × quantities) load page by page?";
    private const string JoinFullWhat = "An inventory availability grid: five tables joined, every column of each table read, 50 rows per page, plus a detail lookup for up to 10 items on each page.";
    private const string JoinFullWhy = "Most Acumatica screens join several tables and read all of their columns. The cost is per-query planning and execution repeated many times, not one heavy query. The full-versus-slim pair shows how much of that cost is just the width of what is fetched.";
    private const string JoinFullShort = "80 pages of 50 (5 sweeps x 16 pages) of the 5-table availability join, integer ORDER BY, plus up to 10 item lookups per page";

    // ---- Card CORE_JOIN_SLIM_1U / _8U ----
    private const string JoinSlimName = "Stock availability list, only the needed columns";
    private const string JoinSlimQuestion = "How much faster is the same list when only the needed columns are fetched?";
    private const string JoinSlimWhat = "The same availability list read through a 10-column projection (Acumatica's tool for lists that fetch only the columns they show).";
    private const string JoinSlimWhy = "It shows whether a database's advantage survives when the application asks for less data. If the gap shrinks a lot here, the difference was in moving wide rows, not in the database's query engine.";
    private const string JoinSlimShort = "The availability list of the full join, 80 pages of 50 through the 10-column PerfBenchmarkProjection, plus up to 10 item lookups per page";

    private static readonly PerfTestDescriptor[] Items =
    {
        Record(PerfScenarioCodes.CoreRead1U, 510, "Load 1u", "Read", 1, "SEQ_READ", ReadName, ReadShort, ReadQuestion, ReadWhat, ReadWhy),
        Record(PerfScenarioCodes.CoreRead8U, 515, "Load 8u", "Read", 8, "PAR_READ", ReadName, ReadShort, ReadQuestion, ReadWhat, ReadWhy + ReadWhy8UAppendix),
        Record(PerfScenarioCodes.CoreInsert1U, 520, "Insert 1u", "Write", 1, "SEQ_WRITE", InsertName, InsertShort, InsertQuestion, InsertWhat, InsertWhy),
        Record(PerfScenarioCodes.CoreInsert8U, 525, "Insert 8u", "Write", 8, "PAR_WRITE", InsertName, InsertShort, InsertQuestion, InsertWhat, InsertWhy),
        Record(PerfScenarioCodes.CoreUpdate1U, 530, "Update 1u", "Update", 1, "SEQ_UPDATE", UpdateName, UpdateShort, UpdateQuestion, UpdateWhat, UpdateWhy),
        Record(PerfScenarioCodes.CoreUpdate8U, 535, "Update 8u", "Update", 8, "PAR_UPDATE", UpdateName, UpdateShort, UpdateQuestion, UpdateWhat, UpdateWhy),
        Record(PerfScenarioCodes.CoreDelete1U, 540, "Delete 1u", "Delete", 1, "SEQ_DELETE", DeleteName, DeleteShort, DeleteQuestion, DeleteWhat, DeleteWhy),
        Record(PerfScenarioCodes.CoreDelete8U, 545, "Delete 8u", "Delete", 8, "PAR_DELETE", DeleteName, DeleteShort, DeleteQuestion, DeleteWhat, DeleteWhy),
        Join(PerfScenarioCodes.CoreJoinFull1U, 550, "Join 1u", "Join", 1, "SEQ_COMPLEX", JoinFullName, JoinFullShort, JoinFullQuestion, JoinFullWhat, JoinFullWhy),
        Join(PerfScenarioCodes.CoreJoinFull8U, 555, "Join 8u", "Join", 8, "PAR_COMPLEX", JoinFullName, JoinFullShort, JoinFullQuestion, JoinFullWhat, JoinFullWhy),
        Join(PerfScenarioCodes.CoreJoinSlim1U, 560, "Slim join 1u", "SlimJoin", 1, "SEQ_PROJECTION", JoinSlimName, JoinSlimShort, JoinSlimQuestion, JoinSlimWhat, JoinSlimWhy),
        Join(PerfScenarioCodes.CoreJoinSlim8U, 565, "Slim join 8u", "SlimJoin", 8, "PAR_PROJECTION", JoinSlimName, JoinSlimShort, JoinSlimQuestion, JoinSlimWhat, JoinSlimWhy)
    };

    private static readonly Dictionary<string, PerfTestDescriptor> ByCode = BuildIndex();

    internal static IReadOnlyList<PerfTestDescriptor> All => Items;

    internal static bool TryGet(string testCode, out PerfTestDescriptor descriptor) =>
        ByCode.TryGetValue(testCode ?? string.Empty, out descriptor);

    private static Dictionary<string, PerfTestDescriptor> BuildIndex()
    {
        var map = new Dictionary<string, PerfTestDescriptor>(StringComparer.OrdinalIgnoreCase);
        foreach (var d in Items) map[d.TestCode] = d;
        return map;
    }

    private static PerfTestDescriptor Record(string code, int sortOrder, string shortLabel, string category, int users, string legacyCode,
        string name, string shortDescription, string question, string what, string why) =>
        Build(code, sortOrder, shortLabel, category, users, legacyCode, name, shortDescription, question, what, why,
            RecordReaderUnit, "chunks", PerfCampaignConstants.CoreRecords / PerfCampaignConstants.CoreChunkSize);

    private static PerfTestDescriptor Join(string code, int sortOrder, string shortLabel, string category, int users, string legacyCode,
        string name, string shortDescription, string question, string what, string why) =>
        Build(code, sortOrder, shortLabel, category, users, legacyCode, name, shortDescription, question, what, why,
            JoinReaderUnit, "pages", CoreScenarioBase.JoinPagesPerPass);

    private static PerfTestDescriptor Build(string code, int sortOrder, string shortLabel, string category, int users, string legacyCode,
        string name, string shortDescription, string question, string what, string why, string readerUnit, string opsUnit, int opsPerPass) =>
        new PerfTestDescriptor
        {
            TestCode = code,
            LegacyTestCode = legacyCode,
            Family = PerfFamilies.Core,
            RunBlock = PerfBlocks.Core,
            Category = category,
            DisplayName = name + (users > 1 ? EightWorkers : OneWorker),
            ShortLabel = shortLabel,
            ShortDescription = shortDescription + (users > 1 ? "; one job shared by 8 parallel workers." : "; 1 worker."),
            Question = question,
            WhatItSimulates = what,
            WhyItMatters = why,
            ReaderUnit = readerUnit,
            SortOrder = sortOrder,
            Users = users,
            HeadlineKind = PerfHeadlineKinds.MedianPassMs,
            OpsUnit = opsUnit,
            ParityExpected = true,
            OrderedChecksum = false,
            IsDestructive = false,
            IsOptional = false,
            ExcludeFromComparison = false,
            ScenarioVersion = 1,
            DefaultOpsPerPass = opsPerPass,
            DefaultPasses = PerfCampaignConstants.CoreMeasuredPasses,
            DefaultWarmUpPasses = PerfCampaignConstants.CoreWarmUpPasses,
            DefaultWarmUpOpsPerWorker = 0,
            OperationCapMs = 0,
            ErrorsInvalidate = true
        };
}

/// <summary>Per-pass totals that one worker accumulates; the coordinating thread sums them in AfterPass.</summary>
internal sealed class CorePassTotals
{
    public long Rows;
    public long Sum;
    public decimal QtyOnHand;
    public decimal QtyAvail;
}

/// <summary>Per-worker state (worker.State). Written only by its own worker during a pass; read by AfterPass after the pass.</summary>
internal sealed class CoreWorkerState
{
    private readonly Dictionary<int, CorePassTotals> _byPass = new Dictionary<int, CorePassTotals>();

    /// <summary>Totals of the pass the current operation belongs to (set in BeforeOperation, untimed).</summary>
    public CorePassTotals Current;

    // Values of the current operation, prepared in BeforeOperation (untimed) so ExecuteOperation does only the timed work.
    public int Chunk;
    public int From;
    public int To;
    public int Iteration;
    public int K;
    public string Batch;
    public int Page;
    public readonly List<int> LookupIds = new List<int>(CoreScenarioBase.JoinLookupsPerPage);

    public CorePassTotals ForPass(int pass)
    {
        if (!_byPass.TryGetValue(pass, out var totals)) _byPass[pass] = totals = new CorePassTotals();
        return totals;
    }

    public CorePassTotals PeekPass(int pass) => _byPass.TryGetValue(pass, out var totals) ? totals : null;
}

/// <summary>Shared CORE behaviour (SPEC §1.4 "Common to all 12"): plan, divisibility check, Params, cache reset, pass labels.</summary>
internal abstract class CoreScenarioBase : PerfScenarioBase
{
    public const int JoinPageSize = PerfCampaignConstants.CoreJoinPageSize;               // 50 rows per page
    public const int JoinPagesPerSweep = 16;                                               // 16 pages of 50 cover 750 < TotalRows <= 800
    public const int JoinPagesPerPass = PerfCampaignConstants.CoreJoinSweepsPerPass * JoinPagesPerSweep;   // 80
    public const int JoinLookupsPerPage = 10;
    public const string SeedFormula = "seq*17";

    internal const string BatchKey = "core.batch";
    internal const string CreatedBatchesKey = "core.createdBatches";

    private PerfRunPlan _plan;

    protected CoreScenarioBase(PerfTestDescriptor descriptor) : base(descriptor) { }

    /// <summary>N = request.NumberOfRecords (control field NumberOfRecords).</summary>
    protected int Records { get; private set; }

    /// <summary>C = request.BatchSize (control field ParallelBatchSize): rows per chunk and per commit.</summary>
    protected int ChunkSize { get; private set; }

    /// <summary>Number of operations per pass for this test before WorkScale is applied.</summary>
    protected abstract int FullOpsPerPass(int records, int chunkSize);

    /// <summary>Extra Params of the test (added after records, chunkSize and seedFormula).</summary>
    protected virtual void AddParams(IDictionary<string, object> prms) { }

    public override PerfRunPlan CreatePlan(PerfRunRequest request)
    {
        if (request == null) throw new ArgumentNullException(nameof(request));

        var n = request.NumberOfRecords;
        var c = request.BatchSize;
        if (n <= 0 || c <= 0)
            throw new PXException(string.Format(CultureInfo.InvariantCulture,
                "{0} needs NumberOfRecords > 0 and ParallelBatchSize > 0 (got {1} and {2}).", Descriptor.TestCode, n, c));

        // SPEC §1.2: at full scale N must split into whole chunks of C, and the chunks evenly over 8 workers.
        var fullScale = request.WorkScale <= 0m || request.WorkScale >= 1m;
        if (fullScale && (n % c != 0 || (n / c) % PerfCampaignConstants.CoreParallelWorkers != 0))
            throw new PXException(string.Format(CultureInfo.InvariantCulture,
                "{0} needs NumberOfRecords divisible by ParallelBatchSize into a multiple of {1} chunks (N % C == 0 and (N / C) % {1} == 0); got N = {2}, C = {3}.",
                Descriptor.TestCode, PerfCampaignConstants.CoreParallelWorkers, n, c));

        Records = n;
        ChunkSize = c;

        var prms = new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["records"] = n,
            ["chunkSize"] = c,
            ["seedFormula"] = SeedFormula
        };
        AddParams(prms);

        _plan = DefaultPlan(
            request,
            opsPerPass: FullOpsPerPass(n, c),
            extraParams: prms,
            measuredPassesFallback: request.Iterations > 0 ? request.Iterations : (int?)null);
        return _plan;
    }

    public override void CreateWorkerState(PerfWorkerContext worker)
    {
        worker.State = new CoreWorkerState();
    }

    /// <summary>Untimed: prepares the operation's values and resets the PerfTestRecord cache (SPEC §1.4 "Cache reset").</summary>
    public override void BeforeOperation(PerfWorkerContext worker, PerfOpInfo op)
    {
        var state = State(worker);
        state.Current = state.ForPass(op.Pass);
        PrepareOperation(worker, state, op);
        Graph(worker).Records.Cache.Clear();
    }

    /// <summary>Untimed, per operation: fill the CoreWorkerState fields that ExecuteOperation needs.</summary>
    protected virtual void PrepareOperation(PerfWorkerContext worker, CoreWorkerState state, PerfOpInfo op) { }

    /// <summary>The plan the engine runs (ctx.Plan), or the one this scenario created.</summary>
    protected PerfRunPlan PlanOf(PerfScenarioContext context) => context?.Plan ?? _plan;

    protected static CoreWorkerState State(PerfWorkerContext worker) =>
        worker.State as CoreWorkerState ?? throw new PXException("CORE worker state is missing (CreateWorkerState did not run).");

    protected static PerfWorkerGraph Graph(PerfWorkerContext worker) =>
        worker.Graph as PerfWorkerGraph ?? throw new PXException("CORE tests need a PerfWorkerGraph as the worker graph.");

    /// <summary>Sum of every worker's totals for one pass (coordinating thread, after the pass).</summary>
    protected static CorePassTotals SumPass(PerfScenarioContext context, int pass)
    {
        var total = new CorePassTotals();
        foreach (var worker in context.Workers)
        {
            var t = (worker.State as CoreWorkerState)?.PeekPass(pass);
            if (t == null) continue;
            total.Rows += t.Rows;
            total.Sum += t.Sum;
            total.QtyOnHand += t.QtyOnHand;
            total.QtyAvail += t.QtyAvail;
        }
        return total;
    }

    /// <summary>"W" for the warm-up pass (-1), "W2", "W3" … for earlier warm-up passes, "1" … "I" for the measured passes.</summary>
    protected static string PassLabel(int pass)
    {
        if (pass >= 0) return (pass + 1).ToString(CultureInfo.InvariantCulture);
        return pass == -1 ? "W" : "W" + (-pass).ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>Value written to PerfTestRecord.Iteration: 1 … I for measured passes, 0 for warm-up passes.</summary>
    protected static int IterationOf(int pass) => pass >= 0 ? pass + 1 : 0;

    protected static string InvariantName(int pass, string what) => "pass" + PassLabel(pass) + "." + what;

    /// <summary>Batch IDs created by this run (INSERT / DELETE), kept for Cleanup. Coordinating thread only.</summary>
    protected static ConcurrentQueue<string> CreatedBatches(PerfScenarioContext context) =>
        (ConcurrentQueue<string>)context.Items.GetOrAdd(CreatedBatchesKey, _ => new ConcurrentQueue<string>());
}
