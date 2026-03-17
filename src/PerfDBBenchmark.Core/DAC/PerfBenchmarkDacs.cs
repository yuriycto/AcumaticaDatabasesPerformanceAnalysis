using System;
using PX.Data;
using PX.Data.BQL;
using PX.Data.BQL.Fluent;
using PX.Objects.GL;
using PX.Objects.IN;

using GLBranch = PX.Objects.GL.Branch;

namespace PerfDBBenchmark.Core.DAC;

[Serializable]
[PXCacheName("PerfDB Benchmark Control")]
public sealed class PerfBenchmarkFilter : PXBqlTable, IBqlTable
{
    public abstract class setupID : BqlInt.Field<setupID> { }
    [PXDBInt(IsKey = true)]
    [PXDefault(1)]
    [PXUIField(DisplayName = "Setup ID", Visible = false, Enabled = false)]
    public int? SetupID { get; set; }

    public abstract class numberOfRecords : BqlInt.Field<numberOfRecords> { }
    [PXDBInt]
    [PXDefault(5000)]
    [PXUIField(DisplayName = "Number of Records")]
    public int? NumberOfRecords { get; set; }

    public abstract class iterations : BqlInt.Field<iterations> { }
    [PXDBInt]
    [PXDefault(3)]
    [PXUIField(DisplayName = "Iterations")]
    public int? Iterations { get; set; }

    public abstract class parallelBatchSize : BqlInt.Field<parallelBatchSize> { }
    [PXDBInt]
    [PXDefault(100)]
    [PXUIField(DisplayName = "Parallel Batch Size")]
    public int? ParallelBatchSize { get; set; }

    public abstract class parallelMaxThreads : BqlInt.Field<parallelMaxThreads> { }
    [PXDBInt]
    [PXDefault(4)]
    [PXUIField(DisplayName = "Parallel Max Threads")]
    public int? ParallelMaxThreads { get; set; }

    public abstract class currentDatabase : BqlString.Field<currentDatabase> { }
    [PXDBString(60, IsUnicode = true)]
    [PXUIField(DisplayName = "Current Database", Enabled = false)]
    public string CurrentDatabase { get; set; }

    public abstract class currentInstance : BqlString.Field<currentInstance> { }
    [PXDBString(60, IsUnicode = true)]
    [PXUIField(DisplayName = "Current Instance", Enabled = false)]
    public string CurrentInstance { get; set; }

    public abstract class detectedCpuCores : BqlInt.Field<detectedCpuCores> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Detected CPU Cores", Enabled = false)]
    public int? DetectedCpuCores { get; set; }

    public abstract class detectedMemoryGb : BqlDecimal.Field<detectedMemoryGb> { }
    [PXDBDecimal]
    [PXUIField(DisplayName = "Detected Memory (GB)", Enabled = false)]
    public decimal? DetectedMemoryGb { get; set; }

    public abstract class recommendedRecords : BqlInt.Field<recommendedRecords> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Recommended Records", Enabled = false)]
    public int? RecommendedRecords { get; set; }

    public abstract class recommendedIterations : BqlInt.Field<recommendedIterations> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Recommended Iterations", Enabled = false)]
    public int? RecommendedIterations { get; set; }

    public abstract class recommendedBatchSize : BqlInt.Field<recommendedBatchSize> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Recommended Batch Size", Enabled = false)]
    public int? RecommendedBatchSize { get; set; }

    public abstract class recommendedMaxThreads : BqlInt.Field<recommendedMaxThreads> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Recommended Max Threads", Enabled = false)]
    public int? RecommendedMaxThreads { get; set; }

    public abstract class hardwareRecommendationSummary : BqlString.Field<hardwareRecommendationSummary> { }
    [PXDBString(512, IsUnicode = true)]
    [PXUIField(DisplayName = "Recommended Settings Summary", Enabled = false)]
    public string HardwareRecommendationSummary { get; set; }

    public abstract class snapshotStatus : BqlString.Field<snapshotStatus> { }
    [PXDBString(512, IsUnicode = true)]
    [PXUIField(DisplayName = "Comparison Snapshot Status", Enabled = false)]
    public string SnapshotStatus { get; set; }

