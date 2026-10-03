<%@ Page Language="C#" MasterPageFile="~/MasterPages/ListView.master" AutoEventWireup="true" ValidateRequest="false"
    Inherits="PX.Web.UI.PXPage" Title="Perf DB Benchmark Results" %>
<%@ MasterType VirtualPath="~/MasterPages/ListView.master" %>

<asp:Content ID="cont1" ContentPlaceHolderID="phDS" runat="server">
    <px:PXDataSource ID="ds" runat="server" Visible="True" Width="100%"
        TypeName="PerfDBBenchmark.Core.Graphs.PerfDBBenchmarkResultsGraph"
        PrimaryView="Results" />
</asp:Content>

<asp:Content ID="cont2" ContentPlaceHolderID="phL" runat="server">
    <%-- Every column mapped on the BenchmarkResult endpoint entity is on this grid (SPEC section 3.6); technical columns are hidden. --%>
    <px:PXGrid ID="gridResults" runat="server" DataSourceID="ds" Width="100%" Height="600px" SkinID="PrimaryInquire">
        <Levels>
            <px:PXGridLevel DataMember="Results">
                <Columns>
                    <px:PXGridColumn DataField="ResultID" Width="90px" />
                    <px:PXGridColumn DataField="InstanceName" Width="140px" />
                    <px:PXGridColumn DataField="DatabaseType" Width="150px" />
                    <px:PXGridColumn DataField="TestCode" Width="190px" />
                    <px:PXGridColumn DataField="DisplayName" Width="260px" />
                    <px:PXGridColumn DataField="Family" Width="110px" />
                    <px:PXGridColumn DataField="TestCategory" Width="100px" />
                    <px:PXGridColumn DataField="ExecutionMode" Width="100px" />
                    <px:PXGridColumn DataField="Status" Width="90px" />
                    <px:PXGridColumn DataField="InvalidReason" Width="200px" />
                    <px:PXGridColumn DataField="CampaignID" Width="220px" />
                    <px:PXGridColumn DataField="RunBlock" Width="60px" />
                    <px:PXGridColumn DataField="RepetitionNo" Width="80px" />
                    <px:PXGridColumn DataField="OrderPosition" Width="70px" />
                    <px:PXGridColumn DataField="IsWarmup" Width="80px" Type="CheckBox" TextAlign="Center" />
                    <px:PXGridColumn DataField="UserCount" Width="60px" />
                    <px:PXGridColumn DataField="HeadlineValue" Width="110px" TextAlign="Right" />
                    <px:PXGridColumn DataField="HeadlineUnit" Width="80px" />
                    <px:PXGridColumn DataField="HigherIsBetter" Width="80px" Type="CheckBox" TextAlign="Center" />
                    <px:PXGridColumn DataField="ElapsedMsPrecise" Width="120px" TextAlign="Right" />
                    <px:PXGridColumn DataField="OpsCount" Width="90px" TextAlign="Right" />
                    <px:PXGridColumn DataField="OpsPerSec" Width="100px" TextAlign="Right" />
                    <px:PXGridColumn DataField="P50Ms" Width="90px" TextAlign="Right" />
                    <px:PXGridColumn DataField="P95Ms" Width="90px" TextAlign="Right" />
                    <px:PXGridColumn DataField="P99Ms" Width="90px" TextAlign="Right" />
                    <px:PXGridColumn DataField="MaxOpMs" Width="100px" TextAlign="Right" />
                    <px:PXGridColumn DataField="RowsReturned" Width="100px" TextAlign="Right" />
                    <px:PXGridColumn DataField="Checksum" Width="200px" />
                    <px:PXGridColumn DataField="ErrorCount" Width="70px" TextAlign="Right" />
                    <px:PXGridColumn DataField="DeadlockCount" Width="80px" TextAlign="Right" />
                    <px:PXGridColumn DataField="RetryCount" Width="70px" TextAlign="Right" />
                    <px:PXGridColumn DataField="LockViolationCount" Width="90px" TextAlign="Right" />
                    <px:PXGridColumn DataField="TimeoutCount" Width="80px" TextAlign="Right" />
                    <px:PXGridColumn DataField="WorkersObservedPeak" Width="90px" TextAlign="Right" />
                    <px:PXGridColumn DataField="MethodologyVersion" Width="100px" />
                    <px:PXGridColumn DataField="ParamsHash" Width="140px" Visible="False" />
                    <px:PXGridColumn DataField="DllSha256" Width="200px" Visible="False" />
                    <px:PXGridColumn DataField="AppDomainStartUtc" Width="200px" Visible="False" />
                    <px:PXGridColumn DataField="ResultJson" Width="300px" Visible="False" />
                    <px:PXGridColumn DataField="RunID" Width="220px" />
                    <px:PXGridColumn DataField="RequestedAtUtc" Width="160px" />
                    <px:PXGridColumn DataField="CapturedAtUtc" Width="160px" />
                    <px:PXGridColumn DataField="ElapsedMs" Width="100px" />
                    <px:PXGridColumn DataField="RecordsCount" Width="110px" />
                    <px:PXGridColumn DataField="Iterations" Width="90px" />
                    <px:PXGridColumn DataField="BatchSize" Width="90px" />
                    <px:PXGridColumn DataField="MaxThreads" Width="90px" />
                    <px:PXGridColumn DataField="Notes" Width="320px" />
                </Columns>
            </px:PXGridLevel>
        </Levels>
    </px:PXGrid>
</asp:Content>
