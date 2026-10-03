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

interface ComparisonRow {
	testCode: string;
	testDisplayName: string;
	shortLabel: string;
	family: string;
	sortOrder: number;
	databaseType: string;
	timePerUnitMs: number;
	headlineValue: number;
	headlineUnit: string;
	higherIsBetter: boolean;
	verdict: string;
	isComparable: boolean;
}

interface ChartBar {
	x: number;
	y: number;
	width: number;
	height: number;
	color: string;
	engineLabel: string;
	engineLabelX: number;
	valueLabel: string;
	valueLabelX: number;
	textY: number;
	tooltip: string;
}

interface ChartGroup {
	label: string;
	labelY: number;
	verdict: string;
	bars: ChartBar[];
}

@graphInfo({
	graphType: "PerfDBBenchmark.Core.Graphs.PerfDBBenchmarkGraph",
	primaryView: "Filter",
})
export class AC301000 extends PXScreen {
	// Okabe-Ito palette, chosen by database engine (never by sorted index) so a colour always means the same engine (SPEC section 0.3 #27).
	private static readonly engineColors: Record<string, string> = {
		SQLServer: "#0072B2",
		MySQL: "#E69F00",
		PostgreSQL: "#CC79A7",
	};
	private static readonly engineNames: Record<string, string> = {
		SQLServer: "SQL Server",
		MySQL: "MySQL",
		PostgreSQL: "PostgreSQL",
	};
	private static readonly engineOrder: string[] = ["SQLServer", "MySQL", "PostgreSQL"];
	// Reader-facing family names (SPEC section 5.5, section 7.1).
	private static readonly familyNames: Record<string, string> = {
		Screens: "Everyday screens",
		Reports: "Reports & month-end",
		OrderEntry: "Order entry (1 clerk) (1 test)",
		ManyUsers: "Many simultaneous users",
		InvoiceRelease: "Invoice release to GL",
		Core: "Platform basics: bulk record work",
	};
	private static readonly emptyStatus = "Run the same tests on all three instances, then click Refresh Status to populate the charts.";

	Filter = createSingle(Filter);
	BenchmarkCatalog = createCollection(BenchmarkCatalog);
	LocalResults = createCollection(LocalResults);
	ComparisonResults = createCollection(ComparisonResults);

	hasVisualizationData = false;
	VisualizationStatus = AC301000.emptyStatus;
	VisualizationCharts: any[] = [];

	ApplyRecommendedSettings: PXActionState;
	RefreshStatus: PXActionState;
	RunBenchmark: PXActionState;
	AbortBenchmark: PXActionState;
	ClearTestRecords: PXActionState;
	RunSequentialRead: PXActionState;
	RunSequentialWrite: PXActionState;
	RunSequentialUpdate: PXActionState;
	RunSequentialDelete: PXActionState;
	RunSequentialComplexJoin: PXActionState;
	RunSequentialProjection: PXActionState;
	RunParallelRead: PXActionState;
	RunParallelWrite: PXActionState;
	RunParallelUpdate: PXActionState;
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
		const rows: ComparisonRow[] = records
			.map((record) => this.toComparisonRow(record))
			.filter((row): row is ComparisonRow => row !== null);

		const hasData = rows.length > 0;
		this.hasVisualizationData = hasData;
		if (!hasData) {
			this.VisualizationStatus = AC301000.emptyStatus;
			this.VisualizationCharts = [];
			return;
		}

		// One chart per Family, families in catalog order (lowest SortOrder first).
		const familyOrder = new Map<string, number>();
		rows.forEach((row) => {
			const current = familyOrder.get(row.family);
			if (current === undefined || row.sortOrder < current) {
				familyOrder.set(row.family, row.sortOrder);
			}
		});
		const families = Array.from(familyOrder.keys()).sort((a, b) => (familyOrder.get(a) ?? 0) - (familyOrder.get(b) ?? 0));
		const engines = new Set<string>(rows.map((row) => row.databaseType));

