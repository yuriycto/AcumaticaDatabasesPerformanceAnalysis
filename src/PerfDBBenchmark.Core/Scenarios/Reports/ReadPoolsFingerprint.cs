using System.Collections.Generic;
using PX.Data;
using PerfDBBenchmark.Core.Scenarios.Screens;

namespace PerfDBBenchmark.Core.Scenarios.Reports;

/// <summary>
/// Master-data fingerprint contributor "screens-reports-pools" (SPEC §1.3.8, §1.8): <c>PerfDeterministic.PairsFingerprint</c>
/// over the (ID, CD) pairs of every Screens and Reports pool, so ENV_CAPTURE proves that each engine samples the same
/// orders, customers, items, ledger and GL accounts (and that their integer IDs, used in ORDER BY, are identical).
/// Read-only and deterministic; discovered by PerfScenarioRegistry through reflection.
/// </summary>
public sealed class ReadPoolsFingerprint : IPerfFingerprintContributor
{
    public string Name => "screens-reports-pools";

    public string Compute(PXGraph graph)
    {
        var pairs = new List<KeyValuePair<int, string>>();

        // SoSample500 has no integer key: the pair is (position in the sample, OrderNbr).
        var orders = ScreenPools.LoadSoSample500();
        for (var i = 0; i < orders.Count; i++) pairs.Add(new KeyValuePair<int, string>(i, "SoSample500:" + orders[i]));

        foreach (var c in ScreenPools.LoadOrderCustomers78()) pairs.Add(new KeyValuePair<int, string>(c.Key, "OrderCustomers78:" + c.Value));
        foreach (var item in ScreenPools.LoadSoldItems91()) pairs.Add(new KeyValuePair<int, string>(item.Key, "SoldItems91:" + item.Value));

        var ledgerId = ReportPools.FindActualLedgerId(graph);
        if (ledgerId == null)
        {
            pairs.Add(new KeyValuePair<int, string>(0, "Ledger:" + PerfCampaignConstants.ActualLedgerCD + ":missing"));
        }
        else
        {
            pairs.Add(new KeyValuePair<int, string>(ledgerId.Value, "Ledger:" + PerfCampaignConstants.ActualLedgerCD));
            foreach (var a in ReportPools.LoadGlAccounts56(ledgerId.Value)) pairs.Add(new KeyValuePair<int, string>(a.Key, "GlAccounts56:" + a.Value));
        }

        // Fixed lists (SearchFragments20, SalesYears14, TbPeriods12) are code constants; they are included so that a code change
        // to a pool definition shows up in the fingerprint as well.
        for (var i = 0; i < ScreenCustomerSearchScenario.Fragments.Length; i++)
            pairs.Add(new KeyValuePair<int, string>(i, "SearchFragments20:" + ScreenCustomerSearchScenario.Fragments[i]));
        for (var i = 0; i < ReportPools.SalesYears14.Length; i++)
            pairs.Add(new KeyValuePair<int, string>(i, "SalesYears14:" + ReportPools.SalesYears14[i]));
        for (var i = 0; i < ReportPools.TbPeriods12.Length; i++)
            pairs.Add(new KeyValuePair<int, string>(i, "TbPeriods12:" + ReportPools.TbPeriods12[i]));

        return PerfDeterministic.PairsFingerprint(pairs);
    }
}
