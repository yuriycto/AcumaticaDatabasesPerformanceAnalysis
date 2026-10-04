using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using PX.Data;
using PX.Data.BQL;
using PX.Data.BQL.Fluent;
using PX.Data.SQLTree;
using PX.Objects.AR;
using PX.Objects.GL;
using PerfDBBenchmark.Core.Scenarios.Business;

namespace PerfDBBenchmark.Core.Scenarios.InvoiceRelease;

/// <summary>Per-worker state of the INV family (worker.State). Touched by one thread at a time.</summary>
internal sealed class InvoiceReleaseWorkerState
{
    public ARInvoiceEntry Graph;
    public int CustomerId;
    public int BranchId;
    /// <summary>Released invoices of this worker over the whole run (warm-up operations included).</summary>
    public int Succeeded;
    public int MeasuredSucceeded;
    public decimal MeasuredAmount;
}

/// <summary>Untimed baseline read in Prepare (SPEC §1.7 Prepare step 3).</summary>
internal sealed class InvoiceReleaseBaseline
{
    public decimal GlPtdDebit;
    public int GlTranCount;
    public int ArTranCount;
    public int ArRegisterCount;

    public override string ToString() =>
        "glPtdDebit(ACTUAL," + PerfCampaignConstants.PinnedFinPeriodID + ")=" + PerfChecksum.Canonical(GlPtdDebit)
        + ";glTran=" + GlTranCount.ToString(CultureInfo.InvariantCulture)
        + ";arTran=" + ArTranCount.ToString(CultureInfo.InvariantCulture)
        + ";arRegister=" + ArRegisterCount.ToString(CultureInfo.InvariantCulture);
}

/// <summary>
/// INV_RELEASE_TO_GL_U01 / _U04 (SPEC §1.7): every operation creates a 350.00 AR invoice without retainage, with two non-stock lines through
/// ARInvoiceEntry and releases it with ReleaseProcess (ARDocumentRelease.ReleaseDoc + AutoPost; never the Release button, never
/// PXLongOperation, never an outer transaction). Released invoices are permanent; Verify checks the exact GL and AR deltas.
/// </summary>
public sealed class InvoiceReleaseScenario : PerfScenarioBase
{
    public const decimal FirstLinePrice = 100.00m;
    public const decimal SecondLinePrice = 250.00m;
    public const decimal InvoiceAmount = FirstLinePrice + SecondLinePrice;   // 350.00
    public const int LinesPerInvoice = 2;
    public const int ExpectedGlLinesPerInvoice = 3;
    private const int MaxReleasedUnpostedListed = 20;

    // coordinating-thread state (never read by workers, which use worker.State and ctx.Items)
    private int _ledgerId;
    private InvoiceReleaseBaseline _baseline;
    private ARInvoiceEntry _coordinatorGraph;
    private int _unreleasedRemoved;
    private int _unreleasedDeleteFailures;
    private string _firstUnreleasedDeleteFailure;

    // the session branch replaced in Prepare (PerfBranchContext.Enter), put back at the end of Cleanup
    private bool _branchEntered;
    private int? _branchBeforeRun;

    public InvoiceReleaseScenario(PerfTestDescriptor descriptor) : base(descriptor) { }

