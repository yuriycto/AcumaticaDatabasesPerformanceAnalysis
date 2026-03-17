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
using PerfDBBenchmark.Core.Support;

namespace PerfDBBenchmark.Core.Pages;

/// <summary>
/// AC301000 page implementation delivered through the precompiled PerfDBBenchmark DLL.
/// Created by AcuPower LTD for performance analysis.
/// Company website: https://acupowererp.com
/// </summary>
public class AC301000 : PXPage
{
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

        if (string.Equals(row.TestCategory, "Complex BQL Join", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(row.TestCategory, "PXProjection", StringComparison.OrdinalIgnoreCase))
        {
            e.Row.Cells["TestDisplayName"].Style.CssClass = "perfFocusCell";
        }
    }

    protected void OverviewChart_OnLoad(object sender, EventArgs e) =>
        BindChart((PXSerialChart)sender, row => true);

    protected void ComplexChart_OnLoad(object sender, EventArgs e) =>
        BindChart((PXSerialChart)sender, row =>
            string.Equals(row.TestCategory, "Complex BQL Join", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(row.TestCategory, "PXProjection", StringComparison.OrdinalIgnoreCase));

    protected void DmlChart_OnLoad(object sender, EventArgs e) =>
        BindChart((PXSerialChart)sender, row =>
            string.Equals(row.TestCategory, "Read", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(row.TestCategory, "Write", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(row.TestCategory, "Delete", StringComparison.OrdinalIgnoreCase));

    private void BindChart(PXSerialChart chart, Func<PerfComparisonResult, bool> predicate)
    {
        if (chart == null)
        {
            return;
        }

        var graph = GetGraph();
        var rows = graph.GetComparisonResults();
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
        SetBenchmarkButtonTooltip("btnSeqRead", PerfBenchmarkTestCodes.SequentialRead);
        SetBenchmarkButtonTooltip("btnSeqWrite", PerfBenchmarkTestCodes.SequentialWrite);
        SetBenchmarkButtonTooltip("btnSeqDelete", PerfBenchmarkTestCodes.SequentialDelete);
        SetBenchmarkButtonTooltip("btnSeqComplex", PerfBenchmarkTestCodes.SequentialComplexJoin);
        SetBenchmarkButtonTooltip("btnSeqProjection", PerfBenchmarkTestCodes.SequentialProjection);
        SetBenchmarkButtonTooltip("btnParRead", PerfBenchmarkTestCodes.ParallelRead);
        SetBenchmarkButtonTooltip("btnParWrite", PerfBenchmarkTestCodes.ParallelWrite);
        SetBenchmarkButtonTooltip("btnParDelete", PerfBenchmarkTestCodes.ParallelDelete);
        SetBenchmarkButtonTooltip("btnParComplex", PerfBenchmarkTestCodes.ParallelComplexJoin);
        SetBenchmarkButtonTooltip("btnParProjection", PerfBenchmarkTestCodes.ParallelProjection);
        SetStaticButtonTooltip("btnRefreshStatus", PerfBenchmarkDescriptions.RefreshStatus);
    }

    private void SetBenchmarkButtonTooltip(string buttonId, string testCode)
    {
        if (FindControlRecursive(this, buttonId) is PXButton button)
        {
            button.ToolTip = PerfBenchmarkCatalog.Get(testCode).ShortDescription;
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
