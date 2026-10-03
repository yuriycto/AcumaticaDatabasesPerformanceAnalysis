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

    // ---- P0 additions (SPEC §3.1) ----

    public abstract class selectedTestCode : BqlString.Field<selectedTestCode> { }
    [PXDBString(64, IsUnicode = true)]
    [PXStringList(ExclusiveValues = false)]
    [PXUIField(DisplayName = "Test to Run")]
    public string SelectedTestCode { get; set; }

    public abstract class campaignID : BqlGuid.Field<campaignID> { }
    [PXDBGuid]
    [PXUIField(DisplayName = "Campaign ID")]
    public Guid? CampaignID { get; set; }

    public abstract class repetitionNo : BqlInt.Field<repetitionNo> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Repetition")]
    public int? RepetitionNo { get; set; }

    public abstract class isWarmup : BqlBool.Field<isWarmup> { }
    [PXDBBool]
    [PXUIField(DisplayName = "Warm-up Run")]
    public bool? IsWarmup { get; set; }

    public abstract class runBlock : BqlString.Field<runBlock> { }
    [PXDBString(8, IsUnicode = true)]
    [PXUIField(DisplayName = "Block")]
    public string RunBlock { get; set; }

    public abstract class orderPosition : BqlInt.Field<orderPosition> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Order Position")]
    public int? OrderPosition { get; set; }

    public abstract class workScale : BqlDecimal.Field<workScale> { }
    [PXDBDecimal(4)]
    [PXUIField(DisplayName = "Work Scale (1 = full)")]
    public decimal? WorkScale { get; set; }

    public abstract class passesOverride : BqlInt.Field<passesOverride> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Measured Passes (0 = test default)")]
    public int? PassesOverride { get; set; }

    public abstract class warmUpPassesOverride : BqlInt.Field<warmUpPassesOverride> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Warm-up Passes (blank = test default)")]
    public int? WarmUpPassesOverride { get; set; }

    public abstract class runBudgetSec : BqlInt.Field<runBudgetSec> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Run Budget (s, 0 = 15 min)")]
    public int? RunBudgetSec { get; set; }

    public abstract class serverAppStartUtc : BqlString.Field<serverAppStartUtc> { }
    [PXString(40, IsUnicode = true)]
    [PXUIField(DisplayName = "Server App Start (UTC)", Enabled = false)]
    public string ServerAppStartUtc { get; set; }

    public abstract class serverDllSha256 : BqlString.Field<serverDllSha256> { }
    [PXString(64, IsUnicode = true)]
    [PXUIField(DisplayName = "Server DLL SHA-256", Enabled = false)]
    public string ServerDllSha256 { get; set; }

    public abstract class serverMethodologyVersion : BqlString.Field<serverMethodologyVersion> { }
    [PXString(16, IsUnicode = true)]
    [PXUIField(DisplayName = "Methodology Version", Enabled = false)]
    public string ServerMethodologyVersion { get; set; }
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

    // ---- P0 additions (SPEC §3.2) ----

    public abstract class campaignID : BqlGuid.Field<campaignID> { }
    [PXDBGuid]
    [PXUIField(DisplayName = "Campaign ID", Enabled = false)]
    public Guid? CampaignID { get; set; }

    public abstract class repetitionNo : BqlInt.Field<repetitionNo> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Repetition", Enabled = false)]
    public int? RepetitionNo { get; set; }

    public abstract class isWarmup : BqlBool.Field<isWarmup> { }
    [PXDBBool]
    [PXUIField(DisplayName = "Warm-up Run", Enabled = false)]
    public bool? IsWarmup { get; set; }

    public abstract class runBlock : BqlString.Field<runBlock> { }
    [PXDBString(8, IsUnicode = true)]
    [PXUIField(DisplayName = "Block", Enabled = false)]
    public string RunBlock { get; set; }

    public abstract class orderPosition : BqlInt.Field<orderPosition> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Order Position", Enabled = false)]
    public int? OrderPosition { get; set; }

    public abstract class family : BqlString.Field<family> { }
    [PXDBString(32, IsUnicode = true)]
    [PXUIField(DisplayName = "Family", Enabled = false)]
    public string Family { get; set; }

    public abstract class methodologyVersion : BqlString.Field<methodologyVersion> { }
    [PXDBString(16, IsUnicode = true)]
    [PXUIField(DisplayName = "Methodology Version", Enabled = false)]
    public string MethodologyVersion { get; set; }

    public abstract class paramsHash : BqlString.Field<paramsHash> { }
    [PXDBString(16, IsUnicode = true)]
    [PXUIField(DisplayName = "Parameters Hash", Enabled = false)]
    public string ParamsHash { get; set; }

    public abstract class userCount : BqlInt.Field<userCount> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Users", Enabled = false)]
    public int? UserCount { get; set; }

    public abstract class elapsedMsPrecise : BqlDecimal.Field<elapsedMsPrecise> { }
    [PXDBDecimal(3)]
    [PXUIField(DisplayName = "Measured Time (ms)", Enabled = false)]
    public decimal? ElapsedMsPrecise { get; set; }

    public abstract class headlineValue : BqlDecimal.Field<headlineValue> { }
    [PXDBDecimal(4)]
    [PXUIField(DisplayName = "Headline Value", Enabled = false)]
    public decimal? HeadlineValue { get; set; }

    public abstract class headlineUnit : BqlString.Field<headlineUnit> { }
    [PXDBString(16, IsUnicode = true)]
    [PXUIField(DisplayName = "Headline Unit", Enabled = false)]
    public string HeadlineUnit { get; set; }

    public abstract class higherIsBetter : BqlBool.Field<higherIsBetter> { }
    [PXDBBool]
    [PXUIField(DisplayName = "Higher Is Better", Enabled = false)]
    public bool? HigherIsBetter { get; set; }

    public abstract class opsCount : BqlInt.Field<opsCount> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Operations", Enabled = false)]
    public int? OpsCount { get; set; }

    public abstract class opsPerSec : BqlDecimal.Field<opsPerSec> { }
    [PXDBDecimal(3)]
    [PXUIField(DisplayName = "Operations per Second", Enabled = false)]
    public decimal? OpsPerSec { get; set; }

    public abstract class p50Ms : BqlDecimal.Field<p50Ms> { }
    [PXDBDecimal(3)]
    [PXUIField(DisplayName = "p50 (ms)", Enabled = false)]
    public decimal? P50Ms { get; set; }

    public abstract class p95Ms : BqlDecimal.Field<p95Ms> { }
    [PXDBDecimal(3)]
    [PXUIField(DisplayName = "p95 (ms)", Enabled = false)]
    public decimal? P95Ms { get; set; }

    public abstract class p99Ms : BqlDecimal.Field<p99Ms> { }
    [PXDBDecimal(3)]
    [PXUIField(DisplayName = "p99 (ms)", Enabled = false)]
    public decimal? P99Ms { get; set; }

    public abstract class maxOpMs : BqlDecimal.Field<maxOpMs> { }
    [PXDBDecimal(3)]
    [PXUIField(DisplayName = "Max Operation (ms)", Enabled = false)]
    public decimal? MaxOpMs { get; set; }

    public abstract class rowsReturned : BqlLong.Field<rowsReturned> { }
    [PXDBLong]
    [PXUIField(DisplayName = "Rows Returned", Enabled = false)]
    public long? RowsReturned { get; set; }

    public abstract class checksum : BqlString.Field<checksum> { }
    [PXDBString(40, IsUnicode = true)]
    [PXUIField(DisplayName = "Checksum", Enabled = false)]
    public string Checksum { get; set; }

    public abstract class errorCount : BqlInt.Field<errorCount> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Errors", Enabled = false)]
    public int? ErrorCount { get; set; }

    public abstract class deadlockCount : BqlInt.Field<deadlockCount> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Deadlocks", Enabled = false)]
    public int? DeadlockCount { get; set; }

    public abstract class retryCount : BqlInt.Field<retryCount> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Retries", Enabled = false)]
    public int? RetryCount { get; set; }

    public abstract class lockViolationCount : BqlInt.Field<lockViolationCount> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Lock Violations", Enabled = false)]
    public int? LockViolationCount { get; set; }

    public abstract class timeoutCount : BqlInt.Field<timeoutCount> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Timeouts", Enabled = false)]
    public int? TimeoutCount { get; set; }

    public abstract class workersObservedPeak : BqlInt.Field<workersObservedPeak> { }
    [PXDBInt]
    [PXUIField(DisplayName = "Workers Observed", Enabled = false)]
    public int? WorkersObservedPeak { get; set; }

    public abstract class status : BqlString.Field<status> { }
    [PXDBString(16, IsUnicode = true)]
    [PXUIField(DisplayName = "Run Status", Enabled = false)]
    public string Status { get; set; }

    public abstract class invalidReason : BqlString.Field<invalidReason> { }
    [PXDBString(256, IsUnicode = true)]
    [PXUIField(DisplayName = "Invalid Reason", Enabled = false)]
    public string InvalidReason { get; set; }

    public abstract class dllSha256 : BqlString.Field<dllSha256> { }
    [PXDBString(64, IsUnicode = true)]
    [PXUIField(DisplayName = "DLL SHA-256", Enabled = false)]
    public string DllSha256 { get; set; }

    public abstract class appDomainStartUtc : BqlString.Field<appDomainStartUtc> { }
    [PXDBString(40, IsUnicode = true)]
    [PXUIField(DisplayName = "App Start (UTC)", Enabled = false)]
    public string AppDomainStartUtc { get; set; }

    public abstract class resultJson : BqlString.Field<resultJson> { }
    [PXDBText(IsUnicode = true)]
    [PXUIField(DisplayName = "Result JSON", Enabled = false)]
    public string ResultJson { get; set; }
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

    // ---- P0 additions (SPEC §3.3) ----

    public abstract class family : BqlString.Field<family> { }
    [PXString(32, IsUnicode = true)]
    [PXUIField(DisplayName = "Family", Enabled = false)]
    public string Family { get; set; }

    public abstract class runBlock : BqlString.Field<runBlock> { }
    [PXString(8, IsUnicode = true)]
    [PXUIField(DisplayName = "Block", Enabled = false)]
    public string RunBlock { get; set; }

    public abstract class shortLabel : BqlString.Field<shortLabel> { }
    [PXString(16, IsUnicode = true)]
    [PXUIField(DisplayName = "Short Label", Enabled = false)]
    public string ShortLabel { get; set; }

    public abstract class question : BqlString.Field<question> { }
    [PXString(1024, IsUnicode = true)]
    [PXUIField(DisplayName = "Question", Enabled = false)]
    public string Question { get; set; }

    public abstract class whatItSimulates : BqlString.Field<whatItSimulates> { }
    [PXString(1024, IsUnicode = true)]
    [PXUIField(DisplayName = "What It Simulates", Enabled = false)]
    public string WhatItSimulates { get; set; }

    public abstract class whyItMatters : BqlString.Field<whyItMatters> { }
    [PXString(1024, IsUnicode = true)]
    [PXUIField(DisplayName = "Why It Matters", Enabled = false)]
    public string WhyItMatters { get; set; }

    public abstract class readerUnit : BqlString.Field<readerUnit> { }
    [PXString(64, IsUnicode = true)]
    [PXUIField(DisplayName = "Reader Unit", Enabled = false)]
    public string ReaderUnit { get; set; }

    public abstract class userCount : BqlInt.Field<userCount> { }
    [PXInt]
    [PXUIField(DisplayName = "Users", Enabled = false)]
    public int? UserCount { get; set; }

    public abstract class headlineKind : BqlString.Field<headlineKind> { }
    [PXString(16, IsUnicode = true)]
    [PXUIField(DisplayName = "Headline Kind", Enabled = false)]
    public string HeadlineKind { get; set; }

    public abstract class headlineUnit : BqlString.Field<headlineUnit> { }
    [PXString(16, IsUnicode = true)]
    [PXUIField(DisplayName = "Headline Unit", Enabled = false)]
    public string HeadlineUnit { get; set; }

    public abstract class higherIsBetter : BqlBool.Field<higherIsBetter> { }
    [PXBool]
    [PXUIField(DisplayName = "Higher Is Better", Enabled = false)]
    public bool? HigherIsBetter { get; set; }

    public abstract class opsUnit : BqlString.Field<opsUnit> { }
    [PXString(32, IsUnicode = true)]
    [PXUIField(DisplayName = "Operation Unit", Enabled = false)]
    public string OpsUnit { get; set; }

    public abstract class parityExpected : BqlBool.Field<parityExpected> { }
    [PXBool]
    [PXUIField(DisplayName = "Parity Expected", Enabled = false)]
    public bool? ParityExpected { get; set; }

    public abstract class isDestructive : BqlBool.Field<isDestructive> { }
    [PXBool]
    [PXUIField(DisplayName = "Permanent Data Changes", Enabled = false)]
    public bool? IsDestructive { get; set; }

    public abstract class isOptional : BqlBool.Field<isOptional> { }
    [PXBool]
    [PXUIField(DisplayName = "Optional", Enabled = false)]
    public bool? IsOptional { get; set; }

    public abstract class excludeFromComparison : BqlBool.Field<excludeFromComparison> { }
    [PXBool]
    [PXUIField(DisplayName = "Excluded from Comparison", Enabled = false)]
    public bool? ExcludeFromComparison { get; set; }

    public abstract class legacyTestCode : BqlString.Field<legacyTestCode> { }
    [PXString(64, IsUnicode = true)]
    [PXUIField(DisplayName = "Legacy Test Code", Enabled = false)]
    public string LegacyTestCode { get; set; }

    public abstract class scenarioVersion : BqlInt.Field<scenarioVersion> { }
    [PXInt]
    [PXUIField(DisplayName = "Scenario Version", Enabled = false)]
    public int? ScenarioVersion { get; set; }

    public abstract class defaultOpsPerPass : BqlInt.Field<defaultOpsPerPass> { }
    [PXInt]
    [PXUIField(DisplayName = "Operations per Pass", Enabled = false)]
    public int? DefaultOpsPerPass { get; set; }

    public abstract class defaultPasses : BqlInt.Field<defaultPasses> { }
    [PXInt]
    [PXUIField(DisplayName = "Measured Passes", Enabled = false)]
    public int? DefaultPasses { get; set; }

    public abstract class defaultWarmUpPasses : BqlInt.Field<defaultWarmUpPasses> { }
    [PXInt]
    [PXUIField(DisplayName = "Warm-up Passes", Enabled = false)]
    public int? DefaultWarmUpPasses { get; set; }
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

    // ---- P0 additions (SPEC §3.4) ----

    public abstract class family : BqlString.Field<family> { }
    [PXString(32, IsUnicode = true)]
    [PXUIField(DisplayName = "Family", Enabled = false)]
    public string Family { get; set; }

    public abstract class shortLabel : BqlString.Field<shortLabel> { }
    [PXString(16, IsUnicode = true)]
    [PXUIField(DisplayName = "Short Label", Enabled = false)]
    public string ShortLabel { get; set; }

    public abstract class sortOrder : BqlInt.Field<sortOrder> { }
    [PXInt]
    [PXUIField(DisplayName = "Sort Order", Enabled = false)]
    public int? SortOrder { get; set; }

    public abstract class userCount : BqlInt.Field<userCount> { }
    [PXInt]
    [PXUIField(DisplayName = "Users", Enabled = false)]
    public int? UserCount { get; set; }

    public abstract class headlineValue : BqlDecimal.Field<headlineValue> { }
    [PXDecimal(4)]
    [PXUIField(DisplayName = "Headline Value", Enabled = false)]
    public decimal? HeadlineValue { get; set; }

    public abstract class headlineUnit : BqlString.Field<headlineUnit> { }
    [PXString(16, IsUnicode = true)]
    [PXUIField(DisplayName = "Headline Unit", Enabled = false)]
    public string HeadlineUnit { get; set; }

    public abstract class higherIsBetter : BqlBool.Field<higherIsBetter> { }
    [PXBool]
    [PXUIField(DisplayName = "Higher Is Better", Enabled = false)]
    public bool? HigherIsBetter { get; set; }

    public abstract class p95Ms : BqlDecimal.Field<p95Ms> { }
    [PXDecimal(3)]
    [PXUIField(DisplayName = "p95 (ms)", Enabled = false)]
    public decimal? P95Ms { get; set; }

    public abstract class opsPerSec : BqlDecimal.Field<opsPerSec> { }
    [PXDecimal(3)]
    [PXUIField(DisplayName = "Operations per Second", Enabled = false)]
    public decimal? OpsPerSec { get; set; }

    public abstract class errorCount : BqlInt.Field<errorCount> { }
    [PXInt]
    [PXUIField(DisplayName = "Errors", Enabled = false)]
    public int? ErrorCount { get; set; }

    public abstract class status : BqlString.Field<status> { }
    [PXString(16, IsUnicode = true)]
    [PXUIField(DisplayName = "Run Status", Enabled = false)]
    public string Status { get; set; }

    public abstract class paramsHash : BqlString.Field<paramsHash> { }
    [PXString(16, IsUnicode = true)]
    [PXUIField(DisplayName = "Parameters Hash", Enabled = false)]
    public string ParamsHash { get; set; }

    public abstract class relToFastest : BqlDecimal.Field<relToFastest> { }
    [PXDecimal(4)]
    [PXUIField(DisplayName = "x Fastest", Enabled = false)]
    public decimal? RelToFastest { get; set; }

    public abstract class verdict : BqlString.Field<verdict> { }
    [PXString(128, IsUnicode = true)]
    [PXUIField(DisplayName = "Verdict", Enabled = false)]
    public string Verdict { get; set; }

    public abstract class isComparable : BqlBool.Field<isComparable> { }
    [PXBool]
    [PXUIField(DisplayName = "Comparable", Enabled = false)]
    public bool? IsComparable { get; set; }
}
