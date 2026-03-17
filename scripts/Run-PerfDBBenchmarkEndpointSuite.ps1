param(
    [string[]]$Instances = @("PerfPG", "PerfMySQL", "PerfSQL"),
    [string]$BaseHost = "http://localhost",
    [string]$Username = "",
    [string]$Password = "",
    [string]$Tenant = "",
    [string]$Branch = "",
    [string]$Locale = "en-US",
    [string]$EndpointName = "PerfDBBenchmark",
    [string]$EndpointVersion = "26.100.001",
    [int]$SetupID = 1,
    [int]$NumberOfRecords = 5000,
    [int]$Iterations = 3,
    [int]$BatchSize = 100,
    [int]$MaxThreads = 4,
    [switch]$UseRecommendedSettings,
    [string[]]$IncludeTests = @(),
    [string[]]$ExcludeTests = @(),
    [int]$PollIntervalSeconds = 2,
    [int]$RequestStartTimeoutSeconds = 30,
    [int]$ActionTimeoutMinutes = 30,
    [switch]$StopOnFailure,
    [switch]$OpenReport,
    [switch]$ClearExistingData,
    [switch]$GenerateReportOnly,
    [switch]$AllowInsecureSsl,
    [string]$ReportsDirectory = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$defaultReportsDirectory = Join-Path $repoRoot "artifacts\benchmark-reports"
$reportsDirectory = if ([string]::IsNullOrWhiteSpace($ReportsDirectory)) { $defaultReportsDirectory } else { $ReportsDirectory }
$runStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$htmlReportPath = Join-Path $reportsDirectory "PerfDBBenchmark-$runStamp.html"
$jsonReportPath = Join-Path $reportsDirectory "PerfDBBenchmark-$runStamp.json"

$legacyServerCertificateCallback = $null
if ($AllowInsecureSsl) {
    $legacyServerCertificateCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

function Get-PlainTextPassword {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProvidedPassword
    )

    if (-not [string]::IsNullOrWhiteSpace($ProvidedPassword)) {
        return $ProvidedPassword
    }

    $securePassword = Read-Host -Prompt "Acumatica password" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Resolve-Username {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProvidedUsername
    )

    if (-not [string]::IsNullOrWhiteSpace($ProvidedUsername)) {
        return $ProvidedUsername
    }

    return Read-Host -Prompt "Acumatica username"
}

function Get-InstanceDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Instance,
        [Parameter(Mandatory = $true)]
        [string]$DefaultBaseHost
    )

    if ($Instance -match '^https?://') {
        $uri = [Uri]$Instance
        $displayName = $uri.Segments[$uri.Segments.Length - 1].TrimEnd('/')
        if ([string]::IsNullOrWhiteSpace($displayName)) {
            $displayName = $uri.Host
        }

        return [pscustomobject]@{
            InputName = $Instance
            DisplayName = $displayName
            CandidateUrls = @($Instance.TrimEnd('/'))
        }
    }

    switch ($Instance.ToLowerInvariant()) {
        "perfmysql" {
            return [pscustomobject]@{
                InputName = $Instance
                DisplayName = "PerfMySQL"
                CandidateUrls = @(
                    ($DefaultBaseHost.TrimEnd('/') + "/PerfMySQL"),
                    ($DefaultBaseHost.TrimEnd('/') + "/PerfrMySQL")
                )
            }
        }
        "perfrmysql" {
            return [pscustomobject]@{
                InputName = $Instance
                DisplayName = "PerfrMySQL"
                CandidateUrls = @(
                    ($DefaultBaseHost.TrimEnd('/') + "/PerfrMySQL"),
                    ($DefaultBaseHost.TrimEnd('/') + "/PerfMySQL")
                )
            }
        }
        "perfsql" {
            return [pscustomobject]@{
                InputName = $Instance
                DisplayName = "PerfSQL"
                CandidateUrls = @(
                    ($DefaultBaseHost.TrimEnd('/') + "/PerfSQL"),
                    ($DefaultBaseHost.TrimEnd('/') + "/PerfrSQL")
                )
            }
        }
        "perfrsql" {
            return [pscustomobject]@{
                InputName = $Instance
                DisplayName = "PerfrSQL"
                CandidateUrls = @(
                    ($DefaultBaseHost.TrimEnd('/') + "/PerfrSQL"),
                    ($DefaultBaseHost.TrimEnd('/') + "/PerfSQL")
                )
            }
        }
        default {
            return [pscustomobject]@{
                InputName = $Instance
                DisplayName = $Instance
                CandidateUrls = @(($DefaultBaseHost.TrimEnd('/') + "/" + $Instance.Trim('/')))
            }
        }
    }
}

function Get-ResponseContentText {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.WebException]$Exception
    )

    if ($null -eq $Exception.Response) {
        return $Exception.Message
    }

    $stream = $Exception.Response.GetResponseStream()
    if ($null -eq $stream) {
        return $Exception.Message
    }

    $reader = [System.IO.StreamReader]::new($stream)
    try {
        return $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Invoke-AcumaticaRequest {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("GET", "POST", "PUT")]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [Parameter(Mandatory = $true)]
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [AllowNull()]
        $Body = $null
    )

    $parameters = @{
        Method = $Method
        Uri = $Uri
        WebSession = $Session
        Headers = @{ Accept = "application/json" }
        UseBasicParsing = $true
        ErrorAction = "Stop"
    }

    if ($null -ne $Body) {
        $parameters["ContentType"] = "application/json"
        $parameters["Body"] = $Body | ConvertTo-Json -Depth 20
    }

    $maxAttempts = 1
    if ($Method -eq "GET" -or $Method -eq "PUT" -or $Uri.EndsWith("/entity/auth/login", [System.StringComparison]::OrdinalIgnoreCase) -or $Uri.EndsWith("/entity/auth/logout", [System.StringComparison]::OrdinalIgnoreCase)) {
        $maxAttempts = 4
    }

    $response = $null
    $lastErrorMessage = $null
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $response = Invoke-WebRequest @parameters
            break
        }
        catch [System.Net.WebException] {
            $content = Get-ResponseContentText -Exception $_.Exception
            $lastErrorMessage = "HTTP $Method $Uri failed. $content"
            if ($attempt -ge $maxAttempts) {
                throw $lastErrorMessage
            }

            Start-Sleep -Seconds ([Math]::Min(8, $attempt * 2))
        }
    }

    if ($null -eq $response) {
        if ([string]::IsNullOrWhiteSpace([string]$lastErrorMessage)) {
            throw "HTTP $Method $Uri failed."
        }

        throw $lastErrorMessage
    }

    $json = $null
    if (-not [string]::IsNullOrWhiteSpace($response.Content)) {
        try {
            $json = $response.Content | ConvertFrom-Json
        }
        catch {
        }
    }

    return [pscustomobject]@{
        StatusCode = [int]$response.StatusCode
        Headers = $response.Headers
        Content = [string]$response.Content
        Json = $json
    }
}

function Connect-AcumaticaInstance {
    param(
        [Parameter(Mandatory = $true)]
        $InstanceDefinition,
        [Parameter(Mandatory = $true)]
        [string]$ResolvedUsername,
        [Parameter(Mandatory = $true)]
        [string]$ResolvedPassword,
        [string]$TenantName,
        [string]$BranchId,
        [string]$UserLocale
    )

    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($candidateUrl in $InstanceDefinition.CandidateUrls) {
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        $loginBody = @{
            name = $ResolvedUsername
            password = $ResolvedPassword
        }

        if (-not [string]::IsNullOrWhiteSpace($TenantName)) {
            $loginBody["tenant"] = $TenantName
        }
        if (-not [string]::IsNullOrWhiteSpace($BranchId)) {
            $loginBody["branch"] = $BranchId
        }
        if (-not [string]::IsNullOrWhiteSpace($UserLocale)) {
            $loginBody["locale"] = $UserLocale
        }

        try {
            Invoke-AcumaticaRequest -Method POST -Uri ($candidateUrl + "/entity/auth/login") -Session $session -Body $loginBody | Out-Null
            return [pscustomobject]@{
                DisplayName = $InstanceDefinition.DisplayName
                BaseUrl = $candidateUrl
                Session = $session
            }
        }
        catch {
            $errors.Add("$candidateUrl -> $($_.Exception.Message)")
        }
    }

    throw "Unable to authenticate to instance '$($InstanceDefinition.DisplayName)'. Attempts: $($errors -join ' | ')"
}

function Disconnect-AcumaticaInstance {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session
    )

    try {
        Invoke-AcumaticaRequest -Method POST -Uri ($BaseUrl + "/entity/auth/logout") -Session $Session | Out-Null
    }
    catch {
    }
}

function Get-EntityRootUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl
    )

    return ($BaseUrl + "/entity/" + $EndpointName + "/" + $EndpointVersion)
}

function Get-FirstRecord {
    param(
        [AllowNull()]
        $Json
    )

    if ($null -eq $Json) {
        return $null
    }

    if ($Json -is [System.Array]) {
        return @($Json) | Select-Object -First 1
    }

    return $Json
}

function Get-RecordFieldValue {
    param(
        [AllowNull()]
        $Record,
        [Parameter(Mandatory = $true)]
        [string]$FieldName
    )

    if ($null -eq $Record) {
        return $null
    }

    $property = $Record.PSObject.Properties[$FieldName]
    if ($null -eq $property) {
        return $null
    }

    $value = $property.Value
    if ($null -eq $value) {
        return $null
    }

    if ($value -is [string] -or $value -is [ValueType]) {
        return $value
    }

    if ($value -is [System.Array]) {
        return $value
    }

    if ($value.PSObject.Properties.Name -contains "value") {
        return $value.value
    }

    return $value
}

function Get-RecordDetailRows {
    param(
        [AllowNull()]
        $Record,
        [Parameter(Mandatory = $true)]
        [string]$FieldName
    )

    $detail = Get-RecordFieldValue -Record $Record -FieldName $FieldName
    if ($null -eq $detail) {
        return @()
    }

    if ($detail -is [System.Array]) {
        return @($detail)
    }

    return @($detail)
}

function Convert-ToNullableInt {
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    return [int]$Value
}

function Convert-ToNullableDateTime {
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    return [DateTime]$Value
}

function Convert-ToNullableGuid {
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    return [Guid]$Value
}

function Format-Duration {
    param(
        [AllowNull()]
        [double]$Milliseconds
    )

    if ($null -eq $Milliseconds) {
        return "n/a"
    }

    $duration = [TimeSpan]::FromMilliseconds([double]$Milliseconds)
    if ($duration.TotalHours -ge 1) {
        return $duration.ToString("hh\:mm\:ss")
    }

    if ($duration.TotalMinutes -ge 1) {
        return $duration.ToString("mm\:ss")
    }

    if ($duration.TotalSeconds -ge 1) {
        return ("{0:0.##} sec" -f $duration.TotalSeconds)
    }

    return ("{0:0} ms" -f $duration.TotalMilliseconds)
}

