# PerfDBBenchmark technical reference (Acumatica 2026 R2)

This page holds the technical detail behind the [main README](../README.md): what the customization contains, how a test run works, the tables and Fluent BQL (FBQL) queries, the REST endpoint, the web.config and database settings used for the campaign, the PowerShell scripts and the output files. The results and the business conclusions are in the main README.

`PerfDBBenchmark` is a DLL-based Acumatica 2026 R2 (build 26.200.0334) customization that runs the same Acumatica workloads on three instances, one per database (Microsoft SQL Server, MySQL 8.0 and PostgreSQL), and compares them. Created by AcuPower LTD for performance analysis ([acupowererp.com](https://acupowererp.com)).

## Contents

- [What the customization includes](#what-the-customization-includes)
- [Project layout](#project-layout)
- [Instances](#instances)
- [Test catalog](#test-catalog)
- [How a run works](#how-a-run-works)
- [Tables, projections and FBQL queries](#tables-projections-and-fbql-queries)
- [REST endpoint](#rest-endpoint)
- [web.config settings](#webconfig-settings)
- [Campaign environment settings](#campaign-environment-settings)
- [PowerShell scripts](#powershell-scripts)
- [Output files](#output-files)
- [Winner and tie rule (formal version)](#winner-and-tie-rule-formal-version)
- [Notes](#notes)

---

## What the customization includes

- **Screen `AC301000` (benchmark control).** Parameters, the "Run a test" panel (test to run, work scale, measured and warm-up passes override, run budget, campaign ID, repetition), the actions `RunBenchmark`, `AbortBenchmark`, `ClearTestRecords` and `ClearTestData`, the benchmark catalog, local results, an indicative cross-instance comparison and per-family charts. The 12 buttons of the previous edition are kept in a collapsed "Legacy buttons" group; they now run the re-baselined `CORE_*` tests.
- **Screen `AC301001` (results).** Every stored result row with its full `ResultJson`.
- **REST endpoint `PerfDBBenchmark/26.200.001`.** Used by the campaign suite; see [REST endpoint](#rest-endpoint).
- **Scenario engine** (`Scenarios/Engine`). Runs one test at a time inside a long operation, times only the measured operation, runs 1, 4, 8 or 16 workers behind a start gate, counts errors, deadlocks and retries, enforces the run budget and writes one result row per run.
- **29 test scenarios in 6 families**, plus `ENV_CAPTURE` (environment and data fingerprints, run before every repetition) and `ENV_WORKERS_PROBE` (proves that 16 workers can run at once). Scenarios are discovered by a registry (`PerfScenarioRegistry`) from factories; a factory that fails to load is skipped and listed in `PerfScenarioRegistry.LoadErrors`, and the screen stays usable.
- **Cross-instance snapshots** written to `<site>\App_Data\PerfDBBenchmark\perfdbbenchmark-results.json` (schema v2), used by the indicative in-app comparison.
- **A precompiled .NET Framework 4.8 DLL** that uses modern C# features, so the customization is deployed as a compiled assembly, not compiled at runtime inside Acumatica.
- **A built-in access-rights bootstrap** for `AC301000` and `AC301001` that copies `RolesInGraph` entries from stock Acumatica screens at runtime, so the screen permissions come with the DLL and no SQL script is needed after publishing.

The in-app comparison on `AC301000` is **indicative only** (5% band, shown only when parameters and DLL match). The published verdicts come only from the report generator (`scripts/New-PerfDBBenchmarkReport.ps1`).

## Project layout

```
src/PerfDBBenchmark.Core/
  DAC/PerfBenchmarkDacs.cs            control row, test records, results, catalog and comparison DACs, PerfBenchmarkProjection
  Graphs/                             PerfDBBenchmarkGraph (AC301000), PerfDBBenchmarkResultsGraph (AC301001)
  Pages/AC301000.cs                   classic code-behind (charts)
  Support/                            hardware detection, legacy codes, access-rights bootstrap
  Scenarios/
    Contracts/                        descriptors, run plan, scenario interfaces, registry, constants (methodology 2026R2-M2)
    Common/                           checksums, statistics, PerfWorkerGraph
    Engine/                           PerfScenarioRunner, start gate, result writer, run control (budget/abort), exception counter,
                                      NoOp throttler, runtime info
    Core/                             CORE_* (platform basics: the original 12, re-baselined)
    Screens/                          SCR_* (everyday screens)
    Reports/                          RPT_* (reports & month-end)
    OrderEntry/                       ORD_* (order entry and many users)
    InvoiceRelease/                   INV_* (invoice release to GL)
    Business/                         data pools and leftover cleaner shared by ORD and INV
    Environment/                      ENV_CAPTURE and ENV_WORKERS_PROBE
customization/PerfDBBenchmark/        Acumatica customization project: project.xml, classic ASPX pages, Modern UI sources
scripts/                              build, publish, environment capture, campaign suite, report generator, browser smoke test
scripts/samples/                      synthetic campaign fixture and credential-file templates
docs/                                 README images (docs/images/2026r2), this page, docs/history (2026 R1 results),
                                      docs/results/2026r2 (analysis.json, README fragments and HTML report of the campaign)
artifacts/                            build output and benchmark reports (git-ignored)
```

## Instances

The scripts default to three local Acumatica 2026 R2 instances, each backed by a different database:

| Instance | Database engine | URL | Database / schema | Login used by Acumatica | Provider |
|---|---|---|---|---|---|
| `PerfSQL` | Microsoft SQL Server 2025 | `http://localhost/PerfSQL` | `PerfSQL` | Windows login `IIS APPPOOL\PerfSQL` | SQL Server provider |
| `PerfMySQL` | MySQL 8.0 | `http://localhost/PerfMySQL` | `perfmysql` | `acumatica` (ALL on `perfmysql`) | `PX.MySql.MySqlDatabaseProvider` (MySqlConnector 1.3.14) |
| `PerfPG` | PostgreSQL 18 | `http://localhost/PerfPG` | `"PerfPG"` (mixed case: quote it) | `acumatica` (SUPERUSER) | PostgreSQL provider (Npgsql 6.0.13) |

- The instance root defaults to `D:\Instances\26.200.0334`; each site has its own IIS application pool. Tenant 2 holds the SalesDemo company.
- The broad database rights of the `acumatica` logins are needed to **publish** the customization: on PostgreSQL the publish runs a system-catalog update that only a superuser may do, and on MySQL it can need index, trigger and routine rights. These are test settings for a single machine, not a production recommendation: once publishing is done, a production installation should grant the logins only the rights it needs.
- All names can be overridden with script parameters, for example:

```powershell
-Instances @("MyPostgres", "MyMySQL", "MySQLServer")
-InstanceRoot "D:\AcumaticaSites\2026R2"
```

The publish script also accepts `PerfrMySQL` / `PerfrSQL` as candidate folder names, in case an instance was created with that spelling. The database type is detected from the provider type (`PerfDatabaseEngines.Detect()`), with the site folder name as a fallback.

## Test catalog

29 result codes in 6 families and 4 blocks, plus the gate run `ENV_CAPTURE`. "Users" are worker threads inside one Acumatica long operation (the instances are unlicensed: 2 users / 2 API users), working with no think time. A test with a fixed amount of work reports time (lower is better); a test with a fixed number of people reports throughput (higher is better).

| TestCode | Family (block) | Display name | Users | Ops per pass | Warm-up | Measured passes | Headline (reader unit) | Legacy code |
|---|---|---|---|---|---|---|---|---|
| `SCR_OPEN_SALES_ORDER` | Screens (A) | Open a sales order | 1 | 500 orders | 1 pass | 1 | median ms per order opened | – |
| `SCR_CUSTOMER_ORDER_HISTORY` | Screens (A) | A customer's order history | 1 | 78 customers | 1 pass | 2 | median ms per lookup | – |
| `SCR_ITEM_BUYERS` | Screens (A) | Who bought this item? | 1 | 91 items | 1 pass | 2 | median ms per lookup | – |
| `SCR_CUSTOMER_SEARCH` | Screens (A) | Find a customer by part of the name | 1 | 100 searches | 1 pass | 1 | median ms per search | – |
| `RPT_SALES_BY_CUSTOMER_MONTH` | Reports (A) | Sales by customer and month | 1 | 14 years | 1 pass | 3 | median ms per yearly report | – |
| `RPT_TRIAL_BALANCE` | Reports (A) | Trial balance | 1 | 12 periods | 1 pass | 3 | median ms per period (cap 60 s per operation) | – |
| `RPT_GL_ACCOUNT_DETAILS` | Reports (A) | GL account details for a year | 1 | 56 accounts | 1 pass | 2 | median ms per account | – |
| `RPT_LARGE_LIST_PAGING` | Reports (A) | Deep paging and counting in a 300,000-line journal | 1 | 12 requests | 1 pass | 3 | median s per pass of 12 requests | – |
| `ORD_SO_ENTRY_U01` | OrderEntry (C) | Enter sales orders – 1 clerk | 1 | 60 orders | 10 orders | 1 | median ms per order saved | – |
| `ORD_SO_ENTRY_U04` / `_U08` / `_U16` | ManyUsers (C) | Enter sales orders – 4 / 8 / 16 clerks working non-stop | 4 / 8 / 16 | 80 / 160 / 320 | 5 per worker | 1 | orders per minute | – |
| `ORD_SO_HOTITEM_U04` / `_U08` / `_U16` | ManyUsers (C) | Everyone sells the best-seller – 4 / 8 / 16 clerks working non-stop | 4 / 8 / 16 | 80 / 160 / 320 | 5 per worker | 1 | orders per minute | – |
| `INV_RELEASE_TO_GL_U01` | InvoiceRelease (D) | Create and release invoices to the GL – 1 person | 1 | 40 invoices | 10 invoices | 1 | median ms per invoice | – |
| `INV_RELEASE_TO_GL_U04` | InvoiceRelease (D) | Create and release invoices to the GL – 4 people working non-stop | 4 | 60 invoices | 3 per worker | 1 | invoices per minute | – |
| `CORE_READ_1U` / `_8U` | Core (B) | Load 10,000 records – 1 worker / one job shared by 8 parallel workers | 1 / 8 | 40 chunks | 1 pass | 3 | median s per 10,000-record job | `SEQ_READ` / `PAR_READ` |
| `CORE_INSERT_1U` / `_8U` | Core (B) | Save 10,000 new records – … | 1 / 8 | 40 chunks | 1 pass | 3 | median s per 10,000-record job | `SEQ_WRITE` / `PAR_WRITE` |
| `CORE_UPDATE_1U` / `_8U` | Core (B) | Change 10,000 records – … | 1 / 8 | 40 chunks | 1 pass | 3 | median s per 10,000-record job | `SEQ_UPDATE` / `PAR_UPDATE` |
| `CORE_DELETE_1U` / `_8U` | Core (B) | Delete 10,000 records – … | 1 / 8 | 40 chunks | 1 pass | 3 | median s per 10,000-record job | `SEQ_DELETE` / `PAR_DELETE` |
| `CORE_JOIN_FULL_1U` / `_8U` | Core (B) | Stock availability list, all columns – … | 1 / 8 | 80 pages | 1 pass | 3 | median ms per list page (pass time ÷ 80) | `SEQ_COMPLEX` / `PAR_COMPLEX` |
| `CORE_JOIN_SLIM_1U` / `_8U` | Core (B) | Stock availability list, only the needed columns – … | 1 / 8 | 80 pages | 1 pass | 3 | median ms per list page (pass time ÷ 80) | `SEQ_PROJECTION` / `PAR_PROJECTION` |
| `ENV_CAPTURE` | Environment (G) | Environment capture | 1 | – | – | – | none (gate, never compared) | – |

- **Blocks:** A = everyday screens and reports (read-only), B = platform basics, C = order entry and many users (self-cleaning), D = invoice release (permanent; run last, after backups). `INV_RELEASE_TO_GL_U04` is marked optional but runs by default.
- **CORE values come from the control row:** N = `NumberOfRecords` (10,000), C = `ParallelBatchSize` (250), measured passes = `Iterations` (3). The engine requires `N % C == 0` and `(N / C) % 8 == 0` at full scale.
- **Legacy codes** are aliases (`PerfLegacyAliases`): old REST clients and the 12 legacy actions run the matching `CORE_*` test.
- **Reader texts:** every descriptor carries `Question`, `WhatItSimulates` and `WhyItMatters`; the README quotes them verbatim. They are also returned by the endpoint's `BenchmarkCatalog`.
- **Fallback:** if the configured thread pool cannot run 16 workers (see `ThreadPoolSize` below), the 16-worker codes become 12-worker codes (`ORD_SO_ENTRY_U12`, `ORD_SO_HOTITEM_U12`) with a new scenario version.

## How a run works

### Lifecycle

The engine (`PerfScenarioRunner`) calls the scenario in this order. **Only `ExecuteOperation` is timed** (`Stopwatch.GetTimestamp()` immediately before and after the call); every other phase is recorded separately in `ResultJson.phasesMs`.

1. `Prepare` (pools, seeds, baselines; untimed) → `CreateWorkerState` (one graph per worker, created on the coordinating thread; untimed).
2. Warm-up: warm-up passes run exactly like measured passes, or warm-up operations per worker (ORD, INV) run before the start gate. Excluded from statistics.
3. For each measured pass: `BeforePass` (untimed; the engine then refreshes every worker graph's row-version stamp), then per operation `BeforeOperation` (untimed) and `ExecuteOperation` (timed), then `AfterPass` (untimed: invariants, cleanup of created documents).
4. `Verify` (invariants and parity values) → `Cleanup` (always runs).

**Pass time:** with 1 worker, the sum of the operation latencies; with W > 1 workers, wall clock from the opening of the start gate to the end of the last worker's last operation (this includes each worker's untimed resets between its own operations, about 0.1 ms for a query-cache clear and about 1 ms for a full reset of a business graph).

**Headline value per run:** `MedianOpMs` = p50 of all successful measured operation latencies; `MedianPassMs` = median of the measured pass times; `OpsPerMin` = median over measured passes of `okOps / (passWallMs / 60000)`. Also stored: `ElapsedMsPrecise` (sum of measured pass times), `OpsPerSec`, p50/p95/max (p99 from 100 operations), per-pass `wallInclResetsMs` and, for W > 1, `steadyOpsPerMin` (operations finished while all W workers were active, a secondary metric).

### Clearing Acumatica's query cache before every timed operation

- Before every operation the engine calls `Clear(PXClearOption.ClearQueriesOnly)` on every graph registered for that worker (untimed). `PXGraph.Clear()` without arguments does **not** clear the query cache.
- Business graphs (`SOOrderEntry`, `ARInvoiceEntry`) are also reset with `Clear(PXClearOption.ClearAll)` in `BeforeOperation`, which is the same as opening a fresh screen.
- Platform-wide caches (setup records, DAC and selector definitions, compiled BQL) stay warm on purpose, as in a running ERP.
- The coordinating thread's graph is query-cache-cleared before `Prepare`, `BeforePass`, `AfterPass`, `Verify` and `Cleanup`.
- `QueryCacheLevel` is never set in web.config. The dry run proves the cache defeat on SQL Server (step 3f): it counts the matching statements (`sys.dm_exec_query_stats`, cross-checked in Query Store) before and after one run and compares the change with **expected = passes × operations × statements per operation by design + the setup read**. By design `CORE_READ_1U` issues 1 statement per operation (the chunk SELECT) and `SCR_CUSTOMER_ORDER_HISTORY` 2 (the TOP 20 list and the grid-footer `COUNT(*)`); each run's `Prepare` adds one read (the READ-SEED check, the customer pool read). The proof is published only for probes where the two are equal. The probe ran on SQL Server only, so the README makes no per-statement claim about MySQL or PostgreSQL; the query-cache clearing itself is the same Acumatica code on all three.

**Engine statement counters (not comparable across databases).** The report shows, from the dry run's step 3f (the counters are read only with `-Diagnostics` in the DryRun profile, never in the Full profile), per database and test, an engine counter of statements per operation over the whole run (warm-up, `Prepare`, `Verify` and REST polling included): SQL Server Batch Requests, MySQL Questions, PostgreSQL `pg_stat_statements` calls (`track_utility = on`). The three counters count different things (for example, SQL Server's Batch Requests leave out transaction-manager BEGIN/COMMIT, the other two count them), so they compare tests within one database only and must not be used to compare databases. No cause is named for the differences between them until a per-statement probe on MySQL and PostgreSQL measures it.

### Workers, start gate and thread pool

- W = 1: operations run inline on the long-operation thread.
- W > 1: one `PXProcessing.ProcessItemsParallel` call per pass with exactly W items, `BatchSize = 1`, `ParallelThreadsCount = W` (set by reflection; the engine throws if the field is missing), the factory `() => MainGraph` (the worker action ignores its graph argument) and a no-op throttler (`PerfNoOpThrottler`).
- Each worker waits at a start gate; the gate opens only when all W workers have arrived. A gate time-out (60 s) makes the run Invalid (`WorkersNotStarted(arrived/W)`). `WorkersObservedPeak` must equal W.
- Operations are assigned as contiguous blocks: worker w gets operations `[⌊w·n/W⌋, ⌊(w+1)·n/W⌋)`.
- 16 workers need `<ThreadPoolSize>32</ThreadPoolSize>` in `<px.core>` (the default pool is 15). The engine pre-checks the configured pool and fails fast when it is smaller than W + 1; `ENV_WORKERS_PROBE` (16 workers, each reading the control row and sleeping 500 ms) proves it in the dry run.

### Status, errors and limits

| Status | Meaning | Result row |
|---|---|---|
| `Completed` | valid result | yes |
| `Capped` | valid result that hit a limit: `operationCap` (one trial-balance operation over 60 s) or `runBudget` (the run budget, default 15 min, `RunBudgetSec` on the control row); ranked last | yes |
| `Invalid` | `WorkersNotStarted`, `WorkerCrashed`, `Errors` (any error in a test where errors invalidate), `Invariant:<name>`, `Cleanup`, `ParallelProcessingDisabled`, `ItemsShortfall`, `Aborted` (the `AbortBenchmark` action) | yes |
| `Failed` | an exception escaped `Prepare` or the engine | no (only `LastRequestStatus = Failed`) |

- The engine catches every exception thrown by `ExecuteOperation`, counts it, keeps the first 5 messages and continues; failed operations are listed as `pass:worker:workerOpIndex` in `ResultJson.errors.failedOps`.
- A first-chance exception counter (active only while measured operations run, filtered to worker threads) counts each exception object once per run: deadlocks, time-outs, lock violations and retries (an upper bound: Acumatica retries silently).
- `ErrorsInvalidate = false` for `ORD_*_U04/U08/U16` and `INV_RELEASE_TO_GL_U04`: under contention, failures are a result. Everywhere else any error makes the run Invalid.
- `AbortBenchmark` is cooperative: workers stop after their current operation, `AfterPass`, `Verify` and `Cleanup` still run.
- **Run budgets in the campaign** come from the final rehearsal's `calibration.json`: four times the test's longest server-side run (`phasesMs.total`), at least 120 s and at most 900 s, the same on every database. The invoice tests have no calibration entry and use the 900 s default. The budget clock includes untimed phases inside the run (for example the deletion of the warm-up orders), and the 900 s ceiling leaves the least headroom for the longest runs; the README states the headroom from the final rehearsal.
- **Budget check in the rehearsal (step 3j).** The rehearsal proves that a run stops at its budget (Capped, with a result row) and that `AbortBenchmark` works. When the slowest trial-balance run takes under 30 s, the budget for this check is half of that run (at least 3 s) instead of the planned 20 s, which would be too close to the run's own length to stop it reliably.

### Checksums, invariants and parity

1. **In-app invariants** are self-consistency checks only (rows per pass equal what `Prepare` counted, every pass gives the same digest, sums match their formula, order cleanup restored the baseline, invoice deltas equal n × 350.00). A failed invariant makes the run `Invalid(Invariant:<name>)`.
2. **Reference values** from the SalesDemo data (`ref.*` keys in `ResultJson.parity`) are checked once in the dry run on all three engines.
3. **Cross-engine parity** is applied by the report: for parity-expected tests, `RowsReturned` and `Checksum` must be identical across the three databases.

`PerfChecksum` is a multiset sum of FNV-1a-64 hashes; `PerfOrderedChecksum` is SHA-256 over ordered rows (used when the order is part of the answer, for example top-N lists). Canonical values: strings `TrimEnd()`, decimals rounded to 4 places (invariant culture), dates `yyyy-MM-ddTHH:mm:ss`, booleans `1`/`0`. Document numbers, identity values, timestamps and GUIDs created by the test are never hashed.

### Determinism

- **Pools** are read in `Prepare` (untimed), trimmed and sorted in C# with ordinal comparison; never sampled with a database text sort or `Random`. Sizes: 500 sales orders (every 14th SO order), 78 customers with SO orders, 91 sold items, 20 fixed search fragments, 14 fiscal years (2013–2026), 12 periods (202507–202606), 56 GL accounts with posted 2025 lines, 20 customers for order entry and invoices, 613 stock items (partitioned 16 ways, so workers never share items), the best-seller AACOMPUT01 at WHOLESALE, and 72 non-stock items for invoices (kits excluded, because AR invoices reject manually entered non-stock kits).
- **Timed queries** end their ORDER BY in a unique key made only of integers, dates or codes proven to be `[0-9A-Z]`; otherwise the result is treated as a set.
- **Pinned values:** order and document date 2026-06-30 (period 202606), branch PRODWHOLE, warehouse WHOLESALE, ledger ACTUAL. Every created document is tagged `PERFBENCH <RunID:N>` in its description.
- **Gates** (suite, before every repetition, from `ENV_CAPTURE`): identical master-data hash (G1), identical data fingerprint (G2; Block D compares the part it does not change, G2d), no leftovers (G3), the same DLL and methodology (G4), no archived sales orders (G5), pre-flight (G6), unchanged client connection and isolation (G7).

### Permanent effects

- Block C: the order-number counter advances, the ERP-transaction counter grows, and the first run leaves 5 zero-quantity `INSiteStatusByCostCenter` rows for pool items that had none (identical on all engines; the availability join then returns 783 rows instead of 778). This is the design expectation of our test protocol; in the first dry run these rows appeared before the order tests, from earlier aborted attempts. In this campaign they were already present from the final rehearsal (781 rows before the rehearsal, 786 after it and still 786 at the campaign end, on all three). The README's residue list ([methodology appendix](../README.md#methodology-appendix)) shows what the campaign actually left, from exact row counts on all three databases.
- Block D: about 750 invoices per engine over a full campaign (743 in the 2026 R2 campaign: 6 × (50 + 72) plus 11 in the warm-up round; about 2,300 GLTran and 1,500 ARTran rows, plus GL batches and the GL, AR and customer balance accumulators). With retainage switched off (see [Invoice release](#invoice-release-to-gl-inv)), every invoice is 350.00 with 3 GL lines: per invoice about 1 invoice, 1 GL batch, 2 AR lines and 3 GL lines, plus the related `Note`, `SearchIndex`, `ARTranPost` and invoice-number rows. Posting to June 2026 also updates the GL balances of every later period that already has history. Backups are taken before the campaign.
- Every site: Acumatica's own monitoring tables grow with activity (licence-transaction history, the resource-usage samples in which the SQL throttle is recorded, dispatcher statistics, the login trace, system events).

## Tables, projections and FBQL queries

All benchmarks use Acumatica Fluent BQL (FBQL) through `SelectFrom<>` syntax, Acumatica graphs for business documents, and `PXDatabase.SelectSingle` for counts (`COUNT(*)` in the same shape on every engine).

### Custom tables

| DAC | Table | Purpose |
|---|---|---|
| `PerfBenchmarkFilter` | `PerfBenchmarkFilter` | Single-row control record: parameters (records, iterations, batch size, max threads), the test to run (`SelectedTestCode`, legacy codes accepted), `CampaignID`, `RepetitionNo` (0 = warm-up repetition), `IsWarmup`, `RunBlock`, `OrderPosition`, `WorkScale`, `PassesOverride`, `WarmUpPassesOverride`, `RunBudgetSec`, detected hardware, and the state of the last request. Unbound server fields: `ServerAppStartUtc`, `ServerDllSha256`, `ServerMethodologyVersion`. |
| `PerfTestRecord` | `PerfTestRecord` | Plain records for the CORE tests (`BatchID`, `OperationType`, `Iteration`, `Sequence`, `PayloadText`, `PayloadValue`; with `[PXNote]`, so every delete also runs Acumatica's attachment check). Between passes the table holds only the persistent seeds `READ-SEED` and `UPDATE-SEED` (10,000 rows each, `PayloadValue = Sequence × 17`). |
| `PerfTestResult` | `PerfTestResult` | One row per run. Besides the original columns: `CampaignID`, `RepetitionNo`, `IsWarmup`, `RunBlock`, `OrderPosition`, `Family`, `MethodologyVersion`, `ParamsHash`, `UserCount`, `ElapsedMsPrecise`, `HeadlineValue`, `HeadlineUnit`, `HigherIsBetter`, `OpsCount`, `OpsPerSec`, `P50Ms`/`P95Ms`/`P99Ms`/`MaxOpMs`, `RowsReturned`, `Checksum`, `ErrorCount`/`DeadlockCount`/`RetryCount`/`LockViolationCount`/`TimeoutCount`, `WorkersObservedPeak`, `Status`, `InvalidReason`, `DllSha256`, `AppDomainStartUtc` and `ResultJson`. Index `(CompanyID, CampaignID, TestCode)`. |

### Projections (read-only, non-persistent)

| DAC | Over | Used by |
|---|---|---|
| `PerfBenchmarkProjection` | the 5-table availability join (10 columns) | `CORE_JOIN_SLIM_*` |
| `PerfSOLineSlim` | `SOLine` of order type SO | `SCR_ITEM_BUYERS` totals |
| `PerfARTranSales` | released `ARTran` (invoice, credit memo, debit memo, cash sale) ⋈ `BAccount` | `RPT_SALES_BY_CUSTOMER_MONTH` |
| `EnvGLTranSums`, `EnvARTranSums`, `EnvSOOrderSums`, `EnvSiteStatusSums` | GLTran, ARTran, SOOrder, INSiteStatusByCostCenter | data fingerprint sums in `ENV_CAPTURE` |
| `PerfTestResultSlim` | `PerfTestResult` | the result writer |

Aggregates that need a line count use a slim, non-aggregated projection queried with `.AggregateTo<GroupBy…, Sum…, Count>`: `Count<Field>` would translate to `COUNT(DISTINCT …)`.

### Stock tables used

| Family | Tables |
|---|---|
| Platform basics (joins) | `InventoryItem`, `INItemClass`, `INSiteStatus`, `INSite`, `Branch` (GL) |
| Everyday screens | `SOOrder`, `SOLine` and the 12 views of `SOOrderEntry` (taxes, shipments, payments, addresses, contacts, currency, commissions, discounts), `Customer`, `BAccount` |
| Reports & month-end | `ARTran`, `BAccount`, `GLHistoryByPeriod`, `GLHistory`, `Account`, `Sub`, `Branch`, `GLTran`, `Batch`, `Ledger` |
| Order entry, many users | `SOOrderEntry` (writes `SOOrder`, `SOLine`, `INSiteStatusByCostCenter`, `ARBalances` and numbering) |
| Invoice release | `ARInvoiceEntry` + `ReleaseProcess` with automatic posting (writes `ARRegister`/`ARInvoice`, `ARTran`, `ARBalances`, `ARHistory`, `Batch`, `GLTran`, `GLHistory`) |

### Platform basics (CORE)

Chunk c (0-based) covers `Sequence` `c·250 + 1 … (c+1)·250`; each operation is one chunk, 40 chunks per pass.

**Load 10,000 records** (read-only select of a `READ-SEED` chunk):

```csharp
SelectFrom<PerfTestRecord>
    .Where<PerfTestRecord.batchID.IsEqual<@P.AsString>
        .And<PerfTestRecord.sequence.IsGreaterEqual<@P.AsInt>>
        .And<PerfTestRecord.sequence.IsLessEqual<@P.AsInt>>>
    .OrderBy<PerfTestRecord.sequence.Asc>
    .View.ReadOnly.Select(worker.Graph, "READ-SEED", a, b)
```

Invariants per pass: 10,000 rows, Σ `PayloadValue` = 850,085,000.

**Save 10,000 new records:** for each record of the chunk `Records.Cache.Insert(new PerfTestRecord { BatchID = "CORE-INS-<RunID>-<pass>", … PayloadValue = s * 17 })`, then `Save.Press()` (one commit per 250 records). After each pass (untimed) the batch is read back, checked and deleted set-based with `PXDatabase.Delete<PerfTestRecord>(…batchID…)`.

**Change 10,000 records:** select the chunk's `UPDATE-SEED` rows (not read-only), set `PayloadValue = Sequence*17 + k` and `PayloadText = "U" + k + "-" + Sequence`, `Records.Cache.Update(row)`, then `Save.Press()`. k = 1 for the warm-up pass and 2, 3, 4 for the measured passes, so every pass really changes every row, and the sums never drift. Chunks are disjoint, so workers never touch the same row.

**Delete 10,000 records:** `BeforePass` (untimed) creates a fresh batch `CORE-DEL-<RunID>-<pass>` of 10,000 rows through the cache (so every row has a NoteID, like a real record) and the engine refreshes the worker graphs' row-version stamps. The timed operation selects the chunk's rows (not read-only), calls `Records.Cache.Delete(row)` for each and `Save.Press()`. Each delete also looks up attachments (`[PXNote]`), as every Acumatica document does.

**Stock availability list, all columns** (5-table join, 50 rows per page, 16 pages × 5 sweeps = 80 pages per pass):

```csharp
SelectFrom<InventoryItem>
    .InnerJoin<INItemClass>.On<INItemClass.itemClassID.IsEqual<InventoryItem.itemClassID>>
    .LeftJoin<INSiteStatus>.On<INSiteStatus.inventoryID.IsEqual<InventoryItem.inventoryID>>
    .LeftJoin<INSite>.On<INSite.siteID.IsEqual<INSiteStatus.siteID>>
    .LeftJoin<GLBranch>.On<GLBranch.branchID.IsEqual<INSite.branchID>>
    .Where<InventoryItem.stkItem.IsEqual<True>.And<INSite.siteID.IsNotNull>>
    .OrderBy<InventoryItem.inventoryID.Asc, INSite.siteID.Asc>      // integers, unique: identical pages on every engine
    .View.ReadOnly.SelectWindowed(g, page * 50, 50)
```

Then, for the first 10 distinct items of the page, a detail lookup:

```csharp
SelectFrom<INSiteStatus>
    .Where<INSiteStatus.inventoryID.IsEqual<@P.AsInt>>
    .View.ReadOnly.SelectWindowed(g, 0, 25, id)
```

The previous edition ordered by `inventoryCD, siteCD`; 91 item codes contain `" / #` and three warehouse codes contain hyphens, which the three databases' collations sort differently.

**Stock availability list, only the needed columns:** the same pages through the 10-column projection:

```csharp
[PXProjection(typeof(
    SelectFrom<InventoryItem>
        .InnerJoin<INItemClass>.On<INItemClass.itemClassID.IsEqual<InventoryItem.itemClassID>>
        .LeftJoin<INSiteStatus>.On<INSiteStatus.inventoryID.IsEqual<InventoryItem.inventoryID>>
        .LeftJoin<INSite>.On<INSite.siteID.IsEqual<INSiteStatus.siteID>>
        .LeftJoin<GLBranch>.On<GLBranch.branchID.IsEqual<INSite.branchID>>
        .Where<InventoryItem.stkItem.IsEqual<True>>), Persistent = false)]
public sealed class PerfBenchmarkProjection : PXBqlTable, IBqlTable { ... }

SelectFrom<PerfBenchmarkProjection>
    .Where<PerfBenchmarkProjection.siteID.IsNotNull>
    .OrderBy<PerfBenchmarkProjection.inventoryID.Asc, PerfBenchmarkProjection.siteID.Asc>
    .View.ReadOnly.SelectWindowed(g, page * 50, 50)
```

with lookups `SelectFrom<PerfBenchmarkProjection>.Where<PerfBenchmarkProjection.inventoryID.IsEqual<@P.AsInt>>.View.ReadOnly.SelectWindowed(g, 0, 20, id)`. Reference on pristine data: 778 rows (783 after the first order-entry run), Σ QtyOnHand = 715,201.66, Σ QtyAvail = 676,996.88.

### Everyday screens (SCR)

**Open a sales order:** `SOOrderEntry`, reset with `Clear(ClearAll)` before each order (untimed), then

```csharp
g.Document.Current = g.Document.Search<SOOrder.orderNbr>(nbr, SOOrderTypeConstants.SalesOrder);
// then every row of: CurrentDocument, Transactions, Taxes, shipmentlist, Adjustments, Billing_Address,
// Billing_Contact, Shipping_Address, Shipping_Contact, currencyinfo, SalesPerTran, DiscountDetails
```

**A customer's order history:** the 20 newest orders plus the count:

```csharp
SelectFrom<SOOrder>
    .InnerJoin<Customer>.On<Customer.bAccountID.IsEqual<SOOrder.customerID>>
    .Where<SOOrder.orderType.IsEqual<SOOrderTypeConstants.salesOrder>
        .And<SOOrder.customerID.IsEqual<@P.AsInt>>>
    .OrderBy<SOOrder.orderDate.Desc, SOOrder.orderNbr.Desc>
    .View.ReadOnly.SelectWindowed(g, 0, 20, customerId);
// + PXDatabase.SelectSingle<SOOrder>(new PXDataField(SQLExpression.Count()), …orderType, customerID…)
```

**Who bought this item?:** the 50 latest lines with order and customer, plus totals through `PerfSOLineSlim`:

```csharp
SelectFrom<SOLine>
    .InnerJoin<SOOrder>.On<SOOrder.orderType.IsEqual<SOLine.orderType>.And<SOOrder.orderNbr.IsEqual<SOLine.orderNbr>>>
    .InnerJoin<Customer>.On<Customer.bAccountID.IsEqual<SOOrder.customerID>>
    .Where<SOLine.orderType.IsEqual<SOOrderTypeConstants.salesOrder>.And<SOLine.inventoryID.IsEqual<@P.AsInt>>>
    .OrderBy<SOOrder.orderDate.Desc, SOLine.orderNbr.Desc, SOLine.lineNbr.Desc>
    .View.ReadOnly.SelectWindowed(g, 0, 50, inventoryId);

SelectFrom<PerfSOLineSlim>
    .Where<PerfSOLineSlim.inventoryID.IsEqual<@P.AsInt>>
    .AggregateTo<GroupBy<PerfSOLineSlim.inventoryID>, Sum<PerfSOLineSlim.orderQty>, Sum<PerfSOLineSlim.curyLineAmt>, Count>
    .View.ReadOnly.Select(g, inventoryId);
```

**Find a customer by part of the name:** 20 ASCII fragments × 5:

```csharp
SelectFrom<Customer>
    .Where<Customer.acctCD.Contains<@P.AsString>.Or<Customer.acctName.Contains<@P.AsString>>>
    .View.ReadOnly.Select(worker.Graph, fragment, fragment)
```

The fragments are ASCII, so all engines must agree. A separate, untimed **accent probe** (`BAccount.acctName` contains `quebec` / `Québec` / `QUÉBEC`; the only match is the vendor "Revenu Québec") publishes how each database treats accents. In the campaign it found 0 / 1 / 1 rows on SQL Server, 1 / 1 / 1 on MySQL and 0 / 1 / 1 on PostgreSQL, the same as in both rehearsals: searching for "quebec" found "Revenu Québec" on MySQL only. The README shows it in Table 2, Everyday screens and the correctness table.

Text rules have two layers per database: the database default, and the rules Acumatica sets for its own columns and searches.

| | Database default (captured) | Acumatica's text columns (captured in the campaign) | Searches (`Contains` → LIKE) |
|---|---|---|---|
| SQL Server | `SQL_Latin1_General_CP1_CI_AS` (case-insensitive, accent-sensitive) | `SQL_Latin1_General_CP1_CI_AS` on 12,790 text columns (including the searched `BAccount.AcctName`), `SQL_Latin1_General_CP1_CS_AS` on 1 | the column collation: case-insensitive, accent-sensitive |
| MySQL | server `utf8mb4_0900_ai_ci`; the `perfmysql` schema `utf8mb4_unicode_ci` | `utf8mb4_unicode_ci` on 6,738 text columns (including `BAccount.AcctName`), `latin1_general_ci` on 6,052, `ascii_general_ci` on 4,298, `ascii_bin` on 1 | Acumatica's LIKE adds `COLLATE utf8mb4_unicode_ci`: case- and accent-insensitive |
| PostgreSQL | libc `English_United States.1252` (UTF8) | Acumatica's ICU collation `latin1_general_ci_ai` (provider icu, nondeterministic, locale `und-u-kc-false-kr-punct-ks-level1`) on 8,101 text columns (including `BAccount.AcctName`), the database default on 4,691: case- and accent-insensitive for comparisons, sorting and grouping | LIKE becomes `ILIKE` with `COLLATE "default"`, so it runs under the libc default: case-insensitive, accent-sensitive |

The column layer is the campaign's capture (`databases.<engine>.collation` in `environment-start.json`). On PostgreSQL only the database default is libc; Acumatica's scripts give its text columns an ICU collation. Because Acumatica's PostgreSQL search runs under the database default, the search is accent-sensitive even though the columns compare without accents.


### Reports & month-end (RPT)

**Sales by customer and month** (one fiscal year per operation):

```csharp
SelectFrom<PerfARTranSales>
    .Where<PerfARTranSales.finPeriodID.IsBetween<@P.AsString, @P.AsString>>
    .AggregateTo<GroupBy<PerfARTranSales.customerID>, GroupBy<PerfARTranSales.acctCD>, GroupBy<PerfARTranSales.finPeriodID>,
                 Sum<PerfARTranSales.tranAmt>, Sum<PerfARTranSales.qty>, Count>
    .OrderBy<PerfARTranSales.customerID.Asc, PerfARTranSales.finPeriodID.Asc>
    .View.ReadOnly.Select(g, year + "01", year + "13")
```

Reference: 6,146 groups and 25,548 lines over the 14 years. ARTran has no index on FinPeriodID, so every report reads about 27,000 lines, which is realistic.

**Trial balance** (one period per operation; capped at 60 s per operation):

```csharp
SelectFrom<GLHistoryByPeriod>
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
    .View.ReadOnly.Select(g, actualLedgerId, period)
```

Reference: 3,871 rows per pass. The sum of `FinYtdBalance` over these rows is used as a checksum only; it is not a trial-balance total.

**GL account details for a year** (one account per operation): the opening balance (the same `GLHistoryByPeriod ⋈ GLHistory` join for period 202412 and the account, summed in C#), then every posted line of FY2025:

```csharp
SelectFrom<GLTran>
    .InnerJoin<Batch>.On<Batch.module.IsEqual<GLTran.module>.And<Batch.batchNbr.IsEqual<GLTran.batchNbr>>>
    .Where<GLTran.ledgerID.IsEqual<@P.AsInt>
        .And<GLTran.accountID.IsEqual<@P.AsInt>>
        .And<GLTran.posted.IsEqual<True>>
        .And<GLTran.finPeriodID.IsBetween<@P.AsString, @P.AsString>>>
    .OrderBy<GLTran.tranDate.Asc, GLTran.module.Asc, GLTran.batchNbr.Asc, GLTran.lineNbr.Asc>
    .View.ReadOnly.Select(g, actualLedgerId, accountId, "202501", "202512")
```

Reference: 56 accounts, 27,211 rows, Σ debit = Σ credit = 683,842,425.80 per pass.

**Deep paging and counting in a 300,000-line journal** (12 requests per pass): pages of 100 `GLTran` rows at offsets 0, 10,000, 100,000, 200,000 and 300,000 in two sort orders, plus two counts:

```csharp
SelectFrom<GLTran>.OrderBy<GLTran.module.Asc, GLTran.batchNbr.Asc, GLTran.lineNbr.Asc>
    .View.ReadOnly.SelectWindowed(g, offset, 100);
SelectFrom<GLTran>.OrderBy<GLTran.tranDate.Desc, GLTran.module.Desc, GLTran.batchNbr.Desc, GLTran.lineNbr.Desc>
    .View.ReadOnly.SelectWindowed(g, offset, 100);
// + 2 × PXDatabase.SelectSingle<GLTran>(new PXDataField(SQLExpression.Count()), …)
```

### Order entry and many users (ORD)

One operation = one 3-line sales order through `SOOrderEntry` with the full business logic (reset with `Clear(ClearAll)` before each order, untimed):

```csharp
var o = g.Document.Insert(new SOOrder { OrderType = SOOrderTypeConstants.SalesOrder });
g.Document.Cache.SetValueExt<SOOrder.customerID>(o, customerId);      // customer before branch
g.Document.Cache.SetValueExt<SOOrder.branchID>(o, branchId);
g.Document.Cache.SetValueExt<SOOrder.orderDate>(o, PerfCampaignConstants.PinnedDocDate);   // 2026-06-30
g.Document.Cache.SetValue<SOOrder.orderDesc>(o, worker.Run.DocumentTag);
o = g.Document.Update(o);
for (var k = 0; k < 3; k++)
{
    var (itemId, qty) = (hot && k == 0) ? (hotItemId, 1m)                // hot variant: line 0 is AACOMPUT01
        : (items[(3 * j + k) % items.Count], 1m + ((j + k) % 3));
    var l = g.Transactions.Insert(new SOLine());
    g.Transactions.Cache.SetValueExt<SOLine.inventoryID>(l, itemId);
    g.Transactions.Cache.SetValueExt<SOLine.siteID>(l, siteId);          // WHOLESALE
    g.Transactions.Cache.SetValueExt<SOLine.orderQty>(l, qty);
    g.Transactions.Update(l);
}
g.Save.Press();
```

- Each worker has its own customer and its own partition of the 613 stock items, so in the spread variant the only shared rows are the order-number counter (updated in its own short transaction, `EnableAutoNumberingInSeparateConnection=true`) and system bookkeeping. In the hot variant every save also updates the `INSiteStatusByCostCenter` row of AACOMPUT01 at WHOLESALE.
- After every pass (untimed) all orders of the run are checked (3 lines, status Open, no hold) and deleted through `SOOrderEntry`, grouped by creator, with up to 3 retries; the stock and customer-balance baseline must be restored exactly.
- The warm-up orders are deleted (untimed) before the measured pass, and the measured pass starts right after that deletion, with no pause, on every database; background clean-up that a database does after those deletes can overlap the measured pass (the README's "How we measured" says so).
- Derived in the report: scaling = orders/min(N clerks) ÷ orders/min(1 clerk, same wall-clock basis); hot-item penalty = orders/min(spread) ÷ orders/min(hot).

### Invoice release to GL (INV)

One operation = one AR invoice with two non-stock lines (100.00 + 250.00, quantity 1, manual discount so the total stays 350.00), saved and released with automatic GL posting:

```csharp
var inv = ie.Document.Insert(new ARInvoice { DocType = ARDocType.Invoice });
ie.Document.Cache.SetValueExt<ARInvoice.customerID>(inv, customerId);
ie.Document.Cache.SetValueExt<ARInvoice.branchID>(inv, branchId);
ie.Document.Cache.SetValueExt<ARInvoice.docDate>(inv, PerfCampaignConstants.PinnedDocDate);   // period 202606
ie.Document.Cache.SetValue<ARInvoice.docDesc>(inv, worker.Run.DocumentTag);
inv = ie.Document.Update(inv);
ie.Document.Cache.SetValueExt<ARInvoice.retainageApply>(inv, false);   // after Update, before the first line (ScenarioVersion 3)
AddLine(ie, pool[(2 * i + 37 * w) % pool.Count], 100.00m);
AddLine(ie, pool[(2 * i + 1 + 37 * w) % pool.Count], 250.00m);
ie.Save.Press();                                                         // phase "create"
ie.ReleaseProcess(new List<ARRegister> { ie.Document.Current });         // phase "releasePost": ReleaseDoc + AutoPost
```

`Verify` checks per run: every invoice released with a posted batch, Σ amounts = n × 350.00, GL debit = credit = n × 350.00, the GLHistory delta for (ACTUAL, 202606) = n × 350.00, ARTran delta = 2n and GLTran delta = n × lines per batch. Invoices are permanent (no rollback inside a transaction: an abort costs very differently per engine).

**Retainage and pay by line (INV `ScenarioVersion` 3).**
- Acumatica copies the customer's retainage setting onto every new AR invoice. One of the four customers the 4-person test uses (BNRCONTRAC, worker 2, because operations are assigned to workers in fixed contiguous blocks) holds back 10% by default; its invoices would post 315.00 to AR plus 35.00 to retainage receivable, with a fourth GL line. The test therefore clears `ARInvoice.retainageApply` right after the header `Update` and before the first line (a clear placed before `Update` would be undone by the cache). Every invoice is then a plain 350.00 invoice with 3 GL lines on every database, and a retainage invariant checks it.
- For BNRCONTRAC the clear does a little work inside the timed "create" phase (one line query for the unsaved document and the retainage account fields); for the other customers it changes nothing. The same on every database.
- BNRCONTRAC also has payment by line allowed (`PaymentsByLinesAllowed = 1`), which Acumatica copies onto the invoice independently of retainage. It was left as defaulted: that worker's invoices are released through Acumatica's pay-by-line path, which keeps a balance per invoice line. Amounts, GL lines and the `ARTranPost` count are unchanged, and it is identical on every database, but that one worker's release path differs slightly from the other three.

**Failed saves in the 2026 R2 campaign (4 people, MySQL).**
- MySQL had 10 failed operations in `INV_RELEASE_TO_GL_U04` over its six analysis runs (2, 1, 5, 0, 1 and 1 per repetition). SQL Server and PostgreSQL had none, and `INV_RELEASE_TO_GL_U01` had none on any database.
- Every one was `PXMassProcessException: Deadlock found when trying to get lock; try restarting transaction`. The engine classed all 10 as contention; none was a lock-wait time-out (time-outs 0) or another error (non-contention errors 0). Over the same runs it counted 21 deadlocks, 21 automatic retries and 80 lock violations (`PXLockViolationException`) on MySQL, and none on the other two.
- By the failed-operation list (`pass:worker:operation`), 8 failures were in measured passes (2, 1, 4, 0, 0 and 1 per repetition; MySQL's measured passes saved 352 of 360 invoices) and 2 in the untimed warm-up invoices (pass −1000, repetitions 3 and 5).
- In every MySQL run the number of invoices left released but not posted (`releasedUnposted`) equalled the run's failed operations, so each failed save left a released invoice whose GL batch stayed unposted (10 in all); every invariant passed.
- The work was identical on the three databases (one parameter hash, `03c6a6989223fad1`: the same 60 invoices per run plus 3 warm-up invoices per person, the same customers, items and amounts). In the two MySQL runs without a measured failure the result checksum equalled the other two databases'.
- Per the tie rule, MySQL is shown with "10 failed saves" and not ranked on this test, and the test is left out of the Invoice release family index.
- The Block D data check (gate G2d) compares the row counts of GLTran, GLHistory, ARTran and ARRegister and the totals of `GLTran.DebitAmt`, `GLTran.CreditAmt` and `ARTran.TranAmt`; it found no difference between the databases (the failed invoices have their GL lines on MySQL as well). It does not compare GLHistory or ARRegister amounts. The test's own GL-balance check (`glHistoryPtdDebitDelta`, the GLHistory debit delta for ACTUAL, 202606) shows the effect of the unposted batches: summed over the seven `INV_RELEASE_TO_GL_U04` runs of each database (warm-up repetition included) it was 150,500.00 on MySQL against 154,000.00 on SQL Server and PostgreSQL, 3,500.00 (10 × 350.00) less.

## REST endpoint

Endpoint **`PerfDBBenchmark/26.200.001`** (was `26.100.001` in 2026 R1), contract version 4.

| Entity | Screen | Content |
|---|---|---|
| `BenchmarkControl` | AC301000 | the control row (§ custom tables), with details `LocalResults` (latest results of this instance) and `BenchmarkCatalog` (every descriptor: family, block, display name, question, reader texts, units, users, defaults, scenario version, legacy code) |
| `BenchmarkResult` | AC301001 | every `PerfTestResult` column, including `ResultJson` |

**Actions (18):** `RefreshStatus`, `ApplyRecommendedSettings` (writes the campaign constants 10,000 / 3 / 250 / 8), `ClearTestData` (set-based delete of test records and results, then the snapshot), `ClearTestRecords` (test records other than the two seeds, plus the leftover cleaners: unfinished test sales orders and unreleased test invoices; released invoices are permanent and never touched), `RunBenchmark` (runs `SelectedTestCode`), `AbortBenchmark` (asks the run in progress to stop; "Nothing to abort" otherwise), and the 12 legacy actions `RunSequentialRead` … `RunParallelProjection`, which run the matching `CORE_*` test.

**Typical sequence** (what the suite does for every run): log in with `POST /entity/auth/login`; `GET /entity/PerfDBBenchmark/26.200.001/BenchmarkControl?$top=1`, then `GET BenchmarkControl/<id>?$expand=BenchmarkCatalog`; `PUT` the parameters and `GET` them back to verify; `POST BenchmarkControl/RunBenchmark`; poll the control row (every 1 s for the first 10 s, then every 3 s); fetch the result with `GET BenchmarkResult?$filter=RunID eq guid'<id>'` (fallback: filter by `TestCode` and match `RunID` on the client).

### End-to-end API read through the Default endpoint (dry-run step 3l): not available

The dry run was meant to time a whole sales-order read through Acumatica's **Default** endpoint (`GET .../SalesOrder/SO/<nbr>?$expand=Details`) as context for "Open a sales order" (never ranked). It cannot be measured on these sites as installed:
- On a plain REST request, Acumatica adds a **branch filter** to every table that has a `BranchID` column: `BranchID IS NULL OR BranchID IN (<branches the user may access>)`.
- In SalesDemo every branch has an access role, and the `admin` user holds none of those roles. The list of allowed branches is therefore empty, the filter becomes `BranchID IS NULL`, and none of the 11,198 sales orders qualifies (they all have a branch). Acumatica answers with its not-found error ("no entity satisfies the condition") on all three databases. According to Acumatica's code (not tested), neither a `$filter` read (it would return an empty list) nor a branch in the login body would change this.
- The benchmark's own tests are not affected: they run inside Acumatica long operations, where Acumatica lifts the branch filter (`PXReadBranchRestrictedScope`), and they set the branch explicitly.
- The README therefore discloses the end-to-end API read as "not available" and shows no number. The sites' users and roles were left as installed.

## web.config settings

Parallel actions need Acumatica parallel processing enabled on each benchmark site:

```xml
<add key="EnableAutoNumberingInSeparateConnection" value="true" />
<add key="ParallelProcessingDisabled" value="false" />
<add key="ParallelProcessingMaxThreads" value="6" />
<add key="ParallelProcessingBatchSize" value="10" />
<add key="IsParallelProcessingSkipBatchExceptions" value="True" />
```

The engine sets the worker count of each parallel call itself (`ParallelThreadsCount = W`, `BatchSize = 1`), so `ParallelProcessingMaxThreads` does not cap the 8 and 16-worker tests, and per-operation errors are counted by the engine even though batch exceptions are skipped.

Settings used for the 2026 R2 campaign on all three sites:

```xml
<compilation debug="False" ... />                                   <!-- production setting -->
<add key="DisableScheduleProcessor" value="True" />                 <!-- no scheduled jobs during timed runs -->
<add key="sqlThrottling:Enabled" value="false" />                   <!-- E14: Acumatica's SQL throttle for sites without a licence off -->
<px.core>
    <ThreadPoolSize>32</ThreadPoolSize>                              <!-- default 15; 16 workers need at least 17 -->
    ...
</px.core>
```

The `sqlThrottling:Enabled` key sits in `<appSettings>`; appSettings feed Acumatica's configuration, the same mechanism as its documented `NodeJs:NodeJsPath` key. Why it is needed is explained under [Acumatica's limits for sites without a licence](#acumaticas-limits-for-sites-without-a-licence).

Never add `QueryCacheLevel`. Editing web.config restarts the site; do it before a campaign, never during one.

## Campaign environment settings

What was aligned for the 2026 R2 campaign (the full disclosure, with captured values, is in the README's [Test environment and fairness](../README.md#test-environment-and-fairness)).

**Database memory**

The commands below read database credentials from files under `<repo>\Exceptions\`. **Make sure that folder is ignored by git before you create the files** (see [Notes](#notes)).

```powershell
# SQL Server: max and min server memory 8 GB
sqlcmd -S localhost -E -C -Q "EXEC sp_configure 'show advanced options',1; RECONFIGURE; EXEC sp_configure 'max server memory (MB)',8192; RECONFIGURE; EXEC sp_configure 'min server memory (MB)',8192; RECONFIGURE;"

# PostgreSQL 18: own cache 2 GB, planner hint 8 GB (restart required)
$env:PGPASSFILE = "<repo>\Exceptions\pgpass.conf"
& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U postgres -h localhost -d postgres -c "ALTER SYSTEM SET shared_buffers = '2GB';" -c "ALTER SYSTEM SET effective_cache_size = '8GB';"
Restart-Service postgresql-x64-18

# MySQL 8.0: buffer pool already 8G (my.ini, set at install; see the README's Table 2); verify only
& "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe" --defaults-extra-file="<repo>\Exceptions\mysql-root.cnf" -e "SELECT @@innodb_buffer_pool_size/1073741824 AS bp_gb, @@transaction_isolation;"
```

**Client connection: loopback TCP without encryption on all three**

- SQL Server: enable the TCP/IP protocol of the default instance, port 1433, listening on 127.0.0.1 only, no inbound firewall rule; connection string `Data Source=tcp:127.0.0.1,1433` (Integrated Security and `Encrypt=False` unchanged). Before, Acumatica used shared memory.
- MySQL: add `SslMode=None` and `AllowPublicKeyRetrieval=True` (MySQL's default `caching_sha2_password` login needs the RSA key exchange over a non-TLS connection; the connection stays unencrypted).
- PostgreSQL: add `SSL Mode=Disable`.
- The MySQL and PostgreSQL connection strings name `localhost`; the environment capture shows the PostgreSQL sessions arriving from `::1`, the IPv6 form of the loopback address (MySQL reports only `TCP/IP`).

These connection settings suit a single test machine where the database is reached only through the loopback address. On a real network, use an encrypted connection (TLS) and do not use `AllowPublicKeyRetrieval=True`: the MySqlConnector documentation warns that it could let a malicious proxy capture the password ([connection options](https://mysqlconnector.net/connection-options/), accessed 2026-10-03).

**MySQL isolation:** left at REPEATABLE READ. Acumatica opens transactions with `BeginTransaction()` and no level; MySqlConnector 1.3.14 then issues `set session transaction isolation level repeatable read`, whatever the server default is, and Acumatica's own database check treats REPEATABLE-READ as the correct MySQL mode. SQL Server runs READ COMMITTED with read-committed snapshot, PostgreSQL READ COMMITTED.

**Host and sites**

- **Application pools:** the three sites' pools always running (no idle timeout, no periodic recycle); all other application pools stopped for the campaign (restarted afterwards).
- **Services:** SQL Server Analysis Services, PolyBase, Launchpad and telemetry stopped for the campaign (restarted afterwards).
- **Statistics:** refreshed once on every table of every engine before the backups (SQL Server `UPDATE STATISTICS` with default sampling, MySQL `ANALYZE TABLE`, PostgreSQL `VACUUM (ANALYZE)`).
- **Test data:** cleared on all three sites before the backups.
- **Limits for sites without a licence:** the SQL throttle turned off, the CPU limit kept (see [the next section](#acumaticas-limits-for-sites-without-a-licence)).
- **Telemetry and Request Profiler:** kept as shipped: PX.Telemetry `LogSQL="True"` switches the in-memory request and SQL profiler on with every request (nothing is saved to the database); observed in the environment captures of the final rehearsal: IsEnabled=True, SqlProfilerEnabled=True, TraceEnabled=False on SQL Server, MySQL and PostgreSQL (`request-profiler.txt` in the campaign folder). Details, including the stored profiler rows, are under "Telemetry and request profiler" in [the next section](#acumaticas-limits-for-sites-without-a-licence).
- **Instrumentation:** `pg_stat_statements` loaded only for the dry run.
- **Host left unchanged:** power plan, sleep settings, the MSI Center performance mode, Windows Update and the antivirus policy.
- **Business events (decision E9):** left on, as SalesDemo installs them. No business-event history row was written on any site in the final rehearsal (`BPEventHistory` empty), and `BPEventHistory` still had 0 rows on all three databases at the campaign end (`table-counts-campaign-end.json`).
- **Antivirus (decision E8):** no exclusion added or removed on the database data folders, so all three run under the same default real-time policy (not individually verified); scheduled scans not changed. The campaign's helper scripts, credential files, logs and database backups were kept in a folder excluded from scanning, outside the repository. The same policy does not necessarily cost each database the same: one that creates or touches more files can be slowed more by real-time scanning.


All "before" values are saved in the campaign folder.

**Backups before the campaign** (required before any invoice test): SQL Server native backup (`COPY_ONLY, COMPRESSION, CHECKSUM`, verified), MySQL cold copy of the data folder plus a `mysqldump`, PostgreSQL template copy plus a `pg_dump`. Backup durations are not compared: the methods differ.

### Acumatica's limits for sites without a licence

The three sites run without a licence. Acumatica then applies limits that a licensed on-premises installation does not have. One was turned off; the others were kept as shipped. All are the same on the three sites.

**SQL throttle: turned off (E14).**
- Acumatica 2026 R2 starts a built-in SQL throttle (`LeakyBucketSqlThrottling` in PX.Data) on every site that does not count as licensed on-premises; a licensed on-premises installation never starts it. Its defaults: it starts 10 minutes after the application starts, allows a burst of 5 minutes of SQL time, then delays SQL calls (from 200 ms, doubling up to 2 minutes). Without a licence each site drains 2 SQL-seconds per second, and every benchmark worker counts as its own sample, so 16 workers fill the bucket faster than it drains.
- Whether a run is held back therefore depends on the database (SQL wall time includes lock waits), on the run order and on the time since the last site restart. It amplifies differences between the databases.
- **Evidence from the first rehearsal (dry run, 2026-10-04).** Acumatica's licence telemetry (`SMLicenseResourceUsageDetailsTmp`, ChartID 8, legend `SQL`) was read on all three databases right before the databases were restored: SQL Server site 2,374,221 ms (1,688,627 ms in the 13:30 UTC interval, during the 16-clerk order entry, and 685,594 ms at 13:50, during the 16-clerk best-seller test); PostgreSQL site 352,331 ms (13:20 interval, during the 16-clerk order-entry runs); MySQL site 0. These are throttle waits summed over all delayed SQL calls of the 16 parallel workers, not elapsed time: for comparison, the 16-clerk order-entry run in which the 1,688,627 ms were recorded took about 345 s on SQL Server (the 685,594 ms belong to the separate best-seller test, so the total must not be set against that one run). Reduced mode was 0 on all three. Those results were discarded.
- **Fix.** `<add key="sqlThrottling:Enabled" value="false" />` in `<appSettings>` on all three sites, identically, applied by the environment script with a saved "before" state and a revert path (the key was absent on all three before).
- **Proof, three layers.** (1) Configuration: the alignment drift check requires the key present, `false` and identical on all three sites before the campaign and before Block D. (2) Runtime: every `ENV_CAPTURE` reads the bound option inside Acumatica (`env.app.sqlThrottling.optionsEnabled`), and the campaign fails unless it is `false` on all three sites. (3) Backstop: the licence telemetry is read after blocks A–C, before Block D and after Block D (after waiting for Acumatica's 10-minute monitor write), and any SQL throttling or reduced mode fails the check. Each reading is stored with its timestamp, because Acumatica deletes these temporary rows after each UTC day.
- **Readings before each restore** are kept in `pre-restore-throttle-evidence.json`: the first (2026-10-04, after the first rehearsal) with the figures above; the second (2026-10-05, after a rehearsal with the throttle off) with 0 ms on all three sites.

**CPU limit: kept (our decision).**
- Without a licence, Acumatica's ResourceGovernor pins each site's worker process (w3wp) to **2 exclusive, randomly chosen logical CPUs**, redrawn every 60 s, starting 2 minutes after the process starts. Acumatica's licence observer also widens the mask to 4 random CPUs for short spells (applied every 5–30 minutes, each time for under a minute). Evidence: six `acumatica_core_1_*` mutexes (3 sites × 2 cores) whose set changes between samples, and, in the first rehearsal, Acumatica's processor time levelling off at about 1.9 cores in multi-user runs on every database (single runs reached up to 2.66 cores over a few seconds, so never "at most 1.9"). The README says "about 2 cores", the limit itself.
- The host has 8 performance and 16 efficiency cores. A 2-core draw holds on average 0.67 performance cores, and 43.5% of draws hold none. Each draw lasts about a minute, so a short run depends on one or two draws and a long run averages over many. The turn order and the 6 repetitions spread the draws over all three databases.
- **Unlimited window after a process start.** A new w3wp runs on all 24 logical CPUs until ResourceGovernor's first tick, about 2 minutes after the start (a snapshot during a full garbage collection can also show 24). After any detected site restart, the suite starts the next measured run on that site no earlier than **150 s after the process start** and records the wait; the report lists any valid run that started earlier.
- `env.app.processAffinity` in every `ENV_CAPTURE` is a snapshot of a mask that changes every minute, not a per-run record.
- With a licence, ResourceGovernor uses the licence's processor count instead of 2 (`GetLicenseProcessors`: `lic.Licensed ? lic.Processors : 2`).
- Effect: Acumatica's tier is capped at about 2 cores on every database. Short tests are noisier, and multi-user tests in which Acumatica is the bottleneck (order entry, invoice release, the Acumatica share of `CORE_*`) are compressed: the differences between databases are smaller than on a licensed installation with more cores.

**Licence counters and violations: kept (no runtime effect).**
- Unlicensed default limits: 2,000 ERP and 100 commerce transactions per day; 20,000 ERP and 1,000 commerce transactions per month; 2 users and 2 API users.
- When the benchmark exceeds them, Acumatica writes `SMLicenseViolations` rows. Without a licence the rows store `TranCount` and `Limit` as 0; they appear only on days when the default limits were exceeded. The README prints them per database with their dates and the label "expected on an unlicensed site (Limit 0); no runtime effect".
- A violation only drives a banner. Registering a transaction never blocks or delays work, API per-minute throttling is off when no per-minute limit is licensed, and reduced mode is off on all three sites. In both pre-restore readings the API counters (throttled, rejected and rejected-login requests) were 0 on all three databases on every day read.

**Telemetry and request profiler: kept as shipped.**
- `Bin\PX.Telemetry.config` (`LogSQL="True"`, identical on the three sites) switches Acumatica's in-memory request and SQL profiler on for every request, with stack traces; its cost grows with the number of SQL statements an action sends and is part of every measured time. The benchmark's profiler guard only reports the state; it does not change it.
- The stored profiler row (`SMPerformanceSettings`) differs as installed: ProfilerEnabled, SqlProfiler and SqlProfilerStackTrace are 1 on the SQL Server site and 0/false on the MySQL and PostgreSQL sites. It was left as installed because PX.Telemetry switches all three flags on with every request on every site anyway.
- The live state read inside each run was identical on all three sites (IsEnabled, SqlProfilerEnabled and SqlProfilerStackTraceEnabled on; SaveRequestsToDb, SaveSqlToDb and TraceEnabled off, so nothing was written to the database), and the campaign would not start otherwise.
- The same telemetry reads SQL Server's Query Store every 20 minutes (`SqlPlanEnabled`); MySQL and PostgreSQL have no counterpart, so only SQL Server does that background work.

### Restores and the repeated rehearsal

- **Restores before the 2026 R2 campaign: two.** The backup manifest's `restores[]` list and the restore logs record exactly two restores of all three databases from the pre-campaign backups, each started by the `Execute-Tests.ps1` chain right after its pre-restore throttle reading: on 4 October 2026 at 20:41 UTC (after the first rehearsal, whose results were discarded) and on 5 October 2026 at 08:08 UTC (after a repeated rehearsal that stopped at step 3d; the final rehearsal followed). Both were verified (row counts of 22 key tables equal to the backup fingerprint on every engine). Earlier launches of the chain on 4 October (10:15 and 11:03 UTC) did not restore, and the final rehearsal's step 3o did not restore either (`restoredFromP2 = false`).
- Any change to code or settings that a measured step ran after the pre-campaign backups means the whole rehearsal is repeated from the start on databases restored from those backups, so one DLL and one configuration produce all of the rehearsal's evidence. Before each restore, the licence telemetry of all three databases is read and saved (above), because the restore resets those tables.
- **PostgreSQL** is restored by recreating `"PerfPG"` from the template copy (`CREATE DATABASE ... TEMPLATE ... STRATEGY FILE_COPY`). The planner statistics (`pg_class`, `pg_statistic`) are copied, but the cumulative activity counters (`last_analyze`/`last_autoanalyze`, `n_live_tup`, `n_mod_since_analyze`, `pg_stat_database`) restart empty. Environment captures therefore show `nLiveTup = 0` and no analyze date for PostgreSQL tables; that does not mean empty tables or stale statistics. PostgreSQL was not analyzed alone afterwards, so all three databases keep the statistics of the backups. The restore also removes the `pg_stat_statements` extension, which the rehearsal re-creates.
- **SQL Server** keeps FULL recovery as installed. Its log chain was inactive when the backups were taken, but became active when the database was restored from them. The log is then pre-sized to 8 GB once, and the campaign takes a log backup between blocks A and B, between B and C, and before Block D (a single `WITH INIT` file). Log backups run between blocks, never during a run. MySQL and PostgreSQL have no corresponding step.
- **Cache state at the start.** Right before the campaign all three database services are restarted the same way. SQL Server starts with an empty buffer pool; MySQL reloads about a quarter of its buffer pool at startup (`innodb_buffer_pool_dump_at_shutdown` / `load_at_startup` on, `dump_pct` 25, as installed); PostgreSQL uses buffered I/O, so its data files may stay in the Windows file cache across the restart. The discarded warm-up repetition of every block and the warm-up passes of every run put the three on an equal footing; data that only a measured run touches can still come from memory on PostgreSQL.

### What happened during the campaign

Campaign `158169ad-ebb1-4c0a-920d-84a8eb311cea` (profile Full, methodology `2026R2-M2`, DLL SHA-256 `84a5b54db4ed7ed44d6e41c8c0f95c87500746a88003cda5f23d0be2af715a7f`, repository commit `902534a`). The files named below are in the campaign folder (git-ignored); `analysis.json`, the README fragments and the HTML report are copied to [docs/results/2026r2/](results/2026r2/README.md).

- **Timeline (UTC).** Blocks A–C ran from 5 October 2026, 12:12 to 6 October, 02:11. The post-part-1 checks at 02:20 held Block D (below); Block D ran from 02:23 to 03:09, and the end captures (environment, exact table counts, throttle reading) and the report followed by 03:11. Each site's Acumatica process started once, between 12:10 and 12:12 on 5 October, and was not restarted during the campaign; the machine itself was last started on 3 October (the same boot time in the start and end captures). The suite waited 93 s once (PostgreSQL, before its first run) so that no measured run started within 150 s of a process start.
- **Desktop use during the campaign (owner's decision of 5 October: "Keep going as is").** The PC was in normal desktop use during part of the campaign (first noticed at about 11:57 UTC on 5 October, shortly before the campaign started, when desktop applications took about 12% of the CPU), which kept the total CPU above the settle gate's 10% limit at times. When the settle gate does not see a quiet machine within its maximum wait (60 s in Block A, 90 s in blocks B–D), the run starts anyway and the time-out is recorded. Settle time-outs per block, from the suite's own count that the post-part-1 check uses (`post-part1-checks.json`; Block D from the suite state in the campaign JSON), including the discarded warm-up repetition: Block A 24 of 168 runs (14.3%), Block B 53 of 252 (21.0%), Block C 8 of 147 (5.4%), Block D 2 of 42 (4.8%). Of the 58 timed-out runs in the analysis set, 22 were SQL Server runs, 21 MySQL and 15 PostgreSQL. The report's appendix prints 13% / 19% / 4.8% / 3.2% because its denominator also includes the 21 `ENV_CAPTURE` gate runs per block (189 / 273 / 168 / 63 runs). The turn order rotated within every repetition, so the background load was spread over the three databases; it adds noise, is disclosed and is not corrected for.
- **Block D gate and the helper (owner's decision of 5 October: "make sure that tests will run even if PC will not be idling").** The first evaluation of the 43 post-part-1 checks (6 October, 02:20) passed 41 and failed 2: "Block B settle time-outs ≤ 20%" (53 of 252 runs, 21.0%) and "No gate warning", which failed only because of the suite's own settle warning for Block B. Block D therefore did not start. A helper prepared on the owner's instruction before the end of part 1 (`Continue-AfterPart1.ps1`; decision record `auto-continue-decision.json`) acted only in exactly that situation: it resumed `Run-Campaign.ps1` with the settle-share threshold relaxed (`-MaxSettleTimeoutShare 1.0`) and that one warning text tolerated, without `-ApproveBlockD` and with every other check unchanged. The re-evaluation passed 43 of 43 post-part-1 checks and all 17 pre-Block-D checks (02:21), and Block D started at 02:23. The settle gate itself (10% CPU, at most 90 s of waiting) was not changed.
- **SQL throttle (E14 backstop).** Acumatica's licence telemetry (`throttle-readings.json`): after blocks A–C (02:20, covering everything since 12:12 on 5 October), before Block D (02:21) and after Block D (03:10, covering Block D): 0 ms of SQL throttling, reduced mode 0 and no CPU flag on all three sites. Every `ENV_CAPTURE` of the campaign (28 per site) read the bound option inside Acumatica as off.
- **Optional tuning check (E11).** Approved, but not run (`decisions.json`: "not run yet"). No verdict was checked against tuned settings.
- **SQL Server log backups.** After Block A (5 October, 14:28), after Block B (19:45) and before Block D (6 October, 02:21), each in under 1 s; never during a run.
- **Licence counters.** The final rehearsal read 3 violation rows per site, all dated 5 October 2026 (daily commerce, daily ERP and monthly commerce limits; `TranCount` and `Limit` stored as 0). The campaign's exact table counts show 6 rows per site at the end (3 more on each); their dates were not read. The API counters (throttled, rejected and rejected-login requests) were not read during the campaign; both pre-restore readings show 0 on all three sites on every day read.
- **Residue.** The exact table counts before and after the campaign (`table-counts-campaign-baseline.json`, `table-counts-campaign-end.json`) are summarised in the [README's methodology appendix](../README.md#methodology-appendix).

## PowerShell scripts

All scripts run in Windows PowerShell 5.1 (`powershell -ExecutionPolicy Bypass -File …`). No password is ever placed on a command line, printed or written by them.

### `Build-PerfDBBenchmarkPackage.ps1`

Builds the customization package from source.

- Compiles `PerfDBBenchmark.Core.csproj` with `dotnet build` for .NET Framework 4.8 in Release mode, resolving Acumatica references from a reference instance under `-InstanceRoot` (default `D:\Instances\26.200.0334\PerfSQL`; its `Bin` folder is passed as `AcumaticaBinFolder`).
- Regenerates `customization/PerfDBBenchmark/project.xml` from the pages, the Modern UI sources and the DLL, copies the DLL into the package folder and writes `artifacts/PerfDBBenchmark.zip`.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Build-PerfDBBenchmarkPackage.ps1
```

### `Publish-PerfDBBenchmark.ps1`

Publishes the package to all three local instances with Acumatica's `PX.CommandLine.exe` (run it **elevated**: the site folders are Administrators-only).

- Builds the package first unless `-SkipPackageBuild`; auto-detects the sites under `-InstanceRoot`; publishes to `PerfPG`, `PerfMySQL` and `PerfSQL`.
- Uses `/merge` and `/skipPreviouslyExecutedDbScripts` by default.
- Writes diagnostics to `artifacts\publish-diagnostics` and, on failure, decompiles reference assemblies with `dnSpy.Console.exe` so that versions can be compared.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Publish-PerfDBBenchmark.ps1
```

### `Get-PerfEnvironment.ps1`

Captures the campaign environment as JSON: host (model, CPU, RAM, disks, OS, power plan), background load, antivirus, repository commit and DLL hashes (repository build and all three sites must match), Acumatica sites (web.config flags, provider, application pool, driver versions), the three database servers (versions, all settings, sizes, statistics dates, instrumentation), the client connection and isolation level Acumatica actually uses, and a highlight list for the README tables. SQL Server is read with Windows authentication; MySQL only through `--defaults-extra-file`; PostgreSQL only through `PGPASSFILE`. Connection strings are read for their keys only.

| Mode | Purpose |
|---|---|
| (none) | full capture (`environment-start.json` / `environment-end.json`) |
| `-Preflight` | only the expected clients are connected to the database servers (exit code 2 otherwise) |
| `-TableCounts` | row counts of every table per engine plus soft-deleted rows; with `-BaselineFile`, the tables that grew |
| `-EngineCounters` | cumulative engine counters for the suite's `-Diagnostics` |
| `-SkipDatabases` | no elevation and no database access |

```powershell
.\scripts\Get-PerfEnvironment.ps1 -OutFile "$camp\environment-start.json" -CampaignDir $camp `
    -MySqlDefaultsFile "<repo>\Exceptions\mysql-root.cnf" -PgPassFile "<repo>\Exceptions\pgpass.conf"
```

### `Run-PerfDBBenchmarkEndpointSuite.ps1`

The campaign runner. It talks to the three instances over the REST endpoint and writes the campaign JSON v2, rewritten atomically after every run so that an interrupted campaign can be resumed with the same `-CampaignId`.

- **Structure:** blocks A → B → C → D; per block a warm-up repetition R0 (discarded) and repetitions 1…6, each with its own instance order (PostgreSQL → MySQL → SQL Server; MySQL → SQL Server → PostgreSQL; SQL Server → PostgreSQL → MySQL; SQL Server → MySQL → PostgreSQL; MySQL → PostgreSQL → SQL Server; PostgreSQL → SQL Server → MySQL); test by test within a repetition.
- **Before every repetition:** `ENV_CAPTURE` on every instance and gates G1–G7. **Before every run:** cool-down (20 s after runs with 8 or more workers), the settle gate (CPU < 10%, disk < 20 MB/s over 3 s, at least 3 s, at most 60 s; blocks B–D also the other database processes < 3% of one core and < 5 MB/s, at most 90 s) and the parameter round-trip check.
- **Re-runs:** a spoiled slot is re-run at the end of its block as a triple (all three instances in that repetition's order); outliers are never re-run. Restarts, stuck instances (run budget + 5 min + 2 min) and the 2-API-user login limit are handled. After a detected site restart, the next measured run on that site starts no earlier than 150 s after the new process started (the unlimited-CPU window, see [Acumatica's limits](#acumaticas-limits-for-sites-without-a-licence)); the wait is recorded with the restart event.
- **Block D** is refused unless `-BackupsVerified` is given and the backup artefacts exist.

| Profile | Content |
|---|---|
| `Full` | 6 repetitions + R0 (publishable) |
| `Quick` | 2 repetitions + R0 at work scale 0.5 (preliminary, never published) |
| `DryRun` | 1 full-size repetition, no R0; with `-WriteCalibration`, `-Diagnostics`, `-ApiReadCheck` (the API read is not available on these sites; see [End-to-end API read](#end-to-end-api-read-through-the-default-endpoint-dry-run-step-3l-not-available)) |
| `Smoke` | 1 repetition at work scale 0.1, 1 measured pass, no warm-up pass, no R0 |

Useful parameters: `-Blocks A,B,C`, `-IncludeTests`, `-ExcludeTests`, `-ExcludeOptional`, `-CalibrationFile` (run budgets from the dry run), `-NoRerun`, `-BetweenBlocksCommand`, `-EnvironmentScript none`, `-PlanOnly` (prints the plan and run counts without credentials or REST calls), `-ReportOnly -InputJson <paths>` (runs the report generator). If `-Password` is omitted, the script prompts for it securely.

```powershell
.\scripts\Run-PerfDBBenchmarkEndpointSuite.ps1 -PlanOnly -Profile Full
.\scripts\Run-PerfDBBenchmarkEndpointSuite.ps1 -Profile Smoke -Blocks A,B,C -Username admin
.\scripts\Run-PerfDBBenchmarkEndpointSuite.ps1 -Profile Full -Blocks A,B,C -Username admin -CalibrationFile "$dry\calibration.json"
.\scripts\Run-PerfDBBenchmarkEndpointSuite.ps1 -Profile Full -Blocks D -BackupsVerified -CampaignId $cid -Username admin -CalibrationFile "$dry\calibration.json"
```

Exit codes: 0 done; 1 error; 3 campaign aborted by a gate (G1/G4); 4 pre-flight failed at campaign start.

### `New-PerfDBBenchmarkReport.ps1`

Builds the report from one or more campaign JSON files (merged by campaign ID, for example when Block D ran on another night): the analysis set (6 slots per test and database), the comparability gate, the parity rules and the [winner and tie rule](#winner-and-tie-rule-formal-version). Every threshold is in the `$TieRule` hashtable at the top of the script and is mirrored into `analysis.json`.

```powershell
.\scripts\New-PerfDBBenchmarkReport.ps1 -InputJson artifacts\benchmark-reports\<id>\PerfDBBenchmark-<id>.json -Publish -ChartUrlPrefix docs/images/2026r2/
.\scripts\New-PerfDBBenchmarkReport.ps1 -SelfTest          # tie-rule test vectors V1-V12
.\scripts\New-PerfDBBenchmarkReport.ps1 -InputJson scripts\samples\campaign-v2-sample.json -OutDir $env:TEMP\perf-report   # synthetic fixture
```

`-Publish` exits with 2 when a test is not comparable (unless `-AllowPartial`, which lists the excluded tests) and with 3 when the profile is not `Full`. A test that hit a time limit is a valid result and never causes exit code 2.

### `Test-PerfDBBenchmark.ps1`

A browser smoke test that drives headless Chrome through the Chrome DevTools Protocol: it logs in to each instance, opens `AC301000`, runs a few tests at a tiny size and checks that local and comparison results appear. It checks deployment only; it is not part of the measurements.

## Output files

| File | Written by | Content |
|---|---|---|
| `artifacts\benchmark-reports\<CampaignId>\PerfDBBenchmark-<CampaignId>.json` | suite | campaign JSON v2: campaign settings (rotation, blocks, core parameters, settle gate, client connection, endpoint, repository commit), instances, the server catalog, the environment (start, end and every `ENV_CAPTURE`), every run with its status, slot, settle data, per-process CPU and I/O counters and the parsed `ResultJson`, and the event log |
| `analysis.json` | report | tie-rule thresholds, cells (analysis-set values, median, min, max, robust CV, CPU per operation), verdicts (pairs, tiers, sentences), families (index, leader, cell words), derived values (scaling, hot-item penalty, 1 → 8 worker speed-up) and diagnostics |
| `PerfDBBenchmark-<CampaignId>.html` | report | self-contained report (inline CSS and SVG, no script) |
| `README-results.md` | report | the README fragments, each marked `<!-- fragment:NAME -->` (not-comparable-notice, at-a-glance, decision-guide, tie-rule, results-by-family, family-&lt;Family&gt;, parity, how-we-measured, environment, limits, not-measured, methodology-appendix, glossary) |
| `charts\*.svg` | report | `at-a-glance.svg`, one chart per family, `scaling-orders.svg`, `speedup-core.svg`; white background, Okabe–Ito colours (SQL Server `#0072B2`, MySQL `#E69F00`, PostgreSQL `#CC79A7`), every bar labelled |
| `environment-*.json`, `table-counts-*.json` | `Get-PerfEnvironment.ps1` | environment captures and table counts (the campaign's residue list compares exact counts of every table, per database, between the baseline taken after the rehearsal and the campaign end) |
| `decisions.json` | campaign orchestration | every environment decision with its "before" state (memory, E1–E14), the decisions of 2026-10-04 (`userDecisions`: SQL throttle off, CPU limit kept, telemetry as shipped, order-entry sizes kept, back-to-back schedule, automatic start, invoice retainage) and the re-run procedure |
| `pre-restore-throttle-evidence.json` | campaign orchestration | Acumatica's licence telemetry of all three databases, read right before each restore from the pre-campaign backups: SQL throttle waits per interval and legend, reduced-mode and CPU flags, violation rows and API counters |
| `post-part1-checks.json`, `pre-blockD-checks.json`, `auto-continue-decision.json`, `throttle-readings.json`, `run-campaign-state.json` | campaign orchestration | the automated checks before Block D, the helper's decision record (see [What happened during the campaign](#what-happened-during-the-campaign)), the throttle readings at every checkpoint and the campaign timeline |
| `docs/results/2026r2/` | copied from the campaign folder for publication | `analysis.json`, `README-results.md` (only its chart links changed, to `../../images/2026r2/`, which is `docs/images/2026r2/`) and the HTML report as `report.html`, so readers can check every published number |
| `ResultJson` (column of `PerfTestResult`) | engine | schema v1, under 64 KB: parameters and their hash, run budget, phase durations, per-pass times and digests, warm-up passes, sub-phases (create / release+post), workers (requested, observed peak, in-flight peak, thread pool size), errors (counts, samples, failed operations), parity values, invariants, capped/aborted state, server facts and, for `ENV_CAPTURE`, the environment |
| `<site>\App_Data\PerfDBBenchmark\perfdbbenchmark-results.json` | engine | snapshot v2: the latest completed, non-warm-up row per (test, parameter hash) of that instance, for the in-app comparison |

## Winner and tie rule (formal version)

The README states the rule in plain language. This is the exact rule implemented in `New-PerfDBBenchmarkReport.ps1`.

**Analysis set.** Each (test, database) has 6 slots, one per measured repetition. A slot's value is the original run if it is valid (`Completed` or `Capped`), otherwise the first valid run of that slot's triple re-run. A slot without a valid run stays empty (n < 6 is shown). Warm-up runs never count; outliers (value / cell median outside 0.67–1.5) are flagged and counted, never re-run or dropped.

**Inputs.** The analysis-set values are converted to time per unit: `t = x` for time headlines, `t = 60000 / x` (ms per operation) for throughput headlines. A `Capped` run counts as +∞.

**Cells.** Median m, min and max over finite values, robust CV = 100 · 1.4826 · MAD / m. A cell is "noisy" when CV > 15%. A cell with at least half of its values at +∞ is a Capped cell, shown as "over the time limit" and ranked last.

**Correctness first.**
1. Parity-expected tests: if two databases agree and the third differs, the third is marked "returned a different answer" and excluded from ranking; if all three differ, there is no speed verdict.
2. Tests where errors do not invalidate a run: a database with errors in any analysis-set run is shown with "N failed saves" and is excluded from the "faster" verdict; parity is compared only when every database has 0 errors.
3. A Capped cell is ranked last; two Capped cells tie.

**Pairwise verdict** between A and B, where A has the lower median:
- `gap = m_B / m_A − 1`, rounded to 6 decimals;
- `T = max(5%, 2 × max(CV_A, CV_B))`;
- `U` = number of pairs (a, b) with a > b, plus 0.5 per tie;
- **tie** if gap < T or U > ⌊0.14 · n_A · n_B⌋ (5 for 6 vs 6: A won at least 31 of 36 pairings, two-sided exact p ≈ 0.041; 4 for 5 vs 6; 3 for 5 vs 5);
- otherwise **slightly faster** (gap < 20%), **faster** (gap ≥ 20% and ratio < 1.5) or **much faster** (ratio ≥ 1.5);
- with fewer than 5 valid values on either side, only "much faster" with U = 0 is allowed; anything else is "inconclusive" (shown like a tie).

**Practical floor ("not noticeable").** A non-tie verdict is marked not noticeable, and counted as a tie in tiers and summaries, when the difference is below: Everyday screens 100 ms per action; Reports & month-end 1 s per report (per pass of 12 requests for deep paging) or 10%; Order entry (1 clerk) and Invoice release by 1 person 100 ms per document; Many simultaneous users and Invoice release by 4 people 10% throughput; Platform basics 10%.

**Tiers.** Tier 1 = the fastest database plus every database tied with it (statistically or not noticeable), Tier 2 = the fastest remaining plus its ties, and so on. Non-transitive results are reported as such; no single winner is invented.

**Family summary.** Family index per database = geometric mean of `m / m_fastest` over the family's tests that are comparable and finite on all three (left-out tests are listed with the reason). A database **leads** a family if it is in Tier 1 on at least 60% of the family's comparable tests and is never "much slower" than another database on any of them. At-a-glance cell: "Leads" (exactly one leader), "Tied" (in Tier 1 on at least 60% of the tests), otherwise "x.xx× slower (typical)".

**Comparability gate (per test).** At least 5 valid slots per database; one parameter hash, methodology version and DLL across all valid runs; matching start and end environment (DLL, Acumatica build, engine versions); identical master data. Otherwise the test is "not comparable" and listed.

**Information only:** a paired sign test per pair over the 6 repetitions (6 of 6 → p = 0.031) is stored in `analysis.json`; it never changes a verdict.

**Self-test vectors** (`-SelfTest`, time per unit):

| # | A | B | Expected |
|---|---|---|---|
| V1 | 100,101,99,100,102,98 | 120,118,122,119,121,120 | A faster (gap 20.0% after rounding, U = 0) |
| V2 | 100,101,99,100,102,98 | 103,99,104,101,102,100 | tie (gap 1.5% < 5%) |
| V3 | 100,101,99,100,102,98 | 160,158,162,159,161,160 | A much faster (1.6×) |
| V4 | 100,130,80,110,95,120 | 112,140,90,125,100,135 | tie (gap 12.9% < T ≈ 43.8%) |
| V5 | 100,100,100,100,100,130 | 108,108,108,108,108,90 | tie (gap 8% ≥ 5%, but U = 11 > 5) |
| V6 | 600 orders/min ×6 | 500 orders/min ×6 | A faster (100 vs 120 ms per order) |
| V7 | 100 ×4 (4 valid) | 160 ×6 | A much faster (n < 5, ratio ≥ 1.5, U = 0) |
| V8 | 100 ×4 (4 valid) | 120 ×6 | inconclusive |
| V9 | 100,101,99,100,102,98 | 110,109,111,110,112,108 | A slightly faster (gap 10%) |
| V10 | screens: 40,40.5,39.5,40,41,39 ms | 46,46.5,45.5,46,47,45 ms | slightly faster, not noticeable (6 ms < 100 ms) |
| V11 | 100 ×6 | 150,150,150,150,+∞,+∞ | A much faster; B is not a Capped cell |
| V12 | 100 ×6 | 150,150,150,+∞,+∞,+∞ | B is a Capped cell (last tier); A much faster |

## Notes

- **Credentials.** Database credentials for the environment script live in files that must stay out of git: copy `scripts/samples/mysql-root.cnf.example` to `<repo>\Exceptions\mysql-root.cnf` and `scripts/samples/pgpass.conf.example` to `<repo>\Exceptions\pgpass.conf`, **and make sure that folder is ignored by git** (add `Exceptions/` to `.gitignore` or `.git/info/exclude` before creating the files; check with `git check-ignore -v Exceptions/mysql-root.cnf`), then fill in the passwords there. The suite asks for the Acumatica password at a secure prompt when `-Password` is omitted. Avoid `;` and `=` in database passwords (Acumatica connection-string limitation).
- **Campaign orchestration.** The elevated helper scripts that applied the environment settings, took the backups and ran the campaign handle credentials and are kept outside the repository; everything they changed is recorded in the campaign folder (`decisions.json` and the "before" files) and disclosed in the README.
- **2026 R2 campaign flow (decisions of 2026-10-04).** One launcher restores the databases when needed, republishes, runs the full rehearsal (dry run) and then starts the campaign **automatically** when the rehearsal ends with no failed step. WARN and MANUAL results do not stop it; they are accepted beforehand under written rules (the table "Pre-decided WARN and MANUAL outcomes" of our test protocol, which is not published) and reviewed after the campaign; the [README's methodology appendix](../README.md#methodology-appendix) lists each WARN and MANUAL result of the final rehearsal and how it was accepted, including the two manual follow-ups that were not done (the trace-log look of step 3i and the duration check of step 3d). No script checks a warning against those rules. The campaign runs **back-to-back** (planned at about 14–15 hours) instead of over two nights; Block D (invoice release) starts automatically only when every automated check after blocks A–C passes, otherwise the campaign stops and waits for a person. In the 2026 R2 campaign two of those checks failed, both because of Block B's settle time-out share (the share check itself and the gate-warning check, which reported the same settle warning), and a helper, prepared on the owner's instruction, resumed with only that threshold relaxed and that one warning text tolerated (see [What happened during the campaign](#what-happened-during-the-campaign)).
- **Order-entry sizes (2× rule waived).** The protocol said to shorten any test that takes more than twice its estimate. The order-entry block (Block C) exceeded its estimate, almost entirely in the 4/8/16-clerk tests, mainly because one order costs about twice the assumed time; we kept the full sizes (80/160/320 orders per run, the same on every database) for sample depth. The deviation is recorded in `decisions.json` (`userDecisions.ordMultiUser2xRule`) and disclosed in the README's Table 3, because the report does not read free-form deviation keys.
- **Long operations and the REST API.** A benchmark run (Run Selected Test, the legacy run buttons and the REST `RunBenchmark` action) runs as a long operation keyed by its RequestID, not by the screen. The screen's own key would make the contract-based API answer every request to `BenchmarkControl` with 409 for as long as the run lasts in that session, so the control row could not be polled and `AbortBenchmark` could not be called. As a consequence, a run started on `AC301000` does not show "Executing. Press to abort" and the page does not refresh when the run ends: press **Refresh Status** (or reopen the screen) and read `LastRequestStatus` / `LastRequestMessage`, and use **Abort Run** to stop a run. Maintenance actions (for example Clear Test Data and Clear Test Records) still run under the screen's key and still show the indicator; while one of them runs, REST requests to `BenchmarkControl` from the same session get 409.
- **Publishing** works directly against the local site folders through `PX.CommandLine.exe`, so no HTTP login is needed for it; it must run elevated.
- **Screen permissions** for `AC301000` and `AC301001` are registered by the customization itself on authenticated requests, so no manual `RolesInGraph` SQL patch is needed after publishing.
- **Methodology version** `2026R2-M2` is stored with every result. Any change to what a test does after a campaign has started must bump that test's `ScenarioVersion`.
- **History.** The 2026 R1 results and their test descriptions are archived in [docs/history/2026R1-results.md](history/2026R1-results.md).
