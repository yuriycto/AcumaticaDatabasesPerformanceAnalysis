<%@ Page Language="C#" MasterPageFile="~/MasterPages/ListView.master" AutoEventWireup="true" ValidateRequest="false"
    Inherits="PX.Web.UI.PXPage" Title="Perf DB Benchmark Results" %>
<%@ MasterType VirtualPath="~/MasterPages/ListView.master" %>

<asp:Content ID="cont1" ContentPlaceHolderID="phDS" runat="server">
    <px:PXDataSource ID="ds" runat="server" Visible="True" Width="100%"
        TypeName="PerfDBBenchmark.Core.Graphs.PerfDBBenchmarkResultsGraph"
        PrimaryView="Results" />
</asp:Content>

<asp:Content ID="cont2" ContentPlaceHolderID="phL" runat="server">
    <px:PXGrid ID="gridResults" runat="server" DataSourceID="ds" Width="100%" Height="600px" SkinID="PrimaryInquire">
        <Levels>
            <px:PXGridLevel DataMember="Results">
                <Columns>
                    <px:PXGridColumn DataField="ResultID" Width="90px" />
                    <px:PXGridColumn DataField="InstanceName" Width="140px" />
                    <px:PXGridColumn DataField="DatabaseType" Width="150px" />
                    <px:PXGridColumn DataField="TestCode" Width="110px" />
                    <px:PXGridColumn DataField="DisplayName" Width="220px" />
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
