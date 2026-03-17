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
            background: linear-gradient(90deg, #0ea5e9 0%, #22c55e 100%);
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
        <p class="perf-note">The most important outcome is the Complex BQL Join and PXProjection comparison across PostgreSQL, MySQL 8.0, and Microsoft SQL Server.</p>
    </div>

    <px:PXFormView ID="frmEnvironment" runat="server" DataSourceID="ds" DataMember="Filter" Width="100%" Caption="Current Environment">
        <Template>
            <px:PXLayoutRule runat="server" StartColumn="True" LabelsWidth="M" ControlSize="XM" />
            <px:PXTextEdit ID="edSetupID" runat="server" DataField="SetupID" />
            <px:PXTextEdit ID="edCurrentDatabase" runat="server" DataField="CurrentDatabase" />
            <px:PXTextEdit ID="edCurrentInstance" runat="server" DataField="CurrentInstance" />
            <px:PXNumberEdit ID="edDetectedCpuCores" runat="server" DataField="DetectedCpuCores" />
            <px:PXNumberEdit ID="edDetectedMemoryGb" runat="server" DataField="DetectedMemoryGb" />
            <px:PXLayoutRule runat="server" StartColumn="True" LabelsWidth="M" ControlSize="XXL" />
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
                        <p>1. Publish the same DLL-based customization to all three instances: <span class="perf-highlight">PerfPG</span>, <span class="perf-highlight">PerfMySQL</span>, and <span class="perf-highlight">PerfSQL</span>.</p>
                        <p>2. Open screen <span class="perf-highlight">AC301000</span> on each instance and apply the recommended settings that were calculated from the detected hardware.</p>
                        <p>3. Run the same test buttons on all three instances. As snapshots become available, the Results and Visualization tabs will highlight the fastest database in green.</p>

                        <h3>Parallel Processing Requirement</h3>
                        <p>Parallel benchmarks use Acumatica's processing infrastructure and require the instance <code>Web.config</code> to enable parallel processing.</p>
                        <pre>&lt;add key="EnableAutoNumberingInSeparateConnection" value="true"/&gt;
&lt;add key="ParallelProcessingDisabled" value="false"/&gt;
&lt;add key="ParallelProcessingMaxThreads" value="6"/&gt;
&lt;add key="ParallelProcessingBatchSize" value="10"/&gt;
&lt;add key="IsParallelProcessingSkipBatchExceptions" value="True" /&gt;</pre>

                        <h3>What Matters Most</h3>
                        <p>The <span class="perf-highlight">Complex BQL Join</span> and <span class="perf-highlight">PXProjection</span> benchmarks simulate realistic Acumatica analytical workloads with multi-table inventory and warehouse joins. These results are the most useful indicator for business reporting and inquiry performance.</p>

                        <h3>Delete Workload Coverage</h3>
                        <p>This customization also measures sequential and parallel delete behavior so you can evaluate cleanup-heavy scenarios, not only inserts and reads.</p>

                                <h3>Publisher</h3>
                                <p>This benchmark package was produced by AcuPower LTD for GitHub publishing and performance-analysis reporting. Company website: <a href="https://acupowererp.com" target="_blank">acupowererp.com</a>.</p>
                    </div>
                </Template>
            </px:PXTabItem>

            <px:PXTabItem Text="Test Parameters">
                <Template>
                    <px:PXFormView ID="frmParameters" runat="server" DataSourceID="ds" DataMember="Filter" Width="100%" Caption="Benchmark Parameters">
                        <Template>
                            <px:PXLayoutRule runat="server" StartColumn="True" GroupCaption="Active Parameters" LabelsWidth="M" ControlSize="M" />
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
                    <div class="perf-button-grid">
                        <div class="perf-button-cell"><px:PXButton ID="btnSeqRead" runat="server" Text="Sequential Read" CommandName="RunSequentialRead" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnSeqWrite" runat="server" Text="Sequential Write" CommandName="RunSequentialWrite" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnSeqDelete" runat="server" Text="Sequential Delete" CommandName="RunSequentialDelete" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnSeqComplex" runat="server" Text="Complex Join (Sequential)" CommandName="RunSequentialComplexJoin" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnSeqProjection" runat="server" Text="PXProjection (Sequential)" CommandName="RunSequentialProjection" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnParRead" runat="server" Text="Parallel Read" CommandName="RunParallelRead" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnParWrite" runat="server" Text="Parallel Write" CommandName="RunParallelWrite" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnParDelete" runat="server" Text="Parallel Delete" CommandName="RunParallelDelete" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnParComplex" runat="server" Text="Complex Join (Parallel)" CommandName="RunParallelComplexJoin" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnParProjection" runat="server" Text="PXProjection (Parallel)" CommandName="RunParallelProjection" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnRefreshStatus" runat="server" Text="Refresh Status" CommandName="RefreshStatus" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnExportExcel" runat="server" Text="Export to Excel" CommandName="ExportToExcel" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                        <div class="perf-button-cell"><px:PXButton ID="btnClearData" runat="server" Text="Clear Test Data" CommandName="ClearTestData" CommandSourceID="ds" Width="100%" Height="40px" /></div>
                    </div>

                    <div class="perf-progress-shell">
                        <div class="perf-progress-title">Progress</div>
                        <div class="perf-progress-bar"><span></span></div>
                        <div class="perf-progress-help">
                            Acumatica will show the standard long-operation progress while each benchmark runs. The moving bar above is a visual cue for business users and the hidden PXSmartPanel below is reserved for progress-related messaging.
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
                                    <px:PXGridColumn DataField="TestCode" Width="130" />
                                    <px:PXGridColumn DataField="DisplayName" Width="250" />
                                    <px:PXGridColumn DataField="ActionName" Width="180" />
                                    <px:PXGridColumn DataField="Category" Width="150" />
                                    <px:PXGridColumn DataField="ExecutionMode" Width="110" />
                                    <px:PXGridColumn DataField="ShortDescription" Width="420" />
                                    <px:PXGridColumn DataField="SortOrder" Width="90" TextAlign="Right" />
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
                                    <px:PXGridColumn DataField="TestCode" Width="130" />
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
                                    <px:PXGridColumn DataField="TestCategory" Width="150" />
                                    <px:PXGridColumn DataField="ExecutionMode" Width="110" />
                                    <px:PXGridColumn DataField="DatabaseType" Width="170" />
                                    <px:PXGridColumn DataField="InstanceName" Width="120" />
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
                        <p><span class="perf-highlight">Green winner rows</span> indicate the fastest currently available database result for a benchmark. Run the same tests on all three sibling instances to complete the comparison set.</p>
                    </div>

                    <div class="perf-visual-section">
                        <div class="perf-progress-title">All Benchmarks</div>
                        <px:PXSerialChart ID="OverviewChart" runat="server" Width="100%" SkinID="Chart1" Height="280px" LegendEnabled="True" OnLoad="OverviewChart_OnLoad">
                            <DataFields Category="Category" Value="Values" Description="Labels"></DataFields>
                            <CategoryAxis ShowFirstLabel="True" ShowLastLabel="True" LabelRotation="25" StartOnAxis="True"></CategoryAxis>
                        </px:PXSerialChart>
                    </div>

                    <div class="perf-visual-section">
                        <div class="perf-progress-title">Analytical Workloads</div>
                        <px:PXSerialChart ID="ComplexChart" runat="server" Width="100%" SkinID="Chart1" Height="260px" LegendEnabled="True" OnLoad="ComplexChart_OnLoad">
                            <DataFields Category="Category" Value="Values" Description="Labels"></DataFields>
                            <CategoryAxis ShowFirstLabel="True" ShowLastLabel="True" LabelRotation="20" StartOnAxis="True"></CategoryAxis>
                        </px:PXSerialChart>
                    </div>

                    <div class="perf-visual-section">
                        <div class="perf-progress-title">Read / Write / Delete</div>
                        <px:PXSerialChart ID="DmlChart" runat="server" Width="100%" SkinID="Chart1" Height="260px" LegendEnabled="True" OnLoad="DmlChart_OnLoad">
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
                                        <px:PXGridColumn DataField="ExecutionMode" Width="110" />
                                        <px:PXGridColumn DataField="DatabaseType" Width="170" />
                                        <px:PXGridColumn DataField="InstanceName" Width="120" />
                                        <px:PXGridColumn DataField="ElapsedMs" Width="110" TextAlign="Right" />
                                        <px:PXGridColumn DataField="WinnerDisplay" Width="210" />
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
