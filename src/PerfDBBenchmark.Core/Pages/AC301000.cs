using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Web.UI;
using PX.Data;
using PX.Common;
using PX.Web.UI;
using PerfDBBenchmark.Core.DAC;
using PerfDBBenchmark.Core.Graphs;
using PerfDBBenchmark.Core.Scenarios;

namespace PerfDBBenchmark.Core.Pages;

/// <summary>
/// AC301000 page implementation delivered through the precompiled PerfDBBenchmark DLL.
/// Created by AcuPower LTD for performance analysis.
/// Company website: https://acupowererp.com
/// </summary>
/// <remarks>
/// Uses only the P0 contracts (PerfScenarioRegistry, PerfLegacyAliases, PerfFamilies) and the graph methods whose
/// signatures stay stable (GetComparisonResults, GetChartPoints, GetChartDatabaseOrder; SPEC §2.3).
/// Charts are grouped by the server-side Family of each test, never by hard-coded categories (SPEC §5.5).
/// </remarks>
public class AC301000 : PXPage
{
    /// <summary>Chart control ID prefix; the rest of the ID is the Family (for example "chartFamilyScreens").</summary>
    private const string FamilyChartPrefix = "chartFamily";

    /// <summary>The 12 legacy buttons keep their IDs and start the matching CORE_* test (PerfLegacyAliases).</summary>
    private static readonly KeyValuePair<string, string>[] LegacyButtons =
    {
        new KeyValuePair<string, string>("btnSeqRead", "SEQ_READ"),
        new KeyValuePair<string, string>("btnSeqWrite", "SEQ_WRITE"),
        new KeyValuePair<string, string>("btnSeqUpdate", "SEQ_UPDATE"),
        new KeyValuePair<string, string>("btnSeqDelete", "SEQ_DELETE"),
        new KeyValuePair<string, string>("btnSeqComplex", "SEQ_COMPLEX"),
        new KeyValuePair<string, string>("btnSeqProjection", "SEQ_PROJECTION"),
        new KeyValuePair<string, string>("btnParRead", "PAR_READ"),
        new KeyValuePair<string, string>("btnParWrite", "PAR_WRITE"),
        new KeyValuePair<string, string>("btnParUpdate", "PAR_UPDATE"),
        new KeyValuePair<string, string>("btnParDelete", "PAR_DELETE"),
        new KeyValuePair<string, string>("btnParComplex", "PAR_COMPLEX"),
        new KeyValuePair<string, string>("btnParProjection", "PAR_PROJECTION")
    };

    protected void Page_Load(object sender, EventArgs e)
    {
        RegisterBenchmarkStyles();
    }

    protected override void OnPreRender(EventArgs e)
    {
        ConfigureButtonTooltips();
        base.OnPreRender(e);
    }

    public override void RegisterClientScriptBlock(string key, string script)
    {
        base.RegisterClientScriptBlock(key, script);
        var renderer = JSManager.GetRenderer(this);
        JSManager.RegisterModule(renderer, typeof(PXChart), JS.AmChart);
        JSManager.RegisterModule(renderer, typeof(PXChart), JS.Chart);
    }

    protected void ComparisonGrid_RowDataBound(object sender, PXGridRowEventArgs e)
    {
        if (e.Row?.DataItem is not PerfComparisonResult row)
        {
            return;
        }

        if (row.IsWinner == true)
        {
            e.Row.Style.CssClass = "perfWinnerRow";
        }

        // The in-app verdict is indicative only; rows that cannot be compared (parameters, DLL or status differ) are muted.
        if (row.IsComparable == false && e.Row.Cells["Verdict"] != null)
        {
            e.Row.Cells["Verdict"].Style.CssClass = "perfMutedNote";
        }

        if (string.Equals(row.Family, PerfFamilies.Reports, StringComparison.OrdinalIgnoreCase) && e.Row.Cells["TestDisplayName"] != null)
        {
            e.Row.Cells["TestDisplayName"].Style.CssClass = "perfFocusCell";
        }
    }

    /// <summary>All comparable tests in one chart.</summary>
    protected void OverviewChart_OnLoad(object sender, EventArgs e) =>
        BindChart((PXSerialChart)sender, row => !IsExcludedFamily(row.Family));

    /// <summary>One chart per Family; the Family is taken from the control ID (chartFamily&lt;Family&gt;).</summary>
    protected void FamilyChart_OnLoad(object sender, EventArgs e)
    {
        if (sender is not PXSerialChart chart)
        {
            return;
        }

        var family = FamilyFromControlId(chart.ID);
        BindChart(chart, row => string.Equals(ResolveFamily(row), family, StringComparison.OrdinalIgnoreCase));
    }

    private static string FamilyFromControlId(string id)
    {
        if (string.IsNullOrEmpty(id) || !id.StartsWith(FamilyChartPrefix, StringComparison.OrdinalIgnoreCase))
        {
            return string.Empty;
        }

        return id.Substring(FamilyChartPrefix.Length);
    }

