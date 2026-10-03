using PX.Data;
using PX.Data.BQL.Fluent;
using PerfDBBenchmark.Core.DAC;

namespace PerfDBBenchmark.Core.Graphs;

/// <summary>
/// Read-only results graph used to expose persisted benchmark runs through REST.
/// Ordered by ResultID descending: CapturedAtUtc ties on MySQL DATETIME(0) (SPEC §2.1 F28).
/// </summary>
public class PerfDBBenchmarkResultsGraph : PXGraph<PerfDBBenchmarkResultsGraph>
{
    public PXCancel<PerfTestResult> Cancel;

    public SelectFrom<PerfTestResult>
        .OrderBy<Desc<PerfTestResult.resultID>>
        .View Results;

    public override bool IsDirty => false;
}