		this.VisualizationStatus =
			`Loaded ${rows.length} comparison row(s) across ${engines.size} database engine(s). ` +
			"Bars show each engine's time relative to the fastest engine on that test (1.00\u00d7 = fastest; lower is better; " +
			"orders or invoices per minute are converted to time per order). The in-app verdict is indicative only; the published verdicts come from the report generator.";
		this.VisualizationCharts = families.map((family) => this.createFamilyChart(family, rows.filter((row) => row.family === family)));
	}

	private toComparisonRow(record: any): ComparisonRow | null {
		const testDisplayName = String(this.getFieldValue(record, "TestDisplayName") ?? "");
		const databaseType = this.normalizeEngine(String(this.getFieldValue(record, "DatabaseType") ?? ""));
		const headlineValue = Number(this.getFieldValue(record, "HeadlineValue") ?? 0);
		const higherIsBetter = this.getFieldValue(record, "HigherIsBetter") === true;
		const elapsedMs = Number(this.getFieldValue(record, "ElapsedMs") ?? 0);
		let timePerUnitMs = 0;
		if (Number.isFinite(headlineValue) && headlineValue > 0) {
			timePerUnitMs = higherIsBetter ? 60000 / headlineValue : headlineValue;
		}
		else if (Number.isFinite(elapsedMs) && elapsedMs > 0) {
			timePerUnitMs = elapsedMs;
		}

		if (testDisplayName.length === 0 || databaseType.length === 0 || !(timePerUnitMs > 0)) {
			return null;
		}

		const family = String(this.getFieldValue(record, "Family") ?? "") || "Other";
		if (family === "Environment") {
			return null;
		}

		const shortLabel = String(this.getFieldValue(record, "ShortLabel") ?? "");
		const sortOrder = Number(this.getFieldValue(record, "SortOrder") ?? 999);
		return {
			testCode: String(this.getFieldValue(record, "TestCode") ?? ""),
			testDisplayName,
			shortLabel: shortLabel.length > 0 ? shortLabel : testDisplayName,
			family,
			sortOrder: Number.isFinite(sortOrder) ? sortOrder : 999,
			databaseType,
			timePerUnitMs,
			headlineValue,
			headlineUnit: String(this.getFieldValue(record, "HeadlineUnit") ?? ""),
			higherIsBetter,
			verdict: String(this.getFieldValue(record, "Verdict") ?? ""),
			isComparable: this.getFieldValue(record, "IsComparable") !== false,
		};
	}

	private createFamilyChart(family: string, rows: ComparisonRow[]): any {
		const width = 1040;
		const labelColumn = 300;
		const engineColumn = 92;
		const plotLeft = labelColumn + engineColumn;
		const plotRight = 150;
		const plotWidth = width - plotLeft - plotRight;
		const barHeight = 16;
		const barGap = 4;
		const groupGap = 14;
		const headerHeight = 22;
		const top = 30;

		const testKeys: string[] = Array.from(new Set<string>(rows.map((row) => row.testCode || row.testDisplayName)));
		const tests = testKeys
			.map((key) => rows.filter((row) => (row.testCode || row.testDisplayName) === key))
			.sort((a, b) => a[0].sortOrder - b[0].sortOrder || a[0].testDisplayName.localeCompare(b[0].testDisplayName));

		// Relative scale: every test is normalised to its own fastest engine, so a 100x range between tests never squeezes the bars.
		let maxRel = 1;
		tests.forEach((testRows) => {
			const fastest = Math.min(...testRows.map((row) => row.timePerUnitMs));
			testRows.forEach((row) => {
				maxRel = Math.max(maxRel, row.timePerUnitMs / fastest);
			});
		});
		const axisMax = this.getNiceRelMax(maxRel);
		const scaleX = (rel: number): number => plotLeft + ((rel - 0) / axisMax) * plotWidth;

		const groups: ChartGroup[] = [];
		let y = top;
		tests.forEach((testRows) => {
			const fastest = Math.min(...testRows.map((row) => row.timePerUnitMs));
			const ordered = AC301000.engineOrder
				.map((engine) => testRows.find((row) => row.databaseType === engine))
				.filter((row): row is ComparisonRow => row !== undefined)
				.concat(testRows.filter((row) => AC301000.engineOrder.indexOf(row.databaseType) < 0));
			const group: ChartGroup = {
				// Server ShortLabel and DisplayName (no hard-coded test maps): "Open SO (Open a sales order)".
				label: testRows[0].shortLabel !== testRows[0].testDisplayName ? `${testRows[0].shortLabel} (${testRows[0].testDisplayName})` : testRows[0].testDisplayName,
				labelY: y + 13,
				verdict: testRows.map((row) => row.verdict).find((v) => v.length > 0) ?? "",
				bars: [],
			};
			y += headerHeight;
			ordered.forEach((row) => {
				const rel = row.timePerUnitMs / fastest;
				const x0 = scaleX(0);
				const x1 = scaleX(rel);
				const engineName = AC301000.engineNames[row.databaseType] ?? row.databaseType;
				const valueLabel = `${rel.toFixed(2)}\u00d7 \u00b7 ${this.formatAbsolute(row)}`;
				group.bars.push({
					x: x0,
					y,
					width: Math.max(1, x1 - x0),
					height: barHeight,
					color: AC301000.engineColors[row.databaseType] ?? "#6b7280",
					engineLabel: engineName,
					engineLabelX: plotLeft - 8,
					valueLabel,
					valueLabelX: x1 + 6,
					textY: y + barHeight - 4,
					tooltip: `${engineName} | ${row.testDisplayName}: ${valueLabel}${row.isComparable ? "" : " (not comparable)"}`,
				});
				y += barHeight + barGap;
			});
			groups.push(group);
			y += groupGap;
		});

		const ticks = [0, 0.25, 0.5, 0.75, 1].map((share) => {
			const rel = axisMax * share;
			return { x: scaleX(rel), label: `${rel.toFixed(rel < 10 ? 1 : 0)}\u00d7` };
		});

		return {
			title: AC301000.familyNames[family] ?? family,
			width,
			height: Math.max(80, y + 24),
			plotTop: top - 6,
			plotBottom: y,
			oneX: scaleX(1),
			ticks,
			groups,
			legend: AC301000.engineOrder.map((engine) => ({ name: AC301000.engineNames[engine], color: AC301000.engineColors[engine] })),
		};
	}

	private formatAbsolute(row: ComparisonRow): string {
		if (row.higherIsBetter) {
			return `${this.formatNumber(row.headlineValue)} per min`;
		}

		const ms = row.timePerUnitMs;
		return ms >= 1000 ? `${this.formatNumber(ms / 1000)} s` : `${this.formatNumber(ms)} ms`;
	}

	private formatNumber(value: number): string {
		if (!Number.isFinite(value)) {
			return "n/a";
		}

		const abs = Math.abs(value);
		if (abs >= 100) {
			return Math.round(value).toLocaleString();
		}

		return abs >= 10 ? value.toFixed(1) : value.toFixed(2);
	}

	private normalizeEngine(value: string): string {
		const name = value.toLowerCase().replace(/\s+/g, "");
		if (name.includes("postgre") || name.includes("pgsql")) {
			return "PostgreSQL";
		}

		if (name.includes("mysql") || name.includes("maria")) {
			return "MySQL";
		}

		if (name.includes("sqlserver") || name.includes("mssql") || name === "sql") {
			return "SQLServer";
		}

		return value;
	}

	private getNiceRelMax(maxRel: number): number {
		const steps = [1.25, 1.5, 2, 2.5, 3, 4, 5, 8, 10, 15, 20, 30, 50, 100];
		for (const step of steps) {
			if (maxRel * 1.08 <= step) {
				return step;
			}
		}

		return Math.ceil(maxRel * 1.1);
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
