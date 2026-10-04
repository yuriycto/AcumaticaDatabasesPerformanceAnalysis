using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using PX.Data;
using PX.Data.BQL;
using PX.Data.BQL.Fluent;
using PX.Data.SQLTree;
using PX.Objects.AR;
using PX.Objects.CR;
using PX.Objects.IN;
using PX.Objects.SO;

namespace PerfDBBenchmark.Core.Scenarios.Screens;

// SPEC §1.5 (cards 1-4), §1.3 (shared rules), §4.8 (coding rules).
// Every Screens and Reports test runs with W = 1: operations run inline on the long-operation thread, the engine clears the
// query cache of every registered graph before each operation (untimed) and times ExecuteOperation only.
// RowsReturned counts the list rows each card calls "rows returned" (top-N rows, detail lines, groups, hits, page rows);
// counts and aggregate totals are not rows. SCR_OPEN_SALES_ORDER counts the rows of all 12 form views.

/// <summary>
/// Per-worker tallies of the current pass, used only to write the catalog reference values (<c>ref.*</c> parity keys, SPEC §1.3.7
/// layer 2). Values are committed at the end of a successful operation, so a failed operation leaves no partial tally.
/// Scenarios never touch the engine-owned checksums; the engine replaces them before every pass.
/// </summary>
internal class ReadPassState
{
    private readonly SortedDictionary<string, decimal> _values = new SortedDictionary<string, decimal>(StringComparer.Ordinal);
    private readonly SortedDictionary<string, string> _texts = new SortedDictionary<string, string>(StringComparer.Ordinal);

    /// <summary>Operations of the current pass that completed without an exception.</summary>
    public int PassOkOps { get; private set; }

    /// <summary>Adds to a per-pass sum.</summary>
    public void Add(string key, decimal amount)
    {
        _values.TryGetValue(key, out var current);
        _values[key] = current + amount;
    }

    /// <summary>Sets a per-pass value (used when the same request repeats inside a pass).</summary>
    public void Set(string key, decimal value) => _values[key] = value;

    public void SetText(string key, string value) => _texts[key] = (value ?? string.Empty).TrimEnd();

    public void CompleteOp() => PassOkOps++;

    public void ResetPass()
    {
        _values.Clear();
        _texts.Clear();
        PassOkOps = 0;
    }

    /// <summary>Canonical values (PerfChecksum.Canonical) keyed by name, ordinal order.</summary>
    public SortedDictionary<string, string> Snapshot()
    {
        var result = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var kv in _values) result[kv.Key] = PerfChecksum.Canonical(kv.Value);
        foreach (var kv in _texts) result[kv.Key] = kv.Value;
        return result;
    }
}

/// <summary>
/// Shared lifecycle of the read-only Screens and Reports scenarios (W = 1, nothing to clean up):
/// <list type="bullet">
/// <item>the plan is the descriptor default plus the scenario's descriptive parameters (part of ParamsHash);</item>
/// <item>the per-pass tally is reset in BeforePass;</item>
/// <item>the <c>ref.*</c> parity values come from the first measured pass that completed every operation (fallback: a complete
/// warm-up pass, which returns the same data because every pass digest must be equal);</item>
/// <item>Verify always calls <c>ctx.CheckPassDigestsStable()</c> (SPEC §1.5 common rules, §4.8 rule 18).</item>
/// </list>
/// </summary>
internal abstract class ReadScenarioBase<TState> : PerfScenarioBase where TState : ReadPassState
{
    private const string RefWrittenKey = "read.refWritten";
    private const string RefWarmUpKey = "read.refWarmUpSnapshot";

    protected ReadScenarioBase(PerfTestDescriptor descriptor) : base(descriptor) { }

    /// <summary>Descriptive, engine-independent parameters added to PerfRunPlan.Params (hashed into ParamsHash).</summary>
    protected virtual IDictionary<string, object> PlanParams() => null;

    public override PerfRunPlan CreatePlan(PerfRunRequest request) => DefaultPlan(request, extraParams: PlanParams());

