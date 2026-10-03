using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using PX.Data;
using PX.Data.BQL;
using PX.Data.BQL.Fluent;
using PX.Data.SQLTree;
using PX.Objects.GL;
using PerfDBBenchmark.Core.Scenarios.Screens;

namespace PerfDBBenchmark.Core.Scenarios.Reports;

// SPEC §1.5 (cards 5-8), §1.3 (shared rules), §4.8 (coding rules). W = 1 for every test; the shared lifecycle
// (per-pass tally, ref.* values, CheckPassDigestsStable in Verify) is ReadScenarioBase in ScreenScenarios.cs.

/// <summary>
/// Data pools of the Reports family (SPEC §1.3.8). Fixed lists are pinned in code; GlAccounts56 is read untimed and sorted
/// in C# with StringComparer.Ordinal after TrimEnd(). Shared with ReadPoolsFingerprint.
/// </summary>
internal static class ReportPools
{
    /// <summary>SalesYears14: fiscal years 2013…2026.</summary>
    internal static readonly string[] SalesYears14 =
    {
        "2013", "2014", "2015", "2016", "2017", "2018", "2019", "2020", "2021", "2022", "2023", "2024", "2025", "2026"
    };

    /// <summary>TbPeriods12: 202507…202512, 202601…202606.</summary>
    internal static readonly string[] TbPeriods12 =
    {
        "202507", "202508", "202509", "202510", "202511", "202512",
        "202601", "202602", "202603", "202604", "202605", "202606"
    };

    internal const string GlYearFirstPeriod = "202501";
    internal const string GlYearLastPeriod = "202512";
    internal const string GlOpeningPeriod = "202412";

    /// <summary>LedgerID of ACTUAL (resolved by CD; the master-data fingerprint proves the IDs are equal on every engine).</summary>
    internal static int? FindActualLedgerId(PXGraph graph)
    {
        Ledger ledger = SelectFrom<Ledger>
            .Where<Ledger.ledgerCD.IsEqual<@P.AsString>>
            .View.ReadOnly.Select(graph, PerfCampaignConstants.ActualLedgerCD).TopFirst;
        return ledger?.LedgerID;
    }

    internal static int LoadActualLedgerId(PXGraph graph) =>
        FindActualLedgerId(graph) ?? throw new PXException("Ledger " + PerfCampaignConstants.ActualLedgerCD + " was not found.");

