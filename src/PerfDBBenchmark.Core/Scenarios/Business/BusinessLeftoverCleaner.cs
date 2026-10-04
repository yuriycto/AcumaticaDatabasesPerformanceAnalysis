using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading;
using PX.Data;
using PX.Data.BQL;
using PX.Data.BQL.Fluent;
using PX.Objects.AR;
using PX.Objects.SO;

namespace PerfDBBenchmark.Core.Scenarios.Business;

/// <summary>
/// Removes leftovers of crashed or interrupted business runs (ClearTestRecords action; SPEC §4.1, §5.2 WP4 item 4):
/// sales orders whose OrderDesc starts with "PERFBENCH " and <b>unreleased</b> AR invoices whose DocDesc starts with "PERFBENCH ".
/// Released invoices are permanent by design and are never touched. Deletes go through SOOrderEntry / ARInvoiceEntry,
/// with PerfGraphs.FreshForWrite before each delete (SPEC §1.3.3), in the PRODWHOLE session branch the documents were written in.
/// </summary>
public sealed class BusinessLeftoverCleaner : IPerfLeftoverCleaner
{
    public string Name => "perfbench-documents";

    public int Clean(PXGraph graph)
    {
        var read = graph ?? PXGraph.CreateInstance<PerfWorkerGraph>();
        var failures = new List<string>();
        var removed = 0;

        // The documents were written in the PRODWHOLE session branch (PerfBranchContext, SPEC §1.6/§1.7); delete them in the
        // same context. Without PRODWHOLE the deletes run in the caller's context.
        int? branchBefore = null;
        var branchEntered = false;
        try
        {
            try
            {
                branchBefore = PerfBranchContext.Enter(PerfBusinessPools.ResolveBranchId(read));
                branchEntered = true;
            }
            catch (PXException)
            {
                // branch not found: keep the caller's branch
            }

            var orders = BusinessDocuments.ReadPerfBenchOrders(read);
            if (orders.Count > 0)
            {
                var so = PXGraph.CreateInstance<SOOrderEntry>();
                removed += BusinessDocuments.DeleteSalesOrders(so, orders, BusinessDocuments.DeleteRetries, failures);
            }

            var invoices = BusinessDocuments.ReadUnreleasedPerfBenchInvoices(read);
            if (invoices.Count > 0)
            {
                var ie = PXGraph.CreateInstance<ARInvoiceEntry>();
                removed += BusinessDocuments.DeleteUnreleasedInvoices(ie, invoices, BusinessDocuments.DeleteRetries, failures);
            }
        }
        finally
        {
            if (branchEntered) PerfBranchContext.Restore(branchBefore);
        }

        if (failures.Count > 0)
        {
            throw new PXException("PERFBENCH leftovers: " + removed.ToString(CultureInfo.InvariantCulture) + " removed, "
                                  + failures.Count.ToString(CultureInfo.InvariantCulture) + " could not be removed. First: " + failures[0]);
        }
        return removed;
    }
}

/// <summary>Result of one document delete.</summary>
public enum BusinessDeleteOutcome
{
    Deleted,
    NotFound,
    /// <summary>The document is not a PERFBENCH document, or the invoice is released; it was left alone.</summary>
    Skipped,
    Failed
}

/// <summary>
/// Untimed read and delete helpers for PERFBENCH sales orders and invoices. Never call them from ExecuteOperation
/// (they sleep between retries and refresh graph timestamps).
/// </summary>
public static class BusinessDocuments
{
    /// <summary>Each delete is retried up to 3 times (SPEC §1.6 AfterPass, review-api M3).</summary>
    public const int DeleteRetries = 3;
    public const int RetryDelayMs = 200;

    /// <summary>True when the text starts with "PERFBENCH " (ordinal, case-sensitive).</summary>
    public static bool IsPerfBenchText(string text) =>
        text != null && text.StartsWith(PerfCampaignConstants.DocumentTagPrefix, StringComparison.Ordinal);