function Get-BenchmarkControl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [string[]]$Expand = @()
    )

    $queryParts = @('$top=1')
    if ($Expand.Count -gt 0) {
        $queryParts += ('$expand=' + ($Expand -join ','))
    }

    $uri = (Get-EntityRootUrl -BaseUrl $BaseUrl) + "/BenchmarkControl?" + ($queryParts -join "&")
    $response = Invoke-AcumaticaRequest -Method GET -Uri $uri -Session $Session
    $record = Get-FirstRecord -Json $response.Json
    if ($null -eq $record) {
        throw "BenchmarkControl was not returned from $uri"
    }

    return $record
}

function Get-BenchmarkResults {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [int]$Top = 25
    )

    $uri = (Get-EntityRootUrl -BaseUrl $BaseUrl) + "/BenchmarkResult?`$top=$Top"
    $response = Invoke-AcumaticaRequest -Method GET -Uri $uri -Session $Session
    if ($null -eq $response.Json) {
        return @()
    }

    if ($response.Json -is [System.Array]) {
        return @($response.Json)
    }

    return @($response.Json)
}

function Get-ControlIdentity {
    param(
        [Parameter(Mandatory = $true)]
        $ControlRecord,
        [Parameter(Mandatory = $true)]
        [int]$ControlSetupID
    )

    $identity = @{
        SetupID = @{
            value = $ControlSetupID
        }
    }

    $idValue = Get-RecordFieldValue -Record $ControlRecord -FieldName "id"
    if (-not [string]::IsNullOrWhiteSpace([string]$idValue)) {
        $identity["id"] = [string]$idValue
    }

    return $identity
}

function Invoke-ControlAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [Parameter(Mandatory = $true)]
        [string]$ActionName,
        [Parameter(Mandatory = $true)]
        $ControlIdentity
    )

    $uri = (Get-EntityRootUrl -BaseUrl $BaseUrl) + "/BenchmarkControl/" + $ActionName
    $body = @{
        entity = $ControlIdentity
    }

    return Invoke-AcumaticaRequest -Method POST -Uri $uri -Session $Session -Body $body
}

function Wait-ForBenchmarkDataClear {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [Parameter(Mandatory = $true)]
        [string]$InstanceLabel,
        [int]$TimeoutSeconds = 180,
        [AllowNull()]
        [string]$ActionInvocationErrorMessage
    )

    $deadlineUtc = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastPollErrorMessage = $null

    while ([DateTime]::UtcNow -lt $deadlineUtc) {
        try {
            $control = Get-BenchmarkControl -BaseUrl $BaseUrl -Session $Session
            $lastPollErrorMessage = $null
        }
        catch {
            $lastPollErrorMessage = $_.Exception.Message
            Start-Sleep -Seconds 2
            continue
        }

        $lastRequestId = Get-RecordFieldValue -Record $control -FieldName "LastRequestID"
        $lastRequestStatus = [string](Get-RecordFieldValue -Record $control -FieldName "LastRequestStatus")
        $lastRequestedTestCode = [string](Get-RecordFieldValue -Record $control -FieldName "LastRequestedTestCode")

        if ([string]::IsNullOrWhiteSpace([string]$lastRequestId) -and
            [string]::IsNullOrWhiteSpace($lastRequestStatus) -and
            [string]::IsNullOrWhiteSpace($lastRequestedTestCode)) {
            return $control
        }

        Start-Sleep -Seconds 2
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$ActionInvocationErrorMessage)) {
        throw $ActionInvocationErrorMessage
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$lastPollErrorMessage)) {
        throw $lastPollErrorMessage
    }

    throw "Timed out waiting for benchmark data cleanup on $InstanceLabel."
}

function Clear-BenchmarkData {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [Parameter(Mandatory = $true)]
        $ControlIdentity,
        [Parameter(Mandatory = $true)]
        [string]$InstanceLabel
    )

    $actionInvocationErrorMessage = $null
    try {
        Invoke-ControlAction -BaseUrl $BaseUrl -Session $Session -ActionName "ClearTestData" -ControlIdentity $ControlIdentity | Out-Null
    }
    catch {
        $actionInvocationErrorMessage = $_.Exception.Message
    }

    return Wait-ForBenchmarkDataClear -BaseUrl $BaseUrl -Session $Session -InstanceLabel $InstanceLabel -ActionInvocationErrorMessage $actionInvocationErrorMessage
}

function Update-ControlParameters {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [Parameter(Mandatory = $true)]
        $ControlIdentity,
        [Parameter(Mandatory = $true)]
        [int]$ControlSetupID,
        [Parameter(Mandatory = $true)]
        [int]$Records,
        [Parameter(Mandatory = $true)]
        [int]$IterationCount,
        [Parameter(Mandatory = $true)]
        [int]$ParallelBatch,
        [Parameter(Mandatory = $true)]
        [int]$ParallelThreads
    )

    $uri = (Get-EntityRootUrl -BaseUrl $BaseUrl) + "/BenchmarkControl"
    $body = @{
        id = $ControlIdentity["id"]
        SetupID = @{ value = $ControlSetupID }
        NumberOfRecords = @{ value = $Records }
        Iterations = @{ value = $IterationCount }
        ParallelBatchSize = @{ value = $ParallelBatch }
        ParallelMaxThreads = @{ value = $ParallelThreads }
    }

    Invoke-AcumaticaRequest -Method PUT -Uri $uri -Session $Session -Body $body | Out-Null
}

function Convert-BenchmarkCatalog {
    param(
        [Parameter(Mandatory = $true)]
        $ControlRecord
    )

    $catalogRows = Get-RecordDetailRows -Record $ControlRecord -FieldName "BenchmarkCatalog"
    $items = foreach ($row in $catalogRows) {
        [pscustomobject]@{
            TestCode = [string](Get-RecordFieldValue -Record $row -FieldName "TestCode")
            DisplayName = [string](Get-RecordFieldValue -Record $row -FieldName "DisplayName")
            ActionName = [string](Get-RecordFieldValue -Record $row -FieldName "ActionName")
            Category = [string](Get-RecordFieldValue -Record $row -FieldName "Category")
            ExecutionMode = [string](Get-RecordFieldValue -Record $row -FieldName "ExecutionMode")
            ShortDescription = [string](Get-RecordFieldValue -Record $row -FieldName "ShortDescription")
            SortOrder = Convert-ToNullableInt (Get-RecordFieldValue -Record $row -FieldName "SortOrder")
        }
    }

    return @($items | Sort-Object SortOrder, DisplayName)
}

function Get-DefaultBenchmarkCatalog {
    return @(
        [pscustomobject]@{
            TestCode = "SEQ_READ"
            DisplayName = "Sequential Read"
            ActionName = "RunSequentialRead"
            Category = "Read"
            ExecutionMode = "Sequential"
            ShortDescription = "Reads the seeded benchmark records through Acumatica BQL in a single-threaded loop."
            SortOrder = 10
        },
        [pscustomobject]@{
            TestCode = "SEQ_WRITE"
            DisplayName = "Sequential Write"
            ActionName = "RunSequentialWrite"
            Category = "Write"
            ExecutionMode = "Sequential"
            ShortDescription = "Inserts benchmark records through the Acumatica cache one batch at a time."
            SortOrder = 20
        },
        [pscustomobject]@{
            TestCode = "SEQ_DELETE"
            DisplayName = "Sequential Delete"
            ActionName = "RunSequentialDelete"
            Category = "Delete"
            ExecutionMode = "Sequential"
            ShortDescription = "Deletes prepared benchmark records sequentially to measure cleanup throughput."
            SortOrder = 30
        },
        [pscustomobject]@{
            TestCode = "SEQ_COMPLEX"
            DisplayName = "Complex BQL Join (Sequential)"
            ActionName = "RunSequentialComplexJoin"
            Category = "Complex BQL Join"
            ExecutionMode = "Sequential"
            ShortDescription = "Runs a realistic multi-table inventory BQL join sequentially for analytical workload comparison."
            SortOrder = 40
        },
        [pscustomobject]@{
            TestCode = "SEQ_PROJECTION"
            DisplayName = "PXProjection Analysis (Sequential)"
            ActionName = "RunSequentialProjection"
            Category = "PXProjection"
            ExecutionMode = "Sequential"
            ShortDescription = "Queries the benchmark PXProjection sequentially to measure analytical projection performance."
            SortOrder = 50
        },
        [pscustomobject]@{
            TestCode = "PAR_READ"
            DisplayName = "Parallel Read"
            ActionName = "RunParallelRead"
            Category = "Read"
            ExecutionMode = "Parallel"
            ShortDescription = "Splits seeded record reads across Acumatica processing workers."
            SortOrder = 60
        },
        [pscustomobject]@{
            TestCode = "PAR_WRITE"
            DisplayName = "Parallel Write"
            ActionName = "RunParallelWrite"
            Category = "Write"
            ExecutionMode = "Parallel"
            ShortDescription = "Splits record inserts across Acumatica processing workers."
            SortOrder = 70
        },
        [pscustomobject]@{
            TestCode = "PAR_DELETE"
            DisplayName = "Parallel Delete"
            ActionName = "RunParallelDelete"
            Category = "Delete"
            ExecutionMode = "Parallel"
            ShortDescription = "Splits delete work across Acumatica processing workers after seeding delete batches."
            SortOrder = 80
        },
        [pscustomobject]@{
            TestCode = "PAR_COMPLEX"
            DisplayName = "Complex BQL Join (Parallel)"
            ActionName = "RunParallelComplexJoin"
            Category = "Complex BQL Join"
            ExecutionMode = "Parallel"
            ShortDescription = "Runs the multi-table analytical BQL join in parallel windows."
            SortOrder = 90
        },
        [pscustomobject]@{
            TestCode = "PAR_PROJECTION"
            DisplayName = "PXProjection Analysis (Parallel)"
            ActionName = "RunParallelProjection"
            Category = "PXProjection"
            ExecutionMode = "Parallel"
            ShortDescription = "Runs the PXProjection analytical workload in parallel windows."
            SortOrder = 100
        }
    ) | Sort-Object SortOrder, DisplayName
}

function Test-BenchmarkMatch {
    param(
        [Parameter(Mandatory = $true)]
        $Benchmark,
        [Parameter(Mandatory = $true)]
        [string[]]$Selectors
    )

    foreach ($selector in $Selectors) {
        if ([string]::IsNullOrWhiteSpace($selector)) {
            continue
        }

        if ($Benchmark.TestCode -ieq $selector -or $Benchmark.ActionName -ieq $selector -or $Benchmark.DisplayName -ieq $selector) {
            return $true
        }
    }

    return $false
}

