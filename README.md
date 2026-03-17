# PerfDBBenchmark

`PerfDBBenchmark` is a DLL-based Acumatica 2026 R1 benchmark customization for comparing database behavior across PostgreSQL, MySQL 8.0, and Microsoft SQL Server by running the same Acumatica workloads on each instance.

Created by AcuPower LTD for performance analysis. Company website: [acupowererp.com](https://acupowererp.com)

## What It Includes

- Screen `AC301000` with responsive tabs, charts, result highlighting, hardware-based recommendations, and current database detection.
- Benchmarks for sequential read, sequential write, sequential delete, parallel read, parallel write, parallel delete, complex FBQL joins, and `PXProjection` analysis.
- Cross-instance comparison snapshots written to `App_Data\PerfDBBenchmark`.
- A precompiled `.NET Framework 4.8` DLL that uses modern C# features so the customization is intended to be deployed as a compiled assembly, not runtime-compiled inside Acumatica.
- A built-in access-rights bootstrap for `AC301000` that copies `RolesInGraph` entries from a stock Acumatica screen at runtime, so the screen permissions are delivered by the customization DLL itself instead of a separate SQL script.

## Project Layout

- `src/PerfDBBenchmark.Core`: compiled DACs, graph, support services, and page code-behind.
- `customization/PerfDBBenchmark`: Acumatica customization source folder containing the ASPX page and generated `project.xml`.
- `scripts/Build-PerfDBBenchmarkPackage.ps1`: builds the DLL, refreshes `project.xml`, copies the DLL into the package folder, and produces `artifacts/PerfDBBenchmark.zip`.
- `scripts/Publish-PerfDBBenchmark.ps1`: uploads and publishes the package to the local benchmark instances with CLI automation and `dnSpy.Console.exe` fallback diagnostics.
- `scripts/Run-PerfDBBenchmarkEndpointSuite.ps1`: authenticates to the packaged `PerfDBBenchmark` REST endpoint, runs all benchmark actions sequentially per instance, and writes HTML and JSON timing reports.

## Required web.config Settings

Parallel benchmark actions require Acumatica parallel processing to be enabled in each benchmark website's `web.config`.

```xml
<add key="EnableAutoNumberingInSeparateConnection" value="true" />
<add key="ParallelProcessingDisabled" value="false" />
<add key="ParallelProcessingMaxThreads" value="6" />
<add key="ParallelProcessingBatchSize" value="10" />
<add key="IsParallelProcessingSkipBatchExceptions" value="True" />
```

Tune the thread and batch settings to the hardware available on each server. The screen also displays recommended values derived from detected CPU cores and RAM.

## Build The Package

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Build-PerfDBBenchmarkPackage.ps1
```

Output:

- `customization/PerfDBBenchmark/project.xml`
- `customization/PerfDBBenchmark/Bin/PerfDBBenchmark.Core.dll`
- `artifacts/PerfDBBenchmark.zip`

## Publish To Local Instances

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Publish-PerfDBBenchmark.ps1
```

The publish script:

- Builds the package first unless `-SkipPackageBuild` is supplied.
- Auto-detects the local benchmark sites under `E:\Instances2\26.100.0168`.
- Publishes to `PerfPG`, `PerfMySQL`, and `PerfSQL` by using `PX.CommandLine.exe`.
- Uses `/merge` and `/skipPreviouslyExecutedDbScripts` by default for safer repeated publishes.
- Writes diagnostics to `artifacts\publish-diagnostics` and decompiles reference assemblies through `E:\dnSpy\6.5.1\dnSpy.Console.exe` if publication fails, so assembly versions can be compared and binding redirects can be added if needed.
- Ships the dedicated `PerfDBBenchmark` endpoint together with the screen, DAC schema, and visible benchmark buttons.

## Run The Endpoint Suite

Publish the customization first so the dedicated endpoint exists on each target instance.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Run-PerfDBBenchmarkEndpointSuite.ps1 -Username admin
```

If `-Password` is omitted, the script securely prompts for it. The default instance order is `PerfPG`, `PerfMySQL`, and `PerfSQL`, and the default benchmark order mirrors `PerfBenchmarkCatalog.All` in the customization source.

Useful examples:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Run-PerfDBBenchmarkEndpointSuite.ps1 -Username admin -UseRecommendedSettings
```

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Run-PerfDBBenchmarkEndpointSuite.ps1 -Username admin -Instances PerfSQL -IncludeTests SEQ_WRITE,PAR_WRITE -NumberOfRecords 1000 -Iterations 2 -BatchSize 50 -MaxThreads 4
```

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Run-PerfDBBenchmarkEndpointSuite.ps1 -Username admin -ClearExistingData
```

The endpoint runner:

- Authenticates through `/entity/auth/login` and uses the dedicated `/entity/PerfDBBenchmark/26.100.001` endpoint.
- Refreshes control status, optionally applies recommended settings, then updates benchmark parameters before running tests.
- Executes all selected benchmark actions sequentially on one instance, waits for completion by polling the persisted control request state, and only then moves to the next action or instance.
- Can clear prior benchmark data on each instance before a rerun by using `-ClearExistingData`.
- Writes a customer-friendly HTML report and a matching JSON artifact under `artifacts\benchmark-reports`.
- Includes a built-in spider chart that normalizes benchmark speed per test so readers can compare the three databases visually.

Generated artifacts:

- `artifacts\benchmark-reports\PerfDBBenchmark-<timestamp>.html`
- `artifacts\benchmark-reports\PerfDBBenchmark-<timestamp>.json`

## Notes

- The publish script works directly against local website roots through `PX.CommandLine.exe`, so HTTP login credentials are not required for the CLI-based publish flow.
- Screen permissions for `AC301000` are now self-registered by the customization on authenticated requests, so no manual `RolesInGraph` SQL patch is required after publish.
- The package description, screen text, and benchmark notes include AcuPower attribution and `acupowererp.com` for repository and GitHub visibility.
