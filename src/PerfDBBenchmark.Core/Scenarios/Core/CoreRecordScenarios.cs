using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using PX.Data;
using PX.Data.BQL;
using PX.Data.BQL.Fluent;
using PX.Data.SQLTree;
using PerfDBBenchmark.Core.DAC;

namespace PerfDBBenchmark.Core.Scenarios.Core;

/// <summary>
/// CORE_READ / CORE_INSERT / CORE_UPDATE / CORE_DELETE (SPEC §1.4). One operation = one chunk c of C rows
/// (Sequence c·C+1 … (c+1)·C), one Save per chunk. Only ExecuteOperation is timed.
/// </summary>
internal abstract class CoreRecordScenarioBase : CoreScenarioBase
{
    protected CoreRecordScenarioBase(PerfTestDescriptor descriptor) : base(descriptor) { }

    /// <summary>Full scale: N / C chunks (40). Below full scale a last partial chunk is allowed.</summary>
    protected override int FullOpsPerPass(int records, int chunkSize) => (records + chunkSize - 1) / chunkSize;

    protected override void PrepareOperation(PerfWorkerContext worker, CoreWorkerState state, PerfOpInfo op)
    {
        var request = worker.Run.Request;
        state.Chunk = op.OpIndex;
        CoreChunks.Range(op.OpIndex, request.NumberOfRecords, request.BatchSize, out state.From, out state.To);
        state.Iteration = IterationOf(op.Pass);
    }

    /// <summary>M = rows covered by the chunks this pass executes (plan.OpsPerPass chunks over Sequence 1 … M; SPEC §1.4).</summary>
    protected int ExpectedRows(PerfScenarioContext context) =>
        CoreChunks.RowsCovered(PlanOf(context)?.OpsPerPass ?? 0, Records, ChunkSize);

    /// <summary>Σ Sequence·17 over Sequence 1 … m = 17·m(m+1)/2 (850,085,000 at m = 10,000).</summary>
    protected static long SeedSum(long m) => PerfCampaignConstants.CorePayloadFactor * m * (m + 1) / 2;

    /// <summary>The reference values of the first measured pass go to ResultJson.parity (checked once in the dry run, SPEC §1.3.7).</summary>
    protected static void RecordPassParity(PerfScenarioContext context, int pass, long rows, long sum, string sumKey = "ref.passSum")
    {
        if (pass != 0) return;
        context.Parity["ref.passRows"] = PerfChecksum.Canonical(rows);
        context.Parity[sumKey] = PerfChecksum.Canonical(sum);
    }
}

/// <summary>CORE_READ_1U / CORE_READ_8U: Load 10,000 records (READ-SEED, ReadOnly BQL, 250 rows per select).</summary>
internal sealed class CoreReadScenario : CoreRecordScenarioBase
{
    public CoreReadScenario(PerfTestDescriptor descriptor) : base(descriptor) { }

    public override void Prepare(PerfScenarioContext context)
    {
        CoreSeedHelper.EnsureSeed(context, PerfCampaignConstants.ReadSeedBatch, Records, ChunkSize, checkPayload: true);
    }

    public override void ExecuteOperation(PerfWorkerContext worker, PerfOpInfo op)
    {
        var state = (CoreWorkerState)worker.State;
        var sum = 0L;
        var rows = 0;
        foreach (PerfTestRecord r in SelectFrom<PerfTestRecord>
                     .Where<PerfTestRecord.batchID.IsEqual<@P.AsString>
                         .And<PerfTestRecord.sequence.IsGreaterEqual<@P.AsInt>>
                         .And<PerfTestRecord.sequence.IsLessEqual<@P.AsInt>>>
                     .OrderBy<PerfTestRecord.sequence.Asc>
                     .View.ReadOnly.Select(worker.Graph, PerfCampaignConstants.ReadSeedBatch, state.From, state.To))
        {
            sum += r.PayloadValue ?? 0;
            rows++;
        }

        worker.Checksum.Add(state.Chunk, rows, sum);
        worker.RowsReturned += rows;
        state.Current.Rows += rows;
        state.Current.Sum += sum;
    }