    /// <summary>Creates the worker state (untimed, coordinating thread, after Prepare). Business graphs are registered here.</summary>
    protected abstract TState CreateState(PerfWorkerContext worker);

    public override void CreateWorkerState(PerfWorkerContext worker) => worker.State = CreateState(worker);

    public override void BeforePass(PerfScenarioContext context, int pass)
    {
        foreach (var worker in context.Workers) (worker.State as TState)?.ResetPass();
    }

    public override void AfterPass(PerfScenarioContext context, int pass)
    {
        if (pass == PerfOpInfo.WarmUpOpsPass || context.Items.ContainsKey(RefWrittenKey) || context.Workers.Count == 0) return;
        var state = context.Workers[0].State as TState;
        var opsPerPass = context.Plan?.OpsPerPass ?? 0;
        if (state == null || opsPerPass <= 0 || state.PassOkOps < opsPerPass) return;

        var snapshot = state.Snapshot();
        if (pass >= 0) WriteReferenceValues(context, snapshot, pass);
        else context.Items.TryAdd(RefWarmUpKey, new KeyValuePair<int, SortedDictionary<string, string>>(pass, snapshot));
    }

    public override void Verify(PerfScenarioContext context, PerfRunMetrics metrics)
    {
        context.CheckPassDigestsStable();

        if (!context.Items.ContainsKey(RefWrittenKey))
        {
            if (context.Items.TryGetValue(RefWarmUpKey, out var stored) && stored is KeyValuePair<int, SortedDictionary<string, string>> warm)
                WriteReferenceValues(context, warm.Value, warm.Key);
            else
                context.Notes["refValues"] = "not written: no pass completed every operation";
        }

        VerifyMore(context, metrics);
    }

    /// <summary>Scenario-specific untimed work at the end of the run (notes, informational probes).</summary>
    protected virtual void VerifyMore(PerfScenarioContext context, PerfRunMetrics metrics) { }

    private static void WriteReferenceValues(PerfScenarioContext context, SortedDictionary<string, string> snapshot, int pass)
    {
        foreach (var kv in snapshot) context.Parity["ref." + kv.Key] = kv.Value;
        context.Notes["refPass"] = pass.ToString(CultureInfo.InvariantCulture);
        context.Notes["refOpsPerPass"] = (context.Plan?.OpsPerPass ?? 0).ToString(CultureInfo.InvariantCulture);
        context.Set(RefWrittenKey, true);
    }

    /// <summary>Pool entry for an operation; the modulo keeps a short pool (or a scaled plan) safe.</summary>
    protected static T PoolItem<T>(IReadOnlyList<T> pool, PerfOpInfo op) => pool[op.OpIndex % pool.Count];

    protected static void RequireNonEmpty<T>(IReadOnlyCollection<T> pool, string poolName)
    {
        if (pool == null || pool.Count == 0)
            throw new PXException("The " + poolName + " pool is empty; the SalesDemo data this test needs is missing.");
    }

    protected static string Invariant(int value) => value.ToString(CultureInfo.InvariantCulture);
}

/// <summary>
/// Data pools of the Screens family (SPEC §1.3.8). Read untimed in Prepare; trimmed with TrimEnd() and sorted in C# with
/// StringComparer.Ordinal (never a database ORDER BY on text, never Random). Shared with ReadPoolsFingerprint.
/// </summary>
internal static class ScreenPools
{
    internal const int SoSampleStep = 14;
    internal const int SoSampleCount = 500;

    /// <summary>SoSample500: SOOrder OrderType 'SO', ordinal by OrderNbr, every 14th, 500 orders (first 000001, last SO009039).</summary>
    internal static List<string> LoadSoSample500()
    {
        var numbers = new List<string>();
        foreach (PXDataRecord rec in PXDatabase.SelectMulti<SOOrder>(
                     new PXDataField<SOOrder.orderNbr>(),
                     new PXDataFieldValue<SOOrder.orderType>(PXDbType.Char, 2, SOOrderTypeConstants.SalesOrder)))
        {
            var nbr = rec.GetString(0);
            if (!string.IsNullOrEmpty(nbr)) numbers.Add(nbr.TrimEnd());
        }
        numbers.Sort(StringComparer.Ordinal);
        return PerfDeterministic.EveryKth(numbers, SoSampleStep, SoSampleCount).ToList();
    }

