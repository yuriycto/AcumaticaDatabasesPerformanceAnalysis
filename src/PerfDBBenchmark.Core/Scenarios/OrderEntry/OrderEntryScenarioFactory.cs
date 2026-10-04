using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace PerfDBBenchmark.Core.Scenarios.OrderEntry;

/// <summary>
/// Family ORD (Block C): "Order entry" (1 clerk) and "Many users" (4/8/16 clerks, spread and hot-item variants).
/// Descriptor values exactly as SPEC §1.2; reader texts exactly as the §1.6 cards. No database access here.
/// </summary>
public sealed class OrderEntryScenarioFactory : IPerfScenarioFactory
{
    private const string EntryQuestionMany =
        "When more people enter orders at the same time, how many orders per minute does the system handle, and how much longer does each person wait?";
    private const string EntryWhatMany =
        "A busy order desk: 4, 8 or 16 clerks each entering orders non-stop, with no pause between orders, for different customers and products. The only shared rows are the order-number counter and system bookkeeping.";
    private const string EntryWhyMany =
        "This is the scaling question that matters most for a growing company. A database that handles parallel work well keeps raising orders per minute from 1 to 16 clerks with only a modest rise in each clerk's wait. Because nobody pauses, 16 clerks here stand for a much larger real team.";

    private const string HotQuestion =
        "What happens when everyone sells the same popular product at the same moment?";
    private const string HotWhat =
        "The same busy order desk, but every order includes the best-selling item from the same warehouse, so every save must update the same stock-availability row and saves queue behind each other.";
    private const string HotWhy =
        "Real businesses have hot spots: one bestseller, one warehouse, one GL account. Compare with the spread version at the same number of people: it shows whether each database's locking makes people wait in an orderly line, hit deadlocks that Acumatica must retry, or fail outright.";

    private static readonly PerfTestDescriptor[] All_ =
    {
        Descriptor(
            PerfScenarioCodes.SoEntryU01, 310, "SO 1u", PerfFamilies.OrderEntry, 1, PerfHeadlineKinds.MedianOpMs, "ms per order saved",
            opsPerPass: 60, warmUpOpsPerWorker: 10, errorsInvalidate: true,
            displayName: "Enter sales orders – 1 clerk",
            shortDescription: "SOOrderEntry: insert a header and 3 lines, then Save (customer AACUSTOMER, pinned date 2026-06-30); orders deleted after each pass.",
            question: "How long does saving a typical 3-line sales order take?",
            what: "A clerk entering an order on the Sales Orders form with the full business logic: defaults, pricing, availability, the inventory plan, numbering and save — about 20–40 database statements across about ten tables in one transaction.",
            why: "This is the everyday write that order desks and integrations do thousands of times a day. One person's save time is mostly Acumatica's own work; any remaining gap between databases is the cost of many small reads and writes inside one business transaction plus how fast each database commits."),

        ManyEntry(PerfScenarioCodes.SoEntryU04, 320, "SO 4u", 4, 80),
        ManyEntry(PerfScenarioCodes.SoEntryU08, 330, "SO 8u", 8, 160),
        ManyEntry(PerfScenarioCodes.SoEntryU16, 340, "SO 16u", 16, 320),

        HotEntry(PerfScenarioCodes.SoHotItemU04, 350, "Hot 4u", 4, 80),
        HotEntry(PerfScenarioCodes.SoHotItemU08, 360, "Hot 8u", 8, 160),
        HotEntry(PerfScenarioCodes.SoHotItemU16, 370, "Hot 16u", 16, 320)
    };

    public IEnumerable<PerfTestDescriptor> Descriptors => All_;

    public IPerfScenario Create(string testCode)
    {
        var d = All_.FirstOrDefault(x => string.Equals(x.TestCode, testCode, StringComparison.OrdinalIgnoreCase));
        if (d == null) return null;
        var hot = d.TestCode.StartsWith("ORD_SO_HOTITEM_", StringComparison.Ordinal);
        return new SalesOrderEntryScenario(d, hot);
    }

    private static PerfTestDescriptor ManyEntry(string code, int sortOrder, string shortLabel, int users, int opsPerPass) =>
        Descriptor(
            code, sortOrder, shortLabel, PerfFamilies.ManyUsers, users, PerfHeadlineKinds.OpsPerMin, "orders per minute",
            opsPerPass: opsPerPass, warmUpOpsPerWorker: 5, errorsInvalidate: false,
            displayName: "Enter sales orders – " + U(users) + " clerks working non-stop",
            shortDescription: "SOOrderEntry: insert a header and 3 lines, then Save; " + U(users) + " workers without pauses, disjoint customers and items per worker; orders deleted after each pass.",
            question: EntryQuestionMany,
            what: EntryWhatMany,
            why: EntryWhyMany);

    private static PerfTestDescriptor HotEntry(string code, int sortOrder, string shortLabel, int users, int opsPerPass) =>
        Descriptor(
            code, sortOrder, shortLabel, PerfFamilies.ManyUsers, users, PerfHeadlineKinds.OpsPerMin, "orders per minute",
            opsPerPass: opsPerPass, warmUpOpsPerWorker: 5, errorsInvalidate: false,
            displayName: "Everyone sells the best-seller – " + U(users) + " clerks working non-stop",
            shortDescription: "As the spread variant, but line 0 of every order is AACOMPUT01 @ WHOLESALE, qty 1: " + U(users) + " workers update the same stock-availability row.",
            question: HotQuestion,
            what: HotWhat,
            why: HotWhy);

    private static string U(int users) => users.ToString(CultureInfo.InvariantCulture);

    private static PerfTestDescriptor Descriptor(
        string code, int sortOrder, string shortLabel, string family, int users, string headlineKind, string readerUnit,
        int opsPerPass, int warmUpOpsPerWorker, bool errorsInvalidate,
        string displayName, string shortDescription, string question, string what, string why) =>
        new PerfTestDescriptor
        {
            TestCode = code,
            LegacyTestCode = null,
            Family = family,
            RunBlock = PerfBlocks.OrderEntry,
            Category = "Order",
            DisplayName = displayName,
            ShortLabel = shortLabel,
            ActionName = PerfScenarioCodes.RunBenchmarkAction,
            ShortDescription = shortDescription,
            Question = question,
            WhatItSimulates = what,
            WhyItMatters = why,
            ReaderUnit = readerUnit,
            SortOrder = sortOrder,
            Users = users,
            HeadlineKind = headlineKind,
            OpsUnit = "orders",
            ParityExpected = true,
            OrderedChecksum = false,
            IsDestructive = false,
            IsOptional = false,
            ExcludeFromComparison = false,
            // 2: runs in the PRODWHOLE session-branch context (PerfBranchContext; v1 saved no order).
            // 3: the per-pass cleanup deletes the orders (v2 left every order behind: the delete used a detached copy of the
            //    order) and orderState counts SOLine rows instead of LineCntr (lines and splits share LineCntr).
            ScenarioVersion = 3,
            DefaultOpsPerPass = opsPerPass,
            DefaultPasses = 1,
            DefaultWarmUpPasses = 0,
            DefaultWarmUpOpsPerWorker = warmUpOpsPerWorker,
            OperationCapMs = 0,
            ErrorsInvalidate = errorsInvalidate
        };
}