function Resolve-BenchmarkSelection {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Catalog,
        [string[]]$IncludedSelectors,
        [string[]]$ExcludedSelectors
    )

    $selected = @($Catalog)

    if ($IncludedSelectors.Count -gt 0) {
        $selected = @($selected | Where-Object { Test-BenchmarkMatch -Benchmark $_ -Selectors $IncludedSelectors })
    }

    if ($ExcludedSelectors.Count -gt 0) {
        $selected = @($selected | Where-Object { -not (Test-BenchmarkMatch -Benchmark $_ -Selectors $ExcludedSelectors) })
    }

    return @($selected | Sort-Object SortOrder, DisplayName)
}

function Get-LatestResultForRun {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [AllowNull()]
        [Guid]$RequestID
    )

    if ($null -eq $RequestID) {
        return $null
    }

    try {
        $rows = Get-BenchmarkResults -BaseUrl $BaseUrl -Session $Session -Top 25
    }
    catch {
        return $null
    }

    $matches = foreach ($row in $rows) {
        $runId = Convert-ToNullableGuid (Get-RecordFieldValue -Record $row -FieldName "RunID")
        if ($runId -eq $RequestID) {
            [pscustomobject]@{
                Row = $row
                CapturedAtUtc = Convert-ToNullableDateTime (Get-RecordFieldValue -Record $row -FieldName "CapturedAtUtc")
            }
        }
    }

    $latestMatch = $matches | Sort-Object CapturedAtUtc -Descending | Select-Object -First 1
    if ($null -eq $latestMatch) {
        return $null
    }

    return $latestMatch.Row
}

function Get-EstimatedRemainingMilliseconds {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        $CompletedRuns,
        [Parameter(Mandatory = $true)]
        [int]$RemainingCount,
        [AllowNull()]
        [double]$CurrentElapsedMs
    )

    if ($CompletedRuns.Count -eq 0) {
        return $null
    }

    $average = ($CompletedRuns | Measure-Object -Property DurationMs -Average).Average
    if ($null -eq $average) {
        return $null
    }

    $remaining = ($average * $RemainingCount)
    if ($null -ne $CurrentElapsedMs) {
        $remaining += $CurrentElapsedMs
    }

    return [double]$remaining
}

function Get-RunCountByStatus {
    param(
        [Parameter(Mandatory = $true)]
        $Runs,
        [Parameter(Mandatory = $true)]
        [string]$Status
    )

    $count = 0
    foreach ($run in $Runs) {
        if ($null -ne $run -and [string]$run.Status -eq $Status) {
            $count++
        }
    }

    return $count
}

function Get-RunDurationTotalMilliseconds {
    param(
        [Parameter(Mandatory = $true)]
        $Runs
    )

    $sum = 0.0
    foreach ($run in $Runs) {
        if ($null -ne $run -and $null -ne $run.DurationMs) {
            $sum += [double]$run.DurationMs
        }
    }

    return $sum
}

function Get-MaxRunDurationMilliseconds {
    param(
        [AllowNull()]
        $Runs
    )

    $max = $null
    foreach ($run in $Runs) {
        if ($null -eq $run -or $null -eq $run.DurationMs) {
            continue
        }

        $duration = [double]$run.DurationMs
        if ($null -eq $max -or $duration -gt $max) {
            $max = $duration
        }
    }

    if ($null -eq $max) {
        return 1
    }

    return $max
}

function Get-BenchmarkChartLabel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BenchmarkCode
    )

    switch ($BenchmarkCode.ToUpperInvariant()) {
        "SEQ_READ" { return "Seq Read" }
        "SEQ_WRITE" { return "Seq Write" }
        "SEQ_DELETE" { return "Seq Delete" }
        "SEQ_COMPLEX" { return "Seq Join" }
        "SEQ_PROJECTION" { return "Seq Proj" }
        "PAR_READ" { return "Par Read" }
        "PAR_WRITE" { return "Par Write" }
        "PAR_DELETE" { return "Par Delete" }
        "PAR_COMPLEX" { return "Par Join" }
        "PAR_PROJECTION" { return "Par Proj" }
        default { return $BenchmarkCode }
    }
}

function Get-FinalCoverageStatusText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstanceName,
        [Parameter(Mandatory = $true)]
        $Runs,
        [Parameter(Mandatory = $true)]
        [object[]]$Catalog
    )

    $completedLookup = @{}
    foreach ($run in $Runs) {
        if ($null -eq $run) {
            continue
        }

        if ([string]$run.InstanceName -ne $InstanceName -or [string]$run.Status -ne "Completed") {
            continue
        }

        $benchmarkCode = [string]$run.BenchmarkCode
        if ([string]::IsNullOrWhiteSpace($benchmarkCode)) {
            continue
        }

        $completedLookup[$benchmarkCode] = $true
    }

    $missingBenchmarks = New-Object System.Collections.Generic.List[string]
    $completedCount = 0
    foreach ($benchmark in $Catalog) {
        $benchmarkCode = [string]$benchmark.TestCode
        if ($completedLookup.ContainsKey($benchmarkCode)) {
            $completedCount++
        }
        else {
            $missingBenchmarks.Add([string]$benchmark.DisplayName)
        }
    }

    $totalCount = @($Catalog).Count
    if ($completedCount -ge $totalCount) {
        return "complete ($completedCount/$totalCount)"
    }

    return "$completedCount/$totalCount complete; missing " + ($missingBenchmarks -join ", ")
}

function Get-FinalizedInstanceSummaries {
    param(
        [Parameter(Mandatory = $true)]
        $InstanceSummaries,
        [Parameter(Mandatory = $true)]
        $Runs,
        [Parameter(Mandatory = $true)]
        [object[]]$Catalog
    )

    $items = foreach ($summary in @($InstanceSummaries)) {
        [pscustomobject]@{
            DisplayName = $summary.DisplayName
            BaseUrl = $summary.BaseUrl
            DatabaseType = $summary.DatabaseType
            Status = $summary.Status
            CompletedCount = $summary.CompletedCount
            FailedCount = $summary.FailedCount
            TotalDurationMs = $summary.TotalDurationMs
            PendingAnalysisStatus = $(Get-FinalCoverageStatusText -InstanceName ([string]$summary.DisplayName) -Runs $Runs -Catalog $Catalog)
            ErrorMessage = $summary.ErrorMessage
        }
    }

    return @($items)
}

function Get-LatestCompletedRunForInstanceBenchmark {
    param(
        [Parameter(Mandatory = $true)]
        $Runs,
        [Parameter(Mandatory = $true)]
        [string]$InstanceName,
        [Parameter(Mandatory = $true)]
        [string]$BenchmarkCode
    )

    $selected = $null
    foreach ($run in $Runs) {
        if ($null -eq $run) {
            continue
        }

        if ([string]$run.InstanceName -eq $InstanceName -and
            [string]$run.BenchmarkCode -eq $BenchmarkCode -and
            [string]$run.Status -eq "Completed") {
            $selected = $run
        }
    }

    return $selected
}

function Get-RadarChartPayload {
    param(
        [Parameter(Mandatory = $true)]
        $Runs,
        [Parameter(Mandatory = $true)]
        $InstanceSummaries,
        [Parameter(Mandatory = $true)]
        [object[]]$Benchmarks
    )

    $labels = New-Object System.Collections.Generic.List[string]
    foreach ($benchmark in $Benchmarks) {
        $labels.Add((Get-BenchmarkChartLabel -BenchmarkCode ([string]$benchmark.BenchmarkCode)))
    }

    $palette = @(
        @{ StrokeColor = "#2563eb"; FillColor = "rgba(37, 99, 235, 0.18)" },
        @{ StrokeColor = "#16a34a"; FillColor = "rgba(22, 163, 74, 0.18)" },
        @{ StrokeColor = "#dc2626"; FillColor = "rgba(220, 38, 38, 0.18)" },
        @{ StrokeColor = "#7c3aed"; FillColor = "rgba(124, 58, 237, 0.18)" }
    )

    $datasets = New-Object System.Collections.Generic.List[object]
    $paletteIndex = 0
    foreach ($summary in @($InstanceSummaries | Sort-Object DisplayName)) {
        $scores = New-Object System.Collections.Generic.List[double]
        foreach ($benchmark in $Benchmarks) {
            $bestDuration = $null
            foreach ($run in $Runs) {
                if ($null -eq $run -or [string]$run.BenchmarkCode -ne [string]$benchmark.BenchmarkCode -or [string]$run.Status -ne "Completed" -or $null -eq $run.DurationMs) {
                    continue
                }

                $candidateDuration = [double]$run.DurationMs
                if ($candidateDuration -le 0) {
                    continue
                }

                if ($null -eq $bestDuration -or $candidateDuration -lt $bestDuration) {
                    $bestDuration = $candidateDuration
                }
            }

            $instanceRun = Get-LatestCompletedRunForInstanceBenchmark -Runs $Runs -InstanceName ([string]$summary.DisplayName) -BenchmarkCode ([string]$benchmark.BenchmarkCode)
            if ($null -eq $instanceRun -or $null -eq $instanceRun.DurationMs -or $null -eq $bestDuration -or $bestDuration -le 0) {
                $scores.Add(0)
                continue
            }

            $score = [Math]::Round(($bestDuration / [double]$instanceRun.DurationMs) * 100, 1)
            $scores.Add($score)
        }

        $paletteEntry = $palette[$paletteIndex % $palette.Count]
        $paletteIndex++
        $datasets.Add([pscustomobject]@{
            Label = $summary.DisplayName
            DatabaseType = $summary.DatabaseType
            StrokeColor = $paletteEntry.StrokeColor
            FillColor = $paletteEntry.FillColor
            Scores = $scores.ToArray()
        })
    }

    return [pscustomobject]@{
        Labels = $labels.ToArray()
        Datasets = $datasets.ToArray()
        Note = "Spider chart uses a normalized speed score per benchmark. Outer edge is faster, and the best result for each benchmark scores 100."
    }
}

function Get-SuiteDurationFromRuns {
    param(
        [Parameter(Mandatory = $true)]
        $Runs
    )

    $startedAtUtc = $null
    $completedAtUtc = $null
    foreach ($run in $Runs) {
        if ($null -eq $run) {
            continue
        }

        if ($null -ne $run.StartedAtUtc -and ($null -eq $startedAtUtc -or $run.StartedAtUtc -lt $startedAtUtc)) {
            $startedAtUtc = $run.StartedAtUtc
        }

        if ($null -ne $run.CompletedAtUtc -and ($null -eq $completedAtUtc -or $run.CompletedAtUtc -gt $completedAtUtc)) {
            $completedAtUtc = $run.CompletedAtUtc
        }
    }

    if ($null -ne $startedAtUtc -and $null -ne $completedAtUtc -and $completedAtUtc -ge $startedAtUtc) {
        return ($completedAtUtc - $startedAtUtc).TotalMilliseconds
    }

    return Get-RunDurationTotalMilliseconds -Runs $Runs
}

