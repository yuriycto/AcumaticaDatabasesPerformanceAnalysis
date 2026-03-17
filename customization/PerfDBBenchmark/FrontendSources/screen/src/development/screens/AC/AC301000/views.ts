import {
	PXFieldOptions,
	PXFieldState,
	PXView,
	columnConfig,
	gridConfig,
	GridPreset,
} from "client-controls";

export class Filter extends PXView {
	SetupID: PXFieldState;
	NumberOfRecords: PXFieldState<PXFieldOptions.CommitChanges>;
	Iterations: PXFieldState<PXFieldOptions.CommitChanges>;
	ParallelBatchSize: PXFieldState<PXFieldOptions.CommitChanges>;
	ParallelMaxThreads: PXFieldState<PXFieldOptions.CommitChanges>;
	CurrentDatabase: PXFieldState;
	CurrentInstance: PXFieldState;
	DetectedCpuCores: PXFieldState;
	DetectedMemoryGb: PXFieldState;
	RecommendedRecords: PXFieldState;
	RecommendedIterations: PXFieldState;
	RecommendedBatchSize: PXFieldState;
	RecommendedMaxThreads: PXFieldState;
	HardwareRecommendationSummary: PXFieldState;
	SnapshotStatus: PXFieldState;
	PendingAnalysisStatus: PXFieldState;
	LastRequestID: PXFieldState;
	LastRequestedTestCode: PXFieldState;
	LastRequestedBenchmark: PXFieldState;
	LastRequestStatus: PXFieldState;
	LastRequestStartedAtUtc: PXFieldState;
	LastRequestCompletedAtUtc: PXFieldState;
	LastRequestElapsedMs: PXFieldState;
	LastRequestMessage: PXFieldState;
}

@gridConfig({
	preset: GridPreset.ShortList,
})
export class LocalResults extends PXView {
	ResultID: PXFieldState;
	RunID: PXFieldState;
	TestCode: PXFieldState;
	TestCategory: PXFieldState;
	ExecutionMode: PXFieldState;
	DisplayName: PXFieldState;
	RequestedAtUtc: PXFieldState;
	ElapsedMs: PXFieldState;
	RecordsCount: PXFieldState;
	Iterations: PXFieldState;
	BatchSize: PXFieldState;
	MaxThreads: PXFieldState;
	CapturedAtUtc: PXFieldState;
	Notes: PXFieldState;
}

@gridConfig({
	preset: GridPreset.ShortList,
})
export class BenchmarkCatalog extends PXView {
	TestCode: PXFieldState;
	DisplayName: PXFieldState;
	ActionName: PXFieldState;
	Category: PXFieldState;
	ExecutionMode: PXFieldState;
	ShortDescription: PXFieldState;
	SortOrder: PXFieldState;
}

@gridConfig({
	preset: GridPreset.ShortList,
})
export class ComparisonResults extends PXView {
	@columnConfig({ hideViewLink: true }) TestDisplayName: PXFieldState;
	TestCategory: PXFieldState;
	ExecutionMode: PXFieldState;
	DatabaseType: PXFieldState;
	InstanceName: PXFieldState;
	ElapsedMs: PXFieldState;
	RecordsCount: PXFieldState;
	Iterations: PXFieldState;
	BatchSize: PXFieldState;
	MaxThreads: PXFieldState;
	WinnerDisplay: PXFieldState;
	CapturedAtUtc: PXFieldState;
	Notes: PXFieldState;
}
