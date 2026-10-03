using System;
using System.Collections.Generic;
using System.Globalization;
using PX.Data;
using PX.Data.BQL;
using PX.Data.BQL.Fluent;
using PX.Objects.IN;
using PerfDBBenchmark.Core.DAC;

using GLBranch = PX.Objects.GL.Branch;

namespace PerfDBBenchmark.Core.Scenarios.Core;

/// <summary>One row of the availability list as read by Prepare (page order: InventoryID, SiteID).</summary>
internal readonly struct CoreJoinRow
{
    public CoreJoinRow(int? inventoryId, int? siteId, decimal qtyOnHand, decimal qtyAvail)
    {
        InventoryID = inventoryId;
        SiteID = siteId;
        QtyOnHand = qtyOnHand;
        QtyAvail = qtyAvail;
    }

    public int? InventoryID { get; }
    public int? SiteID { get; }
    public decimal QtyOnHand { get; }
    public decimal QtyAvail { get; }
}

/// <summary>
/// CORE_JOIN_FULL / CORE_JOIN_SLIM (SPEC §1.4): 80 pages of 50 per pass (5 sweeps × 16 pages; op k reads page k mod 16 at offset 50·page),
/// ORDER BY InventoryID, SiteID (integers, unique), plus a detail lookup for the first 10 distinct items of each page.
/// </summary>
internal abstract class CoreJoinScenarioBase : CoreScenarioBase
{
    private const string RowsInRange = "750<rows<=800";
    private const int MinRowsExclusive = 750;
    private const int MaxRowsInclusive = 800;

    /// <summary>Expected rows and quantity sums per page (0 … 15), from Prepare's full read. Coordinating thread only.</summary>
    private CorePassTotals[] _pageExpected;

    protected CoreJoinScenarioBase(PerfTestDescriptor descriptor) : base(descriptor) { }

    protected override int FullOpsPerPass(int records, int chunkSize) => JoinPagesPerPass;

    protected override void AddParams(IDictionary<string, object> prms)
    {
        prms["pageSize"] = JoinPageSize;
        prms["pagesPerSweep"] = JoinPagesPerSweep;
        prms["sweeps"] = PerfCampaignConstants.CoreJoinSweepsPerPass;
        prms["lookupsPerPage"] = JoinLookupsPerPage;
    }

    /// <summary>The page query without paging, in page order (Prepare only, untimed).</summary>
    protected abstract List<CoreJoinRow> ReadAll(PXGraph graph);

    public override void Prepare(PerfScenarioContext context)
    {
        // 1. Run the join once without paging (untimed): TotalRows, Σ QtyOnHand, Σ QtyAvail
        //    (pristine SalesDemo: 778 / 715,201.66 / 676,996.88; 783 rows after the first Block C run).
        var rows = ReadAll(context.MainGraph);
        var sumOnHand = 0m;
        var sumAvail = 0m;
        foreach (var r in rows)
        {
            sumOnHand += r.QtyOnHand;
            sumAvail += r.QtyAvail;
        }

        context.Parity["ref.totalRows"] = PerfChecksum.Canonical(rows.Count);
        context.Parity["ref.sumQtyOnHand"] = PerfChecksum.Canonical(sumOnHand);
        context.Parity["ref.sumQtyAvail"] = PerfChecksum.Canonical(sumAvail);

        // 2. 750 < TotalRows <= 800 guarantees that 16 pages of 50 cover all rows.
        var inRange = rows.Count > MinRowsExclusive && rows.Count <= MaxRowsInclusive;
        context.CheckInvariant("joinRowsInRange", RowsInRange, inRange ? RowsInRange : rows.Count.ToString(CultureInfo.InvariantCulture));

        var pages = new CorePassTotals[JoinPagesPerSweep];
        for (var page = 0; page < JoinPagesPerSweep; page++)
        {
            var t = new CorePassTotals();
            var end = Math.Min(rows.Count, (page + 1) * JoinPageSize);
            for (var i = page * JoinPageSize; i < end; i++)
            {
                t.Rows++;
                t.QtyOnHand += rows[i].QtyOnHand;
                t.QtyAvail += rows[i].QtyAvail;
            }
            pages[page] = t;
        }
        _pageExpected = pages;
    }

    protected override void PrepareOperation(PerfWorkerContext worker, CoreWorkerState state, PerfOpInfo op)
    {
        state.Page = op.OpIndex % JoinPagesPerSweep;
        state.LookupIds.Clear();
    }