    /// <summary>The row's Family, or the descriptor's Family when an older snapshot row has none.</summary>
    private static string ResolveFamily(PerfComparisonResult row)
    {
        if (!string.IsNullOrWhiteSpace(row.Family))
        {
            return row.Family;
        }

        return TryGetDescriptor(row.TestCode, out var d) ? d.Family : string.Empty;
    }

    private static bool IsExcludedFamily(string family) =>
        string.Equals(family, PerfFamilies.Environment, StringComparison.OrdinalIgnoreCase);

    private void BindChart(PXSerialChart chart, Func<PerfComparisonResult, bool> predicate)
    {
        if (chart == null)
        {
            return;
        }

        var graph = GetGraph();
        var databaseOrder = graph.GetChartDatabaseOrder();
        var points = graph.GetChartPoints(predicate);

        chart.Visible = points.Count > 0;
        if (!chart.Visible)
        {
            chart.DataSource = null;
            return;
        }

        chart.Graphs.Clear();
        foreach (var database in databaseOrder)
        {
            chart.Graphs.Add(new PXChartGraph { Title = database });
        }

        var maxValue = points.SelectMany(x => x.Values).DefaultIfEmpty(0f).Max();
        chart.ValueAxis[0].Minimum = 0;
        chart.ValueAxis[0].Maximum = Math.Max(10, maxValue);
        chart.DataSource = points;
    }

    private PerfDBBenchmarkGraph GetGraph()
    {
        if (FindControlRecursive(this, "ds") is PXDataSource dataSource && dataSource.DataGraph is PerfDBBenchmarkGraph graph)
        {
            return graph;
        }

        return PX.Data.PXGraph.CreateInstance<PerfDBBenchmarkGraph>();
    }

    private static Control FindControlRecursive(Control root, string id)
    {
        if (root == null)
        {
            return null;
        }

        if (string.Equals(root.ID, id, StringComparison.OrdinalIgnoreCase))
        {
            return root;
        }

        foreach (Control child in root.Controls)
        {
            var found = FindControlRecursive(child, id);
            if (found != null)
            {
                return found;
            }
        }

        return null;
    }

    private void RegisterBenchmarkStyles()
    {
        CreateStyleRule("perfWinnerRow", ColorTranslator.FromHtml("#dcfce7"), ColorTranslator.FromHtml("#14532d"), isBold: true);
        CreateStyleRule("perfFocusCell", ColorTranslator.FromHtml("#ecfeff"), ColorTranslator.FromHtml("#155e75"), isBold: true);
        CreateStyleRule("perfMutedNote", ColorTranslator.FromHtml("#f8fafc"), ColorTranslator.FromHtml("#475569"), isBold: false);
    }

    private void ConfigureButtonTooltips()
    {
        foreach (var button in LegacyButtons)
        {
            SetBenchmarkButtonTooltip(button.Key, button.Value);
        }

        SetStaticButtonTooltip("btnRunBenchmark", "Runs the test selected in 'Test to Run' with the parameters on this form (work scale, passes, warm-up passes, run budget).");
        SetStaticButtonTooltip("btnAbortBenchmark", "Asks the run in progress on this instance to stop after its current operation; the run is stored as Invalid (Aborted).");
        SetStaticButtonTooltip("btnClearTestRecords", "Deletes benchmark work records other than the READ-SEED and UPDATE-SEED batches and removes documents left by interrupted runs. Results are kept.");
        SetStaticButtonTooltip("btnRefreshStatus", "Reloads the snapshot and pending-analysis status so you can check which tests have comparable results on all instances.");
    }

    private void SetBenchmarkButtonTooltip(string buttonId, string legacyTestCode)
    {
        if (FindControlRecursive(this, buttonId) is PXButton button)
        {
            button.ToolTip = TryGetDescriptor(legacyTestCode, out var d)
                ? d.ShortDescription ?? d.WhatItSimulates ?? string.Empty
                : string.Empty;
        }
    }

    private static bool TryGetDescriptor(string testCode, out PerfTestDescriptor descriptor)
    {
        descriptor = null;
        try
        {
            return PerfScenarioRegistry.TryGet(PerfLegacyAliases.Map(testCode), out descriptor);
        }
        catch
        {
            // The registry never throws by contract; a tooltip must never break the page.
            return false;
        }
    }

    private void SetStaticButtonTooltip(string buttonId, string toolTip)
    {
        if (FindControlRecursive(this, buttonId) is PXButton button)
        {
            button.ToolTip = toolTip;
        }
    }

    private void CreateStyleRule(string cssClass, Color background, Color foreground, bool isBold)
    {
        var style = new System.Web.UI.WebControls.Style
        {
            BackColor = background,
            ForeColor = foreground
        };

        if (isBold)
        {
            style.Font.Bold = true;
        }

        Header.StyleSheet.CreateStyleRule(style, this, "." + cssClass);
    }
}
