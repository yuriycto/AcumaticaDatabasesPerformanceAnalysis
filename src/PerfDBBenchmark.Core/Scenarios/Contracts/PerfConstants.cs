using System;
using System.Collections.Generic;
using System.IO;
using PX.Data;

namespace PerfDBBenchmark.Core.Scenarios;

/// <summary>Methodology identity. Changing anything that alters what is measured bumps this value.</summary>
public static class PerfMethodology
{
    public const string Version = "2026R2-M2";
    public const int ResultJsonVersion = 1;
}

public static class PerfFamilies
{
    public const string Environment = "Environment";
    public const string Core = "Core";
    public const string Screens = "Screens";
    public const string Reports = "Reports";
    public const string OrderEntry = "OrderEntry";
    public const string ManyUsers = "ManyUsers";
    public const string InvoiceRelease = "InvoiceRelease";
}

/// <summary>Campaign blocks (SPEC §6). Blocks run strictly A → B → C → D.</summary>
public static class PerfBlocks
{
    public const string Gate = "G";          // ENV_CAPTURE (run before every repetition)
    public const string ReadOnly = "A";      // Screens + Reports
    public const string Core = "B";          // re-baselined core 12
    public const string OrderEntry = "C";    // OrderEntry + ManyUsers (self-cleaning)
    public const string Destructive = "D";   // InvoiceRelease (permanent; last; after backups)
}

public static class PerfHeadlineKinds
{
    /// <summary>p50 of all measured operation latencies pooled over the run's measured passes (ms, lower is better).</summary>
    public const string MedianOpMs = "MedianOpMs";
    /// <summary>Median of the measured pass wall times (ms, lower is better).</summary>
    public const string MedianPassMs = "MedianPassMs";
    /// <summary>Median over measured passes of successfulOps / (passWallMs / 60000) (ops per minute, higher is better).</summary>
    public const string OpsPerMin = "OpsPerMin";
    public const string None = "None";
}

public static class PerfRunStatuses
{
    public const string Completed = "Completed";
    public const string Invalid = "Invalid";
    public const string Capped = "Capped";
}

/// <summary>Prefixes for PerfRunMetrics.InvalidReason (free text may follow after ':').</summary>
public static class PerfInvalidReasons
{
    public const string WorkersNotStarted = "WorkersNotStarted";   // WorkersNotStarted(k/W)
    public const string WorkerCrashed = "WorkerCrashed";
    public const string Errors = "Errors";                         // ErrorsInvalidate && ErrorCount > 0
    public const string Invariant = "Invariant";                   // Invariant:<name>
    public const string Cleanup = "Cleanup";
    public const string ParallelDisabled = "ParallelProcessingDisabled";
    public const string ItemsShortfall = "ItemsShortfall";
    public const string Aborted = "Aborted";                       // AbortBenchmark action (SPEC §1.3.4)
}

/// <summary>Why a run was stored as Capped (written to InvalidReason and ResultJson.capped.kind; SPEC §1.3.4).</summary>
public static class PerfCappedKinds
{
    public const string OperationCap = "operationCap";   // one operation exceeded PerfRunPlan.OperationCapMs
    public const string RunBudget = "runBudget";         // the run exceeded PerfRunPlan.RunBudget
}

public static class PerfScenarioCodes
{
    public const string RunBenchmarkAction = "RunBenchmark";
    public const string ClearTestRecordsAction = "ClearTestRecords";
    public const string AbortBenchmarkAction = "AbortBenchmark";

    public const string EnvironmentCapture = "ENV_CAPTURE";

    public const string CoreRead1U = "CORE_READ_1U";
    public const string CoreRead8U = "CORE_READ_8U";
    public const string CoreInsert1U = "CORE_INSERT_1U";
    public const string CoreInsert8U = "CORE_INSERT_8U";
    public const string CoreUpdate1U = "CORE_UPDATE_1U";
    public const string CoreUpdate8U = "CORE_UPDATE_8U";
    public const string CoreDelete1U = "CORE_DELETE_1U";
    public const string CoreDelete8U = "CORE_DELETE_8U";
    public const string CoreJoinFull1U = "CORE_JOIN_FULL_1U";
    public const string CoreJoinFull8U = "CORE_JOIN_FULL_8U";
    public const string CoreJoinSlim1U = "CORE_JOIN_SLIM_1U";
    public const string CoreJoinSlim8U = "CORE_JOIN_SLIM_8U";

    public const string OpenSalesOrder = "SCR_OPEN_SALES_ORDER";
    public const string CustomerOrderHistory = "SCR_CUSTOMER_ORDER_HISTORY";
    public const string ItemBuyers = "SCR_ITEM_BUYERS";
    public const string CustomerSearch = "SCR_CUSTOMER_SEARCH";

    public const string SalesByCustomerMonth = "RPT_SALES_BY_CUSTOMER_MONTH";
    public const string TrialBalance = "RPT_TRIAL_BALANCE";
    public const string GLAccountDetails = "RPT_GL_ACCOUNT_DETAILS";
    public const string LargeListPaging = "RPT_LARGE_LIST_PAGING";

    public const string SoEntryU01 = "ORD_SO_ENTRY_U01";
    public const string SoEntryU04 = "ORD_SO_ENTRY_U04";
    public const string SoEntryU08 = "ORD_SO_ENTRY_U08";
    public const string SoEntryU16 = "ORD_SO_ENTRY_U16";
    public const string SoHotItemU04 = "ORD_SO_HOTITEM_U04";
    public const string SoHotItemU08 = "ORD_SO_HOTITEM_U08";
    public const string SoHotItemU16 = "ORD_SO_HOTITEM_U16";

