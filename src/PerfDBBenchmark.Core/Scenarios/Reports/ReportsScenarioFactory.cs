using System;
using System.Collections.Generic;

namespace PerfDBBenchmark.Core.Scenarios.Reports;

/// <summary>
/// Family RPT "Reports and month-end" (SPEC §1.1 rows 5-8, descriptor values §1.2, card texts §1.5). Block A, read-only, W = 1.
/// No database access in the constructor or in Descriptors (SPEC §4.8 rule 3).
/// </summary>
public sealed class ReportsScenarioFactory : IPerfScenarioFactory
{
    internal static readonly PerfTestDescriptor SalesByCustomerMonth = new PerfTestDescriptor
    {
        TestCode = PerfScenarioCodes.SalesByCustomerMonth,
        SortOrder = 210,
        ShortLabel = "Sales/month",
        Category = "Report",
        Family = PerfFamilies.Reports,
        RunBlock = PerfBlocks.ReadOnly,
        Users = 1,
        HeadlineKind = PerfHeadlineKinds.MedianOpMs,
        ReaderUnit = "ms per yearly report",
        OpsUnit = "reports",
        DefaultOpsPerPass = 14,
        DefaultPasses = 3,
        DefaultWarmUpPasses = 1,
        DefaultWarmUpOpsPerWorker = 0,
        OrderedChecksum = true,
        ParityExpected = true,
        ErrorsInvalidate = true,
        IsDestructive = false,
        IsOptional = false,
        OperationCapMs = 0,
        LegacyTestCode = null,
        DisplayName = "Sales by customer and month",
        ShortDescription = "Released AR invoice and memo lines grouped by customer and financial period for one fiscal year (14 years per pass).",
        Question = "How long does a yearly \"sales by customer by month\" report take?",
        WhatItSimulates = "A sales analysis report or dashboard widget: released invoice and memo lines grouped by customer and financial period for one year.",
        WhyItMatters = "Pure analytics: read a whole table, group it, add it up. Databases differ in how they read and total many rows and in whether they use several CPU cores for one query. If your business lives on sales dashboards and management reports, this is a simple proxy (real dashboards are usually Generic Inquiries with more joins)."
    };

    internal static readonly PerfTestDescriptor TrialBalance = new PerfTestDescriptor
    {
        TestCode = PerfScenarioCodes.TrialBalance,
        SortOrder = 220,
        ShortLabel = "Trial bal.",
        Category = "Report",
        Family = PerfFamilies.Reports,
        RunBlock = PerfBlocks.ReadOnly,
        Users = 1,
        HeadlineKind = PerfHeadlineKinds.MedianOpMs,
        ReaderUnit = "ms per period",
        OpsUnit = "reports",
        DefaultOpsPerPass = 12,
        DefaultPasses = 3,
        DefaultWarmUpPasses = 1,
        DefaultWarmUpOpsPerWorker = 0,
        OrderedChecksum = true,
        ParityExpected = true,
        ErrorsInvalidate = true,
        IsDestructive = false,
        IsOptional = false,
        OperationCapMs = 60000,
        LegacyTestCode = null,
        DisplayName = "Trial balance",
        ShortDescription = "Latest general-ledger balance per branch, account and subaccount at or before one period (GLHistoryByPeriod), 12 periods per pass; capped at 60 s per period.",
        Question = "How long does a month-end trial balance take?",
        WhatItSimulates = "The trial balance / account summary logic: for every branch, account and subaccount, take the latest general-ledger balance at or before the chosen period, using Acumatica's own GLHistoryByPeriod view.",
        WhyItMatters = "Month-end close runs many balance reports like this. For every account it must find the latest balance at or before the chosen month, a demanding kind of question that databases can handle in very different ways. If finance runs many balance reports at close, watch this test."
    };

