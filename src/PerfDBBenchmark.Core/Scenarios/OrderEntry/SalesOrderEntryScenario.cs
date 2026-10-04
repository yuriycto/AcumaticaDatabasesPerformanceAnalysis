using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Threading;
using PX.Data;
using PX.Data.BQL;
using PX.Data.BQL.Fluent;
using PX.Objects.AR;
using PX.Objects.IN;
using PX.Objects.SO;
using PerfDBBenchmark.Core.Scenarios.Business;

namespace PerfDBBenchmark.Core.Scenarios.OrderEntry;

/// <summary>Per-worker state of the ORD family (worker.State). Touched by one thread at a time.</summary>
internal sealed class OrderEntryWorkerState
{
    public SOOrderEntry Graph;
    /// <summary>Order numbers this worker created in the current pass (cleared at the end of AfterPass).</summary>
    public readonly List<string> Created = new List<string>();
    public int CustomerId;
    public int BranchId;
    public int SiteId;
    public int HotItemId;
    /// <summary>ItemPartition[w].</summary>
    public IReadOnlyList<int> Items;
    public int MeasuredOrders;
    public decimal MeasuredOrderTotal;
}

/// <summary>
/// ORD_SO_ENTRY_U01/U04/U08/U16 and ORD_SO_HOTITEM_U04/U08/U16 (SPEC §1.6): every operation enters one 3-line sales order
/// through SOOrderEntry and saves it. Orders are deleted after every pass (untimed, grouped by creator), and the baseline
/// fingerprint (stock availability of the pool items, AR balances of the pool customers) must come back unchanged.
/// </summary>
public sealed class SalesOrderEntryScenario : PerfScenarioBase
{
    public const int LinesPerOrder = 3;
    private const int MaxCleanupSlots = 8;

    private readonly bool _hot;

    // coordinating-thread state (set in Prepare; never read by workers, which use worker.State)
    private int _branchId;
    private int _siteId;
    private int _hotItemId;
    private IReadOnlyList<BusinessPoolMember> _customers;
    private IReadOnlyList<IReadOnlyList<int>> _partitions;
    private HashSet<int> _baselineItems;
    private string _baseline;
    private SOOrderEntry _coordinatorGraph;
    private SOOrderEntry[] _slotGraphs;

    // the session branch replaced in Prepare (PerfBranchContext.Enter), put back at the end of Cleanup
    private bool _branchEntered;
    private int? _branchBeforeRun;

    private double _measuredCleanupMs;
    private int _measuredCleanupOrders;
    private int _parallelFailureCount;
    private int _cleanupFailureCount;
    private string _firstCleanupFailure;
    private int _fallbackDeleted;

    public SalesOrderEntryScenario(PerfTestDescriptor descriptor, bool hotItem) : base(descriptor)
    {
        _hot = hotItem;
    }

    public bool IsHotItemVariant => _hot;

