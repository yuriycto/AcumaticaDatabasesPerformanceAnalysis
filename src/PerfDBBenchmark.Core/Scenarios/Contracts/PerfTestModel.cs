using System;

namespace PerfDBBenchmark.Core.Scenarios;

/// <summary>Static description of one test (one catalog row, SPEC §1.1). Pure data; created by the family factories.</summary>
public sealed class PerfTestDescriptor
{
    public string TestCode { get; init; }                   // ≤ 64 chars, e.g. CORE_READ_1U
    public string LegacyTestCode { get; init; }             // SEQ_READ … for CORE codes, else null
    public string Family { get; init; } = PerfFamilies.Core;
    public string RunBlock { get; init; } = PerfBlocks.Core;
    public string Category { get; init; }                   // legacy grid column (Read, Write, Update, Delete, Join, SlimJoin, Screen, Report, Order, Invoice)
    public string DisplayName { get; init; }                // exact reader-facing name, ≤ 128 chars (SPEC §1.1)
    public string ShortLabel { get; init; }                 // chart label, ≤ 16 chars
    public string ActionName { get; init; } = PerfScenarioCodes.RunBenchmarkAction;
    public string ShortDescription { get; init; }           // tooltip, ≤ 255 chars
    public string Question { get; init; }                   // ≤ 1024 chars, plain language
    public string WhatItSimulates { get; init; }            // ≤ 1024 chars, plain language
    public string WhyItMatters { get; init; }               // ≤ 1024 chars, plain language
    public string ReaderUnit { get; init; }                 // e.g. "ms per order opened", "s per 10,000 records", "orders per minute"
    public int SortOrder { get; init; }
    public int Users { get; init; } = 1;                    // W: simulated users (in-process worker threads)
    public string HeadlineKind { get; init; } = PerfHeadlineKinds.MedianOpMs;
    public string OpsUnit { get; init; } = "operations";    // rows, chunks, pages, screens, lookups, reports, requests, orders, invoices
    public bool ParityExpected { get; init; } = true;
    public bool OrderedChecksum { get; init; }              // true only when Users == 1 and ORDER BY ends in a unique collation-safe key
    public bool IsDestructive { get; init; }                // permanent data changes (INV only)
    public bool IsOptional { get; init; }
    public bool ExcludeFromComparison { get; init; }        // ENV_CAPTURE
    public int ScenarioVersion { get; init; } = 1;
    public int DefaultOpsPerPass { get; init; }
    public int DefaultPasses { get; init; } = 1;            // measured passes per run
    public int DefaultWarmUpPasses { get; init; }           // untimed full passes before the measured ones
    public int DefaultWarmUpOpsPerWorker { get; init; }     // untimed ops per worker before the start gate (ORD/INV)
    public int OperationCapMs { get; init; }                // 0 = no cap; RPT_TRIAL_BALANCE = 60000
    public bool ErrorsInvalidate { get; init; } = true;     // false for ORD_*_U04/U08/U16 and INV_RELEASE_TO_GL_U04 (errors are a reported result)

    public bool HigherIsBetter => HeadlineKind == PerfHeadlineKinds.OpsPerMin;
    public string HeadlineUnit => HeadlineKind == PerfHeadlineKinds.OpsPerMin ? "ops/min" : HeadlineKind == PerfHeadlineKinds.None ? "" : "ms";
    public string ExecutionMode => Users <= 1 ? "Sequential" : "Parallel";
}

/// <summary>Immutable input of one run (one RunBenchmark request), built by the graph from the control row.</summary>
public sealed class PerfRunRequest
{
    public Guid RequestID { get; init; }
    public string TestCode { get; init; }                   // always a catalog code (legacy aliases already mapped)
    public int NumberOfRecords { get; init; }               // CORE: N   (control field NumberOfRecords)
    public int Iterations { get; init; }                    // CORE: measured passes I (control field Iterations)
    public int BatchSize { get; init; }                     // CORE: rows per chunk and per commit C (control field ParallelBatchSize)
    public string DatabaseType { get; init; }               // PerfDatabaseEngines.* value
    public string InstanceName { get; init; }
    public DateTime RequestedAtUtc { get; init; }
    public string RequestedBy { get; init; }

    public Guid? CampaignID { get; init; }
    public int? RepetitionNo { get; init; }                 // 0 = block warm-up repetition
    public bool IsWarmup { get; init; }
    public string RunBlock { get; init; }
    public int? OrderPosition { get; init; }                // 1..3
    public decimal WorkScale { get; init; } = 1m;           // (0,1]: scales ops per pass (ceil, at least Users); 1 = full
    public int? PassesOverride { get; init; }               // > 0 overrides measured passes
    public int? WarmUpPassesOverride { get; init; }         // >= 0 overrides warm-up passes
    public int? RunBudgetSec { get; init; }                 // > 0: per-run time budget in seconds; null/0 = PerfRunPlan.DefaultRunBudget; never hashed
}
