import {
	createCollection,
	createSingle,
	graphInfo,
	PXActionState,
	PXScreen,
} from "client-controls";

import {
	BenchmarkCatalog,
	ComparisonResults,
	Filter,
	LocalResults,
} from "./views";

@graphInfo({
	graphType: "PerfDBBenchmark.Core.Graphs.PerfDBBenchmarkGraph",
	primaryView: "Filter",
})
export class AC301000 extends PXScreen {
	private static readonly benchmarkOrder: Record<string, number> = {
		"Sequential Read": 10,
		"Sequential Write": 20,
		"Sequential Update": 25,
		"Sequential Delete": 30,
		"Complex BQL Join (Sequential)": 40,
		"PXProjection Analysis (Sequential)": 50,
		"Parallel Read": 60,
		"Parallel Write": 70,
		"Parallel Update": 75,
		"Parallel Delete": 80,
		"Complex BQL Join (Parallel)": 90,
		"PXProjection Analysis (Parallel)": 100,
	};
	private static readonly benchmarkShortName: Record<string, string> = {
		"Sequential Read": "Seq Read",
		"Sequential Write": "Seq Write",
		"Sequential Update": "Seq Update",
		"Sequential Delete": "Seq Delete",
		"Complex BQL Join (Sequential)": "Seq Join",
		"PXProjection Analysis (Sequential)": "Seq Projection",
		"Parallel Read": "Par Read",
		"Parallel Write": "Par Write",
		"Parallel Update": "Par Update",
		"Parallel Delete": "Par Delete",
		"Complex BQL Join (Parallel)": "Par Join",
		"PXProjection Analysis (Parallel)": "Par Projection",
	};

	Filter = createSingle(Filter);
	BenchmarkCatalog = createCollection(BenchmarkCatalog);
	LocalResults = createCollection(LocalResults);
	ComparisonResults = createCollection(ComparisonResults);

	hasVisualizationData = false;
	VisualizationStatus = "Run the same tests on all three instances, then click Refresh Status to populate the charts.";
	VisualizationCharts = [
		this.createEmptyChart("All Benchmarks"),
		this.createEmptyChart("Analytical Workloads"),
		this.createEmptyChart("Read / Write / Delete"),
	];

	ApplyRecommendedSettings: PXActionState;
	RefreshStatus: PXActionState;
	RunSequentialRead: PXActionState;
	RunSequentialWrite: PXActionState;
	RunSequentialDelete: PXActionState;
	RunSequentialComplexJoin: PXActionState;
	RunSequentialProjection: PXActionState;
	RunParallelRead: PXActionState;
	RunParallelWrite: PXActionState;
	RunParallelDelete: PXActionState;
	RunParallelComplexJoin: PXActionState;
	RunParallelProjection: PXActionState;
	ExportToExcel: PXActionState;
	ClearTestData: PXActionState;

	protected onAfterInitialize(): void {
		super.onAfterInitialize();
		this.scheduleVisualizationRefresh();
	}

	onCommandExecuted(args: any): void {
		super.onCommandExecuted(args);
		this.scheduleVisualizationRefresh();
	}

	private scheduleVisualizationRefresh(): void {
		[50, 400, 1500].forEach((delay) => {
			window.setTimeout(() => {
				void this.refreshVisualizationData();
			}, delay);
		});
	}

	private async refreshVisualizationData(): Promise<void> {
		try {
			await this.ComparisonResults.refresh();
		}
		catch {
			// The view may not be attach-ready during the first initialization tick.
		}

		this.refreshVisualization();
	}

	private refreshVisualization(): void {
		const records = this.ComparisonResults.records ?? [];
		const normalizedRows = records
			.map((record) => ({
				testDisplayName: String(this.getFieldValue(record, "TestDisplayName") ?? ""),
				testCategory: String(this.getFieldValue(record, "TestCategory") ?? ""),
				databaseType: String(this.getFieldValue(record, "DatabaseType") ?? ""),
				elapsedMs: Number(this.getFieldValue(record, "ElapsedMs") ?? 0),
			}))
			.filter((row) =>
				row.testDisplayName.length > 0 &&
				row.databaseType.length > 0 &&
				Number.isFinite(row.elapsedMs) &&
				row.elapsedMs > 0
			);

		const databaseOrder: string[] = Array.from(new Set<string>(normalizedRows.map((row) => row.databaseType)))
			.sort((left: string, right: string) => left.localeCompare(right));

		const hasData = normalizedRows.length > 0 && databaseOrder.length > 0;
		this.hasVisualizationData = hasData;
		if (!hasData) {
			this.VisualizationStatus = "Run the same tests on all three instances, then click Refresh Status to populate the charts.";
			this.VisualizationCharts = [
				this.createEmptyChart("All Benchmarks"),
				this.createEmptyChart("Analytical Workloads"),
				this.createEmptyChart("Read / Write / Delete"),
			];
			return;
		}

		this.VisualizationStatus = `Loaded ${normalizedRows.length} comparison row(s) across ${databaseOrder.length} database engine(s).`;
		this.VisualizationCharts = [
			this.createSvgChart(normalizedRows, databaseOrder, "All Benchmarks", () => true),
			this.createSvgChart(normalizedRows, databaseOrder, "Analytical Workloads", (row) =>
				row.testCategory === "Complex BQL Join" || row.testCategory === "PXProjection"
			),
			this.createSvgChart(normalizedRows, databaseOrder, "Read / Write / Delete", (row) =>
				row.testCategory === "Read" || row.testCategory === "Write" || row.testCategory === "Delete"
			),
		];
	}

