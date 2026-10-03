using System;
using System.Collections.Generic;
using System.Linq;
using PX.Data;
using PX.Data.BQL;
using PX.Data.BQL.Fluent;
using PX.Objects.AR;
using PX.Objects.CR;
using PX.Objects.CS;
using PX.Objects.GL;
using PX.Objects.IN;

namespace PerfDBBenchmark.Core.Scenarios.Business;

/// <summary>One pool member: the database ID and the trimmed code (CD). Immutable.</summary>
public sealed class BusinessPoolMember
{
    public BusinessPoolMember(int id, string cd)
    {
        ID = id;
        CD = (cd ?? string.Empty).TrimEnd();
    }

    public int ID { get; }
    public string CD { get; }

    public override string ToString() => CD + "#" + ID.ToString(System.Globalization.CultureInfo.InvariantCulture);
}

/// <summary>The stock-item pool of the order-entry family (SPEC §1.3.8): StockItems613 without the hot item, plus the hot item.</summary>
public sealed class BusinessStockPool
{
    public BusinessStockPool(IReadOnlyList<BusinessPoolMember> items, BusinessPoolMember hotItem)
    {
        Items = items ?? throw new ArgumentNullException(nameof(items));
        HotItem = hotItem ?? throw new ArgumentNullException(nameof(hotItem));
    }

    /// <summary>StockItems613: ordinal by InventoryCD, the hot item excluded.</summary>
    public IReadOnlyList<BusinessPoolMember> Items { get; }

    /// <summary>HotItem: AACOMPUT01 (sold at WHOLESALE).</summary>
    public BusinessPoolMember HotItem { get; }
}

/// <summary>
/// Deterministic data pools of the business families (ORD and INV; SPEC §1.3.8). Read untimed in Prepare.
/// Every pool is read without a text ORDER BY, trimmed with TrimEnd() and sorted in C# with StringComparer.Ordinal.
/// Codes (CD) are matched in C# after TrimEnd(), because CD columns are stored padded with trailing spaces
/// and engines compare trailing spaces differently.
/// </summary>
public static class PerfBusinessPools
{
    /// <summary>ItemPartition[w] = StockItems613[i] where i mod 16 = w (w = 0…15).</summary>
    public const int ItemPartitionCount = 16;

    // ctx.Items keys shared by the business scenarios
    public const string BranchIdKey = "branchId";
    public const string SiteIdKey = "siteId";
    public const string LedgerIdKey = "ledgerId";
    public const string HotItemIdKey = "hotItemId";
    public const string CustomersKey = "customers20";
    public const string StockItemsKey = "stockItems613";
    public const string ItemPartitionsKey = "itemPartitions";
    public const string NonStockPoolKey = "nonStockPool";
    public const string BaselineKey = "baseline";

    /// <summary>BranchID of PerfCampaignConstants.BranchCD (PRODWHOLE).</summary>
    public static int ResolveBranchId(PXGraph graph)
    {
        if (graph == null) throw new ArgumentNullException(nameof(graph));
        foreach (Branch b in SelectFrom<Branch>.View.ReadOnly.Select(graph))
        {
            if (b?.BranchID != null && CodeEquals(b.BranchCD, PerfCampaignConstants.BranchCD)) return b.BranchID.Value;
        }
        throw new PXException("Branch " + PerfCampaignConstants.BranchCD + " was not found.");
    }

    /// <summary>SiteID of PerfCampaignConstants.WarehouseCD (WHOLESALE).</summary>
    public static int ResolveSiteId(PXGraph graph)
    {
        if (graph == null) throw new ArgumentNullException(nameof(graph));
        foreach (INSite s in SelectFrom<INSite>.View.ReadOnly.Select(graph))
        {
            if (s?.SiteID != null && CodeEquals(s.SiteCD, PerfCampaignConstants.WarehouseCD)) return s.SiteID.Value;
        }
        throw new PXException("Warehouse " + PerfCampaignConstants.WarehouseCD + " was not found.");
    }

    /// <summary>LedgerID of PerfCampaignConstants.ActualLedgerCD (ACTUAL).</summary>
    public static int ResolveLedgerId(PXGraph graph)
    {
        if (graph == null) throw new ArgumentNullException(nameof(graph));
        foreach (Ledger l in SelectFrom<Ledger>.View.ReadOnly.Select(graph))
        {
            if (l?.LedgerID != null && CodeEquals(l.LedgerCD, PerfCampaignConstants.ActualLedgerCD)) return l.LedgerID.Value;
        }
        throw new PXException("Ledger " + PerfCampaignConstants.ActualLedgerCD + " was not found.");
    }