    public abstract class pendingAnalysisStatus : BqlString.Field<pendingAnalysisStatus> { }
    [PXDBString(2048, IsUnicode = true)]
    [PXUIField(DisplayName = "Pending Analysis Status", Enabled = false)]
    public string PendingAnalysisStatus { get; set; }

    public abstract class lastRequestID : BqlGuid.Field<lastRequestID> { }
    [PXDBGuid]
    [PXUIField(DisplayName = "Last Request ID", Enabled = false)]
    public Guid? LastRequestID { get; set; }

    public abstract class lastRequestedTestCode : BqlString.Field<lastRequestedTestCode> { }
    [PXDBString(64, IsUnicode = true)]
    [PXUIField(DisplayName = "Last Request Test Code", Enabled = false)]
    public string LastRequestedTestCode { get; set; }

    public abstract class lastRequestedBenchmark : BqlString.Field<lastRequestedBenchmark> { }
    [PXDBString(128, IsUnicode = true)]
    [PXUIField(DisplayName = "Last Requested Benchmark", Enabled = false)]
    public string LastRequestedBenchmark { get; set; }

    public abstract class lastRequestStatus : BqlString.Field<lastRequestStatus> { }
    [PXDBString(32, IsUnicode = true)]
    [PXUIField(DisplayName = "Last Request Status", Enabled = false)]
    public string LastRequestStatus { get; set; }

    public abstract class lastRequestStartedAtUtc : BqlDateTime.Field<lastRequestStartedAtUtc> { }
    [PXDBDateAndTime(UseTimeZone = false, PreserveTime = true)]
    [PXUIField(DisplayName = "Last Request Started At", Enabled = false)]
    public DateTime? LastRequestStartedAtUtc { get; set; }

    public abstract class lastRequestCompletedAtUtc : BqlDateTime.Field<lastRequestCompletedAtUtc> { }
    [PXDBDateAndTime(UseTimeZone = false, PreserveTime = true)]
    [PXUIField(DisplayName = "Last Request Completed At", Enabled = false)]
    public DateTime? LastRequestCompletedAtUtc { get; set; }

    public abstract class lastRequestElapsedMs : BqlInt.Field<lastRequestElapsedMs> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Last Request Elapsed (ms)", Enabled = false)]
    public int? LastRequestElapsedMs { get; set; }

    public abstract class lastRequestMessage : BqlString.Field<lastRequestMessage> { }
    [PXDBString(1024, IsUnicode = true)]
    [PXUIField(DisplayName = "Last Request Message", Enabled = false)]
    public string LastRequestMessage { get; set; }

    public abstract class noteID : BqlGuid.Field<noteID> { }
    [PXNote]
    public Guid? NoteID { get; set; }

    public abstract class tstamp : BqlByteArray.Field<tstamp> { }
    [PXDBTimestamp]
    public byte[] Tstamp { get; set; }

    public abstract class createdByID : BqlGuid.Field<createdByID> { }
    [PXDBCreatedByID]
    public Guid? CreatedByID { get; set; }

    public abstract class createdByScreenID : BqlString.Field<createdByScreenID> { }
    [PXDBCreatedByScreenID]
    public string CreatedByScreenID { get; set; }

    public abstract class createdDateTime : BqlDateTime.Field<createdDateTime> { }
    [PXDBCreatedDateTime]
    public DateTime? CreatedDateTime { get; set; }

    public abstract class lastModifiedByID : BqlGuid.Field<lastModifiedByID> { }
    [PXDBLastModifiedByID]
    public Guid? LastModifiedByID { get; set; }

    public abstract class lastModifiedByScreenID : BqlString.Field<lastModifiedByScreenID> { }
    [PXDBLastModifiedByScreenID]
    public string LastModifiedByScreenID { get; set; }

    public abstract class lastModifiedDateTime : BqlDateTime.Field<lastModifiedDateTime> { }
    [PXDBLastModifiedDateTime]
    public DateTime? LastModifiedDateTime { get; set; }
}

