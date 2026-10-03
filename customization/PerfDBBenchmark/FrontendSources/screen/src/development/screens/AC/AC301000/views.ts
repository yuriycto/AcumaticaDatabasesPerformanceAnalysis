import {
	PXFieldOptions,
	PXFieldState,
	PXView,
	columnConfig,
	gridConfig,
	GridPreset,
} from "client-controls";

// Every field mapped on the PerfDBBenchmark endpoint must be on the screen, otherwise the contract API
// cannot read or set it (SPEC section 3.6). Fields that are not useful to people are hidden, not removed.

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

	// SPEC section 3.1: run selection and campaign context (bound, enabled; set by people or by the suite over REST)
	SelectedTestCode: PXFieldState<PXFieldOptions.CommitChanges>;
	CampaignID: PXFieldState;
	RepetitionNo: PXFieldState;
	IsWarmup: PXFieldState;
	RunBlock: PXFieldState;
	OrderPosition: PXFieldState;
	WorkScale: PXFieldState<PXFieldOptions.CommitChanges>;
	PassesOverride: PXFieldState<PXFieldOptions.CommitChanges>;
	WarmUpPassesOverride: PXFieldState;
	RunBudgetSec: PXFieldState;

	// SPEC section 3.1: unbound server facts (read-only; restart and deployment checks)
	ServerAppStartUtc: PXFieldState;
	ServerDllSha256: PXFieldState;
	ServerMethodologyVersion: PXFieldState;
}

@gridConfig({
	preset: GridPreset.ShortList,
})
export class LocalResults extends PXView {
	ResultID: PXFieldState;
	RunID: PXFieldState<PXFieldOptions.Hidden>;
	TestCode: PXFieldState;
	TestCategory: PXFieldState<PXFieldOptions.Hidden>;
	ExecutionMode: PXFieldState<PXFieldOptions.Hidden>;
	DisplayName: PXFieldState;
	Family: PXFieldState;
	Status: PXFieldState;
	InvalidReason: PXFieldState;
	HeadlineValue: PXFieldState;
	HeadlineUnit: PXFieldState;
	HigherIsBetter: PXFieldState<PXFieldOptions.Hidden>;
	UserCount: PXFieldState;
	ElapsedMsPrecise: PXFieldState;
	OpsCount: PXFieldState;
	OpsPerSec: PXFieldState;
	P50Ms: PXFieldState;
	P95Ms: PXFieldState;
	P99Ms: PXFieldState<PXFieldOptions.Hidden>;
	MaxOpMs: PXFieldState<PXFieldOptions.Hidden>;
	ErrorCount: PXFieldState;
	DeadlockCount: PXFieldState<PXFieldOptions.Hidden>;
	RetryCount: PXFieldState<PXFieldOptions.Hidden>;
	LockViolationCount: PXFieldState<PXFieldOptions.Hidden>;
	TimeoutCount: PXFieldState<PXFieldOptions.Hidden>;
	WorkersObservedPeak: PXFieldState<PXFieldOptions.Hidden>;
	RowsReturned: PXFieldState<PXFieldOptions.Hidden>;
	Checksum: PXFieldState<PXFieldOptions.Hidden>;
	CampaignID: PXFieldState<PXFieldOptions.Hidden>;
	RepetitionNo: PXFieldState;
	IsWarmup: PXFieldState;
	RunBlock: PXFieldState<PXFieldOptions.Hidden>;
	OrderPosition: PXFieldState<PXFieldOptions.Hidden>;
	MethodologyVersion: PXFieldState<PXFieldOptions.Hidden>;
	ParamsHash: PXFieldState<PXFieldOptions.Hidden>;
	DllSha256: PXFieldState<PXFieldOptions.Hidden>;
	AppDomainStartUtc: PXFieldState<PXFieldOptions.Hidden>;
	ResultJson: PXFieldState<PXFieldOptions.Hidden>;
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
	SortOrder: PXFieldState;
	TestCode: PXFieldState;
	DisplayName: PXFieldState;
	Family: PXFieldState;
	RunBlock: PXFieldState;
	ShortLabel: PXFieldState;
	UserCount: PXFieldState;
	ReaderUnit: PXFieldState;
	HeadlineKind: PXFieldState;
	HeadlineUnit: PXFieldState;
	HigherIsBetter: PXFieldState;
	OpsUnit: PXFieldState;
	DefaultOpsPerPass: PXFieldState;
	DefaultPasses: PXFieldState;
	DefaultWarmUpPasses: PXFieldState;
	ParityExpected: PXFieldState;
	IsDestructive: PXFieldState;
	IsOptional: PXFieldState;
	ExcludeFromComparison: PXFieldState;
	LegacyTestCode: PXFieldState;
	ScenarioVersion: PXFieldState;
	Question: PXFieldState;
	WhatItSimulates: PXFieldState;
	WhyItMatters: PXFieldState;
	ActionName: PXFieldState<PXFieldOptions.Hidden>;
	Category: PXFieldState;
	ExecutionMode: PXFieldState;
	ShortDescription: PXFieldState;
}

@gridConfig({
	preset: GridPreset.ShortList,
})
export class ComparisonResults extends PXView {
	@columnConfig({ hideViewLink: true }) TestDisplayName: PXFieldState;
	TestCode: PXFieldState<PXFieldOptions.Hidden>;
	Family: PXFieldState;
	ShortLabel: PXFieldState<PXFieldOptions.Hidden>;
	SortOrder: PXFieldState<PXFieldOptions.Hidden>;
	UserCount: PXFieldState;
	TestCategory: PXFieldState;
	ExecutionMode: PXFieldState;
	DatabaseType: PXFieldState;
	InstanceName: PXFieldState;
	HeadlineValue: PXFieldState;
	HeadlineUnit: PXFieldState;
	HigherIsBetter: PXFieldState<PXFieldOptions.Hidden>;
	RelToFastest: PXFieldState;
	Verdict: PXFieldState;
	IsComparable: PXFieldState;
	P95Ms: PXFieldState;
	OpsPerSec: PXFieldState;
	ErrorCount: PXFieldState;
	Status: PXFieldState;
	ParamsHash: PXFieldState<PXFieldOptions.Hidden>;
	ElapsedMs: PXFieldState;
	RecordsCount: PXFieldState;
	Iterations: PXFieldState;
	BatchSize: PXFieldState;
	MaxThreads: PXFieldState;
	WinnerDisplay: PXFieldState;
	CapturedAtUtc: PXFieldState;
	Notes: PXFieldState;
}