    public override void AfterPass(PerfScenarioContext context, int pass)
    {
        var m = ExpectedRows(context);
        var actual = SumPass(context, pass);
        context.CheckInvariant(InvariantName(pass, "rows"), (long)m, actual.Rows);
        context.CheckInvariant(InvariantName(pass, "sum"), SeedSum(m), actual.Sum);
        RecordPassParity(context, pass, actual.Rows, actual.Sum);
    }

    public override void Verify(PerfScenarioContext context, PerfRunMetrics metrics)
    {
        context.CheckPassDigestsStable();
    }
}

/// <summary>CORE_INSERT_1U / CORE_INSERT_8U: Save 10,000 new records (cache insert + Save per 250 rows; batch deleted set-based after each pass).</summary>
internal sealed class CoreInsertScenario : CoreRecordScenarioBase
{
    public CoreInsertScenario(PerfTestDescriptor descriptor) : base(descriptor) { }

    public override void BeforePass(PerfScenarioContext context, int pass)
    {
        var batch = CoreSeedHelper.RunBatchId("CORE-INS-", context.RunId, PassLabel(pass));
        CreatedBatches(context).Enqueue(batch);   // tracked before any row exists, so Cleanup always finds it
        context.Set(BatchKey, batch);
    }

    protected override void PrepareOperation(PerfWorkerContext worker, CoreWorkerState state, PerfOpInfo op)
    {
        base.PrepareOperation(worker, state, op);
        state.Batch = worker.Run.Get<string>(BatchKey);
    }

    public override void ExecuteOperation(PerfWorkerContext worker, PerfOpInfo op)
    {
        var state = (CoreWorkerState)worker.State;
        var g = (PerfWorkerGraph)worker.Graph;
        var cache = g.Records.Cache;
        var sum = 0L;
        var rows = 0;
        for (var s = state.From; s <= state.To; s++)
        {
            var value = s * PerfCampaignConstants.CorePayloadFactor;
            cache.Insert(new PerfTestRecord
            {
                BatchID = state.Batch,
                OperationType = "INSERT",
                Iteration = state.Iteration,
                Sequence = s,
                PayloadValue = value,
                PayloadText = "Insert " + s.ToString(CultureInfo.InvariantCulture)
            });
            sum += value;
            rows++;
        }
        g.Save.Press();

        worker.Checksum.Add(state.Chunk, rows, sum);
        worker.RowsReturned += rows;
        state.Current.Rows += rows;
        state.Current.Sum += sum;
    }

    public override void AfterPass(PerfScenarioContext context, int pass)
    {
        var batch = context.Get<string>(BatchKey);
        if (string.IsNullOrEmpty(batch)) return;

        // 1. Read the batch ReadOnly (untimed). 2. Invariants.
        var m = ExpectedRows(context);
        CoreSeedHelper.ReadBatchTotals(context.MainGraph, batch, out var rows, out var sum);
        context.CheckInvariant(InvariantName(pass, "rows"), (long)m, rows);
        context.CheckInvariant(InvariantName(pass, "sum"), SeedSum(m), sum);
        RecordPassParity(context, pass, rows, sum);

        // 3. Set-based delete of the pass batch, so PerfTestRecord holds only the two seeds between passes. Never throws (rule 16).
        CoreSeedHelper.TryDeleteBatch(context, batch);

        // 4. Clear the main graph's query cache.
        context.MainGraph.Clear(PXClearOption.ClearQueriesOnly);
    }

    public override void Verify(PerfScenarioContext context, PerfRunMetrics metrics)
    {
        context.CheckPassDigestsStable();
    }

    public override void Cleanup(PerfScenarioContext context)
    {
        CoreSeedHelper.DeleteCreatedBatches(context);
    }
}

/// <summary>CORE_UPDATE_1U / CORE_UPDATE_8U: Change 10,000 records (UPDATE-SEED; absolute values Sequence·17 + k per pass).</summary>
internal sealed class CoreUpdateScenario : CoreRecordScenarioBase
{
    public CoreUpdateScenario(PerfTestDescriptor descriptor) : base(descriptor) { }

