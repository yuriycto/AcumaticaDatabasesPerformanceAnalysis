<%@ Page Language="C#" MasterPageFile="~/MasterPages/FormTab.master" AutoEventWireup="true" ValidateRequest="false"
    Inherits="PerfDBBenchmark.Core.Pages.AC301000" Title="Database Performance Benchmark - New UI" %>
<%@ MasterType VirtualPath="~/MasterPages/FormTab.master" %>

<asp:Content ID="cont1" ContentPlaceHolderID="phDS" runat="server">
    <px:PXDataSource ID="ds" runat="server" Visible="True" Width="100%"
        TypeName="PerfDBBenchmark.Core.Graphs.PerfDBBenchmarkGraph"
        PrimaryView="Filter">
    </px:PXDataSource>
</asp:Content>

<asp:Content ID="cont2" ContentPlaceHolderID="phF" runat="server">
    <style>
        .perf-header {
            border: 1px solid #dbeafe;
            background: linear-gradient(90deg, #eff6ff 0%, #f8fafc 100%);
            padding: 14px 18px;
            margin-bottom: 10px;
            border-radius: 8px;
        }
        .perf-header h2 {
            margin: 0 0 6px 0;
            font-size: 22px;
            color: #0f172a;
        }
        .perf-header p {
            margin: 0;
            color: #334155;
            font-size: 13px;
        }
        .perf-note {
            margin-top: 8px;
            color: #0f766e;
            font-weight: 600;
        }
        .perf-button-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
            gap: 12px;
            margin: 10px 0 16px 0;
            align-items: stretch;
        }
        .perf-button-cell {
            display: flex;
            min-height: 40px;
        }
        .perf-section-title {
            font-weight: 600;
            color: #0f172a;
            margin: 14px 0 6px 0;
        }
        .perf-legacy-note {
            color: #475569;
            font-size: 12px;
            margin: 0 0 6px 0;
        }
        .perf-visual-section {
            margin-top: 14px;
        }
        .perf-progress-shell {
            border: 1px solid #cbd5e1;
            background: #f8fafc;
            border-radius: 8px;
            padding: 12px;
            margin-top: 12px;
        }
        .perf-progress-title {
            font-weight: 600;
            color: #0f172a;
            margin-bottom: 8px;
        }
        .perf-progress-bar {
            position: relative;
            height: 14px;
            border-radius: 999px;
            background: #e2e8f0;
            overflow: hidden;
        }
        .perf-progress-bar span {
            display: block;
            width: 45%;
            height: 100%;
            background: linear-gradient(90deg, #0072B2 0%, #CC79A7 100%);
            animation: perfPulse 2s infinite ease-in-out;
        }
        .perf-progress-help {
            margin-top: 8px;
            color: #475569;
            font-size: 12px;
        }
        .perf-instructions {
            padding: 8px 4px 0 4px;
            color: #1e293b;
            line-height: 1.55;
        }
        .perf-instructions h3 {
            margin: 12px 0 6px 0;
            color: #0f172a;
        }
        .perf-instructions code,
        .perf-instructions pre {
            background: #f8fafc;
            border: 1px solid #e2e8f0;
            border-radius: 6px;
        }
        .perf-instructions pre {
            padding: 10px;
            white-space: pre-wrap;
        }
        .perf-highlight {
            color: #14532d;
            font-weight: 700;
        }
        @keyframes perfPulse {
            0% { margin-left: -20%; }
            50% { margin-left: 45%; }
            100% { margin-left: 100%; }
        }
    </style>

    <div class="perf-header">
        <h2>PerfDBBenchmark</h2>
        <p>Precompiled Acumatica database benchmark screen created by AcuPower LTD for performance analysis and published by <a href="https://acupowererp.com" target="_blank">acupowererp.com</a>.</p>
        <p class="perf-note">The same Acumatica workloads (everyday screens, reports, order entry, many users, invoice release and platform basics) run against SQL Server, MySQL and PostgreSQL. The comparison on this screen is indicative; published verdicts come from the report generator.</p>
    </div>

    <px:PXFormView ID="frmEnvironment" runat="server" DataSourceID="ds" DataMember="Filter" Width="100%" Caption="Current Environment">
        <Template>
            <px:PXLayoutRule runat="server" StartColumn="True" LabelsWidth="M" ControlSize="XM" />
            <px:PXTextEdit ID="edSetupID" runat="server" DataField="SetupID" />
            <px:PXTextEdit ID="edCurrentDatabase" runat="server" DataField="CurrentDatabase" />
            <px:PXTextEdit ID="edCurrentInstance" runat="server" DataField="CurrentInstance" />
            <px:PXNumberEdit ID="edDetectedCpuCores" runat="server" DataField="DetectedCpuCores" />
            <px:PXNumberEdit ID="edDetectedMemoryGb" runat="server" DataField="DetectedMemoryGb" />
            <px:PXTextEdit ID="edServerMethodologyVersion" runat="server" DataField="ServerMethodologyVersion" />
            <px:PXTextEdit ID="edServerAppStartUtc" runat="server" DataField="ServerAppStartUtc" />
            <px:PXLayoutRule runat="server" StartColumn="True" LabelsWidth="M" ControlSize="XXL" />
            <px:PXTextEdit ID="edServerDllSha256" runat="server" DataField="ServerDllSha256" />
            <px:PXTextEdit ID="edHardwareRecommendationSummary" runat="server" DataField="HardwareRecommendationSummary" />
            <px:PXTextEdit ID="edSnapshotStatus" runat="server" DataField="SnapshotStatus" />
            <px:PXTextEdit ID="edPendingAnalysisStatus" runat="server" DataField="PendingAnalysisStatus" />
            <px:PXLayoutRule runat="server" StartColumn="True" LabelsWidth="M" ControlSize="M" GroupCaption="Execution Status" />
            <px:PXTextEdit ID="edLastRequestID" runat="server" DataField="LastRequestID" />
            <px:PXTextEdit ID="edLastRequestedTestCode" runat="server" DataField="LastRequestedTestCode" />
            <px:PXTextEdit ID="edLastRequestedBenchmark" runat="server" DataField="LastRequestedBenchmark" />
            <px:PXTextEdit ID="edLastRequestStatus" runat="server" DataField="LastRequestStatus" />
            <px:PXDateTimeEdit ID="edLastRequestStartedAtUtc" runat="server" DataField="LastRequestStartedAtUtc" />
            <px:PXDateTimeEdit ID="edLastRequestCompletedAtUtc" runat="server" DataField="LastRequestCompletedAtUtc" />
            <px:PXNumberEdit ID="edLastRequestElapsedMs" runat="server" DataField="LastRequestElapsedMs" />
            <px:PXTextEdit ID="edLastRequestMessage" runat="server" DataField="LastRequestMessage" />
        </Template>
    </px:PXFormView>
</asp:Content>

<asp:Content ID="cont3" ContentPlaceHolderID="phG" runat="server">
    <px:PXTab ID="tabBenchmark" runat="server" Width="100%" Height="680px" AllowAutoHide="false">
        <Items>
            <px:PXTabItem Text="Instructions">
                <Template>
                    <div class="perf-instructions">
                        <h3>How to Run the Benchmark</h3>
                        <p>1. Publish the same DLL-based customization to all three instances: <span class="perf-highlight">PerfPG</span>, <span class="perf-highlight">PerfMySQL</span>, and <span class="perf-highlight">PerfSQL</span>. The <b>Server DLL SHA-256</b> field must show the same value on all three.</p>
                        <p>2. Open the <span class="perf-highlight">Run Tests</span> tab, choose a test in <b>Test to Run</b> and click <b>Run Benchmark</b> (the <span class="perf-highlight">RunBenchmark</span> action). Leave <b>Work Scale</b> at 1 and the pass overrides empty for full-size runs.</p>
                        <p>3. <b>Run Budget (s)</b> (<span class="perf-highlight">RunBudgetSec</span>) limits one run; 0 or empty means 15 minutes. A run that reaches the budget stops after its current operation, cleans up, and is stored as <b>Capped</b>, which is a valid result ranked last.</p>
                        <p>4. <b>Abort Benchmark</b> (<span class="perf-highlight">AbortBenchmark</span>) asks the run in progress on this instance to stop after its current operation. The run is stored as Invalid (Aborted). With nothing running it answers "Nothing to abort". Only one run per instance can be in progress.</p>
                        <p>5. <b>Clear Test Records</b> deletes benchmark work records other than the READ-SEED and UPDATE-SEED batches and removes documents left by interrupted runs; results are kept. <b>Clear Test Data</b> also deletes every stored result.</p>
                        <p>6. Run the same test with the same parameters on all three instances. The Results Grid and Visualization tabs show an indicative comparison only when the parameters hash and the DLL match. The published verdicts (six repetitions, warm-up, rotation and the tie rule) come from <code>scripts\New-PerfDBBenchmarkReport.ps1</code>.</p>

                        <h3>Parallel Processing and Thread Pool Requirements</h3>
                        <p>Multi-worker tests use Acumatica's processing infrastructure and require parallel processing to be enabled in the instance <code>Web.config</code>.</p>
                        <pre>&lt;add key="EnableAutoNumberingInSeparateConnection" value="true"/&gt;
&lt;add key="ParallelProcessingDisabled" value="false"/&gt;</pre>
                        <p>Tests with <b>16 workers</b> (16 clerks working non-stop) need a larger Acumatica thread pool. Add this element inside <code>&lt;px.core&gt;</code> in web.config (each worker uses one pool thread, plus one for the run itself):</p>
                        <pre>&lt;px.core&gt;
  &lt;ThreadPoolSize&gt;32&lt;/ThreadPoolSize&gt;
&lt;/px.core&gt;</pre>
                        <p>Without it, a 16-worker run is stored as Invalid (WorkersNotStarted) instead of being started with fewer workers.</p>

                        <h3>What the Tests Cover</h3>
                        <p>Everyday screens, reports and month-end, order entry, many simultaneous users, invoice release to GL, and the platform basics (the 12 original record, list and projection tests, re-baselined). The <b>Benchmark Catalog</b> tab lists each test with the question it answers, what it simulates and why it matters.</p>

                        <h3>Legacy Buttons</h3>
                        <p>The 12 original buttons still work. Each one starts the matching platform-basics test (for example Sequential Read starts CORE_READ_1U).</p>

                        <h3>Publisher</h3>
                        <p>This benchmark package was produced by AcuPower LTD for GitHub publishing and performance-analysis reporting. Company website: <a href="https://acupowererp.com" target="_blank">acupowererp.com</a>.</p>
                    </div>
                </Template>
            </px:PXTabItem>

            <px:PXTabItem Text="Test Parameters">
                <Template>
                    <px:PXFormView ID="frmParameters" runat="server" DataSourceID="ds" DataMember="Filter" Width="100%" Caption="Benchmark Parameters">
                        <Template>
                            <px:PXLayoutRule runat="server" StartColumn="True" GroupCaption="Platform Basics Parameters" LabelsWidth="M" ControlSize="M" />
                            <px:PXNumberEdit ID="edNumberOfRecords" runat="server" DataField="NumberOfRecords" />
                            <px:PXNumberEdit ID="edIterations" runat="server" DataField="Iterations" />
                            <px:PXNumberEdit ID="edParallelBatchSize" runat="server" DataField="ParallelBatchSize" />
                            <px:PXNumberEdit ID="edParallelMaxThreads" runat="server" DataField="ParallelMaxThreads" />

                            <px:PXLayoutRule runat="server" StartColumn="True" GroupCaption="Recommended Defaults" LabelsWidth="M" ControlSize="M" />
                            <px:PXNumberEdit ID="edRecommendedRecords" runat="server" DataField="RecommendedRecords" />
                            <px:PXNumberEdit ID="edRecommendedIterations" runat="server" DataField="RecommendedIterations" />
                            <px:PXNumberEdit ID="edRecommendedBatchSize" runat="server" DataField="RecommendedBatchSize" />
                            <px:PXNumberEdit ID="edRecommendedMaxThreads" runat="server" DataField="RecommendedMaxThreads" />

                            <px:PXLayoutRule runat="server" StartColumn="True" />
                            <px:PXButton ID="btnApplyRecommended" runat="server" Text="Apply Recommended Settings" CommandName="ApplyRecommendedSettings" CommandSourceID="ds" Width="240px" Height="28px" />
                        </Template>
                    </px:PXFormView>
                </Template>
            </px:PXTabItem>

            <px:PXTabItem Text="Run Tests">
                <Template>
                    <px:PXFormView ID="frmRunTest" runat="server" DataSourceID="ds" DataMember="Filter" Width="100%" Caption="Run a Test">
                        <Template>
                            <px:PXLayoutRule runat="server" StartColumn="True" GroupCaption="Test" LabelsWidth="M" ControlSize="XL" />
                            <px:PXDropDown ID="edSelectedTestCode" runat="server" DataField="SelectedTestCode" CommitChanges="True" />
                            <px:PXNumberEdit ID="edWorkScale" runat="server" DataField="WorkScale" CommitChanges="True" />
                            <px:PXNumberEdit ID="edPassesOverride" runat="server" DataField="PassesOverride" CommitChanges="True" />
                            <px:PXNumberEdit ID="edWarmUpPassesOverride" runat="server" DataField="WarmUpPassesOverride" />
                            <px:PXNumberEdit ID="edRunBudgetSec" runat="server" DataField="RunBudgetSec" />

                            <px:PXLayoutRule runat="server" StartColumn="True" GroupCaption="Campaign Context (set by the suite)" LabelsWidth="M" ControlSize="XM" />
                            <px:PXTextEdit ID="edCampaignID" runat="server" DataField="CampaignID" />
                            <px:PXNumberEdit ID="edRepetitionNo" runat="server" DataField="RepetitionNo" />
                            <px:PXCheckBox ID="edIsWarmup" runat="server" DataField="IsWarmup" />
                            <px:PXTextEdit ID="edRunBlock" runat="server" DataField="RunBlock" />
                            <px:PXNumberEdit ID="edOrderPosition" runat="server" DataField="OrderPosition" />
                        </Template>
                    </px:PXFormView>

                    <div class="perf-button-grid">
                        <div class="perf-button-cell"><px:PXButton ID="btnRunBenchmark" runat="server" Text="Run Benchmark" CommandName="RunBenchmark" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnAbortBenchmark" runat="server" Text="Abort Benchmark" CommandName="AbortBenchmark" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnClearTestRecords" runat="server" Text="Clear Test Records" CommandName="ClearTestRecords" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnRefreshStatus" runat="server" Text="Refresh Status" CommandName="RefreshStatus" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnExportExcel" runat="server" Text="Export to Excel" CommandName="ExportToExcel" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnClearData" runat="server" Text="Clear Test Data" CommandName="ClearTestData" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                    </div>

                    <div class="perf-section-title">Legacy buttons</div>
                    <p class="perf-legacy-note">The 12 original tests. Each button starts the matching platform-basics test (for example Sequential Read starts CORE_READ_1U).</p>
                    <div class="perf-button-grid">
                        <div class="perf-button-cell"><px:PXButton ID="btnSeqRead" runat="server" Text="Sequential Read" CommandName="RunSequentialRead" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnSeqWrite" runat="server" Text="Sequential Write" CommandName="RunSequentialWrite" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnSeqUpdate" runat="server" Text="Sequential Update" CommandName="RunSequentialUpdate" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnSeqDelete" runat="server" Text="Sequential Delete" CommandName="RunSequentialDelete" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnSeqComplex" runat="server" Text="Complex Join (Sequential)" CommandName="RunSequentialComplexJoin" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnSeqProjection" runat="server" Text="PXProjection (Sequential)" CommandName="RunSequentialProjection" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnParRead" runat="server" Text="Parallel Read" CommandName="RunParallelRead" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnParWrite" runat="server" Text="Parallel Write" CommandName="RunParallelWrite" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnParUpdate" runat="server" Text="Parallel Update" CommandName="RunParallelUpdate" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnParDelete" runat="server" Text="Parallel Delete" CommandName="RunParallelDelete" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnParComplex" runat="server" Text="Complex Join (Parallel)" CommandName="RunParallelComplexJoin" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnParProjection" runat="server" Text="PXProjection (Parallel)" CommandName="RunParallelProjection" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                    </div>

                    <div class="perf-progress-shell">
                        <div class="perf-progress-title">Progress</div>
                        <div class="perf-progress-bar"><span></span></div>
                        <div class="perf-progress-help">
                            Acumatica shows the standard long-operation progress while each benchmark runs. Use Abort Benchmark to stop a run early; the run budget stops it automatically.
                        </div>
                    </div>

                    <px:PXSmartPanel ID="ProgressPanel" runat="server" Caption="Benchmark Progress" CaptionVisible="True" LoadOnDemand="True" Width="700px" Height="200px">
                        <px:PXFormView ID="frmProgressInfo" runat="server" DataSourceID="ds" DataMember="Filter" Width="100%" RenderStyle="Simple" CaptionVisible="False">
                            <Template>
                                <px:PXLayoutRule runat="server" StartColumn="True" LabelsWidth="M" ControlSize="XXL" />
                                <px:PXLabel ID="lblProgressInfo" runat="server">PerfDBBenchmark uses Acumatica long operations and PXProcessing-based parallel execution. Keep this panel available if you want a dedicated progress explainer on the screen.</px:PXLabel>
                                <px:PXTextEdit ID="edProgressSnapshotStatus" runat="server" DataField="SnapshotStatus" />
                                <px:PXTextEdit ID="edProgressPendingAnalysisStatus" runat="server" DataField="PendingAnalysisStatus" />
                                <px:PXTextEdit ID="edProgressLastRequestStatus" runat="server" DataField="LastRequestStatus" />
                                <px:PXTextEdit ID="edProgressLastRequestedBenchmark" runat="server" DataField="LastRequestedBenchmark" />
                                <px:PXTextEdit ID="edProgressLastRequestMessage" runat="server" DataField="LastRequestMessage" />
                            </Template>
                        </px:PXFormView>
                    </px:PXSmartPanel>
                </Template>
            </px:PXTabItem>

            <px:PXTabItem Text="Benchmark Catalog">
                <Template>
                    <px:PXGrid ID="gridBenchmarkCatalog" runat="server" DataSourceID="ds" Width="100%" Height="360px" SkinID="DetailsInTab" SyncPosition="True">
                        <Levels>
                            <px:PXGridLevel DataMember="BenchmarkCatalog">
                                <Columns>
                                    <px:PXGridColumn DataField="SortOrder" Width="70" TextAlign="Right" />
                                    <px:PXGridColumn DataField="TestCode" Width="200" />
                                    <px:PXGridColumn DataField="DisplayName" Width="300" />
                                    <px:PXGridColumn DataField="Family" Width="110" />
                                    <px:PXGridColumn DataField="RunBlock" Width="60" />
                                    <px:PXGridColumn DataField="ShortLabel" Width="100" />
                                    <px:PXGridColumn DataField="UserCount" Width="60" TextAlign="Right" />
                                    <px:PXGridColumn DataField="ReaderUnit" Width="170" />
                                    <px:PXGridColumn DataField="HeadlineKind" Width="110" />
                                    <px:PXGridColumn DataField="HeadlineUnit" Width="80" />
                                    <px:PXGridColumn DataField="HigherIsBetter" Width="80" Type="CheckBox" TextAlign="Center" />
                                    <px:PXGridColumn DataField="OpsUnit" Width="90" />
                                    <px:PXGridColumn DataField="DefaultOpsPerPass" Width="90" TextAlign="Right" />
                                    <px:PXGridColumn DataField="DefaultPasses" Width="80" TextAlign="Right" />
                                    <px:PXGridColumn DataField="DefaultWarmUpPasses" Width="80" TextAlign="Right" />
                                    <px:PXGridColumn DataField="ParityExpected" Width="80" Type="CheckBox" TextAlign="Center" />
                                    <px:PXGridColumn DataField="IsDestructive" Width="90" Type="CheckBox" TextAlign="Center" />
                                    <px:PXGridColumn DataField="IsOptional" Width="70" Type="CheckBox" TextAlign="Center" />
                                    <px:PXGridColumn DataField="ExcludeFromComparison" Width="90" Type="CheckBox" TextAlign="Center" />
                                    <px:PXGridColumn DataField="LegacyTestCode" Width="120" />
                                    <px:PXGridColumn DataField="ScenarioVersion" Width="70" TextAlign="Right" />
                                    <px:PXGridColumn DataField="Question" Width="360" />
                                    <px:PXGridColumn DataField="WhatItSimulates" Width="420" />
                                    <px:PXGridColumn DataField="WhyItMatters" Width="420" />
                                    <px:PXGridColumn DataField="ActionName" Width="140" Visible="False" />
                                    <px:PXGridColumn DataField="Category" Width="100" />
                                    <px:PXGridColumn DataField="ExecutionMode" Width="100" />
                                    <px:PXGridColumn DataField="ShortDescription" Width="420" />
                                </Columns>
                            </px:PXGridLevel>
                        </Levels>
                        <AutoSize Container="Parent" Enabled="True" MinHeight="240" />
                        <Mode AllowAddNew="False" AllowDelete="False" AllowUpdate="False" />
                    </px:PXGrid>
                </Template>
            </px:PXTabItem>

            <px:PXTabItem Text="Local Results">
                <Template>
                    <px:PXGrid ID="gridLocalResults" runat="server" DataSourceID="ds" Width="100%" Height="420px" SkinID="DetailsInTab" SyncPosition="True">
                        <Levels>
                            <px:PXGridLevel DataMember="LocalResults">
                                <Columns>
                                    <px:PXGridColumn DataField="ResultID" Width="90" TextAlign="Right" />
                                    <px:PXGridColumn DataField="DisplayName" Width="250" />
                                    <px:PXGridColumn DataField="TestCode" Width="180" />
                                    <px:PXGridColumn DataField="Family" Width="110" />
                                    <px:PXGridColumn DataField="Status" Width="90" />
                                    <px:PXGridColumn DataField="InvalidReason" Width="180" />
                                    <px:PXGridColumn DataField="HeadlineValue" Width="110" TextAlign="Right" />
                                    <px:PXGridColumn DataField="HeadlineUnit" Width="80" />
                                    <px:PXGridColumn DataField="HigherIsBetter" Width="80" Type="CheckBox" TextAlign="Center" Visible="False" />
                                    <px:PXGridColumn DataField="UserCount" Width="60" TextAlign="Right" />
                                    <px:PXGridColumn DataField="ElapsedMsPrecise" Width="120" TextAlign="Right" />
                                    <px:PXGridColumn DataField="OpsCount" Width="90" TextAlign="Right" />
                                    <px:PXGridColumn DataField="OpsPerSec" Width="100" TextAlign="Right" />
                                    <px:PXGridColumn DataField="P50Ms" Width="90" TextAlign="Right" />
                                    <px:PXGridColumn DataField="P95Ms" Width="90" TextAlign="Right" />
                                    <px:PXGridColumn DataField="P99Ms" Width="90" TextAlign="Right" Visible="False" />
                                    <px:PXGridColumn DataField="MaxOpMs" Width="100" TextAlign="Right" Visible="False" />
                                    <px:PXGridColumn DataField="ErrorCount" Width="70" TextAlign="Right" />
                                    <px:PXGridColumn DataField="DeadlockCount" Width="80" TextAlign="Right" Visible="False" />
                                    <px:PXGridColumn DataField="RetryCount" Width="70" TextAlign="Right" Visible="False" />
                                    <px:PXGridColumn DataField="LockViolationCount" Width="90" TextAlign="Right" Visible="False" />
                                    <px:PXGridColumn DataField="TimeoutCount" Width="80" TextAlign="Right" Visible="False" />
                                    <px:PXGridColumn DataField="WorkersObservedPeak" Width="90" TextAlign="Right" Visible="False" />
                                    <px:PXGridColumn DataField="RowsReturned" Width="100" TextAlign="Right" Visible="False" />
                                    <px:PXGridColumn DataField="Checksum" Width="200" Visible="False" />
                                    <px:PXGridColumn DataField="CampaignID" Width="220" Visible="False" />
                                    <px:PXGridColumn DataField="RepetitionNo" Width="80" TextAlign="Right" />
                                    <px:PXGridColumn DataField="IsWarmup" Width="80" Type="CheckBox" TextAlign="Center" />
                                    <px:PXGridColumn DataField="RunBlock" Width="60" Visible="False" />
                                    <px:PXGridColumn DataField="OrderPosition" Width="70" TextAlign="Right" Visible="False" />
                                    <px:PXGridColumn DataField="MethodologyVersion" Width="100" Visible="False" />
                                    <px:PXGridColumn DataField="ParamsHash" Width="140" Visible="False" />
                                    <px:PXGridColumn DataField="DllSha256" Width="200" Visible="False" />
                                    <px:PXGridColumn DataField="AppDomainStartUtc" Width="200" Visible="False" />
                                    <px:PXGridColumn DataField="ResultJson" Width="300" Visible="False" />
                                    <px:PXGridColumn DataField="RunID" Width="220" />
                                    <px:PXGridColumn DataField="RequestedAtUtc" Width="150" />
                                    <px:PXGridColumn DataField="CapturedAtUtc" Width="150" />
                                    <px:PXGridColumn DataField="ElapsedMs" Width="110" TextAlign="Right" />
                                    <px:PXGridColumn DataField="RecordsCount" Width="100" TextAlign="Right" />
                                    <px:PXGridColumn DataField="Iterations" Width="90" TextAlign="Right" />
                                    <px:PXGridColumn DataField="BatchSize" Width="100" TextAlign="Right" />
                                    <px:PXGridColumn DataField="MaxThreads" Width="100" TextAlign="Right" />
                                    <px:PXGridColumn DataField="Notes" Width="320" />
                                </Columns>
                            </px:PXGridLevel>
                        </Levels>
                        <AutoSize Container="Parent" Enabled="True" MinHeight="260" />
                        <Mode AllowAddNew="False" AllowDelete="False" AllowUpdate="False" />
                    </px:PXGrid>
                </Template>
            </px:PXTabItem>

            <px:PXTabItem Text="Results Grid">
                <Template>
                    <px:PXGrid ID="gridResults" runat="server" DataSourceID="ds" Width="100%" Height="560px" SkinID="DetailsInTab" SyncPosition="True" OnRowDataBound="ComparisonGrid_RowDataBound">
                        <Levels>
                            <px:PXGridLevel DataMember="ComparisonResults">
                                <Columns>
                                    <px:PXGridColumn DataField="TestDisplayName" Width="250" />
                                    <px:PXGridColumn DataField="Family" Width="110" />
                                    <px:PXGridColumn DataField="ShortLabel" Width="100" Visible="False" />
                                    <px:PXGridColumn DataField="SortOrder" Width="70" TextAlign="Right" Visible="False" />
                                    <px:PXGridColumn DataField="UserCount" Width="60" TextAlign="Right" />
                                    <px:PXGridColumn DataField="TestCategory" Width="110" />
                                    <px:PXGridColumn DataField="ExecutionMode" Width="100" />
                                    <px:PXGridColumn DataField="DatabaseType" Width="140" />
                                    <px:PXGridColumn DataField="InstanceName" Width="110" />
                                    <px:PXGridColumn DataField="HeadlineValue" Width="110" TextAlign="Right" />
                                    <px:PXGridColumn DataField="HeadlineUnit" Width="80" />
                                    <px:PXGridColumn DataField="HigherIsBetter" Width="80" Type="CheckBox" TextAlign="Center" Visible="False" />
                                    <px:PXGridColumn DataField="RelToFastest" Width="90" TextAlign="Right" />
                                    <px:PXGridColumn DataField="Verdict" Width="200" />
                                    <px:PXGridColumn DataField="IsComparable" Width="90" Type="CheckBox" TextAlign="Center" />
                                    <px:PXGridColumn DataField="P95Ms" Width="90" TextAlign="Right" />
                                    <px:PXGridColumn DataField="OpsPerSec" Width="100" TextAlign="Right" />
                                    <px:PXGridColumn DataField="ErrorCount" Width="70" TextAlign="Right" />
                                    <px:PXGridColumn DataField="Status" Width="90" />
                                    <px:PXGridColumn DataField="ParamsHash" Width="140" Visible="False" />
                                    <px:PXGridColumn DataField="ElapsedMs" Width="110" TextAlign="Right" />
                                    <px:PXGridColumn DataField="RecordsCount" Width="100" TextAlign="Right" />
                                    <px:PXGridColumn DataField="Iterations" Width="90" TextAlign="Right" />
                                    <px:PXGridColumn DataField="BatchSize" Width="100" TextAlign="Right" />
                                    <px:PXGridColumn DataField="MaxThreads" Width="100" TextAlign="Right" />
                                    <px:PXGridColumn DataField="WinnerDisplay" Width="210" />
                                    <px:PXGridColumn DataField="CapturedAtUtc" Width="150" />
                                    <px:PXGridColumn DataField="Notes" Width="320" />
                                </Columns>
                            </px:PXGridLevel>
                        </Levels>
                        <AutoSize Container="Window" Enabled="True" MinHeight="320" />
                        <Mode AllowAddNew="False" AllowDelete="False" AllowUpdate="False" />
                    </px:PXGrid>
                </Template>
            </px:PXTabItem>

            <px:PXTabItem Text="Visualization">
                <Template>
                    <div class="perf-instructions">
                        <p>One chart per family, in catalog order. The in-app comparison is <span class="perf-highlight">indicative</span>: it appears only when all instances ran the test with the same parameters and DLL. Published verdicts use six repetitions and the tie rule (report generator).</p>
                    </div>

                    <div class="perf-visual-section">
                        <div class="perf-progress-title">All Tests</div>
                        <px:PXSerialChart ID="OverviewChart" runat="server" Width="100%" SkinID="Chart1" Height="280px" LegendEnabled="True" OnLoad="OverviewChart_OnLoad">
                            <DataFields Category="Category" Value="Values" Description="Labels"></DataFields>
                            <CategoryAxis ShowFirstLabel="True" ShowLastLabel="True" LabelRotation="25" StartOnAxis="True"></CategoryAxis>
                        </px:PXSerialChart>
                    </div>

                    <div class="perf-visual-section">
                        <div class="perf-progress-title">Everyday screens</div>
                        <px:PXSerialChart ID="chartFamilyScreens" runat="server" Width="100%" SkinID="Chart1" Height="240px" LegendEnabled="True" OnLoad="FamilyChart_OnLoad">
                            <DataFields Category="Category" Value="Values" Description="Labels"></DataFields>
                            <CategoryAxis ShowFirstLabel="True" ShowLastLabel="True" LabelRotation="20" StartOnAxis="True"></CategoryAxis>
                        </px:PXSerialChart>
                    </div>

                    <div class="perf-visual-section">
                        <div class="perf-progress-title">Reports &amp; month-end</div>
                        <px:PXSerialChart ID="chartFamilyReports" runat="server" Width="100%" SkinID="Chart1" Height="240px" LegendEnabled="True" OnLoad="FamilyChart_OnLoad">
                            <DataFields Category="Category" Value="Values" Description="Labels"></DataFields>
                            <CategoryAxis ShowFirstLabel="True" ShowLastLabel="True" LabelRotation="20" StartOnAxis="True"></CategoryAxis>
                        </px:PXSerialChart>
                    </div>

                    <div class="perf-visual-section">
                        <div class="perf-progress-title">Order entry (1 clerk)</div>
                        <px:PXSerialChart ID="chartFamilyOrderEntry" runat="server" Width="100%" SkinID="Chart1" Height="200px" LegendEnabled="True" OnLoad="FamilyChart_OnLoad">
                            <DataFields Category="Category" Value="Values" Description="Labels"></DataFields>
                            <CategoryAxis ShowFirstLabel="True" ShowLastLabel="True" LabelRotation="20" StartOnAxis="True"></CategoryAxis>
                        </px:PXSerialChart>
                    </div>

                    <div class="perf-visual-section">
                        <div class="perf-progress-title">Many simultaneous users</div>
                        <px:PXSerialChart ID="chartFamilyManyUsers" runat="server" Width="100%" SkinID="Chart1" Height="240px" LegendEnabled="True" OnLoad="FamilyChart_OnLoad">
                            <DataFields Category="Category" Value="Values" Description="Labels"></DataFields>
                            <CategoryAxis ShowFirstLabel="True" ShowLastLabel="True" LabelRotation="20" StartOnAxis="True"></CategoryAxis>
                        </px:PXSerialChart>
                    </div>

                    <div class="perf-visual-section">
                        <div class="perf-progress-title">Invoice release to GL</div>
                        <px:PXSerialChart ID="chartFamilyInvoiceRelease" runat="server" Width="100%" SkinID="Chart1" Height="200px" LegendEnabled="True" OnLoad="FamilyChart_OnLoad">
                            <DataFields Category="Category" Value="Values" Description="Labels"></DataFields>
                            <CategoryAxis ShowFirstLabel="True" ShowLastLabel="True" LabelRotation="20" StartOnAxis="True"></CategoryAxis>
                        </px:PXSerialChart>
                    </div>

                    <div class="perf-visual-section">
                        <div class="perf-progress-title">Platform basics: bulk record work</div>
                        <px:PXSerialChart ID="chartFamilyCore" runat="server" Width="100%" SkinID="Chart1" Height="260px" LegendEnabled="True" OnLoad="FamilyChart_OnLoad">
                            <DataFields Category="Category" Value="Values" Description="Labels"></DataFields>
                            <CategoryAxis ShowFirstLabel="True" ShowLastLabel="True" LabelRotation="20" StartOnAxis="True"></CategoryAxis>
                        </px:PXSerialChart>
                    </div>

                    <div class="perf-visual-section">
                        <div class="perf-progress-title">All Test Outputs</div>
                        <px:PXGrid ID="gridVisualizationResults" runat="server" DataSourceID="ds" Width="100%" Height="260px" SkinID="DetailsInTab" SyncPosition="True" OnRowDataBound="ComparisonGrid_RowDataBound">
                            <Levels>
                                <px:PXGridLevel DataMember="ComparisonResults">
                                    <Columns>
                                        <px:PXGridColumn DataField="TestDisplayName" Width="250" />
                                        <px:PXGridColumn DataField="Family" Width="110" />
                                        <px:PXGridColumn DataField="DatabaseType" Width="140" />
                                        <px:PXGridColumn DataField="InstanceName" Width="110" />
                                        <px:PXGridColumn DataField="HeadlineValue" Width="110" TextAlign="Right" />
                                        <px:PXGridColumn DataField="HeadlineUnit" Width="80" />
                                        <px:PXGridColumn DataField="RelToFastest" Width="90" TextAlign="Right" />
                                        <px:PXGridColumn DataField="Verdict" Width="200" />
                                        <px:PXGridColumn DataField="Status" Width="90" />
                                        <px:PXGridColumn DataField="CapturedAtUtc" Width="150" />
                                    </Columns>
                                </px:PXGridLevel>
                            </Levels>
                            <AutoSize Container="Parent" Enabled="True" MinHeight="220" />
                            <Mode AllowAddNew="False" AllowDelete="False" AllowUpdate="False" />
                        </px:PXGrid>
                    </div>
                </Template>
            </px:PXTabItem>
        </Items>
        <AutoSize Container="Window" Enabled="True" MinHeight="520" />
    </px:PXTab>
</asp:Content>