    // ---------------------------------------------------------------- reads (untimed; always reach the database)

    /// <summary>Every SOOrder (any order type) whose OrderDesc starts with "PERFBENCH ".</summary>
    public static List<SOOrder> ReadPerfBenchOrders(PXGraph graph)
    {
        graph.Clear(PXClearOption.ClearQueriesOnly);
        var list = new List<SOOrder>();
        foreach (SOOrder o in SelectFrom<SOOrder>
                     .Where<SOOrder.orderDesc.StartsWith<@P.AsString>>
                     .View.ReadOnly.Select(graph, PerfCampaignConstants.DocumentTagPrefix.TrimEnd()))
        {
            if (o != null && IsPerfBenchText(o.OrderDesc)) list.Add(o);
        }
        return list;
    }

    /// <summary>The run's sales orders: OrderType = SO and OrderDesc = tag (an equality filter).</summary>
    public static List<SOOrder> ReadOrdersByTag(PXGraph graph, string tag)
    {
        graph.Clear(PXClearOption.ClearQueriesOnly);
        var list = new List<SOOrder>();
        foreach (SOOrder o in SelectFrom<SOOrder>
                     .Where<SOOrder.orderType.IsEqual<SOOrderTypeConstants.salesOrder>
                         .And<SOOrder.orderDesc.IsEqual<@P.AsString>>>
                     .View.ReadOnly.Select(graph, tag))
        {
            if (o != null && string.Equals(o.OrderDesc, tag, StringComparison.Ordinal)) list.Add(o);
        }
        return list;
    }

    /// <summary>Every unreleased AR invoice/memo whose DocDesc starts with "PERFBENCH ".</summary>
    public static List<ARInvoice> ReadUnreleasedPerfBenchInvoices(PXGraph graph)
    {
        graph.Clear(PXClearOption.ClearQueriesOnly);
        var list = new List<ARInvoice>();
        foreach (ARInvoice i in SelectFrom<ARInvoice>
                     .Where<ARInvoice.docDesc.StartsWith<@P.AsString>
                         .And<ARInvoice.released.IsEqual<False>>>
                     .View.ReadOnly.Select(graph, PerfCampaignConstants.DocumentTagPrefix.TrimEnd()))
        {
            if (i != null && i.Released != true && IsPerfBenchText(i.DocDesc)) list.Add(i);
        }
        return list;
    }

    /// <summary>The run's unreleased invoices: DocType = INV, DocDesc = tag, Released = 0 (failed releases).</summary>
    public static List<ARInvoice> ReadUnreleasedInvoicesByTag(PXGraph graph, string tag)
    {
        graph.Clear(PXClearOption.ClearQueriesOnly);
        var list = new List<ARInvoice>();
        foreach (ARInvoice i in SelectFrom<ARInvoice>
                     .Where<ARInvoice.docType.IsEqual<ARDocType.invoice>
                         .And<ARInvoice.docDesc.IsEqual<@P.AsString>>
                         .And<ARInvoice.released.IsEqual<False>>>
                     .View.ReadOnly.Select(graph, tag))
        {
            if (i != null && i.Released != true && string.Equals(i.DocDesc, tag, StringComparison.Ordinal)) list.Add(i);
        }
        return list;
    }

    // ---------------------------------------------------------------- deletes (untimed)

    /// <summary>Deletes the orders one by one through SOOrderEntry; returns the number deleted; failures are appended.</summary>
    public static int DeleteSalesOrders(SOOrderEntry graph, IEnumerable<SOOrder> orders, int retries, ICollection<string> failures)
    {
        var deleted = 0;
        foreach (var o in orders ?? Enumerable.Empty<SOOrder>())
        {
            if (o == null) continue;
            var outcome = DeleteSalesOrder(graph, o.OrderType, o.OrderNbr, retries, out var error);
            if (outcome == BusinessDeleteOutcome.Deleted) deleted++;
            else if (outcome == BusinessDeleteOutcome.Failed) failures?.Add("SO " + o.OrderType + " " + o.OrderNbr + ": " + error);
        }
        return deleted;
    }