    /// <summary>Records the first JoinLookupsPerPage distinct InventoryIDs of the page, in page order.</summary>
    protected static void NoteLookupId(CoreWorkerState state, int? inventoryId)
    {
        if (inventoryId is int id && state.LookupIds.Count < JoinLookupsPerPage && !state.LookupIds.Contains(id))
            state.LookupIds.Add(id);
    }

    public override void AfterPass(PerfScenarioContext context, int pass)
    {
        if (_pageExpected == null) return;

        // Expected values cover only the operations this pass executes (plan.OpsPerPass pages; 80 = 5 × TotalRows at full scale).
        var ops = PlanOf(context)?.OpsPerPass ?? 0;
        var expected = new CorePassTotals();
        for (var k = 0; k < ops; k++)
        {
            var p = _pageExpected[k % JoinPagesPerSweep];
            expected.Rows += p.Rows;
            expected.QtyOnHand += p.QtyOnHand;
            expected.QtyAvail += p.QtyAvail;
        }

        var actual = SumPass(context, pass);
        context.CheckInvariant(InvariantName(pass, "rows"), expected.Rows, actual.Rows);
        context.CheckInvariant(InvariantName(pass, "qtyOnHand"), expected.QtyOnHand, actual.QtyOnHand);
        context.CheckInvariant(InvariantName(pass, "qtyAvail"), expected.QtyAvail, actual.QtyAvail);
    }

    public override void Verify(PerfScenarioContext context, PerfRunMetrics metrics)
    {
        context.CheckPassDigestsStable();
    }
}

/// <summary>CORE_JOIN_FULL_1U / CORE_JOIN_FULL_8U: Stock availability list, all columns (5-table join, every column).</summary>
internal sealed class CoreJoinFullScenario : CoreJoinScenarioBase
{
    public CoreJoinFullScenario(PerfTestDescriptor descriptor) : base(descriptor) { }

    protected override List<CoreJoinRow> ReadAll(PXGraph graph)
    {
        var list = new List<CoreJoinRow>(800);
        foreach (PXResult<InventoryItem, INItemClass, INSiteStatus, INSite, GLBranch> r in SelectFrom<InventoryItem>
                     .InnerJoin<INItemClass>.On<INItemClass.itemClassID.IsEqual<InventoryItem.itemClassID>>
                     .LeftJoin<INSiteStatus>.On<INSiteStatus.inventoryID.IsEqual<InventoryItem.inventoryID>>
                     .LeftJoin<INSite>.On<INSite.siteID.IsEqual<INSiteStatus.siteID>>
                     .LeftJoin<GLBranch>.On<GLBranch.branchID.IsEqual<INSite.branchID>>
                     .Where<InventoryItem.stkItem.IsEqual<True>.And<INSite.siteID.IsNotNull>>
                     .OrderBy<InventoryItem.inventoryID.Asc, INSite.siteID.Asc>
                     .View.ReadOnly.Select(graph))
        {
            var item = (InventoryItem)r;
            var status = (INSiteStatus)r;
            var site = (INSite)r;
            list.Add(new CoreJoinRow(item.InventoryID, site.SiteID, status.QtyOnHand ?? 0m, status.QtyAvail ?? 0m));
        }
        return list;
    }