    /// <summary>OrderCustomers78: distinct SOOrder.CustomerID of 'SO' orders, as (BAccountID, AcctCD), ordinal by AcctCD.</summary>
    internal static List<KeyValuePair<int, string>> LoadOrderCustomers78()
    {
        var ids = new HashSet<int>();
        foreach (PXDataRecord rec in PXDatabase.SelectMulti<SOOrder>(
                     new PXDataField<SOOrder.customerID>(),
                     new PXDataFieldValue<SOOrder.orderType>(PXDbType.Char, 2, SOOrderTypeConstants.SalesOrder)))
        {
            var id = rec.GetInt32(0);
            if (id != null) ids.Add(id.Value);
        }
        return ResolveCodes<BAccount, BAccount.bAccountID, BAccount.acctCD>(ids);
    }

    /// <summary>SoldItems91: distinct SOLine.InventoryID of 'SO' lines, as (InventoryID, InventoryCD), ordinal by InventoryCD.</summary>
    internal static List<KeyValuePair<int, string>> LoadSoldItems91()
    {
        var ids = new HashSet<int>();
        foreach (PXDataRecord rec in PXDatabase.SelectMulti<SOLine>(
                     new PXDataField<SOLine.inventoryID>(),
                     new PXDataFieldValue<SOLine.orderType>(PXDbType.Char, 2, SOOrderTypeConstants.SalesOrder)))
        {
            var id = rec.GetInt32(0);
            if (id != null) ids.Add(id.Value);
        }
        return ResolveCodes<InventoryItem, InventoryItem.inventoryID, InventoryItem.inventoryCD>(ids);
    }

    /// <summary>(ID, TrimEnd(CD)) for the given IDs, sorted ordinally by CD then ID. IDs without a code are dropped.</summary>
    internal static List<KeyValuePair<int, string>> ResolveCodes<TTable, TIdField, TCodeField>(ICollection<int> ids)
        where TTable : class, IBqlTable
        where TIdField : IBqlField
        where TCodeField : IBqlField
    {
        var pairs = new List<KeyValuePair<int, string>>();
        if (ids == null || ids.Count == 0) return pairs;
        foreach (PXDataRecord rec in PXDatabase.SelectMulti<TTable>(new PXDataField<TIdField>(), new PXDataField<TCodeField>()))
        {
            var id = rec.GetInt32(0);
            var cd = rec.GetString(1);
            if (id == null || cd == null || !ids.Contains(id.Value)) continue;
            pairs.Add(new KeyValuePair<int, string>(id.Value, cd.TrimEnd()));
        }
        return SortPairs(pairs);
    }

    internal static List<KeyValuePair<int, string>> SortPairs(IEnumerable<KeyValuePair<int, string>> pairs) =>
        pairs.OrderBy(p => p.Value, StringComparer.Ordinal).ThenBy(p => p.Key).ToList();
}

// ---------------------------------------------------------------------------------------------------------------------
// Card 1 SCR_OPEN_SALES_ORDER: Open a sales order
// ---------------------------------------------------------------------------------------------------------------------

internal sealed class ScreenOpenSalesOrderState : ReadPassState
{
    public SOOrderEntry Graph;
    public IReadOnlyList<string> Orders;
}

/// <summary>SOOrderEntry: Document.Search plus a full read of the 12 views of the Sales Orders form (SO301000).</summary>
internal sealed class ScreenOpenSalesOrderScenario : ReadScenarioBase<ScreenOpenSalesOrderState>
{
    private const string PoolKey = "scr.soSample500";
    private const int SampleOrderNbrsInNotes = 50;