[Serializable]
[PXCacheName("Perf Test Record")]
public sealed class PerfTestRecord : PXBqlTable, IBqlTable
{
    public abstract class recordID : BqlInt.Field<recordID> { }
    [PXDBIdentity(IsKey = true)]
    [PXUIField(DisplayName = "Record ID", Enabled = false)]
    public int? RecordID { get; set; }

    public abstract class batchID : BqlString.Field<batchID> { }
    [PXDBString(64, IsUnicode = true)]
    [PXUIField(DisplayName = "Batch ID")]
    public string BatchID { get; set; }

    public abstract class operationType : BqlString.Field<operationType> { }
    [PXDBString(32, IsUnicode = true)]
    [PXUIField(DisplayName = "Operation Type")]
    public string OperationType { get; set; }

    public abstract class iteration : BqlInt.Field<iteration> { }
    [PXDBInt]
    [PXDefault(0)]
    [PXUIField(DisplayName = "Iteration")]
    public int? Iteration { get; set; }

    public abstract class sequence : BqlInt.Field<sequence> { }
    [PXDBInt]
    [PXDefault(0)]
    [PXUIField(DisplayName = "Sequence")]
    public int? Sequence { get; set; }

    public abstract class payloadText : BqlString.Field<payloadText> { }
    [PXDBString(255, IsUnicode = true)]
    [PXUIField(DisplayName = "Payload Text")]
    public string PayloadText { get; set; }

    public abstract class payloadValue : BqlInt.Field<payloadValue> { }
    [PXDBInt]
    [PXDefault(0)]
    [PXUIField(DisplayName = "Payload Value")]
    public int? PayloadValue { get; set; }

    public abstract class noteID : BqlGuid.Field<noteID> { }
    [PXNote]
    public Guid? NoteID { get; set; }

    public abstract class tstamp : BqlByteArray.Field<tstamp> { }
    [PXDBTimestamp]
    public byte[] Tstamp { get; set; }

    public abstract class createdByID : BqlGuid.Field<createdByID> { }
    [PXDBCreatedByID]
    public Guid? CreatedByID { get; set; }

    public abstract class createdByScreenID : BqlString.Field<createdByScreenID> { }
    [PXDBCreatedByScreenID]
    public string CreatedByScreenID { get; set; }

    public abstract class createdDateTime : BqlDateTime.Field<createdDateTime> { }
    [PXDBCreatedDateTime]
    public DateTime? CreatedDateTime { get; set; }

    public abstract class lastModifiedByID : BqlGuid.Field<lastModifiedByID> { }
    [PXDBLastModifiedByID]
    public Guid? LastModifiedByID { get; set; }

    public abstract class lastModifiedByScreenID : BqlString.Field<lastModifiedByScreenID> { }
    [PXDBLastModifiedByScreenID]
    public string LastModifiedByScreenID { get; set; }

    public abstract class lastModifiedDateTime : BqlDateTime.Field<lastModifiedDateTime> { }
    [PXDBLastModifiedDateTime]
    public DateTime? LastModifiedDateTime { get; set; }
}

[Serializable]
[PXCacheName("Perf Test Result")]
public sealed class PerfTestResult : PXBqlTable, IBqlTable
{
    public abstract class resultID : BqlInt.Field<resultID> { }
    [PXDBIdentity(IsKey = true)]
    [PXUIField(DisplayName = "Result ID", Enabled = false)]
    public int? ResultID { get; set; }

    public abstract class instanceName : BqlString.Field<instanceName> { }
    [PXDBString(64, IsUnicode = true)]
    [PXUIField(DisplayName = "Instance")]
    public string InstanceName { get; set; }

    public abstract class databaseType : BqlString.Field<databaseType> { }
    [PXDBString(64, IsUnicode = true)]
    [PXUIField(DisplayName = "Database")]
    public string DatabaseType { get; set; }

    public abstract class testCode : BqlString.Field<testCode> { }
    [PXDBString(64, IsUnicode = true)]
    [PXUIField(DisplayName = "Test Code")]
    public string TestCode { get; set; }

    public abstract class testCategory : BqlString.Field<testCategory> { }
    [PXDBString(64, IsUnicode = true)]
    [PXUIField(DisplayName = "Category")]
    public string TestCategory { get; set; }