    public override PerfRunPlan CreatePlan(PerfRunRequest request)
    {
        var extra = new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["invoiceAmount"] = InvoiceAmount,
            ["linesPerInvoice"] = LinesPerInvoice,
            ["linePrices"] = "100.00+250.00",
            ["lineFormula"] = "item1=NonStockPool[(2i+37w) mod count]; item2=NonStockPool[(2i+1+37w) mod count]; qty=1; manualDisc=1",
            ["pinnedDocDate"] = PerfCampaignConstants.PinnedDocDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            ["finPeriodID"] = PerfCampaignConstants.PinnedFinPeriodID,
            ["branchCD"] = PerfCampaignConstants.BranchCD,
            ["ledgerCD"] = PerfCampaignConstants.ActualLedgerCD,
            ["customerPool"] = "Customers20[w]",
            ["itemPool"] = "NonStockPool (no kits)",
            ["release"] = "ARInvoiceEntry.ReleaseProcess (AutoPost)",
            ["retainage"] = "off: ARInvoice.retainageApply = false after the header Update",
            ["paymentsByLines"] = "not cleared: ARInvoice.paymentsByLinesAllowed as defaulted from the customer"
        };
        return DefaultPlan(request, extraParams: extra);
    }

    public override void Prepare(PerfScenarioContext context)
    {
        var g = context.MainGraph;
        var users = context.Plan?.Users ?? Math.Max(1, Descriptor.Users);

        // 1. pinned IDs and pools
        var branchId = PerfBusinessPools.ResolveBranchId(g);

        // 1b. the clerk's current branch (PRODWHOLE) before any ARInvoiceEntry exists: AccessInfo.BranchID/BaseCuryID drive the
        //     invoice's BranchID, CuryID and CurrencyInfo defaults and the release graphs; worker threads inherit it
        _branchBeforeRun = PerfBranchContext.Enter(branchId);
        _branchEntered = true;
        context.Notes["branchContext"] = PerfCampaignConstants.BranchCD + "; session branch before the run: "
                                         + (_branchBeforeRun?.ToString(CultureInfo.InvariantCulture) ?? "none");

        _ledgerId = PerfBusinessPools.ResolveLedgerId(g);
        var customers = PerfBusinessPools.LoadCustomers(g);
        var nonStock = PerfBusinessPools.LoadNonStockPool(g);
        if (customers.Count < users)
            throw new PXException(Descriptor.TestCode + ": the customer pool has " + customers.Count.ToString(CultureInfo.InvariantCulture) + " customers; " + users.ToString(CultureInfo.InvariantCulture) + " are needed.");
        if (nonStock.Count < LinesPerInvoice)
            throw new PXException(Descriptor.TestCode + ": the non-stock item pool has " + nonStock.Count.ToString(CultureInfo.InvariantCulture) + " items.");

        context.Set(PerfBusinessPools.BranchIdKey, branchId);
        context.Set(PerfBusinessPools.LedgerIdKey, _ledgerId);
        context.Set(PerfBusinessPools.CustomersKey, customers);
        context.Set(PerfBusinessPools.NonStockPoolKey, (IReadOnlyList<int>)nonStock.Select(m => m.ID).ToArray());
        context.Notes["pool.customers"] = customers.Count.ToString(CultureInfo.InvariantCulture);
        context.Notes["pool.nonStock"] = nonStock.Count.ToString(CultureInfo.InvariantCulture);
        // 1c. per-engine evidence of the flags each worker's customer brings (retainage cleared, pay-by-line kept by decision)
        context.Notes["customersInSlice"] = DescribeCustomerSlice(g, customers, users);

        // 2. sweep unreleased PERFBENCH invoices of earlier runs (coordinating thread, FreshForWrite before each delete)
        var leftovers = BusinessDocuments.ReadUnreleasedPerfBenchInvoices(g);
        var removed = 0;
        if (leftovers.Count > 0)
        {
            var failures = new List<string>();
            removed = BusinessDocuments.DeleteUnreleasedInvoices(CoordinatorGraph(), leftovers, BusinessDocuments.DeleteRetries, failures);
            if (failures.Count > 0)
                context.Notes["leftoverSweepFailures"] = failures.Count.ToString(CultureInfo.InvariantCulture) + ": " + failures[0];
        }
        context.Notes["leftoversRemoved"] = removed.ToString(CultureInfo.InvariantCulture);

        // 3. baseline
        _baseline = ReadBaseline(g);
        context.Set(PerfBusinessPools.BaselineKey, _baseline);
        context.Notes["baseline"] = _baseline.ToString();
    }

    public override void CreateWorkerState(PerfWorkerContext worker)
    {
        var customers = worker.Run.Get<IReadOnlyList<BusinessPoolMember>>(PerfBusinessPools.CustomersKey);
        if (customers == null) throw new PXException(Descriptor.TestCode + ": the business pools were not loaded.");

        var ie = PXGraph.CreateInstance<ARInvoiceEntry>();
        worker.RegisterGraph(ie);
        worker.State = new InvoiceReleaseWorkerState
        {
            Graph = ie,
            CustomerId = customers[worker.Index].ID,
            BranchId = worker.Run.Get<int>(PerfBusinessPools.BranchIdKey)
        };
    }

    public override void BeforeOperation(PerfWorkerContext worker, PerfOpInfo op)
    {
        var state = (InvoiceReleaseWorkerState)worker.State;
        PerfBranchContext.Ensure(state.BranchId);   // worker thread: before Clear(ClearAll) rebuilds AccessInfo
        state.Graph.Clear(PXClearOption.ClearAll);
    }

    public override void ExecuteOperation(PerfWorkerContext worker, PerfOpInfo op)
    {
        var state = (InvoiceReleaseWorkerState)worker.State;
        var ie = state.Graph;
        var w = worker.Index;
        var i = op.WorkerOpIndex;

        var t0 = Stopwatch.GetTimestamp();
        var inv = ie.Document.Insert(new ARInvoice { DocType = ARDocType.Invoice });
        ie.Document.Cache.SetValueExt<ARInvoice.customerID>(inv, state.CustomerId);
        ie.Document.Cache.SetValueExt<ARInvoice.branchID>(inv, state.BranchId);
        ie.Document.Cache.SetValueExt<ARInvoice.docDate>(inv, PerfCampaignConstants.PinnedDocDate);   // period 202606
        ie.Document.Cache.SetValue<ARInvoice.docDesc>(inv, worker.Run.DocumentTag);                    // no ctx in ExecuteOperation (review-api C3)
        inv = ie.Document.Update(inv);
        // v3: no retainage. ARInvoiceEntryRetainage defaults RetainageApply from Customer.RetainageApply (PXFormula on customerID)
        // and each line's RetainagePct from this flag; 6 of Customers20 have 10 % retainage (BNRCONTRAC = worker 2 of U04).
        // Cleared AFTER Update (Update on the same instance replays customerID, whose formula would set it back) and BEFORE the
        // first line (no lines yet, so the FieldVerifying handler asks nothing; the first line insert then refreshes the header
        // snapshot with the flag false). Like manualDisc: every invoice stays 350.00 with 3 GL lines. Unconditional; for
        // customers without retainage it does no database work.
        // Not cleared, by decision: ARInvoice.PaymentsByLinesAllowed. BNRCONTRAC (U04 worker 2) keeps PaymentsByLinesAllowed = 1
        // from the customer, so its invoices take the pay-by-line release path (ARTran line balances maintained): same amounts
        // and GL lines, identical on all engines; disclosed in the SPEC and README.
        ie.Document.Cache.SetValueExt<ARInvoice.retainageApply>(inv, false);
        var pool = worker.Run.Get<IReadOnlyList<int>>(PerfBusinessPools.NonStockPoolKey);           // 72 items, no kits (review-api B2)
        AddLine(ie, pool[(2 * i + 37 * w) % pool.Count], FirstLinePrice);       // qty 1
        AddLine(ie, pool[(2 * i + 1 + 37 * w) % pool.Count], SecondLinePrice);  // qty 1
        ie.Save.Press();
        var t1 = Stopwatch.GetTimestamp();
        worker.RecordPhase("create", PerfStatistics.TicksToMs(t1 - t0));
        ie.ReleaseProcess(new List<ARRegister> { ie.Document.Current });   // ARDocumentRelease.ReleaseDoc + AutoPost; NOT the Release button; no outer transaction
        worker.RecordPhase("releasePost", PerfStatistics.TicksToMs(Stopwatch.GetTimestamp() - t1));
        if (ie.Document.Current?.Released != true) throw new PXException("Invoice was not released.");
        var amount = ie.Document.Current.CuryOrigDocAmt;
        worker.Checksum.Add(w, i, amount);

        state.Succeeded++;
        if (!op.IsWarmUp)
        {
            state.MeasuredSucceeded++;
            state.MeasuredAmount += amount ?? 0m;
        }
    }

    /// <summary>Untimed: deletes this run's unreleased invoices (failed releases) on the coordinating thread. Never throws.</summary>
    public override void AfterPass(PerfScenarioContext context, int pass)
    {
        try
        {
            var unreleased = BusinessDocuments.ReadUnreleasedInvoicesByTag(context.MainGraph, context.DocumentTag);
            if (unreleased.Count > 0)
            {
                var failures = new List<string>();
                _unreleasedRemoved += BusinessDocuments.DeleteUnreleasedInvoices(CoordinatorGraph(), unreleased, BusinessDocuments.DeleteRetries, failures);
                RecordDeleteFailures(context, pass, failures);
            }
        }
        catch (Exception ex)
        {
            RecordDeleteFailures(context, pass, new List<string> { BusinessDocuments.Describe(ex) });
        }
        context.Notes["unreleasedRemoved"] = _unreleasedRemoved.ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>
    /// Cumulative for the run: n = warm-up plus measured successful invoices (SPEC §1.7 Verify). r = tagged invoices whose
    /// release committed but whose GL posting then failed (ARDocumentRelease.ReleaseDoc releases and posts in separate
    /// transactions and throws PXMassProcessException after a failed PostBatchProc): a failed operation (allowed in U04 when it
    /// is contention), so the invoice, its 2 ARTran and its L GLTran rows stay, while GLHistory moves only for posted batches.
    /// </summary>
    public override void Verify(PerfScenarioContext context, PerfRunMetrics metrics)
    {
        var states = context.Workers.Select(wk => wk.State as InvoiceReleaseWorkerState).Where(s => s != null).ToArray();
        var n = states.Sum(s => s.Succeeded);
        var nMeasured = states.Sum(s => s.MeasuredSucceeded);
        var measuredAmount = states.Aggregate(0m, (acc, s) => acc + s.MeasuredAmount);
        var expectedAmount = n * InvoiceAmount;
        var g = context.MainGraph;
        var tag = context.DocumentTag;

        // 1–2. n invoices with this tag: released, open, status Open, GL batch posted; Σ amounts = n × 350.00;
        //      plus r released invoices whose GL batch exists but is not posted (failed operations, see the summary)
        g.Clear(PXClearOption.ClearQueriesOnly);
        var tagged = 0;
        var good = 0;
        var goodAmount = 0m;
        var goodRetainage = 0m;
        var goodPayByLine = 0;
        var goodBatches = new HashSet<string>(StringComparer.Ordinal);
        var releasedUnposted = 0;
        var releasedUnpostedRefs = new List<string>();
        foreach (PXResult<ARInvoice, Batch> r in SelectFrom<ARInvoice>
                     .LeftJoin<Batch>.On<Batch.module.IsEqual<BatchModule.moduleAR>
                         .And<Batch.batchNbr.IsEqual<ARInvoice.batchNbr>>>
                     .Where<ARInvoice.docType.IsEqual<ARDocType.invoice>
                         .And<ARInvoice.docDesc.IsEqual<@P.AsString>>>
                     .View.ReadOnly.Select(g, tag))
        {
            var inv = (ARInvoice)r;
            var batch = (Batch)r;
            if (inv == null || !string.Equals(inv.DocDesc, tag, StringComparison.Ordinal)) continue;
            tagged++;
            if (inv.Released == true && inv.OpenDoc == true && string.Equals(inv.Status, ARDocStatus.Open, StringComparison.Ordinal)
                && batch?.BatchNbr != null && batch.Posted == true)
            {
                good++;
                goodAmount += inv.CuryOrigDocAmt ?? 0m;
                goodRetainage += inv.CuryRetainageTotal ?? 0m;
                if (inv.PaymentsByLinesAllowed == true) goodPayByLine++;
                goodBatches.Add(batch.BatchNbr.TrimEnd());
            }
            else if (inv.Released == true && batch?.BatchNbr != null && batch.Posted != true)
            {
                releasedUnposted++;
                if (releasedUnpostedRefs.Count < MaxReleasedUnpostedListed)
                    releasedUnpostedRefs.Add(inv.RefNbr?.TrimEnd() + "/" + batch.BatchNbr.TrimEnd());
            }
        }
        if (releasedUnposted > 0)
        {
            context.Notes["releasedUnposted"] = releasedUnposted.ToString(CultureInfo.InvariantCulture) + ": "
                + string.Join(",", releasedUnpostedRefs)
                + (releasedUnposted > releasedUnpostedRefs.Count ? ",…+" + (releasedUnposted - releasedUnpostedRefs.Count).ToString(CultureInfo.InvariantCulture) + " more" : "");
        }
        // each released-but-unposted invoice is a failed operation: never more of them than failed operations
        context.CheckInvariant("releasedUnpostedWithinErrors", Math.Min(releasedUnposted, metrics?.ErrorCount ?? 0), releasedUnposted);
        context.CheckInvariant("invoicesTagged", n + releasedUnposted, tagged);
        context.CheckInvariant("invoicesReleasedPosted", n, good);
        // 2a (v3). Σ CuryRetainageTotal of those n = 0: retainage is cleared on every header (names the cause if it ever returns)
        context.CheckInvariant("retainageTotal", 0m, goodRetainage);
        context.CheckInvariant("invoiceAmountSum", expectedAmount, goodAmount);
        // 2b. pay-by-line is left as defaulted (decision): record how many of those n (warm-up included) took that release path.
        //     A note, not a parity key: U04 allows failed (contention) operations, which change n per engine.
        context.Notes["payByLineInvoices"] = goodPayByLine.ToString(CultureInfo.InvariantCulture) + " of "
                                             + good.ToString(CultureInfo.InvariantCulture)
                                             + " released and posted (ARInvoice.PaymentsByLinesAllowed as defaulted, not cleared)";

        // 3. across those batches: Σ Debit = Σ Credit = n × 350.00; L = GL lines per batch
        g.Clear(PXClearOption.ClearQueriesOnly);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var linesPerBatch = new Dictionary<string, int>(StringComparer.Ordinal);
        decimal debit = 0m, credit = 0m;
        foreach (PXResult<GLTran, ARInvoice> r in SelectFrom<GLTran>
                     .InnerJoin<ARInvoice>.On<ARInvoice.batchNbr.IsEqual<GLTran.batchNbr>
                         .And<GLTran.module.IsEqual<BatchModule.moduleAR>>>
                     .Where<ARInvoice.docType.IsEqual<ARDocType.invoice>
                         .And<ARInvoice.docDesc.IsEqual<@P.AsString>>>
                     .View.ReadOnly.Select(g, tag))
        {
            var t = (GLTran)r;
            var bn = t?.BatchNbr?.TrimEnd();
            if (bn == null || !goodBatches.Contains(bn)) continue;
            if (!seen.Add(bn + "|" + (t.LineNbr ?? 0).ToString(CultureInfo.InvariantCulture))) continue;
            debit += t.DebitAmt ?? 0m;
            credit += t.CreditAmt ?? 0m;
            linesPerBatch[bn] = (linesPerBatch.TryGetValue(bn, out var c) ? c : 0) + 1;
        }
        context.CheckInvariant("glDebitSum", expectedAmount, debit);
        context.CheckInvariant("glCreditSum", expectedAmount, credit);
        var linesPerInvoice = GlLinesPerInvoice(linesPerBatch, context);

        // 4–6. deltas against the Prepare baseline (GLHistory: posted batches only; ARTran and GLTran: also the r unposted)
        var now = ReadBaseline(g);
        var before = _baseline ?? throw new PXException(Descriptor.TestCode + ": the baseline was not read in Prepare.");
        context.CheckInvariant("glHistoryPtdDebitDelta", expectedAmount, now.GlPtdDebit - before.GlPtdDebit);
        context.CheckInvariant("arTranDelta", LinesPerInvoice * (n + releasedUnposted), now.ArTranCount - before.ArTranCount);
        context.CheckInvariant("glTranDelta", linesPerInvoice * (n + releasedUnposted), now.GlTranCount - before.GlTranCount);
        context.Notes["arRegisterDelta"] = (now.ArRegisterCount - before.ArRegisterCount).ToString(CultureInfo.InvariantCulture);
        context.Notes["invoicesInclWarmUp"] = n.ToString(CultureInfo.InvariantCulture);

        // parity (compared across engines; for U04 only when ErrorCount = 0 everywhere)
        context.Parity["invoices"] = nMeasured.ToString(CultureInfo.InvariantCulture);
        context.Parity["sumInvoiceAmount"] = PerfChecksum.Canonical(measuredAmount);
        context.Parity["glLinesPerInvoice"] = linesPerInvoice.ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>
    /// Always: deletes any unreleased invoice of this run (released invoices are permanent by design), then puts back the
    /// session branch that Prepare replaced.
    /// </summary>
    public override void Cleanup(PerfScenarioContext context)
    {
        try
        {
            var unreleased = BusinessDocuments.ReadUnreleasedInvoicesByTag(context.MainGraph, context.DocumentTag);
            if (unreleased.Count == 0) return;
            var failures = new List<string>();
            var removed = BusinessDocuments.DeleteUnreleasedInvoices(CoordinatorGraph(), unreleased, BusinessDocuments.DeleteRetries, failures);
            _unreleasedRemoved += removed;
            context.Notes["unreleasedRemoved"] = _unreleasedRemoved.ToString(CultureInfo.InvariantCulture);
            if (failures.Count > 0)
                throw new PXException(Descriptor.TestCode + ": " + failures.Count.ToString(CultureInfo.InvariantCulture) + " unreleased invoices of this run could not be deleted. First: " + failures[0]);
        }
        finally
        {
            if (_branchEntered)
            {
                _branchEntered = false;
                PerfBranchContext.Restore(_branchBeforeRun);
            }
        }
    }

    // ---------------------------------------------------------------- helpers

    /// <summary>Inserts an ARTran: inventoryID, qty 1, curyUnitPrice and manualDisc = true (review-api m1), then Update. Timed (inside ExecuteOperation).</summary>
    private static void AddLine(ARInvoiceEntry ie, int inventoryId, decimal unitPrice)
    {
        var t = ie.Transactions.Insert(new ARTran());
        ie.Transactions.Cache.SetValueExt<ARTran.inventoryID>(t, inventoryId);
        ie.Transactions.Cache.SetValueExt<ARTran.qty>(t, 1m);
        ie.Transactions.Cache.SetValueExt<ARTran.curyUnitPrice>(t, unitPrice);
        ie.Transactions.Cache.SetValueExt<ARTran.manualDisc>(t, true);
        ie.Transactions.Update(t);
    }

    /// <summary>
    /// Untimed (Prepare), never throws: "w0 AACUSTOMER r0/p0; ...; w2 BNRCONTRAC r1/p1; ..." for Customers20[w], w &lt; users, where
    /// r = Customer.RetainageApply (cleared on every invoice header) and p = Customer.PaymentsByLinesAllowed (kept, by decision),
    /// plus the Retainage and Pay by Line feature switches. ARInvoiceEntry defaults ARInvoice.PaymentsByLinesAllowed to
    /// "feature on and p = 1". One read of 1-4 Customer rows on the coordinating thread, the same on every engine.
    /// </summary>
    private static string DescribeCustomerSlice(PXGraph g, IReadOnlyList<BusinessPoolMember> customers, int users)
    {
        try
        {
            var parts = new List<string>();
            var count = Math.Min(users, customers.Count);
            for (var w = 0; w < count; w++)
            {
                var member = customers[w];
                Customer c = SelectFrom<Customer>
                    .Where<Customer.bAccountID.IsEqual<@P.AsInt>>
                    .View.ReadOnly.Select(g, member.ID);
                parts.Add("w" + w.ToString(CultureInfo.InvariantCulture) + " " + member.CD + " "
                          + (c == null ? "not found" : "r" + Flag(c.RetainageApply) + "/p" + Flag(c.PaymentsByLinesAllowed)));
            }

            return string.Join("; ", parts)
                   + " (r = Customer.RetainageApply, cleared on every invoice; p = Customer.PaymentsByLinesAllowed, kept; features: retainage="
                   + Flag(PXAccess.FeatureInstalled<PX.Objects.CS.FeaturesSet.retainage>())
                   + ", paymentsByLines=" + Flag(PXAccess.FeatureInstalled<PX.Objects.CS.FeaturesSet.paymentsByLines>()) + ")";
        }
        catch (Exception ex)
        {
            return "error: " + BusinessDocuments.Describe(ex);
        }
    }

    private static string Flag(bool? value) => value == null ? "?" : value.Value ? "1" : "0";

    /// <summary>Untimed: Σ FinPtdDebit of GLHistory (ACTUAL, 202606, all accounts) and the GLTran / ARTran / ARRegister row counts.</summary>
    private InvoiceReleaseBaseline ReadBaseline(PXGraph g)
    {
        g.Clear(PXClearOption.ClearQueriesOnly);
        var ptdDebit = 0m;
        foreach (GLHistory h in SelectFrom<GLHistory>
                     .Where<GLHistory.ledgerID.IsEqual<@P.AsInt>
                         .And<GLHistory.finPeriodID.IsEqual<@P.AsString>>>
                     .View.ReadOnly.Select(g, _ledgerId, PerfCampaignConstants.PinnedFinPeriodID))
        {
            ptdDebit += h?.FinPtdDebit ?? 0m;
        }

        return new InvoiceReleaseBaseline
        {
            GlPtdDebit = ptdDebit,
            GlTranCount = CountGLTran(),
            ArTranCount = CountARTran(),
            ArRegisterCount = CountARRegister()
        };
    }

    private static int CountGLTran()
    {
        using (PXDataRecord rec = PXDatabase.SelectSingle<GLTran>(new PXDataField(SQLExpression.Count())))
            return rec?.GetInt32(0) ?? 0;
    }

    private static int CountARTran()
    {
        using (PXDataRecord rec = PXDatabase.SelectSingle<ARTran>(new PXDataField(SQLExpression.Count())))
            return rec?.GetInt32(0) ?? 0;
    }

    private static int CountARRegister()
    {
        using (PXDataRecord rec = PXDatabase.SelectSingle<ARRegister>(new PXDataField(SQLExpression.Count())))
            return rec?.GetInt32(0) ?? 0;
    }

    /// <summary>L = GL lines per batch observed in this run (expected 3). Mixed counts take the most frequent value and are noted.</summary>
    private static int GlLinesPerInvoice(Dictionary<string, int> linesPerBatch, PerfScenarioContext context)
    {
        if (linesPerBatch.Count == 0) return 0;
        var groups = linesPerBatch.Values
            .GroupBy(v => v)
            .OrderByDescending(gr => gr.Count())
            .ThenBy(gr => gr.Key)
            .ToArray();
        if (groups.Length > 1)
        {
            context.Notes["glLinesPerInvoiceMixed"] = string.Join(",", groups
                .OrderBy(gr => gr.Key)
                .Select(gr => gr.Key.ToString(CultureInfo.InvariantCulture) + " lines x" + gr.Count().ToString(CultureInfo.InvariantCulture)));
        }
        var l = groups[0].Key;
        if (l != ExpectedGlLinesPerInvoice)
            context.Notes["glLinesPerInvoiceUnexpected"] = "expected " + ExpectedGlLinesPerInvoice.ToString(CultureInfo.InvariantCulture) + ", observed " + l.ToString(CultureInfo.InvariantCulture);
        return l;
    }

    private void RecordDeleteFailures(PerfScenarioContext context, int pass, List<string> failures)
    {
        if (failures == null || failures.Count == 0) return;
        _unreleasedDeleteFailures += failures.Count;
        if (_firstUnreleasedDeleteFailure == null)
            _firstUnreleasedDeleteFailure = "pass " + (pass == PerfOpInfo.WarmUpOpsPass ? "warmUpOps" : pass.ToString(CultureInfo.InvariantCulture)) + ": " + failures[0];
        context.Notes["unreleasedDeleteFailures"] = _unreleasedDeleteFailures.ToString(CultureInfo.InvariantCulture) + "; first: " + _firstUnreleasedDeleteFailure;
    }

    private ARInvoiceEntry CoordinatorGraph() => _coordinatorGraph ??= PXGraph.CreateInstance<ARInvoiceEntry>();
}