    /// <summary>k = 1 for the warm-up pass, k = p + 2 for measured pass p (SPEC §1.4). Earlier extra warm-up passes continue the formula.</summary>
    private static int KOf(int pass) => pass + 2;

    public override void Prepare(PerfScenarioContext context)
    {
        // Count and Sequence set only; the values may be anything (they are overwritten with absolute values every pass).
        CoreSeedHelper.EnsureSeed(context, PerfCampaignConstants.UpdateSeedBatch, Records, ChunkSize, checkPayload: false);
    }

    protected override void PrepareOperation(PerfWorkerContext worker, CoreWorkerState state, PerfOpInfo op)
    {
        base.PrepareOperation(worker, state, op);
        state.K = KOf(op.Pass);
    }

    public override void ExecuteOperation(PerfWorkerContext worker, PerfOpInfo op)
    {
        var state = (CoreWorkerState)worker.State;
        var g = (PerfWorkerGraph)worker.Graph;
        var cache = g.Records.Cache;
        var k = state.K;
        var kText = k.ToString(CultureInfo.InvariantCulture);
        var sum = 0L;
        var rows = 0;
        foreach (PerfTestRecord r in SelectFrom<PerfTestRecord>
                     .Where<PerfTestRecord.batchID.IsEqual<@P.AsString>
                         .And<PerfTestRecord.sequence.IsGreaterEqual<@P.AsInt>>
                         .And<PerfTestRecord.sequence.IsLessEqual<@P.AsInt>>>
                     .OrderBy<PerfTestRecord.sequence.Asc>
                     .View.Select(g, PerfCampaignConstants.UpdateSeedBatch, state.From, state.To))
        {
            var seq = r.Sequence ?? 0;
            var value = seq * PerfCampaignConstants.CorePayloadFactor + k;
            var copy = (PerfTestRecord)cache.CreateCopy(r);
            copy.PayloadValue = value;
            copy.PayloadText = "U" + kText + "-" + seq.ToString(CultureInfo.InvariantCulture);
            cache.Update(copy);
            sum += value;
            rows++;
        }
        g.Save.Press();

        worker.Checksum.Add(state.Chunk, sum);
        worker.RowsReturned += rows;
        state.Current.Rows += rows;
        state.Current.Sum += sum;
    }

    public override void AfterPass(PerfScenarioContext context, int pass)
    {
        // Read UPDATE-SEED ReadOnly (untimed) over the Sequences this pass updated: rows = M, Σ = 17·M(M+1)/2 + M·k.
        var m = ExpectedRows(context);
        var k = KOf(pass);
        CoreSeedHelper.ReadSeedRangeTotals(context.MainGraph, PerfCampaignConstants.UpdateSeedBatch, 1, m, out var rows, out var sum);
        context.CheckInvariant(InvariantName(pass, "rows"), (long)m, rows);
        context.CheckInvariant(InvariantName(pass, "sum"), SeedSum(m) + (long)m * k, sum);
        RecordPassParity(context, pass, rows, sum - (long)m * k, "ref.passSumMinusK");
    }
}

/// <summary>CORE_DELETE_1U / CORE_DELETE_8U: Delete 10,000 records (cache delete + Save per 250 rows on a batch prepared untimed in BeforePass).</summary>
internal sealed class CoreDeleteScenario : CoreRecordScenarioBase
{
    public CoreDeleteScenario(PerfTestDescriptor descriptor) : base(descriptor) { }

    public override void BeforePass(PerfScenarioContext context, int pass)
    {
        var batch = CoreSeedHelper.RunBatchId("CORE-DEL-", context.RunId, PassLabel(pass));
        CreatedBatches(context).Enqueue(batch);   // tracked before any row exists, so Cleanup always finds it
        context.Set(BatchKey, batch);

        // Untimed: M rows through the cache path (every row gets a NoteID, as a real record has), a Save per chunk,
        // 8 slots with one PerfWorkerGraph each.
        CoreSeedHelper.InsertBatch(context, batch, "DELETE", IterationOf(pass), ExpectedRows(context), ChunkSize,
            s => "Delete " + s.ToString(CultureInfo.InvariantCulture));

        // The engine refreshes every worker graph's row-version stamp after BeforePass (SPEC §1.3.3, review-api B1).
        // Doing it here as well is cheap, untimed and keeps CORE_DELETE valid even if that engine step were missing.
        foreach (var worker in context.Workers) worker.RefreshTimeStamps();
    }