function Get-InstanceSnapshotPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstanceName
    )

    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem)) {
        $instancesRoot = Join-Path $drive.Root "Instances2"
        if (-not (Test-Path -LiteralPath $instancesRoot)) {
            continue
        }

        $candidate = Get-ChildItem -Path $instancesRoot -Filter "perfdbbenchmark-results.json" -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -like ("*\" + $InstanceName + "\App_Data\PerfDBBenchmark\perfdbbenchmark-results.json") } |
            Select-Object -First 1

        if ($null -ne $candidate) {
            return $candidate.FullName
        }
    }

    throw "Could not locate perfdbbenchmark-results.json for instance $InstanceName."
}

function Load-InstanceSnapshotEnvelope {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstanceName
    )

    $snapshotPath = Get-InstanceSnapshotPath -InstanceName $InstanceName
    return (Get-Content -LiteralPath $snapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Load-PersistedBenchmarkState {
    param(
        [Parameter(Mandatory = $true)]
        $InstanceDefinitions,
        [Parameter(Mandatory = $true)]
        [string]$ResolvedUsername,
        [Parameter(Mandatory = $true)]
        [string]$ResolvedPassword,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$TenantName,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$BranchId,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$UserLocale,
        [Parameter(Mandatory = $true)]
        [int]$ControlSetupID
    )

    $catalog = @(Get-DefaultBenchmarkCatalog)
    $runResults = New-Object System.Collections.Generic.List[object]
    $instanceSummaries = New-Object System.Collections.Generic.List[object]

    foreach ($instanceDefinition in $InstanceDefinitions) {
        $connection = $null
        $instanceRunResults = New-Object System.Collections.Generic.List[object]

        try {
            $connection = Connect-AcumaticaInstance -InstanceDefinition $instanceDefinition -ResolvedUsername $ResolvedUsername -ResolvedPassword $ResolvedPassword -TenantName $TenantName -BranchId $BranchId -UserLocale $UserLocale
            $control = Get-BenchmarkControl -BaseUrl $connection.BaseUrl -Session $connection.Session
            $controlIdentity = Get-ControlIdentity -ControlRecord $control -ControlSetupID $ControlSetupID
            Invoke-ControlAction -BaseUrl $connection.BaseUrl -Session $connection.Session -ActionName "RefreshStatus" -ControlIdentity $controlIdentity | Out-Null
            $control = Get-BenchmarkControl -BaseUrl $connection.BaseUrl -Session $connection.Session

            $displayInstanceName = [string](Get-RecordFieldValue -Record $control -FieldName "CurrentInstance")
            if ([string]::IsNullOrWhiteSpace($displayInstanceName)) {
                $displayInstanceName = $instanceDefinition.DisplayName
            }

            $databaseType = [string](Get-RecordFieldValue -Record $control -FieldName "CurrentDatabase")
            $snapshotStatus = [string](Get-RecordFieldValue -Record $control -FieldName "SnapshotStatus")
            $pendingAnalysisStatus = [string](Get-RecordFieldValue -Record $control -FieldName "PendingAnalysisStatus")
            $snapshotEnvelope = Load-InstanceSnapshotEnvelope -InstanceName $displayInstanceName
            if ([string]::IsNullOrWhiteSpace($databaseType)) {
                $databaseType = [string](Get-RecordFieldValue -Record $snapshotEnvelope -FieldName "DatabaseType")
            }

            $latestByBenchmarkCode = @{}
            foreach ($row in @(Get-RecordFieldValue -Record $snapshotEnvelope -FieldName "Results")) {
                $benchmarkCode = [string](Get-RecordFieldValue -Record $row -FieldName "TestCode")
                if ([string]::IsNullOrWhiteSpace($benchmarkCode)) {
                    continue
                }

                $capturedAtUtc = Convert-ToNullableDateTime (Get-RecordFieldValue -Record $row -FieldName "CapturedAtUtc")
                if (-not $latestByBenchmarkCode.ContainsKey($benchmarkCode) -or $capturedAtUtc -gt $latestByBenchmarkCode[$benchmarkCode].CapturedAtUtc) {
                    $latestByBenchmarkCode[$benchmarkCode] = [pscustomobject]@{
                        Row = $row
                        CapturedAtUtc = $capturedAtUtc
                    }
                }
            }

            foreach ($benchmark in $catalog) {
                $benchmarkCode = [string]$benchmark.TestCode
                if (-not $latestByBenchmarkCode.ContainsKey($benchmarkCode)) {
                    continue
                }

                $resultRow = $latestByBenchmarkCode[$benchmarkCode].Row
                $durationMs = Convert-ToNullableInt (Get-RecordFieldValue -Record $resultRow -FieldName "ElapsedMs")
                $completedAtUtc = Convert-ToNullableDateTime (Get-RecordFieldValue -Record $resultRow -FieldName "CapturedAtUtc")
                $startedAtUtc = $null
                if ($null -ne $completedAtUtc -and $null -ne $durationMs) {
                    $startedAtUtc = $completedAtUtc.AddMilliseconds(-1 * [double]$durationMs)
                }

                $runResult = New-RunResult `
                    -InstanceName $displayInstanceName `
                    -BaseUrl $connection.BaseUrl `
                    -DatabaseType $databaseType `
                    -Benchmark $benchmark `
                    -Status "Completed" `
                    -RequestID $benchmarkCode `
                    -DurationMs $durationMs `
                    -StartedAtUtc $startedAtUtc `
                    -CompletedAtUtc $completedAtUtc `
                    -Message ([string](Get-RecordFieldValue -Record $resultRow -FieldName "Notes")) `
                    -Records (Convert-ToNullableInt (Get-RecordFieldValue -Record $resultRow -FieldName "RecordsCount")) `
                    -IterationCount (Convert-ToNullableInt (Get-RecordFieldValue -Record $resultRow -FieldName "Iterations")) `
                    -ParallelBatch (Convert-ToNullableInt (Get-RecordFieldValue -Record $resultRow -FieldName "BatchSize")) `
                    -ParallelThreads (Convert-ToNullableInt (Get-RecordFieldValue -Record $resultRow -FieldName "MaxThreads")) `
                    -SnapshotStatus $snapshotStatus `
                    -PendingAnalysisStatus $pendingAnalysisStatus

                $runResults.Add($runResult)
                $instanceRunResults.Add($runResult)
            }

            $instanceStatus = if ((Get-RunCountByStatus -Runs $instanceRunResults -Status "Completed") -eq @($catalog).Count) {
                "Completed"
            }
            elseif ($instanceRunResults.Count -gt 0) {
                "CompletedWithGaps"
            }
            else {
                "NotRun"
            }

            $instanceSummaries.Add([pscustomobject]@{
                DisplayName = $displayInstanceName
                BaseUrl = $connection.BaseUrl
                DatabaseType = $databaseType
                Status = $instanceStatus
                CompletedCount = $(Get-RunCountByStatus -Runs $instanceRunResults -Status "Completed")
                FailedCount = 0
                TotalDurationMs = $(Get-RunDurationTotalMilliseconds -Runs $instanceRunResults)
                PendingAnalysisStatus = $pendingAnalysisStatus
                ErrorMessage = ""
            })
        }
        catch {
            $instanceSummaries.Add([pscustomobject]@{
                DisplayName = $instanceDefinition.DisplayName
                BaseUrl = if ($null -ne $connection) { $connection.BaseUrl } else { ($instanceDefinition.CandidateUrls | Select-Object -First 1) }
                DatabaseType = ""
                Status = "Failed"
                CompletedCount = $(Get-RunCountByStatus -Runs $instanceRunResults -Status "Completed")
                FailedCount = 0
                TotalDurationMs = $(Get-RunDurationTotalMilliseconds -Runs $instanceRunResults)
                PendingAnalysisStatus = ""
                ErrorMessage = $_.Exception.Message
            })
        }
        finally {
            if ($null -ne $connection) {
                Disconnect-AcumaticaInstance -BaseUrl $connection.BaseUrl -Session $connection.Session
            }
        }
    }

    return [pscustomobject]@{
        InstanceSummaries = $instanceSummaries.ToArray()
        Runs = $runResults.ToArray()
        TotalSuiteDurationMs = Get-SuiteDurationFromRuns -Runs $runResults
    }
}

function Write-RunResultLine {
    param(
        [Parameter(Mandatory = $true)]
        $RunResult,
        [Parameter(Mandatory = $true)]
        [double]$ScaleMaxMs
    )

    $barWidth = 24
    $durationMs = if ($null -eq $RunResult.DurationMs) { 0 } else { [double]$RunResult.DurationMs }
    $filled = if ($ScaleMaxMs -le 0) { 0 } else { [Math]::Min($barWidth, [int][Math]::Round(($durationMs / $ScaleMaxMs) * $barWidth)) }
    $bar = ("#" * $filled).PadRight($barWidth, ".")
    $statusText = $RunResult.Status.ToUpperInvariant().PadRight(9)
    $line = "{0,-10} | {1,-31} | {2,-9} | {3,9} | {4}" -f $RunResult.InstanceName, $RunResult.BenchmarkName, $statusText, (Format-Duration -Milliseconds $RunResult.DurationMs), $bar

    switch ($RunResult.Status) {
        "Completed" { Write-Host $line -ForegroundColor Green }
        "Failed" { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line -ForegroundColor Yellow }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$RunResult.Message)) {
        Write-Host ("  " + $RunResult.Message) -ForegroundColor DarkGray
    }
}

function Write-InstanceBanner {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    Write-Host ""
    Write-Host ("=" * 90) -ForegroundColor DarkCyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ("=" * 90) -ForegroundColor DarkCyan
}