    public const string InvoiceReleaseU01 = "INV_RELEASE_TO_GL_U01";
    public const string InvoiceReleaseU04 = "INV_RELEASE_TO_GL_U04";
}

/// <summary>The 12 legacy codes/actions keep working and start the matching CORE_* test (SPEC §2.1).</summary>
public static class PerfLegacyAliases
{
    private static readonly Dictionary<string, string> Map_ = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
        ["SEQ_READ"] = PerfScenarioCodes.CoreRead1U,
        ["PAR_READ"] = PerfScenarioCodes.CoreRead8U,
        ["SEQ_WRITE"] = PerfScenarioCodes.CoreInsert1U,
        ["PAR_WRITE"] = PerfScenarioCodes.CoreInsert8U,
        ["SEQ_UPDATE"] = PerfScenarioCodes.CoreUpdate1U,
        ["PAR_UPDATE"] = PerfScenarioCodes.CoreUpdate8U,
        ["SEQ_DELETE"] = PerfScenarioCodes.CoreDelete1U,
        ["PAR_DELETE"] = PerfScenarioCodes.CoreDelete8U,
        ["SEQ_COMPLEX"] = PerfScenarioCodes.CoreJoinFull1U,
        ["PAR_COMPLEX"] = PerfScenarioCodes.CoreJoinFull8U,
        ["SEQ_PROJECTION"] = PerfScenarioCodes.CoreJoinSlim1U,
        ["PAR_PROJECTION"] = PerfScenarioCodes.CoreJoinSlim8U
    };

    /// <summary>Returns the CORE_* code for a legacy code; any other input is returned unchanged.</summary>
    public static string Map(string code) =>
        code != null && Map_.TryGetValue(code, out var mapped) ? mapped : code;

    /// <summary>Returns the legacy code for a CORE_* code, or null.</summary>
    public static string LegacyOf(string coreCode)
    {
        foreach (var kv in Map_)
        {
            if (string.Equals(kv.Value, coreCode, StringComparison.OrdinalIgnoreCase)) return kv.Key;
        }
        return null;
    }

    public static IReadOnlyDictionary<string, string> All => Map_;
}

public static class PerfDatabaseEngines
{
    public const string SqlServer = "SQLServer";
    public const string MySql = "MySQL";
    public const string PostgreSql = "PostgreSQL";
    public const string Unknown = "Unknown";

    /// <summary>Maps the real provider types: PX.Data.PXSqlDatabaseProvider, PX.MySql.MySqlDatabaseProvider, PX.PgSql.PgSqlDatabaseProvider.
    /// Falls back to the site folder name (PerfSQL / PerfMySQL / PerfPG) when the provider type is unexpected (review-api m7).</summary>
    public static string Detect()
    {
        string t;
        try { t = PXDatabase.Provider?.GetType().FullName ?? string.Empty; }
        catch { t = string.Empty; }

        var byType = FromName(t, isProviderType: true);
        if (byType != Unknown) return byType;

        string folder;
        try { folder = new DirectoryInfo(AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\', '/')).Name; }
        catch { folder = string.Empty; }
        return FromName(folder, isProviderType: false);
    }

    private static string FromName(string t, bool isProviderType)
    {
        if (string.IsNullOrEmpty(t)) return Unknown;
        if (Has(t, "PgSql") || Has(t, "Npgsql") || Has(t, "Postgre") || (!isProviderType && t.EndsWith("PG", StringComparison.OrdinalIgnoreCase))) return PostgreSql;
        if (Has(t, "MySql") || Has(t, "Maria")) return MySql;
        if (Has(t, "PXSqlDatabaseProvider") || Has(t, "SqlServer") || Has(t, "MsSql") || (!isProviderType && Has(t, "SQL"))) return SqlServer;
        return Unknown;
    }

    private static bool Has(string s, string part) => s.IndexOf(part, StringComparison.OrdinalIgnoreCase) >= 0;

    /// <summary>Reader-facing engine name used in results and reports.</summary>
    public static string DisplayName(string engine) => engine switch
    {
        SqlServer => "SQL Server",
        MySql => "MySQL",
        PostgreSql => "PostgreSQL",
        _ => "Unknown"
    };
}

/// <summary>Pinned campaign values (SPEC §1.2 and §1.3). Never derive these from the business date or hardware.</summary>
public static class PerfCampaignConstants
{
    // CORE family
    public const string ReadSeedBatch = "READ-SEED";
    public const string UpdateSeedBatch = "UPDATE-SEED";
    public const int CoreRecords = 10000;          // N
    public const int CoreChunkSize = 250;          // C: rows per chunk = rows per commit
    public const int CoreMeasuredPasses = 3;       // I
    public const int CoreWarmUpPasses = 1;
    public const int CoreParallelWorkers = 8;      // W for *_8U
    public const int CorePayloadFactor = 17;       // PayloadValue = Sequence * 17 (+ k for UPDATE-SEED)
    public const int CoreJoinPageSize = 50;
    public const int CoreJoinSweepsPerPass = 5;

    // Business families
    public static readonly DateTime PinnedDocDate = new DateTime(2026, 6, 30);
    public const string PinnedFinPeriodID = "202606";
    public const string BranchCD = "PRODWHOLE";
    public const string WarehouseCD = "WHOLESALE";
    public const string HotItemCD = "AACOMPUT01";
    public const string ActualLedgerCD = "ACTUAL";
    public const string DocumentTagPrefix = "PERFBENCH ";

    /// <summary>"PERFBENCH &lt;RunID:N&gt;" written to SOOrder.OrderDesc / ARInvoice.DocDesc.</summary>
    public static string DocumentTag(Guid runId) => DocumentTagPrefix + runId.ToString("N");
}