    /// <summary>
    /// Customers20: Customer Status A, CreditRule N, CuryID USD; default Location with CTaxZoneID NULL and CBranchID NULL;
    /// ordinal by AcctCD (SPEC §1.3.8; 20 customers in SalesDemo, first AACUSTOMER).
    /// </summary>
    public static IReadOnlyList<BusinessPoolMember> LoadCustomers(PXGraph graph)
    {
        if (graph == null) throw new ArgumentNullException(nameof(graph));
        var rows = new List<BusinessPoolMember>();
        foreach (PXResult<Customer, Location> r in SelectFrom<Customer>
                     .InnerJoin<Location>.On<Location.bAccountID.IsEqual<Customer.bAccountID>
                         .And<Location.locationID.IsEqual<Customer.defLocationID>>>
                     .Where<Customer.status.IsEqual<CustomerStatus.active>
                         .And<Customer.creditRule.IsEqual<@P.AsString>>
                         .And<Customer.curyID.IsEqual<@P.AsString>>
                         .And<Location.cTaxZoneID.IsNull>
                         .And<Location.cBranchID.IsNull>>
                     .View.ReadOnly.Select(graph, CreditRuleTypes.CS_NO_CHECKING, "USD"))
        {
            var c = (Customer)r;
            if (c?.BAccountID != null) rows.Add(new BusinessPoolMember(c.BAccountID.Value, c.AcctCD));
        }
        return Ordinal(rows);
    }

    /// <summary>
    /// StockItems613 and HotItem: active stock items, not a kit, LotSerTrack not numbered, BaseUnit = SalesUnit,
    /// with an INItemSite at WHOLESALE, ordinal by InventoryCD; the hot item AACOMPUT01 is taken out of the pool (SPEC §1.3.8).
    /// </summary>
    public static BusinessStockPool LoadStockItems(PXGraph graph, int siteId)
    {
        if (graph == null) throw new ArgumentNullException(nameof(graph));
        var rows = new List<BusinessPoolMember>();
        foreach (PXResult<InventoryItem, INLotSerClass, INItemSite> r in SelectFrom<InventoryItem>
                     .InnerJoin<INLotSerClass>.On<INLotSerClass.lotSerClassID.IsEqual<InventoryItem.lotSerClassID>>
                     .InnerJoin<INItemSite>.On<INItemSite.inventoryID.IsEqual<InventoryItem.inventoryID>
                         .And<INItemSite.siteID.IsEqual<@P.AsInt>>>
                     .Where<InventoryItem.stkItem.IsEqual<True>
                         .And<InventoryItem.kitItem.IsEqual<False>>
                         .And<InventoryItem.itemStatus.IsEqual<InventoryItemStatus.active>>
                         .And<INLotSerClass.lotSerTrack.IsEqual<INLotSerTrack.notNumbered>>
                         .And<InventoryItem.baseUnit.IsEqual<InventoryItem.salesUnit>>>
                     .View.ReadOnly.Select(graph, siteId))
        {
            var i = (InventoryItem)r;
            if (i?.InventoryID != null) rows.Add(new BusinessPoolMember(i.InventoryID.Value, i.InventoryCD));
        }

        var all = Ordinal(rows);
        var hot = all.FirstOrDefault(m => CodeEquals(m.CD, PerfCampaignConstants.HotItemCD)) ?? ResolveInventoryItem(graph, PerfCampaignConstants.HotItemCD);
        var pool = all.Where(m => m.ID != hot.ID).ToArray();
        return new BusinessStockPool(pool, hot);
    }

    /// <summary>ItemPartition[w] = StockItems613[i] where i mod 16 = w; disjoint for w = 0…15 (38–39 items each).</summary>
    public static IReadOnlyList<IReadOnlyList<int>> BuildItemPartitions(IReadOnlyList<BusinessPoolMember> stockItems)
    {
        if (stockItems == null) throw new ArgumentNullException(nameof(stockItems));
        var parts = new List<int>[ItemPartitionCount];
        for (var w = 0; w < ItemPartitionCount; w++) parts[w] = new List<int>();
        for (var i = 0; i < stockItems.Count; i++) parts[i % ItemPartitionCount].Add(stockItems[i].ID);
        return parts.Select(p => (IReadOnlyList<int>)p.ToArray()).ToArray();
    }