    /// <summary>
    /// GlAccounts56: distinct GLTran.AccountID with LedgerID = ACTUAL, Posted = 1 and FinPeriodID 202501–202512,
    /// as (AccountID, AccountCD), ordinal by AccountCD.
    /// </summary>
    internal static List<KeyValuePair<int, string>> LoadGlAccounts56(int ledgerId)
    {
        var ids = new HashSet<int>();
        foreach (PXDataRecord rec in PXDatabase.SelectMulti<GLTran>(
                     new PXDataField<GLTran.accountID>(),
                     new PXDataField<GLTran.posted>(),
                     new PXDataFieldValue<GLTran.ledgerID>(PXDbType.Int, 4, ledgerId),
                     new PXDataFieldValue<GLTran.finPeriodID>(PXDbType.Char, 6, GlYearFirstPeriod, PXComp.GE),
                     new PXDataFieldValue<GLTran.finPeriodID>(PXDbType.Char, 6, GlYearLastPeriod, PXComp.LE)))
        {
            if (rec.GetBoolean(1) != true) continue;
            var id = rec.GetInt32(0);
            if (id != null) ids.Add(id.Value);
        }
        return ScreenPools.ResolveCodes<Account, Account.accountID, Account.accountCD>(ids);
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// Card 5 RPT_SALES_BY_CUSTOMER_MONTH: Sales by customer and month
// ---------------------------------------------------------------------------------------------------------------------

internal sealed class ReportSalesByCustomerMonthState : ReadPassState
{
}

/// <summary>Released AR lines grouped by customer × financial period for one fiscal year, through PerfARTranSales.</summary>
internal sealed class ReportSalesByCustomerMonthScenario : ReadScenarioBase<ReportSalesByCustomerMonthState>
{
    public ReportSalesByCustomerMonthScenario(PerfTestDescriptor descriptor) : base(descriptor) { }

    protected override IDictionary<string, object> PlanParams() => new Dictionary<string, object>(StringComparer.Ordinal)
    {
        ["years"] = ReportPools.SalesYears14,
        ["periodRange"] = "YYYY01..YYYY13",
        ["tranTypes"] = "INV,CRM,DRM,CSL released"
    };

    protected override ReportSalesByCustomerMonthState CreateState(PerfWorkerContext worker) => new ReportSalesByCustomerMonthState();

    public override void ExecuteOperation(PerfWorkerContext worker, PerfOpInfo op)
    {
        var state = worker.StateAs<ReportSalesByCustomerMonthState>();
        var year = ReportPools.SalesYears14[op.OpIndex % ReportPools.SalesYears14.Length];

        var groups = 0;
        var lines = 0;
        var amount = 0m;
        foreach (PXResult<PerfARTranSales> r in SelectFrom<PerfARTranSales>
                     .Where<PerfARTranSales.finPeriodID.IsBetween<@P.AsString, @P.AsString>>
                     .AggregateTo<GroupBy<PerfARTranSales.customerID>, GroupBy<PerfARTranSales.acctCD>, GroupBy<PerfARTranSales.finPeriodID>,
                                  Sum<PerfARTranSales.tranAmt>, Sum<PerfARTranSales.qty>, Count>
                     .OrderBy<PerfARTranSales.customerID.Asc, PerfARTranSales.finPeriodID.Asc>
                     .View.ReadOnly.Select(worker.Graph, year + "01", year + "13"))
        {
            var row = (PerfARTranSales)r;
            var lineCount = r.RowCount ?? 0;
            worker.OrderedChecksum.Add(row.AcctCD, row.FinPeriodID, row.TranAmt, row.Qty, lineCount);
            groups++;
            lines += lineCount;
            amount += row.TranAmt ?? 0m;
        }
        worker.RowsReturned += groups;

        state.Add("groups", groups);
        state.Add("lines", lines);
        state.Set("year." + year + ".groups", groups);
        state.Set("year." + year + ".lines", lines);
        state.Set("year." + year + ".tranAmt", amount);
        state.CompleteOp();
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// Card 6 RPT_TRIAL_BALANCE: Trial balance
// ---------------------------------------------------------------------------------------------------------------------

internal sealed class ReportTrialBalanceState : ReadPassState
{
    public int LedgerId;
}

/// <summary>
/// GLHistoryByPeriod ⋈ GLHistory (last-activity row) ⋈ Account ⋈ Sub ⋈ Branch for one period. Operation cap 60 s
/// (descriptor OperationCapMs = 60000; the engine stops the run and stores it as Capped). Σ FinYtdBalance of the
/// last-activity rows is a checksum, not a trial-balance total (review-api m10).
/// </summary>
internal sealed class ReportTrialBalanceScenario : ReadScenarioBase<ReportTrialBalanceState>
{
    private const string LedgerKey = "rpt.ledgerId";

    public ReportTrialBalanceScenario(PerfTestDescriptor descriptor) : base(descriptor) { }

    protected override IDictionary<string, object> PlanParams() => new Dictionary<string, object>(StringComparer.Ordinal)
    {
        ["ledger"] = PerfCampaignConstants.ActualLedgerCD,
        ["periods"] = ReportPools.TbPeriods12
    };

    public override void Prepare(PerfScenarioContext context)
    {
        var ledgerId = ReportPools.LoadActualLedgerId(context.MainGraph);
        context.Set(LedgerKey, ledgerId);
    }

    protected override ReportTrialBalanceState CreateState(PerfWorkerContext worker) =>
        new ReportTrialBalanceState { LedgerId = worker.Run.Get<int>(LedgerKey) };

    public override void ExecuteOperation(PerfWorkerContext worker, PerfOpInfo op)
    {
        var state = worker.StateAs<ReportTrialBalanceState>();
        var period = ReportPools.TbPeriods12[op.OpIndex % ReportPools.TbPeriods12.Length];

        var rows = 0;
        var ytd = 0m;
        foreach (PXResult<GLHistoryByPeriod, GLHistory, Account, Sub, Branch> r in SelectFrom<GLHistoryByPeriod>
                     .InnerJoin<GLHistory>.On<GLHistory.ledgerID.IsEqual<GLHistoryByPeriod.ledgerID>
                         .And<GLHistory.branchID.IsEqual<GLHistoryByPeriod.branchID>>
                         .And<GLHistory.accountID.IsEqual<GLHistoryByPeriod.accountID>>
                         .And<GLHistory.subID.IsEqual<GLHistoryByPeriod.subID>>
                         .And<GLHistory.finPeriodID.IsEqual<GLHistoryByPeriod.lastActivityPeriod>>>
                     .InnerJoin<Account>.On<Account.accountID.IsEqual<GLHistoryByPeriod.accountID>>
                     .InnerJoin<Sub>.On<Sub.subID.IsEqual<GLHistoryByPeriod.subID>>
                     .InnerJoin<Branch>.On<Branch.branchID.IsEqual<GLHistoryByPeriod.branchID>>
                     .Where<GLHistoryByPeriod.ledgerID.IsEqual<@P.AsInt>.And<GLHistoryByPeriod.finPeriodID.IsEqual<@P.AsString>>>
                     .OrderBy<GLHistoryByPeriod.branchID.Asc, GLHistoryByPeriod.accountID.Asc, GLHistoryByPeriod.subID.Asc>
                     .View.ReadOnly.Select(worker.Graph, state.LedgerId, period))
        {
            GLHistoryByPeriod byPeriod = r;
            GLHistory history = r;
            worker.OrderedChecksum.Add(byPeriod.BranchID, byPeriod.AccountID, byPeriod.SubID, byPeriod.LastActivityPeriod,
                history.FinYtdBalance, history.FinPtdDebit, history.FinPtdCredit);
            rows++;
            ytd += history.FinYtdBalance ?? 0m;
        }
        worker.RowsReturned += rows;

        state.Add("rows", rows);
        state.Set("period." + period + ".rows", rows);
        state.Set("period." + period + ".sumFinYtdBalance", ytd);
        state.CompleteOp();
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// Card 7 RPT_GL_ACCOUNT_DETAILS: GL account details for a year
// ---------------------------------------------------------------------------------------------------------------------

internal sealed class ReportGLAccountDetailsState : ReadPassState
{
    public int LedgerId;
    public IReadOnlyList<KeyValuePair<int, string>> Accounts;
}

/// <summary>Opening balance (GLHistoryByPeriod at 202412) plus every posted GLTran ⋈ Batch line of FY2025 for one account.</summary>
internal sealed class ReportGLAccountDetailsScenario : ReadScenarioBase<ReportGLAccountDetailsState>
{
    private const string LedgerKey = "rpt.ledgerId";
    private const string PoolKey = "rpt.glAccounts56";

    public ReportGLAccountDetailsScenario(PerfTestDescriptor descriptor) : base(descriptor) { }

    protected override IDictionary<string, object> PlanParams() => new Dictionary<string, object>(StringComparer.Ordinal)
    {
        ["ledger"] = PerfCampaignConstants.ActualLedgerCD,
        ["pool"] = "GlAccounts56: distinct GLTran.AccountID, ledger ACTUAL, posted, 202501-202512, ordinal AccountCD",
        ["openingPeriod"] = ReportPools.GlOpeningPeriod,
        ["periods"] = ReportPools.GlYearFirstPeriod + ".." + ReportPools.GlYearLastPeriod
    };

    public override void Prepare(PerfScenarioContext context)
    {
        var ledgerId = ReportPools.LoadActualLedgerId(context.MainGraph);
        var pool = ReportPools.LoadGlAccounts56(ledgerId);
        RequireNonEmpty(pool, "GlAccounts56");
        context.Set(LedgerKey, ledgerId);
        context.Set(PoolKey, pool);
        context.Notes["poolSize"] = Invariant(pool.Count);
    }

    protected override ReportGLAccountDetailsState CreateState(PerfWorkerContext worker) =>
        new ReportGLAccountDetailsState
        {
            LedgerId = worker.Run.Get<int>(LedgerKey),
            Accounts = worker.Run.Get<List<KeyValuePair<int, string>>>(PoolKey)
        };

    public override void ExecuteOperation(PerfWorkerContext worker, PerfOpInfo op)
    {
        var state = worker.StateAs<ReportGLAccountDetailsState>();
        var g = worker.Graph;
        var account = PoolItem(state.Accounts, op);
        var accountId = account.Key;

        // 1. Opening balance: last-activity history rows at or before 202412, summed in C# over branches and subaccounts.
        var opening = 0m;
        foreach (PXResult<GLHistoryByPeriod, GLHistory> r in SelectFrom<GLHistoryByPeriod>
                     .InnerJoin<GLHistory>.On<GLHistory.ledgerID.IsEqual<GLHistoryByPeriod.ledgerID>
                         .And<GLHistory.branchID.IsEqual<GLHistoryByPeriod.branchID>>
                         .And<GLHistory.accountID.IsEqual<GLHistoryByPeriod.accountID>>
                         .And<GLHistory.subID.IsEqual<GLHistoryByPeriod.subID>>
                         .And<GLHistory.finPeriodID.IsEqual<GLHistoryByPeriod.lastActivityPeriod>>>
                     .Where<GLHistoryByPeriod.ledgerID.IsEqual<@P.AsInt>
                         .And<GLHistoryByPeriod.finPeriodID.IsEqual<@P.AsString>>
                         .And<GLHistoryByPeriod.accountID.IsEqual<@P.AsInt>>>
                     .View.ReadOnly.Select(g, state.LedgerId, ReportPools.GlOpeningPeriod, accountId))
        {
            GLHistory history = r;
            opening += history.FinYtdBalance ?? 0m;
        }
        worker.OrderedChecksum.Add(account.Value, "open", opening);

        // 2. Details: every posted line of the fiscal year with its batch, full DACs.
        var rows = 0;
        var debit = 0m;
        var credit = 0m;
        foreach (PXResult<GLTran, Batch> r in SelectFrom<GLTran>
                     .InnerJoin<Batch>.On<Batch.module.IsEqual<GLTran.module>.And<Batch.batchNbr.IsEqual<GLTran.batchNbr>>>
                     .Where<GLTran.ledgerID.IsEqual<@P.AsInt>
                         .And<GLTran.accountID.IsEqual<@P.AsInt>>
                         .And<GLTran.posted.IsEqual<True>>
                         .And<GLTran.finPeriodID.IsBetween<@P.AsString, @P.AsString>>>
                     .OrderBy<GLTran.tranDate.Asc, GLTran.module.Asc, GLTran.batchNbr.Asc, GLTran.lineNbr.Asc>
                     .View.ReadOnly.Select(g, state.LedgerId, accountId, ReportPools.GlYearFirstPeriod, ReportPools.GlYearLastPeriod))
        {
            GLTran tran = r;
            worker.OrderedChecksum.Add(tran.TranDate, tran.Module, tran.BatchNbr, tran.LineNbr, tran.DebitAmt, tran.CreditAmt);
            rows++;
            debit += tran.DebitAmt ?? 0m;
            credit += tran.CreditAmt ?? 0m;
        }
        worker.RowsReturned += rows;

        state.Add("accounts", 1);
        state.Add("rows", rows);
        state.Add("sumDebitAmt", debit);
        state.Add("sumCreditAmt", credit);
        state.CompleteOp();
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// Card 8 RPT_LARGE_LIST_PAGING: Deep paging and counting in a 300,000-line journal
// ---------------------------------------------------------------------------------------------------------------------

internal sealed class ReportLargeListPagingState : ReadPassState
{
}

/// <summary>
/// Ops 0-4: GLTran pages of 100 by document key at offsets 0/10k/100k/200k/300k; ops 5-9: the same offsets newest first;
/// op 10: COUNT(*) of GLTran; op 11: COUNT(*) of FY2025. Each request also records its own sub-phase.
/// </summary>
internal sealed class ReportLargeListPagingScenario : ReadScenarioBase<ReportLargeListPagingState>
{
    internal const int PageSize = 100;
    internal const int RequestsPerCycle = 12;
    internal static readonly int[] Offsets = { 0, 10000, 100000, 200000, 300000 };

    /// <summary>Offsets whose first key has a catalog reference value (SPEC §1.5 card 8).</summary>
    private static readonly HashSet<int> ReferenceOffsets = new HashSet<int> { 0, 300000 };

    public ReportLargeListPagingScenario(PerfTestDescriptor descriptor) : base(descriptor) { }

    protected override IDictionary<string, object> PlanParams() => new Dictionary<string, object>(StringComparer.Ordinal)
    {
        ["offsets"] = Offsets,
        ["pageSize"] = PageSize,
        ["sortOrders"] = "doc: module,batchNbr,lineNbr asc; new: tranDate,module,batchNbr,lineNbr desc",
        ["counts"] = "all; finPeriodID 202501..202512"
    };

    protected override ReportLargeListPagingState CreateState(PerfWorkerContext worker) => new ReportLargeListPagingState();

    public override void ExecuteOperation(PerfWorkerContext worker, PerfOpInfo op)
    {
        var state = worker.StateAs<ReportLargeListPagingState>();
        var g = worker.Graph;
        var k = op.OpIndex % RequestsPerCycle;

        if (k < 10)
        {
            var byDocument = k < 5;
            var offset = Offsets[k % 5];
            var phase = (byDocument ? "doc@" : "new@") + offset.ToString(CultureInfo.InvariantCulture);

            var t0 = Stopwatch.GetTimestamp();
            var page = byDocument
                ? SelectFrom<GLTran>
                    .OrderBy<GLTran.module.Asc, GLTran.batchNbr.Asc, GLTran.lineNbr.Asc>
                    .View.ReadOnly.SelectWindowed(g, offset, PageSize)
                : SelectFrom<GLTran>
                    .OrderBy<GLTran.tranDate.Desc, GLTran.module.Desc, GLTran.batchNbr.Desc, GLTran.lineNbr.Desc>
                    .View.ReadOnly.SelectWindowed(g, offset, PageSize);
            worker.RecordPhase(phase, PerfStatistics.TicksToMs(Stopwatch.GetTimestamp() - t0));

            string firstKey = null;
            var rows = 0;
            foreach (GLTran tran in page)
            {
                worker.OrderedChecksum.Add(k, tran.Module, tran.BatchNbr, tran.LineNbr);
                if (firstKey == null) firstKey = Key(tran);
                rows++;
            }
            worker.RowsReturned += rows;
            if (ReferenceOffsets.Contains(offset)) state.SetText("firstKey." + phase, firstKey);
        }
        else
        {
            var countAll = k == 10;
            var phase = countAll ? "countAll" : "countFY2025";

            var t0 = Stopwatch.GetTimestamp();
            int count;
            if (countAll)
            {
                using (PXDataRecord rec = PXDatabase.SelectSingle<GLTran>(new PXDataField(SQLExpression.Count())))
                {
                    count = rec?.GetInt32(0) ?? 0;
                }
            }
            else
            {
                using (PXDataRecord rec = PXDatabase.SelectSingle<GLTran>(
                           new PXDataField(SQLExpression.Count()),
                           new PXDataFieldValue<GLTran.finPeriodID>(PXDbType.Char, 6, ReportPools.GlYearFirstPeriod, PXComp.GE),
                           new PXDataFieldValue<GLTran.finPeriodID>(PXDbType.Char, 6, ReportPools.GlYearLastPeriod, PXComp.LE)))
                {
                    count = rec?.GetInt32(0) ?? 0;
                }
            }
            worker.RecordPhase(phase, PerfStatistics.TicksToMs(Stopwatch.GetTimestamp() - t0));

            worker.OrderedChecksum.Add(k, count);
            state.Set(phase, count);
        }

        state.CompleteOp();
    }

    private static string Key(GLTran tran) =>
        (tran.Module ?? string.Empty).TrimEnd() + "/" + (tran.BatchNbr ?? string.Empty).TrimEnd() + "/" +
        (tran.LineNbr?.ToString(CultureInfo.InvariantCulture) ?? string.Empty);
}
