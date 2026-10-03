using System;
using System.Collections.Generic;

namespace PerfDBBenchmark.Core.Scenarios.Screens;

/// <summary>
/// Family SCR "Everyday screens" (SPEC §1.1 rows 1-4, descriptor values §1.2, card texts §1.5). Block A, read-only, W = 1.
/// No database access in the constructor or in Descriptors (SPEC §4.8 rule 3).
/// </summary>
public sealed class ScreensScenarioFactory : IPerfScenarioFactory
{
    internal static readonly PerfTestDescriptor OpenSalesOrder = new PerfTestDescriptor
    {
        TestCode = PerfScenarioCodes.OpenSalesOrder,
        SortOrder = 110,
        ShortLabel = "Open SO",
        Category = "Screen",
        Family = PerfFamilies.Screens,
        RunBlock = PerfBlocks.ReadOnly,
        Users = 1,
        HeadlineKind = PerfHeadlineKinds.MedianOpMs,
        ReaderUnit = "ms per order opened",
        OpsUnit = "screens",
        DefaultOpsPerPass = 500,
        DefaultPasses = 1,
        DefaultWarmUpPasses = 1,
        DefaultWarmUpOpsPerWorker = 0,
        OrderedChecksum = true,
        ParityExpected = true,
        ErrorsInvalidate = true,
        IsDestructive = false,
        IsOptional = false,
        OperationCapMs = 0,
        LegacyTestCode = null,
        DisplayName = "Open a sales order",
        ShortDescription = "Opens sales orders through Acumatica's sales-order logic (SOOrderEntry) and reads the 12 views of the Sales Orders form.",
        Question = "How fast does a sales order open on screen?",
        WhatItSimulates = "Opening an existing order on the Sales Orders form (SO301000) with Acumatica's real sales-order logic and reading what the form shows: header, lines, taxes, shipments, payments, addresses, contacts, currency, commissions and discounts.",
        WhyItMatters = "Opening a document is what everyone does all day. It is not one big query but 15–25 small ones, so the fixed cost of each request to the database matters more than raw power. This number is the database-dependent part of opening the form; the browser and the network add the same time on every database."
    };

    internal static readonly PerfTestDescriptor CustomerOrderHistory = new PerfTestDescriptor
    {
        TestCode = PerfScenarioCodes.CustomerOrderHistory,
        SortOrder = 120,
        ShortLabel = "Cust orders",
        Category = "Screen",
        Family = PerfFamilies.Screens,
        RunBlock = PerfBlocks.ReadOnly,
        Users = 1,
        HeadlineKind = PerfHeadlineKinds.MedianOpMs,
        ReaderUnit = "ms per lookup",
        OpsUnit = "lookups",
        DefaultOpsPerPass = 78,
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
        DisplayName = "A customer's order history",
        ShortDescription = "The 20 newest sales orders of one customer plus the record count shown in the grid footer.",
        Question = "How fast does a customer's order list show the newest orders and the total count?",
        WhatItSimulates = "The Sales Orders list filtered to one customer: the 20 newest orders plus the 'N records' count in the grid footer.",
        WhyItMatters = "'Find this customer's records, newest first, and tell me how many there are' is the most common list in any ERP. It tests whether the database can jump straight to one customer's rows, sort them and count them quickly."
    };

    internal static readonly PerfTestDescriptor ItemBuyers = new PerfTestDescriptor
    {
        TestCode = PerfScenarioCodes.ItemBuyers,
        SortOrder = 130,
        ShortLabel = "Item buyers",
        Category = "Screen",
        Family = PerfFamilies.Screens,
        RunBlock = PerfBlocks.ReadOnly,
        Users = 1,
        HeadlineKind = PerfHeadlineKinds.MedianOpMs,
        ReaderUnit = "ms per lookup",
        OpsUnit = "lookups",
        DefaultOpsPerPass = 91,
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
        DisplayName = "Who bought this item?",
        ShortDescription = "The 50 most recent sales-order lines of one item with order date and customer, plus total lines, quantity and amount.",
        Question = "How fast can I see the latest sales of a product and its totals?",
        WhatItSimulates = "A sales-history lookup for one item: the 50 most recent sales-order lines with order date and customer, plus total lines, quantity and amount.",
        WhyItMatters = "A classic 'find by product, then fetch each line's order and customer' lookup: many small key lookups joined together. It shows how efficiently each database follows relationships between tables, which most detail screens and inquiries rely on."
    };

    internal static readonly PerfTestDescriptor CustomerSearch = new PerfTestDescriptor
    {
        TestCode = PerfScenarioCodes.CustomerSearch,
        SortOrder = 140,
        ShortLabel = "Cust search",
        Category = "Screen",
        Family = PerfFamilies.Screens,
        RunBlock = PerfBlocks.ReadOnly,
        Users = 1,
        HeadlineKind = PerfHeadlineKinds.MedianOpMs,
        ReaderUnit = "ms per search",
        OpsUnit = "searches",
        DefaultOpsPerPass = 100,
        DefaultPasses = 1,
        DefaultWarmUpPasses = 1,
        DefaultWarmUpOpsPerWorker = 0,
        OrderedChecksum = false,
        ParityExpected = true,
        ErrorsInvalidate = true,
        IsDestructive = false,
        IsOptional = false,
        OperationCapMs = 0,
        LegacyTestCode = null,
        DisplayName = "Find a customer by part of the name",
        ShortDescription = "A 'contains' search on customer ID and name with all matches returned (20 name fragments, 5 times each).",
        Question = "When I type part of a customer's name, how fast do matches appear, and does every database find the same customers?",
        WhatItSimulates = "The quick search in the customer selector: a 'contains' search on customer ID and name, all matches returned.",
        WhyItMatters = "The customer list is small, so speed differences here mostly reflect the fixed cost of each request to the database. The bigger message is about answers: a wildcard search cannot use a normal index on any of these databases, and the three treat accented letters differently. If your names contain accents, users can see different search results depending on the database."
    };

    private static readonly PerfTestDescriptor[] All = { OpenSalesOrder, CustomerOrderHistory, ItemBuyers, CustomerSearch };

    public IEnumerable<PerfTestDescriptor> Descriptors => All;

    public IPerfScenario Create(string testCode)
    {
        if (Is(testCode, PerfScenarioCodes.OpenSalesOrder)) return new ScreenOpenSalesOrderScenario(OpenSalesOrder);
        if (Is(testCode, PerfScenarioCodes.CustomerOrderHistory)) return new ScreenCustomerOrderHistoryScenario(CustomerOrderHistory);
        if (Is(testCode, PerfScenarioCodes.ItemBuyers)) return new ScreenItemBuyersScenario(ItemBuyers);
        if (Is(testCode, PerfScenarioCodes.CustomerSearch)) return new ScreenCustomerSearchScenario(CustomerSearch);
        return null;
    }

    private static bool Is(string testCode, string code) =>
        string.Equals(testCode?.Trim(), code, StringComparison.OrdinalIgnoreCase);
}