    public abstract class executionMode : BqlString.Field<executionMode> { }
    [PXDBString(24, IsUnicode = true)]
    [PXUIField(DisplayName = "Mode")]
    public string ExecutionMode { get; set; }

    public abstract class displayName : BqlString.Field<displayName> { }
    [PXDBString(128, IsUnicode = true)]
    [PXUIField(DisplayName = "Display Name")]
    public string DisplayName { get; set; }

    public abstract class runID : BqlGuid.Field<runID> { }
    [PXDBGuid]
    [PXUIField(DisplayName = "Run ID", Enabled = false)]
    public Guid? RunID { get; set; }

    public abstract class requestedAtUtc : BqlDateTime.Field<requestedAtUtc> { }
    [PXDBDateAndTime(UseTimeZone = false, PreserveTime = true)]
    [PXUIField(DisplayName = "Requested At")]
    public DateTime? RequestedAtUtc { get; set; }

    public abstract class recordsCount : BqlInt.Field<recordsCount> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Records")]
    public int? RecordsCount { get; set; }

    public abstract class iterations : BqlInt.Field<iterations> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Iterations")]
    public int? Iterations { get; set; }

    public abstract class batchSize : BqlInt.Field<batchSize> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Batch Size")]
    public int? BatchSize { get; set; }

    public abstract class maxThreads : BqlInt.Field<maxThreads> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Max Threads")]
    public int? MaxThreads { get; set; }

    public abstract class elapsedMs : BqlInt.Field<elapsedMs> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Elapsed (ms)")]
    public int? ElapsedMs { get; set; }

    public abstract class notes : BqlString.Field<notes> { }
    [PXDBString(1024, IsUnicode = true)]
    [PXUIField(DisplayName = "Notes")]
    public string Notes { get; set; }

    public abstract class capturedAtUtc : BqlDateTime.Field<capturedAtUtc> { }
    [PXDBDateAndTime(UseTimeZone = false, PreserveTime = true)]
    [PXDefault(typeof(AccessInfo.businessDate))]
    [PXUIField(DisplayName = "Captured At")]
    public DateTime? CapturedAtUtc { get; set; }

    public abstract class noteID : BqlGuid.Field<noteID> { }
    [PXNote]
    public Guid? NoteID { get; set; }

    public abstract class tstamp : BqlByteArray.Field<tstamp> { }
    [PXDBTimestamp]
    public byte[] Tstamp { get; set; }

    public abstract class createdByID : BqlGuid.Field<createdByID> { }
    [PXDBCreatedByID]
    public Guid? CreatedByID { get; set; }

    public abstract class createdByScreenID : BqlString.Field<createdByScreenID> { }
    [PXDBCreatedByScreenID]
    public string CreatedByScreenID { get; set; }

    public abstract class createdDateTime : BqlDateTime.Field<createdDateTime> { }
    [PXDBCreatedDateTime]
    public DateTime? CreatedDateTime { get; set; }

    public abstract class lastModifiedByID : BqlGuid.Field<lastModifiedByID> { }
    [PXDBLastModifiedByID]
    public Guid? LastModifiedByID { get; set; }

    public abstract class lastModifiedByScreenID : BqlString.Field<lastModifiedByScreenID> { }
    [PXDBLastModifiedByScreenID]
    public string LastModifiedByScreenID { get; set; }

    public abstract class lastModifiedDateTime : BqlDateTime.Field<lastModifiedDateTime> { }
    [PXDBLastModifiedDateTime]
    public DateTime? LastModifiedDateTime { get; set; }
}

[Serializable]
[PXCacheName("Perf Benchmark Definition")]
public sealed class PerfBenchmarkDefinition : PXBqlTable, IBqlTable
{
    public abstract class testCode : BqlString.Field<testCode> { }
    [PXString(64, IsUnicode = true, IsKey = true)]
    [PXUIField(DisplayName = "Test Code", Enabled = false)]
    public string TestCode { get; set; }

    public abstract class displayName : BqlString.Field<displayName> { }
    [PXString(128, IsUnicode = true)]
    [PXUIField(DisplayName = "Benchmark", Enabled = false)]
    public string DisplayName { get; set; }