    public ScreenOpenSalesOrderScenario(PerfTestDescriptor descriptor) : base(descriptor) { }

    protected override IDictionary<string, object> PlanParams() => new Dictionary<string, object>(StringComparer.Ordinal)
    {
        ["pool"] = "SoSample500: SOOrder type SO, ordinal OrderNbr, every 14th, 500",
        ["views"] = "CurrentDocument,Transactions,Taxes,shipmentlist,Adjustments,Billing_Address,Billing_Contact,Shipping_Address,Shipping_Contact,currencyinfo,SalesPerTran,DiscountDetails"
    };

    public override void Prepare(PerfScenarioContext context)
    {
        var pool = ScreenPools.LoadSoSample500();
        RequireNonEmpty(pool, "SoSample500");
        context.Set(PoolKey, pool);
        context.Notes["poolSize"] = Invariant(pool.Count);
    }

    protected override ScreenOpenSalesOrderState CreateState(PerfWorkerContext worker)
    {
        var graph = PXGraph.CreateInstance<SOOrderEntry>();
        worker.RegisterGraph(graph);
        return new ScreenOpenSalesOrderState { Graph = graph, Orders = worker.Run.Get<List<string>>(PoolKey) };
    }

    /// <summary>Equivalent to opening a fresh screen (untimed).</summary>
    public override void BeforeOperation(PerfWorkerContext worker, PerfOpInfo op) =>
        worker.StateAs<ScreenOpenSalesOrderState>().Graph.Clear(PXClearOption.ClearAll);

    public override void ExecuteOperation(PerfWorkerContext worker, PerfOpInfo op)
    {
        var state = worker.StateAs<ScreenOpenSalesOrderState>();
        var g = state.Graph;
        var nbr = PoolItem(state.Orders, op);

        SOOrder order = g.Document.Search<SOOrder.orderNbr>(nbr, SOOrderTypeConstants.SalesOrder);
        if (order == null) throw new PXException("Sales order SO " + nbr + " was not found.");
        g.Document.Current = order;

        // Enumerate fully, in this fixed order, counting rows per view (DEC\PX.Objects-26r2\SOOrderEntry.cs:7656-7851).
        var header = Rows(g.CurrentDocument.Select());
        var lines = Rows(g.Transactions.Select());
        var taxes = Rows(g.Taxes.Select());
        var shipments = Rows(g.shipmentlist.Select());
        var payments = Rows(g.Adjustments.Select());
        var billAddress = Rows(g.Billing_Address.Select());
        var billContact = Rows(g.Billing_Contact.Select());
        var shipAddress = Rows(g.Shipping_Address.Select());
        var shipContact = Rows(g.Shipping_Contact.Select());
        var currency = Rows(g.currencyinfo.Select());
        var commissions = Rows(g.SalesPerTran.Select());
        var discounts = Rows(g.DiscountDetails.Select());

        var current = g.Document.Current ?? order;
        worker.OrderedChecksum.Add(nbr, lines, taxes, shipments, payments, current.CuryOrderTotal);
        worker.RowsReturned += header + lines + taxes + shipments + payments + billAddress + billContact + shipAddress +
                               shipContact + currency + commissions + discounts;

        state.Add("orders", 1);
        state.Add("lines", lines);
        state.Add("shipments", shipments);
        state.Add("payments", payments);
        state.Add("taxes", taxes);
        state.Add("sumCuryOrderTotal", current.CuryOrderTotal ?? 0m);
        state.Add("sumOrderQty", current.OrderQty ?? 0m);
        state.CompleteOp();
    }

    /// <summary>The first 50 sample order numbers, for the end-to-end API comparison of dry-run step 3l (review-fairness M11).</summary>
    protected override void VerifyMore(PerfScenarioContext context, PerfRunMetrics metrics)
    {
        var pool = context.Get<List<string>>(PoolKey);
        if (pool != null) context.Notes["sampleOrderNbrs"] = string.Join(",", pool.Take(SampleOrderNbrsInNotes));
    }