    /// <summary>
    /// NonStockPool: InventoryItem StkItem 0, KitItem 0, ItemType N, DeferredCode NULL, ItemStatus AC, SalesAcctID NOT NULL,
    /// ordinal by InventoryCD (72 items, first COMPHDW). Non-stock kits are excluded because AR invoices reject them (review-api B2).
    /// </summary>
    public static IReadOnlyList<BusinessPoolMember> LoadNonStockPool(PXGraph graph)
    {
        if (graph == null) throw new ArgumentNullException(nameof(graph));
        var rows = new List<BusinessPoolMember>();
        foreach (InventoryItem i in SelectFrom<InventoryItem>
                     .Where<InventoryItem.stkItem.IsEqual<False>
                         .And<InventoryItem.kitItem.IsEqual<False>>
                         .And<InventoryItem.itemType.IsEqual<INItemTypes.nonStockItem>>
                         .And<InventoryItem.deferredCode.IsNull>
                         .And<InventoryItem.itemStatus.IsEqual<InventoryItemStatus.active>>
                         .And<InventoryItem.salesAcctID.IsNotNull>>
                     .View.ReadOnly.Select(graph))
        {
            if (i?.InventoryID != null) rows.Add(new BusinessPoolMember(i.InventoryID.Value, i.InventoryCD));
        }
        return Ordinal(rows);
    }

    /// <summary>Distinct by ID, sorted ordinally by the trimmed CD, then by ID (SPEC §1.3.6).</summary>
    public static IReadOnlyList<BusinessPoolMember> Ordinal(IEnumerable<BusinessPoolMember> members)
    {
        var seen = new HashSet<int>();
        var list = new List<BusinessPoolMember>();
        foreach (var m in members ?? Enumerable.Empty<BusinessPoolMember>())
        {
            if (m != null && seen.Add(m.ID)) list.Add(m);
        }
        return list
            .OrderBy(m => m.CD, StringComparer.Ordinal)
            .ThenBy(m => m.ID)
            .ToArray();
    }

    /// <summary>Ordinal comparison of two codes after TrimEnd().</summary>
    public static bool CodeEquals(string a, string b) =>
        string.Equals((a ?? string.Empty).TrimEnd(), (b ?? string.Empty).TrimEnd(), StringComparison.Ordinal);

    private static BusinessPoolMember ResolveInventoryItem(PXGraph graph, string inventoryCD)
    {
        foreach (InventoryItem i in SelectFrom<InventoryItem>
                     .Where<InventoryItem.inventoryCD.StartsWith<@P.AsString>>
                     .View.ReadOnly.Select(graph, inventoryCD))
        {
            if (i?.InventoryID != null && CodeEquals(i.InventoryCD, inventoryCD)) return new BusinessPoolMember(i.InventoryID.Value, i.InventoryCD);
        }
        throw new PXException("Inventory item " + inventoryCD + " was not found.");
    }
}

/// <summary>
/// Master-data fingerprint of the business pools (ENV_CAPTURE, SPEC §1.8): PerfDeterministic.PairsFingerprint over the (ID, CD)
/// pairs of Customers20, StockItems613, HotItem and NonStockPool. Each CD is prefixed with its pool name so that a member moving
/// between pools changes the hash. Read-only and deterministic.
/// </summary>
public sealed class BusinessPoolsFingerprint : IPerfFingerprintContributor
{
    public string Name => "business-pools";

    public string Compute(PXGraph graph)
    {
        try
        {
            var siteId = PerfBusinessPools.ResolveSiteId(graph);
            var customers = PerfBusinessPools.LoadCustomers(graph);
            var stock = PerfBusinessPools.LoadStockItems(graph, siteId);
            var nonStock = PerfBusinessPools.LoadNonStockPool(graph);

            var pairs = new List<KeyValuePair<int, string>>();
            foreach (var m in customers) pairs.Add(new KeyValuePair<int, string>(m.ID, "customers20/" + m.CD));
            foreach (var m in stock.Items) pairs.Add(new KeyValuePair<int, string>(m.ID, "stockItems613/" + m.CD));
            pairs.Add(new KeyValuePair<int, string>(stock.HotItem.ID, "hotItem/" + stock.HotItem.CD));
            foreach (var m in nonStock) pairs.Add(new KeyValuePair<int, string>(m.ID, "nonStockPool/" + m.CD));
            return PerfDeterministic.PairsFingerprint(pairs);
        }
        catch (Exception ex)
        {
            // Never throw out of ENV_CAPTURE; an unreadable pool makes the fingerprint differ from a healthy instance.
            return "error:" + ex.GetType().Name + ":" + ex.Message;
        }
    }
}