    public abstract class actionName : BqlString.Field<actionName> { }
    [PXString(64, IsUnicode = true)]
    [PXUIField(DisplayName = "Action Name", Enabled = false)]
    public string ActionName { get; set; }

    public abstract class category : BqlString.Field<category> { }
    [PXString(64, IsUnicode = true)]
    [PXUIField(DisplayName = "Category", Enabled = false)]
    public string Category { get; set; }

    public abstract class executionMode : BqlString.Field<executionMode> { }
    [PXString(24, IsUnicode = true)]
    [PXUIField(DisplayName = "Mode", Enabled = false)]
    public string ExecutionMode { get; set; }

    public abstract class shortDescription : BqlString.Field<shortDescription> { }
    [PXString(512, IsUnicode = true)]
    [PXUIField(DisplayName = "Description", Enabled = false)]
    public string ShortDescription { get; set; }

    public abstract class sortOrder : BqlInt.Field<sortOrder> { }
    [PXInt]
    [PXUIField(DisplayName = "Sort Order", Enabled = false)]
    public int? SortOrder { get; set; }
}

[Serializable]
[PXHidden]
[PXCacheName("Perf Benchmark Projection")]
[PXProjection(typeof(
    SelectFrom<InventoryItem>
        .InnerJoin<INItemClass>.On<INItemClass.itemClassID.IsEqual<InventoryItem.itemClassID>>
        .LeftJoin<INSiteStatus>.On<INSiteStatus.inventoryID.IsEqual<InventoryItem.inventoryID>>
        .LeftJoin<INSite>.On<INSite.siteID.IsEqual<INSiteStatus.siteID>>
        .LeftJoin<GLBranch>.On<GLBranch.branchID.IsEqual<INSite.branchID>>
        .Where<InventoryItem.stkItem.IsEqual<True>>), Persistent = false)]
public sealed class PerfBenchmarkProjection : PXBqlTable, IBqlTable
{
    public abstract class inventoryID : BqlInt.Field<inventoryID> { }
    [PXDBInt(BqlField = typeof(InventoryItem.inventoryID), IsKey = true)]
    [PXUIField(DisplayName = "Inventory ID")]
    public int? InventoryID { get; set; }

    public abstract class siteID : BqlInt.Field<siteID> { }
    [PXDBInt(BqlField = typeof(INSite.siteID), IsKey = true)]
    [PXUIField(DisplayName = "Site ID")]
    public int? SiteID { get; set; }

    public abstract class inventoryCD : BqlString.Field<inventoryCD> { }
    [PXDBString(60, IsUnicode = true, BqlField = typeof(InventoryItem.inventoryCD))]
    [PXUIField(DisplayName = "Inventory CD")]
    public string InventoryCD { get; set; }

    public abstract class descr : BqlString.Field<descr> { }
    [PXDBString(255, IsUnicode = true, BqlField = typeof(InventoryItem.descr))]
    [PXUIField(DisplayName = "Description")]
    public string Descr { get; set; }

    public abstract class itemClassCD : BqlString.Field<itemClassCD> { }
    [PXDBString(60, IsUnicode = true, BqlField = typeof(INItemClass.itemClassCD))]
    [PXUIField(DisplayName = "Item Class")]
    public string ItemClassCD { get; set; }

    public abstract class baseUnit : BqlString.Field<baseUnit> { }
    [PXDBString(16, IsUnicode = true, BqlField = typeof(InventoryItem.baseUnit))]
    [PXUIField(DisplayName = "Base Unit")]
    public string BaseUnit { get; set; }

    public abstract class siteCD : BqlString.Field<siteCD> { }
    [PXDBString(30, IsUnicode = true, BqlField = typeof(INSite.siteCD))]
    [PXUIField(DisplayName = "Warehouse")]
    public string SiteCD { get; set; }

    public abstract class branchCD : BqlString.Field<branchCD> { }
    [PXDBString(30, IsUnicode = true, BqlField = typeof(GLBranch.branchCD))]
    [PXUIField(DisplayName = "Branch")]
    public string BranchCD { get; set; }