function Wait-ForBenchmarkExecution {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [Parameter(Mandatory = $true)]
        $Benchmark,
        [Parameter(Mandatory = $true)]
        [DateTime]$InvocationStartedUtc,
        [Parameter(Mandatory = $true)]
        [int]$ControlSetupID,
        [Parameter(Mandatory = $true)]
        [int]$StartTimeoutSeconds,
        [Parameter(Mandatory = $true)]
        [int]$TimeoutMinutes,
        [Parameter(Mandatory = $true)]
        [int]$IntervalSeconds,
        [Parameter(Mandatory = $true)]
        [int]$OverallRunIndex,
        [Parameter(Mandatory = $true)]
        [int]$OverallRunCount,
        [Parameter(Mandatory = $true)]
        [int]$RemainingRunCount,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        $CompletedRuns,
        [Parameter(Mandatory = $true)]
        [string]$InstanceLabel,
        [AllowNull()]
        [string]$ActionInvocationErrorMessage
    )

    $startDeadlineUtc = $InvocationStartedUtc.AddSeconds($StartTimeoutSeconds)
    $completionDeadlineUtc = $InvocationStartedUtc.AddMinutes($TimeoutMinutes)
    $requestId = $null
    $latestControl = $null
    $phase = "Waiting for long operation to start"
    $lastPollErrorMessage = $null

    while ([DateTime]::UtcNow -lt $completionDeadlineUtc) {
        try {
            $latestControl = Get-BenchmarkControl -BaseUrl $BaseUrl -Session $Session
            $lastPollErrorMessage = $null
        }
        catch {
            $lastPollErrorMessage = $_.Exception.Message
            $phase = "Retrying after endpoint read failure"
            Start-Sleep -Seconds $IntervalSeconds
            continue
        }

        $lastRequestStatus = [string](Get-RecordFieldValue -Record $latestControl -FieldName "LastRequestStatus")
        $lastRequestedTestCode = [string](Get-RecordFieldValue -Record $latestControl -FieldName "LastRequestedTestCode")
        $lastStartedAtUtc = Convert-ToNullableDateTime (Get-RecordFieldValue -Record $latestControl -FieldName "LastRequestStartedAtUtc")
        $lastRequestId = Convert-ToNullableGuid (Get-RecordFieldValue -Record $latestControl -FieldName "LastRequestID")
        $currentElapsedMs = ([DateTime]::UtcNow - $InvocationStartedUtc).TotalMilliseconds
        $estimatedRemainingMs = Get-EstimatedRemainingMilliseconds -CompletedRuns $CompletedRuns -RemainingCount $RemainingRunCount -CurrentElapsedMs $currentElapsedMs

        $overallPercent = 0
        if ($OverallRunCount -gt 0) {
            $overallPercent = [Math]::Min(99, [int][Math]::Round((($OverallRunIndex - 1) / [double]$OverallRunCount) * 100))
        }

        $statusLine = "{0} | {1} | elapsed {2}" -f $InstanceLabel, $Benchmark.DisplayName, (Format-Duration -Milliseconds $currentElapsedMs)
        if ($null -ne $estimatedRemainingMs) {
            $statusLine += " | ETA " + (Format-Duration -Milliseconds $estimatedRemainingMs)
        }

        Write-Progress -Id 1 -Activity "PerfDB benchmark suite" -Status $statusLine -PercentComplete $overallPercent
        Write-Progress -Id 2 -ParentId 1 -Activity $Benchmark.DisplayName -Status $phase -PercentComplete 0

        if ($null -eq $requestId) {
            $matchingStart = ($lastRequestedTestCode -eq $Benchmark.TestCode) -and ($null -ne $lastStartedAtUtc) -and ($lastStartedAtUtc -ge $InvocationStartedUtc.AddSeconds(-5))
            if ($matchingStart -and $null -ne $lastRequestId) {
                $requestId = $lastRequestId
                $phase = "Running request $requestId"
            }
            elseif ([DateTime]::UtcNow -gt $startDeadlineUtc) {
                if (-not [string]::IsNullOrWhiteSpace([string]$ActionInvocationErrorMessage)) {
                    throw $ActionInvocationErrorMessage
                }

                if (-not [string]::IsNullOrWhiteSpace([string]$lastPollErrorMessage)) {
                    throw $lastPollErrorMessage
                }

                throw "Timed out waiting for benchmark '$($Benchmark.DisplayName)' to start on $InstanceLabel."
            }
        }
        else {
            $statusMatchesRequest = ($lastRequestId -eq $requestId)
            if ($statusMatchesRequest -and $lastRequestStatus -eq "Completed") {
                $resultRow = Get-LatestResultForRun -BaseUrl $BaseUrl -Session $Session -RequestID $requestId
                return [pscustomobject]@{
                    Control = $latestControl
                    RequestID = $requestId
                    ResultRow = $resultRow
                }
            }

            if ($statusMatchesRequest -and $lastRequestStatus -eq "Failed") {
                $message = [string](Get-RecordFieldValue -Record $latestControl -FieldName "LastRequestMessage")
                throw "Benchmark '$($Benchmark.DisplayName)' failed on $InstanceLabel. $message"
            }
        }

        Start-Sleep -Seconds $IntervalSeconds
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$lastPollErrorMessage)) {
        throw $lastPollErrorMessage
    }

    throw "Timed out waiting for benchmark '$($Benchmark.DisplayName)' to complete on $InstanceLabel."
}

function New-RunResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstanceName,
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [string]$DatabaseType,
        [Parameter(Mandatory = $true)]
        $Benchmark,
        [Parameter(Mandatory = $true)]
        [string]$Status,
        [AllowNull()]
        $RequestID,
        [AllowNull()]
        [double]$DurationMs,
        [AllowNull()]
        [DateTime]$StartedAtUtc,
        [AllowNull()]
        [DateTime]$CompletedAtUtc,
        [AllowNull()]
        [string]$Message,
        [AllowNull()]
        [int]$Records,
        [AllowNull()]
        [int]$IterationCount,
        [AllowNull()]
        [int]$ParallelBatch,
        [AllowNull()]
        [int]$ParallelThreads,
        [AllowNull()]
        [string]$SnapshotStatus,
        [AllowNull()]
        [string]$PendingAnalysisStatus
    )

    return [pscustomobject]@{
        InstanceName = $InstanceName
        BaseUrl = $BaseUrl
        DatabaseType = $DatabaseType
        BenchmarkCode = $Benchmark.TestCode
        BenchmarkName = $Benchmark.DisplayName
        ActionName = $Benchmark.ActionName
        Category = $Benchmark.Category
        ExecutionMode = $Benchmark.ExecutionMode
        Status = $Status
        RequestID = $RequestID
        DurationMs = $DurationMs
        StartedAtUtc = $StartedAtUtc
        CompletedAtUtc = $CompletedAtUtc
        Message = $Message
        NumberOfRecords = $Records
        Iterations = $IterationCount
        BatchSize = $ParallelBatch
        MaxThreads = $ParallelThreads
        SnapshotStatus = $SnapshotStatus
        PendingAnalysisStatus = $PendingAnalysisStatus
    }
}

