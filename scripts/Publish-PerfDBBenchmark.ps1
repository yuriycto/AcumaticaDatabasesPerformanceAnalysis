param(
    [string]$InstanceRoot = "E:\Instances2\26.100.0168",
    [string[]]$Targets = @("PerfPG", "PerfMySQL", "PerfSQL"),
    [string]$CustomizationName = "PerfDBBenchmark",
    [string]$PackagePath = "",
    [string]$ModernUiBuildTarget = "PerfSQL",
    [bool]$MergePublishedProjects = $true,
    [bool]$SkipPreviouslyExecutedDbScripts = $true,
    [switch]$SkipPackageBuild,
    [string]$DnSpyPath = "E:\dnSpy\6.5.1\dnSpy.Console.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$buildScriptPath = Join-Path $PSScriptRoot "Build-PerfDBBenchmarkPackage.ps1"
$defaultPackagePath = Join-Path $repoRoot "artifacts\$CustomizationName.zip"
$packagePath = if ([string]::IsNullOrWhiteSpace($PackagePath)) { $defaultPackagePath } else { $PackagePath }
$packageDllPath = Join-Path $repoRoot "src\PerfDBBenchmark.Core\bin\Release\net48\PerfDBBenchmark.Core.dll"
$diagnosticsRoot = Join-Path $repoRoot "artifacts\publish-diagnostics"

function Get-TargetDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    switch ($Name.ToLowerInvariant()) {
        "perfpg" {
            return [pscustomobject]@{
                Name = "PerfPG"
                FolderCandidates = @("PerfPG")
                UrlLabels = @("http://localhost/PerfPG")
            }
        }
        "perfmysql" {
            return [pscustomobject]@{
                Name = "PerfMySQL"
                FolderCandidates = @("PerfMySQL", "PerfrMySQL")
                UrlLabels = @("http://localhost/PerfMySQL", "http://localhost/PerfrMySQL")
            }
        }
        "perfsql" {
            return [pscustomobject]@{
                Name = "PerfSQL"
                FolderCandidates = @("PerfSQL", "PerfrSQL")
                UrlLabels = @("http://localhost/PerfSQL", "http://localhost/PerfrSQL")
            }
        }
        default {
            return [pscustomobject]@{
                Name = $Name
                FolderCandidates = @($Name)
                UrlLabels = @("http://localhost/$Name")
            }
        }
    }
}

function Resolve-WebsiteRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string[]]$FolderCandidates
    )

    foreach ($folderCandidate in $FolderCandidates) {
        $websiteRoot = Join-Path $Root $folderCandidate
        if (Test-Path -LiteralPath $websiteRoot) {
            return $websiteRoot
        }
    }

    throw "Unable to locate any website root for: $($FolderCandidates -join ', ') under '$Root'."
}

function Invoke-PxCli {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WebsiteRoot,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $pxCliPath = Join-Path $WebsiteRoot "Bin\PX.CommandLine.exe"
    if (-not (Test-Path -LiteralPath $pxCliPath)) {
        throw "PX.CommandLine.exe was not found for website '$WebsiteRoot'."
    }

    & $pxCliPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "PX.CommandLine failed with exit code $LASTEXITCODE for website '$WebsiteRoot'."
    }
}

function Get-WebConfigAppSettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WebsiteRoot
    )

    $webConfigPath = Join-Path $WebsiteRoot "web.config"
    if (-not (Test-Path -LiteralPath $webConfigPath)) {
        return @{}
    }

    [xml]$webConfig = Get-Content -LiteralPath $webConfigPath -Raw
    $appSettings = @{}
    if ($null -ne $webConfig.configuration.appSettings) {
        foreach ($addNode in $webConfig.configuration.appSettings.add) {
            $appSettings[[string]$addNode.key] = [string]$addNode.value
        }
    }

    return $appSettings
}