    public override void ExecuteOperation(PerfWorkerContext worker, PerfOpInfo op)
    {
        var state = (CoreWorkerState)worker.State;
        var g = worker.Graph;
        var page = state.Page;
        var rows = 0L;
        var onHand = 0m;
        var avail = 0m;

        // Integer ORDER BY (InventoryID, SiteID; unique, 778/778): no collation dependence (replaces G:739-748, which sorted by CDs).
        foreach (PXResult<InventoryItem, INItemClass, INSiteStatus, INSite, GLBranch> r in SelectFrom<InventoryItem>
                     .InnerJoin<INItemClass>.On<INItemClass.itemClassID.IsEqual<InventoryItem.itemClassID>>
                     .LeftJoin<INSiteStatus>.On<INSiteStatus.inventoryID.IsEqual<InventoryItem.inventoryID>>
                     .LeftJoin<INSite>.On<INSite.siteID.IsEqual<INSiteStatus.siteID>>
                     .LeftJoin<GLBranch>.On<GLBranch.branchID.IsEqual<INSite.branchID>>
                     .Where<InventoryItem.stkItem.IsEqual<True>.And<INSite.siteID.IsNotNull>>
                     .OrderBy<InventoryItem.inventoryID.Asc, INSite.siteID.Asc>
                     .View.ReadOnly.SelectWindowed(g, page * JoinPageSize, JoinPageSize))
        {
            var item = (InventoryItem)r;
            var status = (INSiteStatus)r;
            var site = (INSite)r;
            worker.Checksum.Add(page, item.InventoryID, site.SiteID, status.QtyOnHand, status.QtyAvail);
            rows++;
            onHand += status.QtyOnHand ?? 0m;
            avail += status.QtyAvail ?? 0m;
            NoteLookupId(state, item.InventoryID);
        }

        var lookupRows = 0L;
        foreach (var id in state.LookupIds)
        {
            var n = 0;
            var q = 0m;
            foreach (INSiteStatus s in SelectFrom<INSiteStatus>
                         .Where<INSiteStatus.inventoryID.IsEqual<@P.AsInt>>
                         .View.ReadOnly.SelectWindowed(g, 0, 25, id))
            {
                n++;
                q += (s.QtyOnHand ?? 0m) + (s.QtyAvail ?? 0m);
            }
            worker.Checksum.Add(page, "L", id, n, q);
            lookupRows += n;
        }

        worker.RowsReturned += rows + lookupRows;
        state.Current.Rows += rows;
        state.Current.QtyOnHand += onHand;
        state.Current.QtyAvail += avail;
    }
}

/// <summary>CORE_JOIN_SLIM_1U / CORE_JOIN_SLIM_8U: the same list through the 10-column PerfBenchmarkProjection.</summary>
internal sealed class CoreJoinSlimScenario : CoreJoinScenarioBase
{
    public CoreJoinSlimScenario(PerfTestDescriptor descriptor) : base(descriptor) { }

    protected override List<CoreJoinRow> ReadAll(PXGraph graph)
    {
        var list = new List<CoreJoinRow>(800);
        foreach (PerfBenchmarkProjection r in SelectFrom<PerfBenchmarkProjection>
                     .Where<PerfBenchmarkProjection.siteID.IsNotNull>
                     .OrderBy<PerfBenchmarkProjection.inventoryID.Asc, PerfBenchmarkProjection.siteID.Asc>
                     .View.ReadOnly.Select(graph))
        {
            list.Add(new CoreJoinRow(r.InventoryID, r.SiteID, r.QtyOnHand ?? 0m, r.QtyAvail ?? 0m));
        }
        return list;
    }

    public override void ExecuteOperation(PerfWorkerContext worker, PerfOpInfo op)
    {
        var state = (CoreWorkerState)worker.State;
        var g = worker.Graph;
        var page = state.Page;
        var rows = 0L;
        var onHand = 0m;
        var avail = 0m;

        foreach (PerfBenchmarkProjection r in SelectFrom<PerfBenchmarkProjection>
                     .Where<PerfBenchmarkProjection.siteID.IsNotNull>
                     .OrderBy<PerfBenchmarkProjection.inventoryID.Asc, PerfBenchmarkProjection.siteID.Asc>
                     .View.ReadOnly.SelectWindowed(g, page * JoinPageSize, JoinPageSize))
        {
            worker.Checksum.Add(page, r.InventoryID, r.SiteID, r.QtyOnHand, r.QtyAvail);
            rows++;
            onHand += r.QtyOnHand ?? 0m;
            avail += r.QtyAvail ?? 0m;
            NoteLookupId(state, r.InventoryID);
        }

        var lookupRows = 0L;
        foreach (var id in state.LookupIds)
        {
            var n = 0;
            var q = 0m;
            foreach (PerfBenchmarkProjection s in SelectFrom<PerfBenchmarkProjection>
                         .Where<PerfBenchmarkProjection.inventoryID.IsEqual<@P.AsInt>>
                         .View.ReadOnly.SelectWindowed(g, 0, 20, id))
            {
                n++;
                q += (s.QtyOnHand ?? 0m) + (s.QtyAvail ?? 0m);
            }
            worker.Checksum.Add(page, "L", id, n, q);
            lookupRows += n;
        }

        worker.RowsReturned += rows + lookupRows;
        state.Current.Rows += rows;
        state.Current.QtyOnHand += onHand;
        state.Current.QtyAvail += avail;
    }
}