function Get-EncodedHtml {
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) {
        return ""
    }

    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Write-HtmlReport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        $Payload
    )

    $runs = @($Payload.Runs)
    $instanceSummaries = @($Payload.InstanceSummaries)
    $benchmarks = @($runs | Group-Object BenchmarkCode | ForEach-Object { $_.Group[0] } | Sort-Object BenchmarkName)
    $instances = @($instanceSummaries | Sort-Object DisplayName)
    $maxDurationMs = Get-MaxRunDurationMilliseconds -Runs ($runs | Where-Object { $_.Status -eq "Completed" -and $null -ne $_.DurationMs })
    $radarPayload = Get-RadarChartPayload -Runs $runs -InstanceSummaries $instances -Benchmarks $benchmarks

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine("<!DOCTYPE html>")
    [void]$builder.AppendLine("<html lang='en'>")
    [void]$builder.AppendLine("<head>")
    [void]$builder.AppendLine("<meta charset='utf-8' />")
    [void]$builder.AppendLine("<title>PerfDBBenchmark Endpoint Run</title>")
    [void]$builder.AppendLine("<style>")
    [void]$builder.AppendLine("body { font-family: Arial, sans-serif; margin: 24px; color: #1f2937; background: #f7fafc; }")
    [void]$builder.AppendLine("h1, h2 { margin-bottom: 8px; }")
    [void]$builder.AppendLine(".muted { color: #6b7280; }")
    [void]$builder.AppendLine(".cards { display: flex; gap: 16px; flex-wrap: wrap; margin: 16px 0 24px 0; }")
    [void]$builder.AppendLine(".card { background: white; border-radius: 10px; padding: 16px; min-width: 180px; box-shadow: 0 1px 4px rgba(15, 23, 42, 0.08); }")
    [void]$builder.AppendLine(".metric { font-size: 28px; font-weight: bold; color: #111827; }")
    [void]$builder.AppendLine("table { width: 100%; border-collapse: collapse; background: white; margin-bottom: 24px; }")
    [void]$builder.AppendLine("th, td { border: 1px solid #e5e7eb; padding: 10px; text-align: left; vertical-align: top; }")
    [void]$builder.AppendLine("th { background: #eff6ff; }")
    [void]$builder.AppendLine(".ok { color: #166534; font-weight: bold; }")
    [void]$builder.AppendLine(".fail { color: #991b1b; font-weight: bold; }")
    [void]$builder.AppendLine(".warn { color: #92400e; font-weight: bold; }")
    [void]$builder.AppendLine(".bar { width: 220px; height: 12px; border-radius: 6px; background: #e5e7eb; overflow: hidden; margin-top: 6px; }")
    [void]$builder.AppendLine(".bar > span { display: block; height: 12px; background: linear-gradient(90deg, #2563eb, #60a5fa); }")
    [void]$builder.AppendLine(".grid-note { font-size: 12px; color: #6b7280; }")
    [void]$builder.AppendLine(".chart-shell { background: white; border-radius: 10px; padding: 16px; box-shadow: 0 1px 4px rgba(15, 23, 42, 0.08); margin-bottom: 24px; }")
    [void]$builder.AppendLine("</style>")
    [void]$builder.AppendLine("</head>")
    [void]$builder.AppendLine("<body>")
    [void]$builder.AppendLine("<h1>PerfDBBenchmark Endpoint Run</h1>")
    [void]$builder.AppendLine("<div class='muted'>Generated " + (Get-EncodedHtml $Payload.GeneratedAtLocal) + " | Endpoint " + (Get-EncodedHtml ($Payload.Settings.EndpointName + " " + $Payload.Settings.EndpointVersion)) + "</div>")
    [void]$builder.AppendLine("<div class='cards'>")
    [void]$builder.AppendLine("<div class='card'><div>Total suite time</div><div class='metric'>" + (Get-EncodedHtml (Format-Duration -Milliseconds $Payload.TotalSuiteDurationMs)) + "</div></div>")
    [void]$builder.AppendLine("<div class='card'><div>Completed benchmarks</div><div class='metric'>" + (Get-EncodedHtml $Payload.CompletedCount) + "</div></div>")
    [void]$builder.AppendLine("<div class='card'><div>Failed benchmarks</div><div class='metric'>" + (Get-EncodedHtml $Payload.FailedCount) + "</div></div>")
    [void]$builder.AppendLine("<div class='card'><div>Instances</div><div class='metric'>" + (Get-EncodedHtml $instanceSummaries.Count) + "</div></div>")
    [void]$builder.AppendLine("</div>")

    [void]$builder.AppendLine("<h2>Instance Totals</h2>")
    [void]$builder.AppendLine("<table>")
    [void]$builder.AppendLine("<thead><tr><th>Instance</th><th>Database</th><th>Status</th><th>Completed</th><th>Failed</th><th>Total duration</th><th>Final coverage</th></tr></thead>")
    [void]$builder.AppendLine("<tbody>")
    foreach ($summary in $instances) {
        $cssClass = if ($summary.Status -eq "Completed") { "ok" } elseif ($summary.Status -eq "Failed") { "fail" } else { "warn" }
        [void]$builder.AppendLine("<tr>")
        [void]$builder.AppendLine("<td>" + (Get-EncodedHtml $summary.DisplayName) + "</td>")
        [void]$builder.AppendLine("<td>" + (Get-EncodedHtml $summary.DatabaseType) + "</td>")
        [void]$builder.AppendLine("<td class='" + $cssClass + "'>" + (Get-EncodedHtml $summary.Status) + "</td>")
        [void]$builder.AppendLine("<td>" + (Get-EncodedHtml $summary.CompletedCount) + "</td>")
        [void]$builder.AppendLine("<td>" + (Get-EncodedHtml $summary.FailedCount) + "</td>")
        [void]$builder.AppendLine("<td>" + (Get-EncodedHtml (Format-Duration -Milliseconds $summary.TotalDurationMs)) + "</td>")
        [void]$builder.AppendLine("<td>" + (Get-EncodedHtml $summary.PendingAnalysisStatus) + "</td>")
        [void]$builder.AppendLine("</tr>")
        if (-not [string]::IsNullOrWhiteSpace([string]$summary.ErrorMessage)) {
            [void]$builder.AppendLine("<tr><td colspan='7' class='grid-note'>" + (Get-EncodedHtml $summary.ErrorMessage) + "</td></tr>")
        }
    }
    [void]$builder.AppendLine("</tbody></table>")

    if (@($radarPayload.Datasets).Count -gt 0 -and @($radarPayload.Labels).Count -gt 2) {
        [void]$builder.AppendLine("<h2>Spider Chart</h2>")
        [void]$builder.AppendLine("<div class='chart-shell'>")
        [void]$builder.AppendLine("<canvas id='radarChart' width='1100' height='780'></canvas>")
        [void]$builder.AppendLine("<div class='grid-note'>" + (Get-EncodedHtml $radarPayload.Note) + "</div>")
        [void]$builder.AppendLine("</div>")
    }

    [void]$builder.AppendLine("<h2>Benchmark Matrix</h2>")
    [void]$builder.AppendLine("<table>")
    [void]$builder.AppendLine("<thead><tr><th>Benchmark</th>")
    foreach ($summary in $instances) {
        [void]$builder.AppendLine("<th>" + (Get-EncodedHtml $summary.DisplayName) + "</th>")
    }
    [void]$builder.AppendLine("</tr></thead>")
    [void]$builder.AppendLine("<tbody>")
    foreach ($benchmark in $benchmarks) {
        [void]$builder.AppendLine("<tr>")
        [void]$builder.AppendLine("<td><strong>" + (Get-EncodedHtml $benchmark.BenchmarkName) + "</strong><div class='grid-note'>" + (Get-EncodedHtml $benchmark.Category + " / " + $benchmark.ExecutionMode) + "</div></td>")
        foreach ($summary in $instances) {
            $run = $runs | Where-Object { $_.InstanceName -eq $summary.DisplayName -and $_.BenchmarkCode -eq $benchmark.BenchmarkCode } | Select-Object -Last 1
            if ($null -eq $run) {
                [void]$builder.AppendLine("<td class='warn'>not run</td>")
                continue
            }

            $cssClass = if ($run.Status -eq "Completed") { "ok" } elseif ($run.Status -eq "Failed") { "fail" } else { "warn" }
            $barPercent = 0
            if ($null -ne $run.DurationMs -and $maxDurationMs -gt 0) {
                $barPercent = [Math]::Max(4, [int][Math]::Round(($run.DurationMs / [double]$maxDurationMs) * 100))
            }

            [void]$builder.AppendLine("<td>")
            [void]$builder.AppendLine("<div class='" + $cssClass + "'>" + (Get-EncodedHtml $run.Status) + "</div>")
            [void]$builder.AppendLine("<div>" + (Get-EncodedHtml (Format-Duration -Milliseconds $run.DurationMs)) + "</div>")
            if ($run.Status -eq "Completed") {
                [void]$builder.AppendLine("<div class='bar'><span style='width:" + $barPercent + "%'></span></div>")
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$run.Message)) {
                [void]$builder.AppendLine("<div class='grid-note'>" + (Get-EncodedHtml $run.Message) + "</div>")
            }
            [void]$builder.AppendLine("</td>")
        }
        [void]$builder.AppendLine("</tr>")
    }
    [void]$builder.AppendLine("</tbody></table>")

    [void]$builder.AppendLine("<h2>Detailed Runs</h2>")
    [void]$builder.AppendLine("<table>")
    [void]$builder.AppendLine("<thead><tr><th>Instance</th><th>Benchmark</th><th>Status</th><th>Duration</th><th>Started</th><th>Completed</th><th>Message</th></tr></thead>")
    [void]$builder.AppendLine("<tbody>")
    foreach ($run in ($runs | Sort-Object InstanceName, BenchmarkName)) {
        $cssClass = if ($run.Status -eq "Completed") { "ok" } elseif ($run.Status -eq "Failed") { "fail" } else { "warn" }
        [void]$builder.AppendLine("<tr>")
        [void]$builder.AppendLine("<td>" + (Get-EncodedHtml $run.InstanceName) + "</td>")
        [void]$builder.AppendLine("<td>" + (Get-EncodedHtml $run.BenchmarkName) + "</td>")
        [void]$builder.AppendLine("<td class='" + $cssClass + "'>" + (Get-EncodedHtml $run.Status) + "</td>")
        [void]$builder.AppendLine("<td>" + (Get-EncodedHtml (Format-Duration -Milliseconds $run.DurationMs)) + "</td>")
        [void]$builder.AppendLine("<td>" + (Get-EncodedHtml $run.StartedAtUtc) + "</td>")
        [void]$builder.AppendLine("<td>" + (Get-EncodedHtml $run.CompletedAtUtc) + "</td>")
        [void]$builder.AppendLine("<td>" + (Get-EncodedHtml $run.Message) + "</td>")
        [void]$builder.AppendLine("</tr>")
    }
    [void]$builder.AppendLine("</tbody></table>")
    if (@($radarPayload.Datasets).Count -gt 0 -and @($radarPayload.Labels).Count -gt 2) {
        $radarJson = ($radarPayload | ConvertTo-Json -Depth 8 -Compress) -replace "</", "<\/"
        [void]$builder.AppendLine("<script>")
        [void]$builder.AppendLine("const radarPayload = " + $radarJson + ";")
        [void]$builder.AppendLine("(function () {")
        [void]$builder.AppendLine("  const canvas = document.getElementById('radarChart');")
        [void]$builder.AppendLine("  if (!canvas || !canvas.getContext) return;")
        [void]$builder.AppendLine("  const ctx = canvas.getContext('2d');")
        [void]$builder.AppendLine("  const width = canvas.width;")
        [void]$builder.AppendLine("  const height = canvas.height;")
        [void]$builder.AppendLine("  const centerX = width * 0.38;")
        [void]$builder.AppendLine("  const centerY = height * 0.5;")
        [void]$builder.AppendLine("  const radius = Math.min(width, height) * 0.28;")
        [void]$builder.AppendLine("  const labelRadius = radius + 34;")
        [void]$builder.AppendLine("  const labels = radarPayload.Labels || [];")
        [void]$builder.AppendLine("  const datasets = radarPayload.Datasets || [];")
        [void]$builder.AppendLine("  const count = labels.length;")
        [void]$builder.AppendLine("  if (count < 3) return;")
        [void]$builder.AppendLine("  function getAngle(index) { return (-Math.PI / 2) + ((Math.PI * 2 * index) / count); }")
        [void]$builder.AppendLine("  function getPoint(index, value, multiplier) {")
        [void]$builder.AppendLine("    const angle = getAngle(index);")
        [void]$builder.AppendLine("    const distance = (value / 100) * multiplier;")
        [void]$builder.AppendLine("    return { x: centerX + Math.cos(angle) * distance, y: centerY + Math.sin(angle) * distance };")
        [void]$builder.AppendLine("  }")
        [void]$builder.AppendLine("  function drawPolygon(multiplier, strokeStyle) {")
        [void]$builder.AppendLine("    ctx.beginPath();")
        [void]$builder.AppendLine("    for (let i = 0; i < count; i++) {")
        [void]$builder.AppendLine("      const point = getPoint(i, 100, multiplier);")
        [void]$builder.AppendLine("      if (i === 0) ctx.moveTo(point.x, point.y); else ctx.lineTo(point.x, point.y);")
        [void]$builder.AppendLine("    }")
        [void]$builder.AppendLine("    ctx.closePath();")
        [void]$builder.AppendLine("    ctx.strokeStyle = strokeStyle;")
        [void]$builder.AppendLine("    ctx.stroke();")
        [void]$builder.AppendLine("  }")
        [void]$builder.AppendLine("  ctx.clearRect(0, 0, width, height);")
        [void]$builder.AppendLine("  ctx.lineWidth = 1;")
        [void]$builder.AppendLine("  ctx.font = '12px Arial';")
        [void]$builder.AppendLine("  ctx.fillStyle = '#334155';")
        [void]$builder.AppendLine("  [25, 50, 75, 100].forEach(level => {")
        [void]$builder.AppendLine("    drawPolygon(radius * (level / 100), '#dbe3ee');")
        [void]$builder.AppendLine("    ctx.fillText(level.toString(), centerX + 6, centerY - (radius * (level / 100)) + 12);")
        [void]$builder.AppendLine("  });")
        [void]$builder.AppendLine("  for (let i = 0; i < count; i++) {")
        [void]$builder.AppendLine("    const axisPoint = getPoint(i, 100, radius);")
        [void]$builder.AppendLine("    ctx.beginPath();")
        [void]$builder.AppendLine("    ctx.moveTo(centerX, centerY);")
        [void]$builder.AppendLine("    ctx.lineTo(axisPoint.x, axisPoint.y);")
        [void]$builder.AppendLine("    ctx.strokeStyle = '#cbd5e1';")
        [void]$builder.AppendLine("    ctx.stroke();")
        [void]$builder.AppendLine("    const labelPoint = getPoint(i, 100, labelRadius);")
        [void]$builder.AppendLine("    ctx.textAlign = labelPoint.x < centerX - 6 ? 'right' : (labelPoint.x > centerX + 6 ? 'left' : 'center');")
        [void]$builder.AppendLine("    ctx.textBaseline = labelPoint.y < centerY - 6 ? 'bottom' : (labelPoint.y > centerY + 6 ? 'top' : 'middle');")
        [void]$builder.AppendLine("    ctx.fillText(labels[i], labelPoint.x, labelPoint.y);")
        [void]$builder.AppendLine("  }")
        [void]$builder.AppendLine("  datasets.forEach(dataset => {")
        [void]$builder.AppendLine("    const values = dataset.Scores || [];")
        [void]$builder.AppendLine("    ctx.beginPath();")
        [void]$builder.AppendLine("    for (let i = 0; i < count; i++) {")
        [void]$builder.AppendLine("      const point = getPoint(i, values[i] || 0, radius);")
        [void]$builder.AppendLine("      if (i === 0) ctx.moveTo(point.x, point.y); else ctx.lineTo(point.x, point.y);")
        [void]$builder.AppendLine("    }")
        [void]$builder.AppendLine("    ctx.closePath();")
        [void]$builder.AppendLine("    ctx.fillStyle = dataset.FillColor;")
        [void]$builder.AppendLine("    ctx.strokeStyle = dataset.StrokeColor;")
        [void]$builder.AppendLine("    ctx.lineWidth = 2;")
        [void]$builder.AppendLine("    ctx.fill();")
        [void]$builder.AppendLine("    ctx.stroke();")
        [void]$builder.AppendLine("    for (let i = 0; i < count; i++) {")
        [void]$builder.AppendLine("      const point = getPoint(i, values[i] || 0, radius);")
        [void]$builder.AppendLine("      ctx.beginPath();")
        [void]$builder.AppendLine("      ctx.arc(point.x, point.y, 3, 0, Math.PI * 2);")
        [void]$builder.AppendLine("      ctx.fillStyle = dataset.StrokeColor;")
        [void]$builder.AppendLine("      ctx.fill();")
        [void]$builder.AppendLine("    }")
        [void]$builder.AppendLine("  });")
        [void]$builder.AppendLine("  const legendX = width * 0.73;")
        [void]$builder.AppendLine("  let legendY = 48;")
        [void]$builder.AppendLine("  ctx.textAlign = 'left';")
        [void]$builder.AppendLine("  ctx.textBaseline = 'middle';")
        [void]$builder.AppendLine("  ctx.font = '13px Arial';")
        [void]$builder.AppendLine("  datasets.forEach(dataset => {")
        [void]$builder.AppendLine("    ctx.fillStyle = dataset.FillColor;")
        [void]$builder.AppendLine("    ctx.strokeStyle = dataset.StrokeColor;")
        [void]$builder.AppendLine("    ctx.lineWidth = 2;")
        [void]$builder.AppendLine("    ctx.fillRect(legendX, legendY - 7, 18, 14);")
        [void]$builder.AppendLine("    ctx.strokeRect(legendX, legendY - 7, 18, 14);")
        [void]$builder.AppendLine("    ctx.fillStyle = '#111827';")
        [void]$builder.AppendLine("    const suffix = dataset.DatabaseType ? ' (' + dataset.DatabaseType + ')' : '';")
        [void]$builder.AppendLine("    ctx.fillText(dataset.Label + suffix, legendX + 28, legendY);")
        [void]$builder.AppendLine("    legendY += 28;")
        [void]$builder.AppendLine("  });")
        [void]$builder.AppendLine("})();")
        [void]$builder.AppendLine("</script>")
    }
    [void]$builder.AppendLine("</body></html>")

    [System.IO.File]::WriteAllText($Path, $builder.ToString(), [System.Text.UTF8Encoding]::new($false))
}

