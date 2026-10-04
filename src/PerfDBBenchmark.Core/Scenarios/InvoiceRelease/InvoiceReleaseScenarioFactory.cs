using System;
using System.Collections.Generic;
using System.Linq;

namespace PerfDBBenchmark.Core.Scenarios.InvoiceRelease;

/// <summary>
/// Family INV (Block D, destructive, run last after backups): create an AR invoice and release it with automatic GL posting.
/// Descriptor values exactly as SPEC §1.2; reader texts exactly as the §1.7 cards. No database access here.
/// </summary>
public sealed class InvoiceReleaseScenarioFactory : IPerfScenarioFactory
{
    private static readonly PerfTestDescriptor[] All_ =
    {
        Descriptor(
            PerfScenarioCodes.InvoiceReleaseU01, 410, "Invoice 1u", 1, PerfHeadlineKinds.MedianOpMs, "ms per invoice",
            opsPerPass: 40, warmUpOpsPerWorker: 10, errorsInvalidate: true, isOptional: false,
            displayName: "Create and release invoices to the GL – 1 person",
            shortDescription: "ARInvoiceEntry: create an invoice with 2 non-stock lines (100.00 + 250.00), Save, then ReleaseProcess with automatic GL posting. Permanent.",
            question: "How long does it take to create a customer invoice, release it and post it to the general ledger?",
            what: "Invoices and Memos (AR301000) followed by Release with automatic GL posting: the invoice, customer balance, AR history, a new GL batch and the GL balances for this period and all later periods are written.",
            why: "Releasing and posting documents is the heaviest routine write in accounting. Each release updates running totals that many documents share. The 1-person number shows the raw cost of posting; if month-end close is your bottleneck, weight this family most."),

        Descriptor(
            PerfScenarioCodes.InvoiceReleaseU04, 420, "Invoice 4u", 4, PerfHeadlineKinds.OpsPerMin, "invoices per minute",
            opsPerPass: 60, warmUpOpsPerWorker: 3, errorsInvalidate: false, isOptional: true,
            displayName: "Create and release invoices to the GL – 4 people working non-stop",
            shortDescription: "As the 1-person test with 4 workers without pauses, one customer each, all posting to the same AR and sales accounts. Permanent.",
            question: "Can four people release and post invoices at the same time, or do they queue?",
            what: "Four people releasing invoices for different customers at once; all post to the same AR and sales accounts, so they share the same GL balance rows — the real contention of a month-end mass release.",
            why: "Month-end batches are often released side by side. This shows whether posting scales with more people or turns into a queue, and whether any database has to retry or fails.")
    };

    public IEnumerable<PerfTestDescriptor> Descriptors => All_;

    public IPerfScenario Create(string testCode)
    {
        var d = All_.FirstOrDefault(x => string.Equals(x.TestCode, testCode, StringComparison.OrdinalIgnoreCase));
        return d == null ? null : new InvoiceReleaseScenario(d);
    }

    private static PerfTestDescriptor Descriptor(
        string code, int sortOrder, string shortLabel, int users, string headlineKind, string readerUnit,
        int opsPerPass, int warmUpOpsPerWorker, bool errorsInvalidate, bool isOptional,
        string displayName, string shortDescription, string question, string what, string why) =>
        new PerfTestDescriptor
        {
            TestCode = code,
            LegacyTestCode = null,
            Family = PerfFamilies.InvoiceRelease,
            RunBlock = PerfBlocks.Destructive,
            Category = "Invoice",
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
            OpsUnit = "invoices",
            ParityExpected = true,
            OrderedChecksum = false,
            IsDestructive = true,
            IsOptional = isOptional,
            ExcludeFromComparison = false,
            // 2: runs in the PRODWHOLE session-branch context (PerfBranchContext).
            // 3: the invoice header clears RetainageApply (v2: Customers20[2] BNRCONTRAC got 10 % retainage, 315.00 + 35.00 on the
            //    retainage receivable account, 4 GL lines; U04 invoiceAmountSum/glTranDelta failed identically on all engines).
            ScenarioVersion = 3,
            DefaultOpsPerPass = opsPerPass,
            DefaultPasses = 1,
            DefaultWarmUpPasses = 0,
            DefaultWarmUpOpsPerWorker = warmUpOpsPerWorker,
            OperationCapMs = 0,
            ErrorsInvalidate = errorsInvalidate
        };
}