    private static int Rows(IEnumerable rows)
    {
        var n = 0;
        if (rows == null) return 0;
        foreach (var _ in rows) n++;
        return n;
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// Card 2 SCR_CUSTOMER_ORDER_HISTORY: A customer's order history
// ---------------------------------------------------------------------------------------------------------------------

internal sealed class ScreenCustomerOrderHistoryState : ReadPassState
{
    public IReadOnlyList<KeyValuePair<int, string>> Customers;
}

/// <summary>Top 20 SOOrder ⋈ Customer by date descending plus the grid-footer COUNT(*), for one customer per operation.</summary>
internal sealed class ScreenCustomerOrderHistoryScenario : ReadScenarioBase<ScreenCustomerOrderHistoryState>
{
    private const string PoolKey = "scr.orderCustomers78";
    private const int TopRows = 20;

    public ScreenCustomerOrderHistoryScenario(PerfTestDescriptor descriptor) : base(descriptor) { }

    protected override IDictionary<string, object> PlanParams() => new Dictionary<string, object>(StringComparer.Ordinal)
    {
        ["pool"] = "OrderCustomers78: distinct SOOrder.CustomerID of type SO, ordinal AcctCD",
        ["topRows"] = TopRows
    };

    public override void Prepare(PerfScenarioContext context)
    {
        var pool = ScreenPools.LoadOrderCustomers78();
        RequireNonEmpty(pool, "OrderCustomers78");
        context.Set(PoolKey, pool);
        context.Notes["poolSize"] = Invariant(pool.Count);
    }

    protected override ScreenCustomerOrderHistoryState CreateState(PerfWorkerContext worker) =>
        new ScreenCustomerOrderHistoryState { Customers = worker.Run.Get<List<KeyValuePair<int, string>>>(PoolKey) };

    public override void ExecuteOperation(PerfWorkerContext worker, PerfOpInfo op)
    {
        var state = worker.StateAs<ScreenCustomerOrderHistoryState>();
        var g = worker.Graph;
        var customer = PoolItem(state.Customers, op);
        var id = customer.Key;

        var top = SelectFrom<SOOrder>
            .InnerJoin<Customer>.On<Customer.bAccountID.IsEqual<SOOrder.customerID>>
            .Where<SOOrder.orderType.IsEqual<SOOrderTypeConstants.salesOrder>
                .And<SOOrder.customerID.IsEqual<@P.AsInt>>>
            .OrderBy<SOOrder.orderDate.Desc, SOOrder.orderNbr.Desc>
            .View.ReadOnly.SelectWindowed(g, 0, TopRows, id);

        int total;
        using (PXDataRecord rec = PXDatabase.SelectSingle<SOOrder>(
                   new PXDataField(SQLExpression.Count()),
                   new PXDataFieldValue<SOOrder.orderType>(PXDbType.Char, 2, SOOrderTypeConstants.SalesOrder),
                   new PXDataFieldValue<SOOrder.customerID>(PXDbType.Int, 4, id)))
        {
            total = rec?.GetInt32(0) ?? 0;
        }

        var rows = 0;
        var sumTotal = 0m;
        foreach (PXResult<SOOrder, Customer> r in top)
        {
            SOOrder order = r;
            Customer cust = r;
            worker.OrderedChecksum.Add(cust.AcctCD, order.OrderNbr, order.OrderDate, order.CuryOrderTotal);
            rows++;
            sumTotal += order.CuryOrderTotal ?? 0m;
        }
        worker.OrderedChecksum.Add(customer.Value, "count", total);
        worker.RowsReturned += rows;

        state.Add("rows", rows);
        state.Add("sumCounts", total);
        state.Add("sumCuryOrderTotal", sumTotal);
        state.CompleteOp();
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// Card 3 SCR_ITEM_BUYERS: Who bought this item?
// ---------------------------------------------------------------------------------------------------------------------

internal sealed class ScreenItemBuyersState : ReadPassState
{
    public IReadOnlyList<KeyValuePair<int, string>> Items;
}

/// <summary>Top 50 SOLine ⋈ SOOrder ⋈ Customer for one item plus totals through the slim projection PerfSOLineSlim.</summary>
internal sealed class ScreenItemBuyersScenario : ReadScenarioBase<ScreenItemBuyersState>
{
    private const string PoolKey = "scr.soldItems91";
    private const int TopRows = 50;

    public ScreenItemBuyersScenario(PerfTestDescriptor descriptor) : base(descriptor) { }

    protected override IDictionary<string, object> PlanParams() => new Dictionary<string, object>(StringComparer.Ordinal)
    {
        ["pool"] = "SoldItems91: distinct SOLine.InventoryID of type SO, ordinal InventoryCD",
        ["topRows"] = TopRows
    };

    public override void Prepare(PerfScenarioContext context)
    {
        var pool = ScreenPools.LoadSoldItems91();
        RequireNonEmpty(pool, "SoldItems91");
        context.Set(PoolKey, pool);
        context.Notes["poolSize"] = Invariant(pool.Count);
    }

    protected override ScreenItemBuyersState CreateState(PerfWorkerContext worker) =>
        new ScreenItemBuyersState { Items = worker.Run.Get<List<KeyValuePair<int, string>>>(PoolKey) };

    public override void ExecuteOperation(PerfWorkerContext worker, PerfOpInfo op)
    {
        var state = worker.StateAs<ScreenItemBuyersState>();
        var g = worker.Graph;
        var item = PoolItem(state.Items, op);
        var id = item.Key;

        var lines = SelectFrom<SOLine>
            .InnerJoin<SOOrder>.On<SOOrder.orderType.IsEqual<SOLine.orderType>.And<SOOrder.orderNbr.IsEqual<SOLine.orderNbr>>>
            .InnerJoin<Customer>.On<Customer.bAccountID.IsEqual<SOOrder.customerID>>
            .Where<SOLine.orderType.IsEqual<SOOrderTypeConstants.salesOrder>.And<SOLine.inventoryID.IsEqual<@P.AsInt>>>
            .OrderBy<SOOrder.orderDate.Desc, SOLine.orderNbr.Desc, SOLine.lineNbr.Desc>
            .View.ReadOnly.SelectWindowed(g, 0, TopRows, id);

        var lineCount = 0;
        var totalQty = 0m;
        var totalAmt = 0m;
        foreach (PXResult<PerfSOLineSlim> r in SelectFrom<PerfSOLineSlim>
                     .Where<PerfSOLineSlim.inventoryID.IsEqual<@P.AsInt>>
                     .AggregateTo<GroupBy<PerfSOLineSlim.inventoryID>, Sum<PerfSOLineSlim.orderQty>, Sum<PerfSOLineSlim.curyLineAmt>, Count>
                     .View.ReadOnly.Select(g, id))
        {
            var totals = (PerfSOLineSlim)r;
            lineCount += r.RowCount ?? 0;
            totalQty += totals.OrderQty ?? 0m;
            totalAmt += totals.CuryLineAmt ?? 0m;
        }

        var rows = 0;
        var sumQty = 0m;
        var sumAmt = 0m;
        foreach (PXResult<SOLine, SOOrder, Customer> r in lines)
        {
            SOLine line = r;
            worker.OrderedChecksum.Add(item.Value, line.OrderNbr, line.LineNbr, line.OrderQty, line.CuryLineAmt);
            rows++;
            sumQty += line.OrderQty ?? 0m;
            sumAmt += line.CuryLineAmt ?? 0m;
        }
        worker.OrderedChecksum.Add(item.Value, "tot", lineCount, totalQty, totalAmt);
        worker.RowsReturned += rows;

        state.Add("rows", rows);
        state.Add("sumOrderQty", sumQty);
        state.Add("sumCuryLineAmt", sumAmt);
        state.Add("totLines", lineCount);
        state.Add("totQty", totalQty);
        state.Add("totAmount", totalAmt);
        state.CompleteOp();
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// Card 4 SCR_CUSTOMER_SEARCH: Find a customer by part of the name
// ---------------------------------------------------------------------------------------------------------------------

internal sealed class ScreenCustomerSearchState : ReadPassState
{
}

/// <summary>Customer acctCD/acctName Contains, all hits; set (multiset) checksum, plus an informational accent probe.</summary>
internal sealed class ScreenCustomerSearchScenario : ReadScenarioBase<ScreenCustomerSearchState>
{
    /// <summary>SearchFragments20, fixed order (SPEC §1.5 card 4). ASCII only, so every engine must return the same customers.</summary>
    internal static readonly string[] Fragments =
    {
        "co", "st", "ar", "el", "ma", "in", "ser", "con", "ind", "group",
        "Wid", "FOOD", "tech", "supply", "dev", "ltd", "serv", "agri", "bake", "xyzq"
    };

    /// <summary>Accent probe values: quebec, Québec, QUÉBEC. The literals use \u escapes (U+00E9, U+00C9) so the compiled
    /// strings do not depend on how the source file is decoded (this file is UTF-8 without a BOM).</summary>
    internal static readonly string[] AccentProbes = { "quebec", "Qu\u00e9bec", "QU\u00c9BEC" };

    public ScreenCustomerSearchScenario(PerfTestDescriptor descriptor) : base(descriptor) { }

    protected override IDictionary<string, object> PlanParams() => new Dictionary<string, object>(StringComparer.Ordinal)
    {
        ["fragments"] = Fragments,
        ["match"] = "Customer.acctCD contains f OR Customer.acctName contains f"
    };

    protected override ScreenCustomerSearchState CreateState(PerfWorkerContext worker) => new ScreenCustomerSearchState();

    public override void ExecuteOperation(PerfWorkerContext worker, PerfOpInfo op)
    {
        var state = worker.StateAs<ScreenCustomerSearchState>();
        var fragment = Fragments[op.OpIndex % Fragments.Length];

        var hits = SelectFrom<Customer>
            .Where<Customer.acctCD.Contains<@P.AsString>.Or<Customer.acctName.Contains<@P.AsString>>>
            .View.ReadOnly.Select(worker.Graph, fragment, fragment);

        var n = 0;
        foreach (Customer c in hits)
        {
            worker.Checksum.Add(fragment, (c.AcctCD ?? string.Empty).TrimEnd());
            n++;
        }
        worker.RowsReturned += n;

        state.Add("hitsPerPass", n);
        state.Set("hits." + fragment, n);
        state.CompleteOp();
    }

    /// <summary>
    /// Untimed, informational: how each engine treats accented letters in a 'contains' search. Keys starting with "probe."
    /// never block ranking; the report shows them as a "Same answer?" row. SQL Server today: 0 / 1 / 1.
    /// Keys are "probe.accent.&lt;n&gt;.&lt;term&gt;" (1 = quebec, 2 = Québec, 3 = QUÉBEC): the number keeps the keys distinct
    /// when compared without case, because Windows PowerShell 5.1 (the campaign suite) cannot parse a JSON object whose
    /// keys differ only in case ("Québec" / "QUÉBEC"), and the whole ResultJson would be lost.
    /// </summary>
    protected override void VerifyMore(PerfScenarioContext context, PerfRunMetrics metrics)
    {
        for (var i = 0; i < AccentProbes.Length; i++)
        {
            var probe = AccentProbes[i];
            var key = "probe.accent." + (i + 1).ToString(CultureInfo.InvariantCulture) + "." + probe;
            try
            {
                var n = 0;
                foreach (BAccount _ in SelectFrom<BAccount>
                             .Where<BAccount.acctName.Contains<@P.AsString>>
                             .View.ReadOnly.Select(context.MainGraph, probe))
                {
                    n++;
                }
                context.Parity[key] = Invariant(n);
            }
            catch (Exception ex)
            {
                context.Notes[key] = "unavailable: " + ex.Message;
            }
        }
    }
}