try {
    $resolvedUsername = Resolve-Username -ProvidedUsername $Username
    $resolvedPassword = Get-PlainTextPassword -ProvidedPassword $Password

    New-Item -Path $reportsDirectory -ItemType Directory -Force | Out-Null

    $instanceDefinitions = @(
        foreach ($instance in $Instances) {
            Get-InstanceDefinition -Instance $instance -DefaultBaseHost $BaseHost
        }
    )

    $suiteStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $runResults = New-Object System.Collections.Generic.List[object]
    $completedRuns = New-Object System.Collections.Generic.List[object]
    $instanceSummaries = New-Object System.Collections.Generic.List[object]
    $shouldAbort = $false
    $totalRunCount = 0
    $totalSuiteDurationMs = 0

    if ($GenerateReportOnly) {
        $persistedState = Load-PersistedBenchmarkState -InstanceDefinitions $instanceDefinitions -ResolvedUsername $resolvedUsername -ResolvedPassword $resolvedPassword -TenantName $Tenant -BranchId $Branch -UserLocale $Locale -ControlSetupID $SetupID
        foreach ($run in @($persistedState.Runs)) {
            $runResults.Add($run)
        }
        foreach ($summary in @($persistedState.InstanceSummaries)) {
            $instanceSummaries.Add($summary)
        }

        $suiteStopwatch.Stop()
        $totalSuiteDurationMs = $persistedState.TotalSuiteDurationMs
        Write-Progress -Id 1 -Activity "PerfDB benchmark suite" -Completed
    }
    elseif (-not $shouldAbort) {
        $overallRunIndex = 0

        foreach ($instanceDefinition in $instanceDefinitions) {
            Write-InstanceBanner -Title ("Running benchmark suite on " + $instanceDefinition.DisplayName)
            $connection = $null
            $instanceRunResults = New-Object System.Collections.Generic.List[object]

            try {
                $connection = Connect-AcumaticaInstance -InstanceDefinition $instanceDefinition -ResolvedUsername $resolvedUsername -ResolvedPassword $resolvedPassword -TenantName $Tenant -BranchId $Branch -UserLocale $Locale
                $control = Get-BenchmarkControl -BaseUrl $connection.BaseUrl -Session $connection.Session
                $controlIdentity = Get-ControlIdentity -ControlRecord $control -ControlSetupID $SetupID

                if ($ClearExistingData) {
                    Clear-BenchmarkData -BaseUrl $connection.BaseUrl -Session $connection.Session -ControlIdentity $controlIdentity -InstanceLabel $instanceDefinition.DisplayName | Out-Null
                    $control = Get-BenchmarkControl -BaseUrl $connection.BaseUrl -Session $connection.Session
                    $controlIdentity = Get-ControlIdentity -ControlRecord $control -ControlSetupID $SetupID
                }

                Invoke-ControlAction -BaseUrl $connection.BaseUrl -Session $connection.Session -ActionName "RefreshStatus" -ControlIdentity $controlIdentity | Out-Null

                if ($UseRecommendedSettings) {
                    Invoke-ControlAction -BaseUrl $connection.BaseUrl -Session $connection.Session -ActionName "ApplyRecommendedSettings" -ControlIdentity $controlIdentity | Out-Null
                }
                else {
                    Update-ControlParameters -BaseUrl $connection.BaseUrl -Session $connection.Session -ControlIdentity $controlIdentity -ControlSetupID $SetupID -Records $NumberOfRecords -IterationCount $Iterations -ParallelBatch $BatchSize -ParallelThreads $MaxThreads
                }

                $preparedControl = Get-BenchmarkControl -BaseUrl $connection.BaseUrl -Session $connection.Session
                $catalog = @(Resolve-BenchmarkSelection -Catalog (Get-DefaultBenchmarkCatalog) -IncludedSelectors $IncludeTests -ExcludedSelectors $ExcludeTests)
                $catalogCount = @($catalog).Count
                if ($catalogCount -eq 0) {
                    throw "No benchmarks matched the requested selection on $($instanceDefinition.DisplayName)."
                }

                if ($totalRunCount -eq 0) {
                    $totalRunCount = $catalogCount * $instanceDefinitions.Count
                }

                $displayInstanceName = [string](Get-RecordFieldValue -Record $preparedControl -FieldName "CurrentInstance")
                if ([string]::IsNullOrWhiteSpace($displayInstanceName)) {
                    $displayInstanceName = $instanceDefinition.DisplayName
                }

                $databaseType = [string](Get-RecordFieldValue -Record $preparedControl -FieldName "CurrentDatabase")
                $effectiveRecords = Convert-ToNullableInt (Get-RecordFieldValue -Record $preparedControl -FieldName "NumberOfRecords")
                $effectiveIterations = Convert-ToNullableInt (Get-RecordFieldValue -Record $preparedControl -FieldName "Iterations")
                $effectiveBatchSize = Convert-ToNullableInt (Get-RecordFieldValue -Record $preparedControl -FieldName "ParallelBatchSize")
                $effectiveMaxThreads = Convert-ToNullableInt (Get-RecordFieldValue -Record $preparedControl -FieldName "ParallelMaxThreads")

                Write-Host ("Target URL : " + $connection.BaseUrl) -ForegroundColor DarkGray
                Write-Host ("Database   : " + $databaseType) -ForegroundColor DarkGray
                Write-Host ("Parameters : records={0}, iterations={1}, batch={2}, threads={3}" -f $effectiveRecords, $effectiveIterations, $effectiveBatchSize, $effectiveMaxThreads) -ForegroundColor DarkGray
                Write-Host ("Benchmarks : " + (($catalog | ForEach-Object { $_.DisplayName }) -join ", ")) -ForegroundColor DarkGray

                foreach ($benchmark in $catalog) {
                    $overallRunIndex++
                    $remainingRunCount = [Math]::Max(0, $totalRunCount - $overallRunIndex)
                    Write-Host ""
                    Write-Host ("[{0}/{1}] {2} -> {3}" -f $overallRunIndex, $totalRunCount, $displayInstanceName, $benchmark.DisplayName) -ForegroundColor Cyan
                    Write-Host ("  " + $benchmark.ShortDescription) -ForegroundColor DarkGray

                    $invocationStartedUtc = [DateTime]::UtcNow

                    try {
                        $actionInvocationErrorMessage = $null
                        try {
                            Invoke-ControlAction -BaseUrl $connection.BaseUrl -Session $connection.Session -ActionName $benchmark.ActionName -ControlIdentity $controlIdentity | Out-Null
                        }
                        catch {
                            $actionInvocationErrorMessage = $_.Exception.Message
                        }

                        $executionResult = Wait-ForBenchmarkExecution -BaseUrl $connection.BaseUrl -Session $connection.Session -Benchmark $benchmark -InvocationStartedUtc $invocationStartedUtc -ControlSetupID $SetupID -StartTimeoutSeconds $RequestStartTimeoutSeconds -TimeoutMinutes $ActionTimeoutMinutes -IntervalSeconds $PollIntervalSeconds -OverallRunIndex $overallRunIndex -OverallRunCount $totalRunCount -RemainingRunCount $remainingRunCount -CompletedRuns $completedRuns -InstanceLabel $displayInstanceName -ActionInvocationErrorMessage $actionInvocationErrorMessage

                        $finalControl = $executionResult.Control
                        $resultRow = $executionResult.ResultRow
                        $requestId = $executionResult.RequestID
                        $durationMs = Convert-ToNullableInt (Get-RecordFieldValue -Record $resultRow -FieldName "ElapsedMs")
                        if ($null -eq $durationMs) {
                            $durationMs = Convert-ToNullableInt (Get-RecordFieldValue -Record $finalControl -FieldName "LastRequestElapsedMs")
                        }

                        $startedAtUtc = Convert-ToNullableDateTime (Get-RecordFieldValue -Record $finalControl -FieldName "LastRequestStartedAtUtc")
                        $completedAtUtc = Convert-ToNullableDateTime (Get-RecordFieldValue -Record $finalControl -FieldName "LastRequestCompletedAtUtc")
                        $message = [string](Get-RecordFieldValue -Record $finalControl -FieldName "LastRequestMessage")
                        $snapshotStatus = [string](Get-RecordFieldValue -Record $finalControl -FieldName "SnapshotStatus")
                        $pendingAnalysisStatus = [string](Get-RecordFieldValue -Record $finalControl -FieldName "PendingAnalysisStatus")

                        $runResult = New-RunResult -InstanceName $displayInstanceName -BaseUrl $connection.BaseUrl -DatabaseType $databaseType -Benchmark $benchmark -Status "Completed" -RequestID $requestId -DurationMs $durationMs -StartedAtUtc $startedAtUtc -CompletedAtUtc $completedAtUtc -Message $message -Records $effectiveRecords -IterationCount $effectiveIterations -ParallelBatch $effectiveBatchSize -ParallelThreads $effectiveMaxThreads -SnapshotStatus $snapshotStatus -PendingAnalysisStatus $pendingAnalysisStatus
                        $runResults.Add($runResult)
                        $instanceRunResults.Add($runResult)
                        $completedRuns.Add($runResult)
                        $scaleMaxMs = Get-MaxRunDurationMilliseconds -Runs $completedRuns
                        Write-RunResultLine -RunResult $runResult -ScaleMaxMs $scaleMaxMs
                    }
                    catch {
                        $failedControl = $null
                        try {
                            $failedControl = Get-BenchmarkControl -BaseUrl $connection.BaseUrl -Session $connection.Session
                        }
                        catch {
                        }

                        $failureMessage = $_.Exception.Message
                        $failedRunResult = New-RunResult -InstanceName $displayInstanceName -BaseUrl $connection.BaseUrl -DatabaseType $databaseType -Benchmark $benchmark -Status "Failed" -RequestID $null -DurationMs (([DateTime]::UtcNow - $invocationStartedUtc).TotalMilliseconds) -StartedAtUtc $invocationStartedUtc -CompletedAtUtc ([DateTime]::UtcNow) -Message $failureMessage -Records $effectiveRecords -IterationCount $effectiveIterations -ParallelBatch $effectiveBatchSize -ParallelThreads $effectiveMaxThreads -SnapshotStatus ([string](Get-RecordFieldValue -Record $failedControl -FieldName "SnapshotStatus")) -PendingAnalysisStatus ([string](Get-RecordFieldValue -Record $failedControl -FieldName "PendingAnalysisStatus"))
                        $runResults.Add($failedRunResult)
                        $instanceRunResults.Add($failedRunResult)
                        $scaleMaxMs = Get-MaxRunDurationMilliseconds -Runs ($runResults | Where-Object { $null -ne $_.DurationMs })
                        Write-RunResultLine -RunResult $failedRunResult -ScaleMaxMs $scaleMaxMs

                        if ($StopOnFailure) {
                            throw
                        }
                    }
                }

                Invoke-ControlAction -BaseUrl $connection.BaseUrl -Session $connection.Session -ActionName "RefreshStatus" -ControlIdentity $controlIdentity | Out-Null
                $finalInstanceControl = Get-BenchmarkControl -BaseUrl $connection.BaseUrl -Session $connection.Session
                $instanceSummaries.Add([pscustomobject]@{
                    DisplayName = $displayInstanceName
                    BaseUrl = $connection.BaseUrl
                    DatabaseType = $databaseType
                    Status = if ((Get-RunCountByStatus -Runs $instanceRunResults -Status "Failed") -gt 0) { "CompletedWithFailures" } else { "Completed" }
                    CompletedCount = $(Get-RunCountByStatus -Runs $instanceRunResults -Status "Completed")
                    FailedCount = $(Get-RunCountByStatus -Runs $instanceRunResults -Status "Failed")
                    TotalDurationMs = $(Get-RunDurationTotalMilliseconds -Runs $instanceRunResults)
                    PendingAnalysisStatus = [string](Get-RecordFieldValue -Record $finalInstanceControl -FieldName "PendingAnalysisStatus")
                    ErrorMessage = ""
                })
            }
            catch {
                $instanceSummaries.Add([pscustomobject]@{
                    DisplayName = $instanceDefinition.DisplayName
                    BaseUrl = if ($null -ne $connection) { $connection.BaseUrl } else { ($instanceDefinition.CandidateUrls | Select-Object -First 1) }
                    DatabaseType = ""
                    Status = "Failed"
                    CompletedCount = $(Get-RunCountByStatus -Runs $instanceRunResults -Status "Completed")
                    FailedCount = $(Get-RunCountByStatus -Runs $instanceRunResults -Status "Failed")
                    TotalDurationMs = $(Get-RunDurationTotalMilliseconds -Runs $instanceRunResults)
                    PendingAnalysisStatus = ""
                    ErrorMessage = $_.Exception.Message
                })

                if ($StopOnFailure) {
                    $shouldAbort = $true
                    break
                }
            }
            finally {
                Write-Progress -Id 2 -Activity "Benchmark execution" -Completed
                if ($null -ne $connection) {
                    Disconnect-AcumaticaInstance -BaseUrl $connection.BaseUrl -Session $connection.Session
                }
            }
        }
    }

    if (-not $GenerateReportOnly) {
        $suiteStopwatch.Stop()
        $totalSuiteDurationMs = $suiteStopwatch.Elapsed.TotalMilliseconds
        Write-Progress -Id 1 -Activity "PerfDB benchmark suite" -Completed
    }
    $finalCatalog = @(Get-DefaultBenchmarkCatalog)
    $finalInstanceSummaries = @(
        foreach ($summary in $instanceSummaries) {
            $completedLookup = @{}
            foreach ($run in $runResults) {
                if ($null -eq $run) {
                    continue
                }

                if ([string]$run.InstanceName -ne [string]$summary.DisplayName -or [string]$run.Status -ne "Completed") {
                    continue
                }

                $benchmarkCode = [string]$run.BenchmarkCode
                if ([string]::IsNullOrWhiteSpace($benchmarkCode)) {
                    continue
                }

                $completedLookup[$benchmarkCode] = $true
            }

            $missingBenchmarks = New-Object System.Collections.Generic.List[string]
            $completedCount = 0
            foreach ($benchmark in $finalCatalog) {
                $benchmarkCode = [string]$benchmark.TestCode
                if ($completedLookup.ContainsKey($benchmarkCode)) {
                    $completedCount++
                }
                else {
                    $missingBenchmarks.Add([string]$benchmark.DisplayName)
                }
            }

            $coverageText = if ($completedCount -ge @($finalCatalog).Count) {
                "complete ($completedCount/$(@($finalCatalog).Count))"
            }
            else {
                "$completedCount/$(@($finalCatalog).Count) complete; missing " + ($missingBenchmarks -join ", ")
            }

            [pscustomobject]@{
                DisplayName = $summary.DisplayName
                BaseUrl = $summary.BaseUrl
                DatabaseType = $summary.DatabaseType
                Status = $summary.Status
                CompletedCount = $summary.CompletedCount
                FailedCount = $summary.FailedCount
                TotalDurationMs = $summary.TotalDurationMs
                PendingAnalysisStatus = $coverageText
                ErrorMessage = $summary.ErrorMessage
            }
        }
    )

    $payload = [pscustomobject]@{
        GeneratedAtUtc = [DateTime]::UtcNow
        GeneratedAtLocal = $(Get-Date)
        TotalSuiteDurationMs = $totalSuiteDurationMs
        CompletedCount = $(Get-RunCountByStatus -Runs $runResults -Status "Completed")
        FailedCount = $(Get-RunCountByStatus -Runs $runResults -Status "Failed")
        Settings = [pscustomobject]@{
            EndpointName = $EndpointName
            EndpointVersion = $EndpointVersion
            Instances = $Instances
            SetupID = $SetupID
            UseRecommendedSettings = [bool]$UseRecommendedSettings
            NumberOfRecords = $NumberOfRecords
            Iterations = $Iterations
            BatchSize = $BatchSize
            MaxThreads = $MaxThreads
            ClearExistingData = [bool]$ClearExistingData
            PollIntervalSeconds = $PollIntervalSeconds
            ActionTimeoutMinutes = $ActionTimeoutMinutes
        }
        InstanceSummaries = $finalInstanceSummaries
        Runs = $runResults.ToArray()
    }

    [System.IO.File]::WriteAllText($jsonReportPath, ($payload | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
    Write-HtmlReport -Path $htmlReportPath -Payload $payload

    Write-Host ""
    Write-Host "PerfDBBenchmark endpoint suite complete." -ForegroundColor Green
    Write-Host ("HTML report : " + $htmlReportPath) -ForegroundColor Green
    Write-Host ("JSON report : " + $jsonReportPath) -ForegroundColor Green

    Write-Host ""
    Write-Host ("{0,-10} | {1,-31} | {2,-9} | {3,9}" -f "Instance", "Benchmark", "Status", "Duration") -ForegroundColor White
    Write-Host ("-" * 72) -ForegroundColor DarkGray
    $summaryScaleMaxMs = Get-MaxRunDurationMilliseconds -Runs ($runResults | Where-Object { $null -ne $_.DurationMs })
    foreach ($run in ($runResults | Sort-Object InstanceName, BenchmarkName)) {
        Write-RunResultLine -RunResult $run -ScaleMaxMs $summaryScaleMaxMs
    }

    if ($OpenReport -and (Test-Path -LiteralPath $htmlReportPath)) {
        Start-Process -FilePath $htmlReportPath
    }

    [pscustomobject]@{
        HtmlReportPath = $htmlReportPath
        JsonReportPath = $jsonReportPath
        CompletedCount = $payload.CompletedCount
        FailedCount = $payload.FailedCount
        TotalSuiteDuration = $(Format-Duration -Milliseconds $payload.TotalSuiteDurationMs)
    }
}
finally {
    if ($AllowInsecureSsl) {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $legacyServerCertificateCallback
    }
}
