using PX.Data;
using PX.Data.BQL.Fluent;
using PerfDBBenchmark.Core.DAC;

namespace PerfDBBenchmark.Core.Scenarios;

/// <summary>Lightweight graph for benchmark work: no constructor side effects (no WMI, no snapshot reads).</summary>
public class PerfWorkerGraph : PXGraph<PerfWorkerGraph>
{
    public PXSave<PerfTestRecord> Save;
    public SelectFrom<PerfTestRecord>.View Records;

    public PerfWorkerGraph()
    {
        UnattendedMode = true;   // no session query-cache load, no session writes on Clear
    }
}