    protected override void PrepareOperation(PerfWorkerContext worker, CoreWorkerState state, PerfOpInfo op)
    {
        base.PrepareOperation(worker, state, op);
        state.Batch = worker.Run.Get<string>(BatchKey);
    }

    public override void ExecuteOperation(PerfWorkerContext worker, PerfOpInfo op)
    {
        var state = (CoreWorkerState)worker.State;
        var g = (PerfWorkerGraph)worker.Graph;
        var cache = g.Records.Cache;
        var sum = 0L;
        var rows = 0;
        foreach (PerfTestRecord r in SelectFrom<PerfTestRecord>
                     .Where<PerfTestRecord.batchID.IsEqual<@P.AsString>
                         .And<PerfTestRecord.sequence.IsGreaterEqual<@P.AsInt>>
                         .And<PerfTestRecord.sequence.IsLessEqual<@P.AsInt>>>
                     .OrderBy<PerfTestRecord.sequence.Asc>
                     .View.Select(g, state.Batch, state.From, state.To))
        {
            sum += r.PayloadValue ?? 0;
            rows++;
            cache.Delete(r);
        }
        g.Save.Press();

        worker.Checksum.Add(state.Chunk, rows, sum);
        worker.RowsReturned += rows;
        state.Current.Rows += rows;
        state.Current.Sum += sum;
    }

    public override void AfterPass(PerfScenarioContext context, int pass)
    {
        var batch = context.Get<string>(BatchKey);
        var m = ExpectedRows(context);
        var actual = SumPass(context, pass);
        context.CheckInvariant(InvariantName(pass, "deletedRows"), (long)m, actual.Rows);
        context.CheckInvariant(InvariantName(pass, "deletedSum"), SeedSum(m), actual.Sum);
        RecordPassParity(context, pass, actual.Rows, actual.Sum);
        if (string.IsNullOrEmpty(batch)) return;

        var remaining = CoreSeedHelper.CountBatch(batch);
        context.CheckInvariant(InvariantName(pass, "remaining"), 0, remaining);

        // Only after a failure: remove what is left so the next pass starts from the same table size. Never throws (rule 16).
        if (remaining != 0) CoreSeedHelper.TryDeleteBatch(context, batch);
    }

    public override void Verify(PerfScenarioContext context, PerfRunMetrics metrics)
    {
        // A row-version (stamp) regression shows as Invariant:lockViolations instead of anonymous errors (review-api B1).
        context.CheckInvariant("lockViolations", 0, metrics?.LockViolationCount ?? 0);
        context.CheckPassDigestsStable();
    }

    public override void Cleanup(PerfScenarioContext context)
    {
        CoreSeedHelper.DeleteCreatedBatches(context);
    }
}

/// <summary>Chunk arithmetic. Chunk c (0-based) covers Sequence a = c·C + 1 … b = min((c+1)·C, N).</summary>
internal static class CoreChunks
{
    public static void Range(int chunk, int records, int chunkSize, out int from, out int to)
    {
        from = chunk * chunkSize + 1;
        to = Math.Min(records, (chunk + 1) * chunkSize);   // to < from (an empty chunk) only below full scale with odd settings
    }

    /// <summary>Rows covered by chunks 0 … ops-1: min(ops·C, N), never negative.</summary>
    public static int RowsCovered(int ops, int records, int chunkSize)
    {
        if (ops <= 0 || records <= 0 || chunkSize <= 0) return 0;
        return (int)Math.Min((long)ops * chunkSize, records);
    }
}

/// <summary>Seeds, batch creation and set-based deletes. All untimed (Prepare, BeforePass, AfterPass, Cleanup).</summary>
internal static class CoreSeedHelper
{
    /// <summary>"CORE-INS-&lt;RunID:N&gt;-&lt;p&gt;" / "CORE-DEL-&lt;RunID:N&gt;-&lt;p&gt;" (at most 64 characters).</summary>
    public static string RunBatchId(string prefix, Guid runId, string passLabel) =>
        prefix + runId.ToString("N") + "-" + passLabel;