	private createEmptyChart(title: string): any {
		const width = 1040;
		const height = 320;
		const plotLeft = 58;
		const plotRight = 24;
		const plotTop = 18;
		const plotBottom = 88;

		return {
			title,
			width,
			height,
			plotLeft,
			plotRight,
			plotTop,
			plotBottom,
			plotEndX: width - plotRight,
			axisBottom: height - plotBottom,
			categories: [],
			yTicks: [],
			series: [],
			legend: [],
		};
	}

	private createSvgChart(
		rows: Array<{ testDisplayName: string; testCategory: string; databaseType: string; elapsedMs: number }>,
		databaseOrder: string[],
		title: string,
		predicate: (row: { testDisplayName: string; testCategory: string; databaseType: string; elapsedMs: number }) => boolean
	): any {
		const chart = this.createEmptyChart(title);
		const filteredRows = rows
			.filter(predicate)
			.sort((left, right) =>
				(this.getBenchmarkSortOrder(left.testDisplayName) - this.getBenchmarkSortOrder(right.testDisplayName)) ||
				left.databaseType.localeCompare(right.databaseType)
			);

		const benchmarkNames: string[] = Array.from(new Set<string>(filteredRows.map((row) => row.testDisplayName)))
			.sort((left, right) => this.getBenchmarkSortOrder(left) - this.getBenchmarkSortOrder(right));
		if (benchmarkNames.length === 0) {
			return chart;
		}

		const plotWidth = chart.plotEndX - chart.plotLeft;
		const plotHeight = chart.axisBottom - chart.plotTop;
		const xStep = benchmarkNames.length > 1 ? plotWidth / (benchmarkNames.length - 1) : 0;
		const maxValue = filteredRows.reduce((currentMax, row) => Math.max(currentMax, row.elapsedMs), 0);
		const yMax = this.getNiceAxisMax(maxValue);

		const getX = (index: number): number =>
			benchmarkNames.length > 1
				? chart.plotLeft + xStep * index
				: chart.plotLeft + plotWidth / 2;
		const getY = (value: number): number =>
			chart.plotTop + plotHeight - ((value / yMax) * plotHeight);

		chart.categories = benchmarkNames.map((benchmarkName, index) => {
			const x = getX(index);
			return {
				x,
				label: this.getBenchmarkShortLabel(benchmarkName),
				transform: `rotate(25 ${x} ${chart.axisBottom + 20})`,
			};
		});

		chart.yTicks = Array.from({ length: 5 }, (_, index) => {
			const value = yMax - ((yMax / 4) * index);
			return {
				y: chart.plotTop + ((plotHeight / 4) * index),
				label: this.formatAxisValue(value),
			};
		});

		chart.legend = databaseOrder.map((databaseType, index) => ({
			name: databaseType,
			color: this.getSeriesColor(index),
		}));

		chart.series = databaseOrder.map((databaseType, index) => {
			const color = this.getSeriesColor(index);
			const points = benchmarkNames.map((benchmarkName, benchmarkIndex) => {
				const match = filteredRows.find((row) => row.testDisplayName === benchmarkName && row.databaseType === databaseType);
				const value = match ? match.elapsedMs : 0;
				const x = getX(benchmarkIndex);
				const y = getY(value);
				return {
					x,
					y,
					tooltip: `${databaseType} | ${benchmarkName}: ${value > 0 ? value.toLocaleString() + " ms" : "n/a"}`,
				};
			});

			return {
				name: databaseType,
				color,
				path: points.map((point, pointIndex) => `${pointIndex === 0 ? "M" : "L"} ${point.x} ${point.y}`).join(" "),
				points,
			};
		});

		return chart;
	}

	private getBenchmarkSortOrder(displayName: string): number {
		return AC301000.benchmarkOrder[displayName] ?? 999;
	}

	private getBenchmarkShortLabel(displayName: string): string {
		return AC301000.benchmarkShortName[displayName] ?? displayName;
	}

	private getSeriesColor(index: number): string {
		const palette = ["#2563eb", "#16a34a", "#dc2626", "#7c3aed"];
		return palette[index % palette.length];
	}

	private getNiceAxisMax(maxValue: number): number {
		if (maxValue <= 10) {
			return 10;
		}

		const exponent = Math.pow(10, Math.floor(Math.log10(maxValue)));
		const fraction = maxValue / exponent;
		if (fraction <= 1) {
			return exponent;
		}

		if (fraction <= 2) {
			return 2 * exponent;
		}

		if (fraction <= 5) {
			return 5 * exponent;
		}

		return 10 * exponent;
	}

	private formatAxisValue(value: number): string {
		if (value >= 1000) {
			return `${Math.round(value / 1000)}k`;
		}

		return `${Math.round(value)}`;
	}

	private getFieldValue(record: any, fieldName: string): any {
		if (!record) {
			return undefined;
		}

		const fieldState = record[fieldName];
		if (fieldState && typeof fieldState === "object" && "value" in fieldState) {
			return fieldState.value;
		}

		return fieldState;
	}
}