    internal static readonly PerfTestDescriptor GLAccountDetails = new PerfTestDescriptor
    {
        TestCode = PerfScenarioCodes.GLAccountDetails,
        SortOrder = 230,
        ShortLabel = "Acct details",
        Category = "Report",
        Family = PerfFamilies.Reports,
        RunBlock = PerfBlocks.ReadOnly,
        Users = 1,
        HeadlineKind = PerfHeadlineKinds.MedianOpMs,
        ReaderUnit = "ms per account",
        OpsUnit = "reports",
        DefaultOpsPerPass = 56,
        DefaultPasses = 2,
        DefaultWarmUpPasses = 1,
        DefaultWarmUpOpsPerWorker = 0,
        OrderedChecksum = true,
        ParityExpected = true,
        ErrorsInvalidate = true,
        IsDestructive = false,
        IsOptional = false,
        OperationCapMs = 0,
        LegacyTestCode = null,
        DisplayName = "GL account details for a year",
        ShortDescription = "Opening balance plus every posted general-ledger line with its batch for one account and fiscal year 2025 (56 accounts per pass).",
        Question = "How long does it take to list a year of transactions for a GL account, with its opening balance?",
        WhatItSimulates = "The Account Details inquiry (GL404000) for one account and fiscal year on the biggest table, GLTran (302,000 rows): opening balance plus every posted line with its batch.",
        WhyItMatters = "Accountants drill into accounts constantly, and the general ledger is where a company's data grows fastest. This test shows how each database handles a year of lines for one account in the largest table in this dataset (302,000 lines). It does not show what happens at ten times that size."
    };

    internal static readonly PerfTestDescriptor LargeListPaging = new PerfTestDescriptor
    {
        TestCode = PerfScenarioCodes.LargeListPaging,
        SortOrder = 240,
        ShortLabel = "Paging+count",
        Category = "Report",
        Family = PerfFamilies.Reports,
        RunBlock = PerfBlocks.ReadOnly,
        Users = 1,
        HeadlineKind = PerfHeadlineKinds.MedianPassMs,
        ReaderUnit = "s per pass of 12 requests",
        OpsUnit = "requests",
        DefaultOpsPerPass = 12,
        DefaultPasses = 3,
        DefaultWarmUpPasses = 1,
        DefaultWarmUpOpsPerWorker = 0,
        OrderedChecksum = true,
        ParityExpected = true,
        ErrorsInvalidate = true,
        IsDestructive = false,
        IsOptional = false,
        OperationCapMs = 0,
        LegacyTestCode = null,
        DisplayName = "Deep paging and counting in a 300,000-line journal",
        ShortDescription = "Ten pages of 100 journal lines at offsets up to 300,000 in two sort orders, plus two record counts (12 requests per pass).",
        Question = "When an integration or report pages deep into a very large list, or asks \"how many records?\", how long does it wait?",
        WhatItSimulates = "Integrations, API clients ($skip paging) and reports that page deep into the 302,000-line Journal Transactions list in two sort orders, plus the record counts that grids show in their footers. (Acumatica's own grids reach the last page by reversing the sort, not by skipping 300,000 rows.)",
        WhyItMatters = "Skipping rows costs time in proportion to the skip on every database, and counting a large table costs more on some databases than on others. Integrations that page through big lists, and every grid footer that shows '1–100 of 302,062', depend on it."
    };

    private static readonly PerfTestDescriptor[] All = { SalesByCustomerMonth, TrialBalance, GLAccountDetails, LargeListPaging };

    public IEnumerable<PerfTestDescriptor> Descriptors => All;

    public IPerfScenario Create(string testCode)
    {
        if (Is(testCode, PerfScenarioCodes.SalesByCustomerMonth)) return new ReportSalesByCustomerMonthScenario(SalesByCustomerMonth);
        if (Is(testCode, PerfScenarioCodes.TrialBalance)) return new ReportTrialBalanceScenario(TrialBalance);
        if (Is(testCode, PerfScenarioCodes.GLAccountDetails)) return new ReportGLAccountDetailsScenario(GLAccountDetails);
        if (Is(testCode, PerfScenarioCodes.LargeListPaging)) return new ReportLargeListPagingScenario(LargeListPaging);
        return null;
    }

    private static bool Is(string testCode, string code) =>
        string.Equals(testCode?.Trim(), code, StringComparison.OrdinalIgnoreCase);
}