function Get-ParallelProcessingWarnings {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$AppSettings
    )

    $warnings = New-Object System.Collections.Generic.List[string]

    if ($AppSettings["ParallelProcessingDisabled"] -ne "false") {
        $warnings.Add("web.config should include ParallelProcessingDisabled=false.")
    }
    if ([string]::IsNullOrWhiteSpace($AppSettings["ParallelProcessingMaxThreads"])) {
        $warnings.Add("web.config should include ParallelProcessingMaxThreads.")
    }
    if ([string]::IsNullOrWhiteSpace($AppSettings["ParallelProcessingBatchSize"])) {
        $warnings.Add("web.config should include ParallelProcessingBatchSize.")
    }
    if ([string]::IsNullOrWhiteSpace($AppSettings["EnableAutoNumberingInSeparateConnection"])) {
        $warnings.Add("web.config should include EnableAutoNumberingInSeparateConnection=true for parallel workloads.")
    }

    return $warnings
}

function Invoke-NpmCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FrontendRoot,
        [Parameter(Mandatory = $true)]
        [string]$NodeJsRoot,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $npmPath = Join-Path $NodeJsRoot "npm.cmd"
    if (-not (Test-Path -LiteralPath $npmPath)) {
        throw "npm.cmd was not found under '$NodeJsRoot'."
    }

    $originalPath = $env:Path
    try {
        $env:Path = "$NodeJsRoot;$originalPath"
        Push-Location -LiteralPath $FrontendRoot
        & $npmPath @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            throw "npm $($Arguments -join ' ') failed with exit code $LASTEXITCODE in '$FrontendRoot'."
        }
    }
    finally {
        Pop-Location
        $env:Path = $originalPath
    }
}

function Ensure-ModernUiBundle {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WebsiteRoot,
        [Parameter(Mandatory = $true)]
        [hashtable]$AppSettings,
        [string]$ScreenId = "AC301000"
    )

    $nodeJsRoot = $AppSettings["NodeJs:NodeJsPath"]
    if ([string]::IsNullOrWhiteSpace($nodeJsRoot)) {
        throw "NodeJs:NodeJsPath is missing in web.config for '$WebsiteRoot'."
    }

    $frontendRoot = Join-Path $WebsiteRoot "FrontendSources"
    if (-not (Test-Path -LiteralPath $frontendRoot)) {
        throw "FrontendSources folder was not found for '$WebsiteRoot'."
    }

    $nodeModulesRoot = Join-Path $frontendRoot "node_modules"
    if (-not (Test-Path -LiteralPath $nodeModulesRoot)) {
        Write-Host "Installing FrontendSources dependencies for '$WebsiteRoot'..." -ForegroundColor Cyan
        Invoke-NpmCommand -FrontendRoot $frontendRoot -NodeJsRoot $nodeJsRoot -Arguments @("run", "getmodules")
    }

    Write-Host "Building Modern UI bundle for '$ScreenId' in '$WebsiteRoot'..." -ForegroundColor Cyan
    Invoke-NpmCommand -FrontendRoot $frontendRoot -NodeJsRoot $nodeJsRoot -Arguments @("run", "build-dev", "--", "--env", "customFolder=development")

    $bundleFiles = Get-ChildItem -LiteralPath (Join-Path $WebsiteRoot "Scripts\Screens") -File | Where-Object { $_.Name -like "$ScreenId*" }
    if ($bundleFiles.Count -eq 0) {
        throw "No Modern UI bundle files were produced for '$ScreenId' under '$WebsiteRoot\Scripts\Screens'."
    }

    $screenInfoRoot = Join-Path $WebsiteRoot "App_Data\TSScreenInfo"
    $screenInfoFiles = @()
    if (Test-Path -LiteralPath $screenInfoRoot) {
        $screenInfoFiles = @(Get-ChildItem -LiteralPath $screenInfoRoot -File | Where-Object { $_.Name -like "$ScreenId*" })
    }

    if ($screenInfoFiles.Count -eq 0) {
        throw "No TSScreenInfo files were produced for '$ScreenId' under '$screenInfoRoot'."
    }

    return [pscustomobject]@{
        BundleFiles = @($bundleFiles)
        ScreenInfoFiles = @($screenInfoFiles)
    }
}