    /// <summary>
    /// Content check of a persistent seed batch (SPEC §1.4 "Seeds"): count = N and Sequence set = {1 … N}; with checkPayload also
    /// PayloadValue = 17·Sequence on every row, hence Σ = 17·N(N+1)/2. On failure the batch is deleted set-based and inserted again
    /// through the cache (a Save every C rows, 8 slots), then checked once more; a second failure makes Prepare fail.
    /// </summary>
    public static void EnsureSeed(PerfScenarioContext context, string batch, int records, int chunkSize, bool checkPayload)
    {
        var problem = CheckSeed(context.MainGraph, batch, records, checkPayload);
        if (problem == null) return;

        context.Notes["core.reseeded." + batch] = problem;
        DeleteBatch(batch);
        InsertBatch(context, batch, "SEED", 0, records, chunkSize, s => "Seed " + s.ToString(CultureInfo.InvariantCulture));

        context.MainGraph.Clear(PXClearOption.ClearQueriesOnly);
        var again = CheckSeed(context.MainGraph, batch, records, checkPayload);
        if (again != null)
            throw new PXException("The " + batch + " batch is still wrong after re-seeding: " + again + ".");
    }

    /// <summary>Returns null when the batch is correct, otherwise the first problem found.</summary>
    private static string CheckSeed(PXGraph graph, string batch, int records, bool checkPayload)
    {
        var seen = new bool[records + 1];
        var count = 0L;
        var sum = 0L;
        foreach (PerfTestRecord r in SelectFrom<PerfTestRecord>
                     .Where<PerfTestRecord.batchID.IsEqual<@P.AsString>>
                     .View.ReadOnly.Select(graph, batch))
        {
            count++;
            var seq = r.Sequence ?? 0;
            if (seq < 1 || seq > records)
                return string.Format(CultureInfo.InvariantCulture, "Sequence {0} is outside 1..{1}", seq, records);
            if (seen[seq])
                return string.Format(CultureInfo.InvariantCulture, "Sequence {0} occurs more than once", seq);
            seen[seq] = true;

            var value = r.PayloadValue ?? 0;
            if (checkPayload && value != seq * PerfCampaignConstants.CorePayloadFactor)
                return string.Format(CultureInfo.InvariantCulture, "PayloadValue of Sequence {0} is {1}, not {2}", seq, value, seq * PerfCampaignConstants.CorePayloadFactor);
            sum += value;
        }

        if (count != records)
            return string.Format(CultureInfo.InvariantCulture, "{0} rows instead of {1}", count, records);
        var expectedSum = PerfCampaignConstants.CorePayloadFactor * (long)records * (records + 1) / 2;
        if (checkPayload && sum != expectedSum)
            return string.Format(CultureInfo.InvariantCulture, "sum of PayloadValue is {0}, not {1}", sum, expectedSum);
        return null;
    }

    /// <summary>
    /// Inserts Sequence 1 … rowsTotal (PayloadValue = Sequence·17) into a batch through the cache path, one Save per chunk of C rows,
    /// with RunUntimedParallel over 8 slots and one PerfWorkerGraph per slot (created here, on the coordinating thread).
    /// </summary>
    public static void InsertBatch(PerfScenarioContext context, string batch, string operationType, int iteration, int rowsTotal, int chunkSize,
        Func<int, string> payloadText)
    {
        if (rowsTotal <= 0 || chunkSize <= 0) return;
        var chunks = (rowsTotal + chunkSize - 1) / chunkSize;
        var slots = Math.Max(1, Math.Min(PerfCampaignConstants.CoreParallelWorkers, chunks));
        var graphs = new PerfWorkerGraph[slots];
        for (var i = 0; i < slots; i++) graphs[i] = PXGraph.CreateInstance<PerfWorkerGraph>();

        context.RunUntimedParallel(slots, chunks, (slot, chunk) =>
        {
            var g = graphs[((slot % slots) + slots) % slots];
            var cache = g.Records.Cache;
            CoreChunks.Range(chunk, rowsTotal, chunkSize, out var from, out var to);
            for (var s = from; s <= to; s++)
            {
                cache.Insert(new PerfTestRecord
                {
                    BatchID = batch,
                    OperationType = operationType,
                    Iteration = iteration,
                    Sequence = s,
                    PayloadValue = s * PerfCampaignConstants.CorePayloadFactor,
                    PayloadText = payloadText(s)
                });
            }
            g.Save.Press();
            cache.Clear();
        });
    }