    /// <summary>Deletes the unreleased invoices one by one through ARInvoiceEntry; returns the number deleted; failures are appended.</summary>
    public static int DeleteUnreleasedInvoices(ARInvoiceEntry graph, IEnumerable<ARInvoice> invoices, int retries, ICollection<string> failures)
    {
        var deleted = 0;
        foreach (var i in invoices ?? Enumerable.Empty<ARInvoice>())
        {
            if (i == null) continue;
            var outcome = DeleteUnreleasedInvoice(graph, i.DocType, i.RefNbr, retries, out var error);
            if (outcome == BusinessDeleteOutcome.Deleted) deleted++;
            else if (outcome == BusinessDeleteOutcome.Failed) failures?.Add("AR " + i.DocType + " " + i.RefNbr + ": " + error);
        }
        return deleted;
    }

    /// <summary>
    /// Deletes one PERFBENCH sales order through SOOrderEntry (Document.Delete + Save). PerfGraphs.FreshForWrite runs before
    /// every attempt; retried up to <paramref name="retries"/> times, 200 ms apart, on PXDatabaseException / PXLockViolationException.
    /// <para>
    /// The order is located through the graph's cache (Document.Search, as the Sales Orders form does), so Document.Current is
    /// the very instance the SOOrder cache holds. A read-only lookup (SOOrder.PK.Find without IncludeDirty) returns a detached
    /// copy; Document.Delete then reads the row again and marks that second instance Deleted, and the cascade delete of the lines
    /// fails in SOOrderEntry.SOLine_RowDeleted, which calls Document.Cache.MarkUpdated(Document.Current, true): "Cannot mark the
    /// record as updated because another record with the same key exists in the cache" (PXCache.Delete/readItem,
    /// GraphHelper.MarkUpdated).
    /// </para>
    /// </summary>
    public static BusinessDeleteOutcome DeleteSalesOrder(SOOrderEntry graph, string orderType, string orderNbr, int retries, out string error)
    {
        if (graph == null) throw new ArgumentNullException(nameof(graph));
        error = null;
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                PerfGraphs.FreshForWrite(graph);
                var order = LocateForWrite(graph, orderType, orderNbr);
                if (order == null) return BusinessDeleteOutcome.NotFound;
                if (!IsPerfBenchText(order.OrderDesc))
                {
                    error = "not a PERFBENCH order";
                    return BusinessDeleteOutcome.Skipped;
                }
                graph.Document.Current = order;
                graph.Document.Delete(order);
                graph.Save.Press();
                return BusinessDeleteOutcome.Deleted;
            }
            catch (Exception ex)
            {
                error = Describe(ex);
                SafeReset(graph);
                if (attempt >= retries || !IsRetryable(ex)) return BusinessDeleteOutcome.Failed;
                Thread.Sleep(RetryDelayMs);
            }
        }
    }

    /// <summary>
    /// Deletes one unreleased PERFBENCH invoice through ARInvoiceEntry (Document.Delete + Save; ARRegister is soft-deleted, an UPDATE
    /// checked against the graph stamp, hence FreshForWrite before every attempt). Released invoices are skipped, never deleted.
    /// </summary>
    public static BusinessDeleteOutcome DeleteUnreleasedInvoice(ARInvoiceEntry graph, string docType, string refNbr, int retries, out string error)
    {
        if (graph == null) throw new ArgumentNullException(nameof(graph));
        error = null;
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                PerfGraphs.FreshForWrite(graph);
                graph.Clear(PXClearOption.ClearQueriesOnly);
                ARInvoice invoice = graph.Document.Search<ARInvoice.refNbr>(refNbr, docType);
                if (invoice == null) return BusinessDeleteOutcome.NotFound;
                if (invoice.Released == true || !IsPerfBenchText(invoice.DocDesc))
                {
                    error = invoice.Released == true ? "released (permanent)" : "not a PERFBENCH invoice";
                    return BusinessDeleteOutcome.Skipped;
                }
                graph.Document.Current = invoice;
                graph.Document.Delete(graph.Document.Current);
                graph.Save.Press();
                return BusinessDeleteOutcome.Deleted;
            }
            catch (Exception ex)
            {
                error = Describe(ex);
                SafeReset(graph);
                if (attempt >= retries || !IsRetryable(ex)) return BusinessDeleteOutcome.Failed;
                Thread.Sleep(RetryDelayMs);
            }
        }
    }

    /// <summary>
    /// The order as the instance held by graph's SOOrder cache, or null when it does not exist. Document.Search merges the row
    /// into the cache; Document also applies the customer's row-level restriction (Match&lt;Customer, Current&lt;AccessInfo.userName&gt;&gt;),
    /// so an order the session cannot see there is looked up with PKFindOptions.IncludeDirty, which reads through a
    /// cache-merging view as well. Never a read-only copy (see DeleteSalesOrder).
    /// </summary>
    private static SOOrder LocateForWrite(SOOrderEntry graph, string orderType, string orderNbr)
    {
        SOOrder order = graph.Document.Search<SOOrder.orderNbr>(orderNbr, orderType);
        if (order == null) order = SOOrder.PK.Find(graph, orderType, orderNbr, PKFindOptions.IncludeDirty);
        if (order == null) return null;
        return graph.Document.Cache.Locate(order) as SOOrder ?? order;
    }

    /// <summary>Number of SOLine rows per order of the run (OrderType SO, OrderDesc = tag), keyed by OrderNbr.</summary>
    /// <remarks>
    /// SOOrder.LineCntr is not a line count: SOLine.LineNbr and SOLineSplit.SplitLineNbr both take their numbers from it
    /// (PXLineNbr(typeof(SOOrder.lineCntr))), so a 3-line order with one split per line has LineCntr 6.
    /// </remarks>
    public static Dictionary<string, int> CountLinesByTag(PXGraph graph, string tag)
    {
        graph.Clear(PXClearOption.ClearQueriesOnly);
        var counts = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (PXResult<SOLine, SOOrder> r in SelectFrom<SOLine>
                     .InnerJoin<SOOrder>.On<SOLine.FK.Order>
                     .Where<SOOrder.orderType.IsEqual<SOOrderTypeConstants.salesOrder>
                         .And<SOOrder.orderDesc.IsEqual<@P.AsString>>>
                     .View.ReadOnly.Select(graph, tag))
        {
            var line = (SOLine)r;
            var order = (SOOrder)r;
            if (line?.OrderNbr == null || order == null || !string.Equals(order.OrderDesc, tag, StringComparison.Ordinal)) continue;
            counts[line.OrderNbr] = counts.TryGetValue(line.OrderNbr, out var n) ? n + 1 : 1;
        }
        return counts;
    }

    /// <summary>True for PXDatabaseException (deadlock, lock-wait time-out, serialization failure) and PXLockViolationException, also when wrapped.</summary>
    public static bool IsRetryable(Exception ex)
    {
        for (var e = ex; e != null; e = e.InnerException)
        {
            if (e is PXDatabaseException || e is PXLockViolationException) return true;
        }
        return false;
    }

    /// <summary>Short one-line description for Notes (type and message, at most 300 characters).</summary>
    public static string Describe(Exception ex)
    {
        if (ex == null) return string.Empty;
        var inner = ex;
        while (inner.InnerException != null && (!(inner is PXException) || string.IsNullOrEmpty(inner.Message))) inner = inner.InnerException;
        var text = inner.GetType().Name + ": " + (inner.Message ?? string.Empty).Replace('\r', ' ').Replace('\n', ' ');
        return text.Length > 300 ? text.Substring(0, 300) : text;
    }

    private static void SafeReset(PXGraph graph)
    {
        try { graph.Clear(PXClearOption.ClearAll); }
        catch { /* the next attempt calls FreshForWrite again */ }
    }
}