    public override PerfRunPlan CreatePlan(PerfRunRequest request)
    {
        if (Descriptor.Users > PerfBusinessPools.ItemPartitionCount)
            throw new PXException(Descriptor.TestCode + ": at most " + PerfBusinessPools.ItemPartitionCount.ToString(CultureInfo.InvariantCulture) + " workers are supported (one item partition each).");

        var extra = new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["variant"] = _hot ? "hotItem" : "spread",
            ["linesPerOrder"] = LinesPerOrder,
            ["pinnedDocDate"] = PerfCampaignConstants.PinnedDocDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            ["branchCD"] = PerfCampaignConstants.BranchCD,
            ["warehouseCD"] = PerfCampaignConstants.WarehouseCD,
            ["customerPool"] = "Customers20[w]",
            ["itemPool"] = "StockItems613 mod " + PerfBusinessPools.ItemPartitionCount.ToString(CultureInfo.InvariantCulture),
            ["lineFormula"] = "item=ItemPartition[w][(3j+k) mod count]; qty=1+((j+k) mod 3)",
            ["cleanup"] = "deleteAfterEachPass"
        };
        if (_hot) extra["hotItemCD"] = PerfCampaignConstants.HotItemCD;
        return DefaultPlan(request, extraParams: extra);
    }

    public override void Prepare(PerfScenarioContext context)
    {
        var g = context.MainGraph;
        var users = context.Plan?.Users ?? Math.Max(1, Descriptor.Users);

        // 1. pinned IDs
        _branchId = PerfBusinessPools.ResolveBranchId(g);
        _siteId = PerfBusinessPools.ResolveSiteId(g);

        // 1b. the clerk's current branch (PRODWHOLE) before any SOOrderEntry exists: AccessInfo.BranchID/BaseCuryID drive the
        //     order's BranchID, CuryID and CurrencyInfo defaults; worker threads started from this thread inherit it
        _branchBeforeRun = PerfBranchContext.Enter(_branchId);
        _branchEntered = true;
        context.Notes["branchContext"] = PerfCampaignConstants.BranchCD + "; session branch before the run: "
                                         + (_branchBeforeRun?.ToString(CultureInfo.InvariantCulture) ?? "none");

        // 2. pools
        _customers = PerfBusinessPools.LoadCustomers(g);
        var stock = PerfBusinessPools.LoadStockItems(g, _siteId);
        _hotItemId = stock.HotItem.ID;
        _partitions = PerfBusinessPools.BuildItemPartitions(stock.Items);
        if (_customers.Count < users)
            throw new PXException(Descriptor.TestCode + ": the customer pool has " + _customers.Count.ToString(CultureInfo.InvariantCulture) + " customers; " + users.ToString(CultureInfo.InvariantCulture) + " are needed.");
        for (var w = 0; w < users; w++)
        {
            if (_partitions[w].Count < LinesPerOrder)
                throw new PXException(Descriptor.TestCode + ": item partition " + w.ToString(CultureInfo.InvariantCulture) + " has fewer than " + LinesPerOrder.ToString(CultureInfo.InvariantCulture) + " items.");
        }

        context.Set(PerfBusinessPools.BranchIdKey, _branchId);
        context.Set(PerfBusinessPools.SiteIdKey, _siteId);
        context.Set(PerfBusinessPools.HotItemIdKey, _hotItemId);
        context.Set(PerfBusinessPools.CustomersKey, _customers);
        context.Set(PerfBusinessPools.StockItemsKey, stock.Items);
        context.Set(PerfBusinessPools.ItemPartitionsKey, _partitions);
        context.Notes["pool.customers"] = _customers.Count.ToString(CultureInfo.InvariantCulture);
        context.Notes["pool.stockItems"] = stock.Items.Count.ToString(CultureInfo.InvariantCulture);

        // 3. sweep leftovers of earlier runs (any PERFBENCH order), coordinating thread, FreshForWrite before each delete
        var leftovers = BusinessDocuments.ReadPerfBenchOrders(g);
        var removed = 0;
        if (leftovers.Count > 0)
        {
            var failures = new List<string>();
            removed = BusinessDocuments.DeleteSalesOrders(CoordinatorGraph(), leftovers, BusinessDocuments.DeleteRetries, failures);
            if (failures.Count > 0)
                context.Notes["leftoverSweepFailures"] = failures.Count.ToString(CultureInfo.InvariantCulture) + ": " + failures[0];
        }
        context.Notes["leftoversRemoved"] = removed.ToString(CultureInfo.InvariantCulture);

        // 4. baseline fingerprint (pool items + hot item at WHOLESALE; AR balances of Customers20[0…W-1])
        _baselineItems = new HashSet<int>(stock.Items.Select(m => m.ID)) { _hotItemId };
        _baseline = ReadBaseline(g, users);
        context.Set(PerfBusinessPools.BaselineKey, _baseline);
        context.Notes["baseline"] = _baseline;
    }

    public override void CreateWorkerState(PerfWorkerContext worker)
    {
        var w = worker.Index;
        var customers = worker.Run.Get<IReadOnlyList<BusinessPoolMember>>(PerfBusinessPools.CustomersKey);
        var partitions = worker.Run.Get<IReadOnlyList<IReadOnlyList<int>>>(PerfBusinessPools.ItemPartitionsKey);
        if (customers == null || partitions == null) throw new PXException(Descriptor.TestCode + ": the business pools were not loaded.");

        var g = PXGraph.CreateInstance<SOOrderEntry>();
        worker.RegisterGraph(g);
        worker.State = new OrderEntryWorkerState
        {
            Graph = g,
            CustomerId = customers[w].ID,
            BranchId = worker.Run.Get<int>(PerfBusinessPools.BranchIdKey),
            SiteId = worker.Run.Get<int>(PerfBusinessPools.SiteIdKey),
            HotItemId = worker.Run.Get<int>(PerfBusinessPools.HotItemIdKey),
            Items = partitions[w]
        };
    }

    public override void BeforeOperation(PerfWorkerContext worker, PerfOpInfo op)
    {
        var state = (OrderEntryWorkerState)worker.State;
        PerfBranchContext.Ensure(state.BranchId);   // worker thread: before Clear(ClearAll) rebuilds AccessInfo
        state.Graph.Clear(PXClearOption.ClearAll);
    }

    public override void ExecuteOperation(PerfWorkerContext worker, PerfOpInfo op)
    {
        var state = (OrderEntryWorkerState)worker.State;
        var g = state.Graph;
        var w = worker.Index;
        var j = op.WorkerOpIndex;
        var items = state.Items;

        var o = g.Document.Insert(new SOOrder { OrderType = SOOrderTypeConstants.SalesOrder });
        g.Document.Cache.SetValueExt<SOOrder.customerID>(o, state.CustomerId);   // customer before branch
        g.Document.Cache.SetValueExt<SOOrder.branchID>(o, state.BranchId);
        g.Document.Cache.SetValueExt<SOOrder.orderDate>(o, PerfCampaignConstants.PinnedDocDate);
        g.Document.Cache.SetValue<SOOrder.orderDesc>(o, worker.Run.DocumentTag);   // no ctx in ExecuteOperation (review-api C3)
        o = g.Document.Update(o);
        for (var k = 0; k < LinesPerOrder; k++)
        {
            var (itemId, qty) = (_hot && k == 0) ? (state.HotItemId, 1m)
                : (items[(3 * j + k) % items.Count], 1m + ((j + k) % 3));
            var l = g.Transactions.Insert(new SOLine());
            g.Transactions.Cache.SetValueExt<SOLine.inventoryID>(l, itemId);
            g.Transactions.Cache.SetValueExt<SOLine.siteID>(l, state.SiteId);
            g.Transactions.Cache.SetValueExt<SOLine.orderQty>(l, qty);
            g.Transactions.Update(l);
        }
        g.Save.Press();

        var saved = g.Document.Current;
        state.Created.Add(saved.OrderNbr);
        worker.Checksum.Add(w, j, saved.CuryOrderTotal, LinesPerOrder);
        if (!op.IsWarmUp)
        {
            state.MeasuredOrders++;
            state.MeasuredOrderTotal += saved.CuryOrderTotal ?? 0m;
        }
    }

    /// <summary>Untimed, after every measured pass and after the per-worker warm-up operations. Never throws.</summary>
    public override void AfterPass(PerfScenarioContext context, int pass)
    {
        var label = PassLabel(pass);
        var g = context.MainGraph;
        var states = context.Workers.Select(wk => wk.State as OrderEntryWorkerState).ToArray();
        var createdCount = states.Sum(s => s?.Created.Count ?? 0);

        // 1. the run's orders: count and state
        try
        {
            var orders = BusinessDocuments.ReadOrdersByTag(g, context.DocumentTag);
            context.CheckInvariant("orderCount:" + label, createdCount, orders.Count);
            var good = orders.Count(o => o.LineCntr == LinesPerOrder && o.Hold != true && o.CreditHold != true
                                         && string.Equals(o.Status, SOOrderStatus.Open, StringComparison.Ordinal));
            context.CheckInvariant("orderState:" + label, orders.Count, good);
        }
        catch (Exception ex)
        {
            context.CheckInvariant("orderCount:" + label, createdCount, "read failed: " + BusinessDocuments.Describe(ex));
        }

        // 2. delete them, grouped by creator: worker w's orders run sequentially on slot w mod S (review-api M3)
        var failures = new ConcurrentQueue<string>();
        var deleted = 0;
        var sw = Stopwatch.StartNew();
        try
        {
            var workerCount = states.Length;
            var slots = Math.Max(1, Math.Min(MaxCleanupSlots, workerCount));
            EnsureSlotGraphs(slots);
            context.RunUntimedParallel(slots, workerCount, (slot, w) =>
            {
                try
                {
                    var st = states[w];
                    if (st == null || st.Created.Count == 0) return;
                    var sg = _slotGraphs[slot];
                    foreach (var nbr in st.Created.ToArray())
                    {
                        var outcome = BusinessDocuments.DeleteSalesOrder(sg, SOOrderTypeConstants.SalesOrder, nbr, BusinessDocuments.DeleteRetries, out var error);
                        if (outcome == BusinessDeleteOutcome.Deleted) Interlocked.Increment(ref deleted);
                        else if (outcome == BusinessDeleteOutcome.Failed) failures.Enqueue("worker " + w.ToString(CultureInfo.InvariantCulture) + " SO " + nbr + ": " + error);
                    }
                }
                catch (Exception ex)
                {
                    failures.Enqueue("worker " + w.ToString(CultureInfo.InvariantCulture) + ": " + BusinessDocuments.Describe(ex));
                }
            });
        }
        catch (Exception ex)
        {
            failures.Enqueue("parallel cleanup: " + BusinessDocuments.Describe(ex));
        }
        sw.Stop();

        if (!failures.IsEmpty)
        {
            // recovered below by the sequential fallback, or reported as cleanupFailures
            _parallelFailureCount += failures.Count;
            context.Notes["cleanupParallelFailures"] = _parallelFailureCount.ToString(CultureInfo.InvariantCulture);
        }

        // 2b. anything still present: once more, sequentially, on the coordinating thread (FreshForWrite before each delete)
        var finalFailures = new List<string>();
        try
        {
            var remaining = BusinessDocuments.ReadOrdersByTag(g, context.DocumentTag);
            if (remaining.Count > 0)
            {
                var fallback = BusinessDocuments.DeleteSalesOrders(CoordinatorGraph(), remaining, BusinessDocuments.DeleteRetries, finalFailures);
                _fallbackDeleted += fallback;
                context.Notes["cleanupFallbackDeleted"] = _fallbackDeleted.ToString(CultureInfo.InvariantCulture);
            }
        }
        catch (Exception ex)
        {
            finalFailures.Add("sequential cleanup: " + BusinessDocuments.Describe(ex));
        }

        // notes: failures that remain after the fallback, and ms per deleted order
        if (finalFailures.Count > 0)
        {
            _cleanupFailureCount += finalFailures.Count;
            if (_firstCleanupFailure == null)
            {
                var firstParallel = failures.TryPeek(out var p) ? " (parallel step: " + p + ")" : string.Empty;
                _firstCleanupFailure = "pass " + label + ": " + finalFailures[0] + firstParallel;
            }
            context.Notes["cleanupFailures"] = _cleanupFailureCount.ToString(CultureInfo.InvariantCulture) + "; first: " + _firstCleanupFailure;
        }
        var cleanupMs = sw.Elapsed.TotalMilliseconds;
        if (pass >= 0)
        {
            _measuredCleanupMs += cleanupMs;
            _measuredCleanupOrders += deleted;
            if (_measuredCleanupOrders > 0)
                context.Notes["cleanupMsPerOrder"] = Ms(_measuredCleanupMs / _measuredCleanupOrders);
        }
        else if (deleted > 0)
        {
            context.Notes["cleanupMsPerOrder." + label] = Ms(cleanupMs / deleted);
        }

        // 3. nothing of this run may remain
        try
        {
            var left = BusinessDocuments.ReadOrdersByTag(g, context.DocumentTag);
            context.CheckInvariant("leftoverOrders:" + label, 0, left.Count);
        }
        catch (Exception ex)
        {
            context.CheckInvariant("leftoverOrders:" + label, 0, "read failed: " + BusinessDocuments.Describe(ex));
        }

        // 4. the baseline fingerprint must be restored
        try
        {
            if (_baseline != null)
                context.CheckInvariant("baselineRestored:" + label, _baseline, ReadBaseline(g, states.Length));
        }
        catch (Exception ex)
        {
            context.CheckInvariant("baselineRestored:" + label, _baseline, "read failed: " + BusinessDocuments.Describe(ex));
        }

        // 5. next pass starts with empty lists
        foreach (var st in states) st?.Created.Clear();
    }

    public override void Verify(PerfScenarioContext context, PerfRunMetrics metrics)
    {
        var states = context.Workers.Select(wk => wk.State as OrderEntryWorkerState).Where(s => s != null).ToArray();
        var orders = states.Sum(s => s.MeasuredOrders);
        var total = states.Aggregate(0m, (acc, s) => acc + s.MeasuredOrderTotal);
        context.Parity["orders"] = orders.ToString(CultureInfo.InvariantCulture);
        context.Parity["sumOrderTotal"] = PerfChecksum.Canonical(total);
    }

    /// <summary>
    /// Always: removes any order of this run that is still present (coordinating thread, FreshForWrite before each delete),
    /// then puts back the session branch that Prepare replaced.
    /// </summary>
    public override void Cleanup(PerfScenarioContext context)
    {
        try
        {
            var remaining = BusinessDocuments.ReadOrdersByTag(context.MainGraph, context.DocumentTag);
            if (remaining.Count == 0) return;
            var failures = new List<string>();
            var removed = BusinessDocuments.DeleteSalesOrders(CoordinatorGraph(), remaining, BusinessDocuments.DeleteRetries, failures);
            context.Notes["cleanupSweepRemoved"] = removed.ToString(CultureInfo.InvariantCulture);
            if (failures.Count > 0)
                throw new PXException(Descriptor.TestCode + ": " + failures.Count.ToString(CultureInfo.InvariantCulture) + " sales orders of this run could not be deleted. First: " + failures[0]);
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

    // ---------------------------------------------------------------- helpers (untimed)

    /// <summary>
    /// Σ QtySOBooked and Σ QtyAvail of INSiteStatusByCostCenter (WHOLESALE, CostCenterID 0) over the pool items plus the hot item,
    /// and (Σ CurrentBal, Σ TotalOpenOrders) of ARBalances for Customers20[0…W-1] (SPEC §1.6 Prepare step 4).
    /// </summary>
    private string ReadBaseline(PXGraph g, int users)
    {
        g.Clear(PXClearOption.ClearQueriesOnly);

        decimal booked = 0m, avail = 0m;
        foreach (INSiteStatusByCostCenter s in SelectFrom<INSiteStatusByCostCenter>
                     .Where<INSiteStatusByCostCenter.siteID.IsEqual<@P.AsInt>
                         .And<INSiteStatusByCostCenter.costCenterID.IsEqual<@P.AsInt>>>
                     .View.ReadOnly.Select(g, _siteId, 0))
        {
            if (s?.InventoryID is int id && _baselineItems.Contains(id))
            {
                booked += s.QtySOBooked ?? 0m;
                avail += s.QtyAvail ?? 0m;
            }
        }

        var perCustomer = new PerfOrderedChecksum();
        decimal currentBal = 0m, openOrders = 0m;
        var count = Math.Min(Math.Max(1, users), _customers.Count);
        for (var w = 0; w < count; w++)
        {
            decimal cb = 0m, oo = 0m;
            foreach (ARBalances b in SelectFrom<ARBalances>
                         .Where<ARBalances.customerID.IsEqual<@P.AsInt>>
                         .View.ReadOnly.Select(g, _customers[w].ID))
            {
                cb += b?.CurrentBal ?? 0m;
                oo += b?.TotalOpenOrders ?? 0m;
            }
            perCustomer.Add(_customers[w].CD, cb, oo);
            currentBal += cb;
            openOrders += oo;
        }

        return "qtySOBooked=" + PerfChecksum.Canonical(booked)
               + ";qtyAvail=" + PerfChecksum.Canonical(avail)
               + ";arCurrentBal=" + PerfChecksum.Canonical(currentBal)
               + ";arTotalOpenOrders=" + PerfChecksum.Canonical(openOrders)
               + ";arPerCustomer=" + perCustomer;
    }

    private SOOrderEntry CoordinatorGraph() => _coordinatorGraph ??= PXGraph.CreateInstance<SOOrderEntry>();

    /// <summary>One SOOrderEntry per cleanup slot, created once per run on the coordinating thread.</summary>
    private void EnsureSlotGraphs(int slots)
    {
        if (_slotGraphs != null && _slotGraphs.Length >= slots) return;
        var graphs = new SOOrderEntry[slots];
        for (var s = 0; s < slots; s++)
        {
            graphs[s] = _slotGraphs != null && s < _slotGraphs.Length ? _slotGraphs[s] : PXGraph.CreateInstance<SOOrderEntry>();
        }
        _slotGraphs = graphs;
    }

    private static string PassLabel(int pass) =>
        pass == PerfOpInfo.WarmUpOpsPass ? "warmUpOps" : pass.ToString(CultureInfo.InvariantCulture);

    private static string Ms(double value) => Math.Round(value, 3).ToString("0.###", CultureInfo.InvariantCulture);
}
