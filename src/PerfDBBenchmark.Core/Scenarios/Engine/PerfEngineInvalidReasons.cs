namespace PerfDBBenchmark.Core.Scenarios;

/// <summary>
/// InvalidReason values of the status rules the engine adds after SPEC §4.4 rule 7 (PerfScenarioRunner.ApplyStatus).
/// The original reasons stay in PerfInvalidReasons (WP0 contract file, unchanged).
/// </summary>
public static class PerfEngineInvalidReasons
{
    public const string NonContentionErrors = "NonContentionErrors";   // rule 7b, NonContentionErrors:<n>: ErrorsInvalidate = false and an operation failed for a reason other than a deadlock, lock violation, time-out or serialization failure
    public const string NoSuccessfulOps = "NoSuccessfulOps";           // rule 7c, NoSuccessfulOps(0/<attempted>): measured operations were planned and none succeeded
}