    public abstract class qtyOnHand : BqlDecimal.Field<qtyOnHand> { }
    [PXDBDecimal(BqlField = typeof(INSiteStatus.qtyOnHand))]
    [PXUIField(DisplayName = "Qty. On Hand")]
    public decimal? QtyOnHand { get; set; }

    public abstract class qtyAvail : BqlDecimal.Field<qtyAvail> { }
    [PXDBDecimal(BqlField = typeof(INSiteStatus.qtyAvail))]
    [PXUIField(DisplayName = "Qty. Available")]
    public decimal? QtyAvail { get; set; }
}

[Serializable]
[PXCacheName("Perf Comparison Result")]
public sealed class PerfComparisonResult : PXBqlTable, IBqlTable
{
    public abstract class lineNbr : BqlInt.Field<lineNbr> { }
    [PXInt(IsKey = true)]
    [PXUIField(DisplayName = "Line Nbr.", Enabled = false)]
    public int? LineNbr { get; set; }

    public abstract class testCode : BqlString.Field<testCode> { }
    [PXString(64, IsUnicode = true)]
    [PXUIField(DisplayName = "Test Code", Enabled = false)]
    public string TestCode { get; set; }

    public abstract class testDisplayName : BqlString.Field<testDisplayName> { }
    [PXString(128, IsUnicode = true)]
    [PXUIField(DisplayName = "Benchmark")]
    public string TestDisplayName { get; set; }

    public abstract class testCategory : BqlString.Field<testCategory> { }
    [PXString(64, IsUnicode = true)]
    [PXUIField(DisplayName = "Category")]
    public string TestCategory { get; set; }

    public abstract class executionMode : BqlString.Field<executionMode> { }
    [PXString(24, IsUnicode = true)]
    [PXUIField(DisplayName = "Mode")]
    public string ExecutionMode { get; set; }

    public abstract class databaseType : BqlString.Field<databaseType> { }
    [PXString(64, IsUnicode = true)]
    [PXUIField(DisplayName = "Database")]
    public string DatabaseType { get; set; }

    public abstract class instanceName : BqlString.Field<instanceName> { }
    [PXString(64, IsUnicode = true)]
    [PXUIField(DisplayName = "Instance")]
    public string InstanceName { get; set; }

    public abstract class elapsedMs : BqlInt.Field<elapsedMs> { }
    [PXInt]
    [PXUIField(DisplayName = "Elapsed (ms)")]
    public int? ElapsedMs { get; set; }

    public abstract class recordsCount : BqlInt.Field<recordsCount> { }
    [PXInt]
    [PXUIField(DisplayName = "Records")]
    public int? RecordsCount { get; set; }

    public abstract class iterations : BqlInt.Field<iterations> { }
    [PXInt]
    [PXUIField(DisplayName = "Iterations")]
    public int? Iterations { get; set; }

    public abstract class batchSize : BqlInt.Field<batchSize> { }
    [PXInt]
    [PXUIField(DisplayName = "Batch Size")]
    public int? BatchSize { get; set; }

    public abstract class maxThreads : BqlInt.Field<maxThreads> { }
    [PXInt]
    [PXUIField(DisplayName = "Max Threads")]
    public int? MaxThreads { get; set; }

    public abstract class capturedAtUtc : BqlDateTime.Field<capturedAtUtc> { }
    [PXDateAndTime]
    [PXUIField(DisplayName = "Captured At")]
    public DateTime? CapturedAtUtc { get; set; }

    public abstract class winnerDisplay : BqlString.Field<winnerDisplay> { }
    [PXString(64, IsUnicode = true)]
    [PXUIField(DisplayName = "Winner")]
    public string WinnerDisplay { get; set; }

    public abstract class isWinner : BqlBool.Field<isWinner> { }
    [PXBool]
    [PXUIField(DisplayName = "Winner?", Enabled = false)]
    public bool? IsWinner { get; set; }

    public abstract class notes : BqlString.Field<notes> { }
    [PXString(1024, IsUnicode = true)]
    [PXUIField(DisplayName = "Notes")]
    public string Notes { get; set; }
}