function Copy-ModernUiBundle {
    param(
        [Parameter(Mandatory = $true)]
        $ModernUiArtifacts,
        [Parameter(Mandatory = $true)]
        [string]$DestinationWebsiteRoot
    )

    $destinationScreensRoot = Join-Path $DestinationWebsiteRoot "Scripts\Screens"
    New-Item -Path $destinationScreensRoot -ItemType Directory -Force | Out-Null

    foreach ($bundleFile in @($ModernUiArtifacts.BundleFiles)) {
        Copy-Item -LiteralPath $bundleFile.FullName -Destination (Join-Path $destinationScreensRoot $bundleFile.Name) -Force
    }

    $destinationScreenInfoRoot = Join-Path $DestinationWebsiteRoot "App_Data\TSScreenInfo"
    New-Item -Path $destinationScreenInfoRoot -ItemType Directory -Force | Out-Null

    foreach ($screenInfoFile in @($ModernUiArtifacts.ScreenInfoFiles)) {
        Copy-Item -LiteralPath $screenInfoFile.FullName -Destination (Join-Path $destinationScreenInfoRoot $screenInfoFile.Name) -Force
    }
}

function Get-AssemblyVersionDescription {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AssemblyPath
    )

    if (-not (Test-Path -LiteralPath $AssemblyPath)) {
        return "<missing>"
    }

    try {
        $assemblyName = [System.Reflection.AssemblyName]::GetAssemblyName($AssemblyPath)
        return "$($assemblyName.Name) $($assemblyName.Version)"
    }
    catch {
        return "<unreadable>"
    }
}

function Write-BindingDiagnostics {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WebsiteRoot,
        [Parameter(Mandatory = $true)]
        [string]$InstanceName
    )

    $instanceDiagnosticsFolder = Join-Path $diagnosticsRoot $InstanceName
    New-Item -Path $instanceDiagnosticsFolder -ItemType Directory -Force | Out-Null

    $assembliesToInspect = @(
        (Join-Path $WebsiteRoot "Bin\PX.Common.dll"),
        (Join-Path $WebsiteRoot "Bin\PX.Common.Std.dll"),
        (Join-Path $WebsiteRoot "Bin\PX.Data.dll"),
        (Join-Path $WebsiteRoot "Bin\PX.Data.BQL.Fluent.dll"),
        (Join-Path $WebsiteRoot "Bin\PX.Objects.dll"),
        (Join-Path $WebsiteRoot "Bin\PX.Web.UI.dll"),
        $packageDllPath
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("PerfDBBenchmark publish diagnostics")
    $lines.Add("Instance: $InstanceName")
    $lines.Add("Website root: $WebsiteRoot")
    $lines.Add("Generated at: $(Get-Date -Format o)")
    $lines.Add("")
    $lines.Add("Assemblies:")

    foreach ($assemblyPath in $assembliesToInspect) {
        $lines.Add(" - $assemblyPath :: $(Get-AssemblyVersionDescription -AssemblyPath $assemblyPath)")
    }

    $lines.Add("")
    $lines.Add("Binding redirect suggestion:")
    $lines.Add("If PerfDBBenchmark.Core references assembly versions different from the website Bin folder, add or update web.config assemblyBinding redirects for the mismatched assemblies before retrying publish.")

    $diagnosticsPath = Join-Path $instanceDiagnosticsFolder "binding-diagnostics.txt"
    [System.IO.File]::WriteAllLines($diagnosticsPath, $lines)
    return $diagnosticsPath
}