    /// <summary>Set-based delete (untimed only: PXDatabase.Delete reads the matching rows first; review-api m5).</summary>
    public static void DeleteBatch(string batch)
    {
        PXDatabase.Delete<PerfTestRecord>(
            new PXDataFieldRestrict<PerfTestRecord.batchID>(PXDbType.NVarChar, 64, batch, PXComp.EQ));
    }

    /// <summary>Set-based delete with 3 attempts. A failure is recorded in ctx.Notes and left to Cleanup; it never throws (SPEC §4.8 rule 16).</summary>
    public static bool TryDeleteBatch(PerfScenarioContext context, string batch)
    {
        Exception last = null;
        for (var attempt = 1; attempt <= 3; attempt++)
        {
            try
            {
                DeleteBatch(batch);
                return true;
            }
            catch (Exception ex)
            {
                last = ex;
            }
        }
        context.Notes["core.deleteFailed." + batch] = last?.Message ?? "unknown error";
        return false;
    }

    /// <summary>Cleanup: set-based delete of every batch this run created. Tries all of them, then rethrows the first failure.</summary>
    public static void DeleteCreatedBatches(PerfScenarioContext context)
    {
        if (!context.Items.TryGetValue(CoreScenarioBase.CreatedBatchesKey, out var value) || !(value is ConcurrentQueue<string> batches)) return;

        Exception first = null;
        var done = new HashSet<string>(StringComparer.Ordinal);
        foreach (var batch in batches)
        {
            if (string.IsNullOrEmpty(batch) || !done.Add(batch)) continue;
            try { DeleteBatch(batch); }
            catch (Exception ex) { first ??= ex; }
        }
        if (first != null) throw first;
    }

    /// <summary>COUNT(*) of a batch through PXDatabase (the same COUNT shape on every engine; SPEC §0.3 #24).</summary>
    public static int CountBatch(string batch)
    {
        using (PXDataRecord rec = PXDatabase.SelectSingle<PerfTestRecord>(
                   new PXDataField(SQLExpression.Count()),
                   new PXDataFieldValue<PerfTestRecord.batchID>(PXDbType.NVarChar, 64, batch)))
        {
            return rec?.GetInt32(0) ?? 0;
        }
    }

    /// <summary>Rows and Σ PayloadValue of a whole batch, read ReadOnly through BQL.</summary>
    public static void ReadBatchTotals(PXGraph graph, string batch, out long rows, out long sum)
    {
        rows = 0;
        sum = 0;
        foreach (PerfTestRecord r in SelectFrom<PerfTestRecord>
                     .Where<PerfTestRecord.batchID.IsEqual<@P.AsString>>
                     .View.ReadOnly.Select(graph, batch))
        {
            rows++;
            sum += r.PayloadValue ?? 0;
        }
    }

    /// <summary>Rows and Σ PayloadValue of Sequence from … to of a batch, read ReadOnly through BQL.</summary>
    public static void ReadSeedRangeTotals(PXGraph graph, string batch, int from, int to, out long rows, out long sum)
    {
        rows = 0;
        sum = 0;
        if (to < from) return;
        foreach (PerfTestRecord r in SelectFrom<PerfTestRecord>
                     .Where<PerfTestRecord.batchID.IsEqual<@P.AsString>
                         .And<PerfTestRecord.sequence.IsGreaterEqual<@P.AsInt>>
                         .And<PerfTestRecord.sequence.IsLessEqual<@P.AsInt>>>
                     .View.ReadOnly.Select(graph, batch, from, to))
        {
            rows++;
            sum += r.PayloadValue ?? 0;
        }
    }
}