function Start-DnSpyDiagnostics {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WebsiteRoot
    )

    if (-not (Test-Path -LiteralPath $DnSpyPath)) {
        Write-Warning "dnSpy was not found at '$DnSpyPath'."
        return
    }

    $assemblyPaths = @(
        (Join-Path $WebsiteRoot "Bin\PX.Data.dll"),
        (Join-Path $WebsiteRoot "Bin\PX.Objects.dll"),
        (Join-Path $WebsiteRoot "Bin\PX.Web.UI.dll"),
        $packageDllPath
    ) | Where-Object { Test-Path -LiteralPath $_ }

    if ($assemblyPaths.Count -eq 0) {
        Write-Warning "No assemblies were available for dnSpy diagnostics."
        return
    }

    $outputRoot = Join-Path $diagnosticsRoot "dnspy-console"
    $instanceOutputRoot = Join-Path $outputRoot ([System.IO.Path]::GetFileName($WebsiteRoot))
    New-Item -Path $instanceOutputRoot -ItemType Directory -Force | Out-Null

    foreach ($assemblyPath in $assemblyPaths) {
        $assemblyOutputRoot = Join-Path $instanceOutputRoot ([System.IO.Path]::GetFileNameWithoutExtension($assemblyPath))
        New-Item -Path $assemblyOutputRoot -ItemType Directory -Force | Out-Null
        & $DnSpyPath -o $assemblyOutputRoot $assemblyPath | Out-Null
    }
}

if (-not $SkipPackageBuild) {
    if (-not (Test-Path -LiteralPath $buildScriptPath)) {
        throw "Build script was not found: $buildScriptPath"
    }

    Write-Host "Building package before publish..." -ForegroundColor Cyan
    & $buildScriptPath -InstanceRoot $InstanceRoot
    if ($LASTEXITCODE -ne 0) {
        throw "The package build script failed with exit code $LASTEXITCODE."
    }
}

if (-not (Test-Path -LiteralPath $packagePath)) {
    throw "Customization package was not found: $packagePath"
}

New-Item -Path $diagnosticsRoot -ItemType Directory -Force | Out-Null

$publishResults = New-Object System.Collections.Generic.List[object]
$appSettingsByTarget = @{}

foreach ($target in $Targets) {
    $definition = Get-TargetDefinition -Name $target
    $websiteRoot = Resolve-WebsiteRoot -Root $InstanceRoot -FolderCandidates $definition.FolderCandidates
    $appSettings = Get-WebConfigAppSettings -WebsiteRoot $websiteRoot
    $appSettingsByTarget[$definition.Name] = $appSettings
    $parallelWarnings = Get-ParallelProcessingWarnings -AppSettings $appSettings

    Write-Host ""
    Write-Host "Publishing $CustomizationName to $($definition.Name) ($websiteRoot)..." -ForegroundColor Cyan
    Write-Host "Expected URL(s): $($definition.UrlLabels -join ', ')" -ForegroundColor DarkGray

    foreach ($warning in $parallelWarnings) {
        Write-Warning "$($definition.Name): $warning"
    }

    try {
        Invoke-PxCli -WebsiteRoot $websiteRoot -Arguments @(
            "/method", "UploadCustomization",
            "/path", $packagePath,
            "/name", $CustomizationName,
            "/replace"
        )

        $publishArguments = @(
            "/method", "PublishCustomization",
            "/name", $CustomizationName
        )

        if ($MergePublishedProjects) {
            $publishArguments += "/merge"
        }
        if ($SkipPreviouslyExecutedDbScripts) {
            $publishArguments += "/skipPreviouslyExecutedDbScripts"
        }

        Invoke-PxCli -WebsiteRoot $websiteRoot -Arguments $publishArguments

        $publishResults.Add([pscustomobject]@{
            Target = $definition.Name
            WebsiteRoot = $websiteRoot
            Urls = ($definition.UrlLabels -join ", ")
            Status = "Published"
        })
    }
    catch {
        $diagnosticsPath = Write-BindingDiagnostics -WebsiteRoot $websiteRoot -InstanceName $definition.Name
        Start-DnSpyDiagnostics -WebsiteRoot $websiteRoot
        throw "Publish failed for '$($definition.Name)'. Diagnostics were written to '$diagnosticsPath'. dnSpy.Console diagnostics were generated for assembly inspection. $($_.Exception.Message)"
    }
}

if ($publishResults.Count -gt 0) {
    foreach ($result in $publishResults) {
        Ensure-ModernUiBundle -WebsiteRoot $result.WebsiteRoot -AppSettings $appSettingsByTarget[$result.Target] | Out-Null
    }
}

Write-Host ""
Write-Host "Publish completed successfully." -ForegroundColor Green
$publishResults | Format-Table -AutoSize
