<#
.SYNOPSIS
    PerfDBBenchmark campaign suite for Acumatica 2026 R2 (SPEC sections 3.9, 3.10, 5.4 and 6).

.DESCRIPTION
    Runs the benchmark campaign over the REST endpoint PerfDBBenchmark/26.200.001 on the three instances
    (PerfPG, PerfMySQL, PerfSQL) and writes the campaign JSON v2:
        artifacts\benchmark-reports\<CampaignId>\PerfDBBenchmark-<CampaignId>.json
    The file is rewritten atomically after every run, so an interrupted campaign can be resumed with the
    same -CampaignId.

    Campaign structure (SPEC section 6.7):
      blocks A -> B -> C -> D; per block the warm-up repetition R0 (discarded) and repetitions 1..N, each in
      its rotation order; test-major interleave; ENV_CAPTURE and gates G1-G7 before every repetition;
      cool-down and settle gate before every run; parameter verification (SPEC section 3.10) before every run;
      triple re-runs at the end of every block; restart, stuck-instance, login-limit and resume handling.

    -PlanOnly prints the plan and the run counts without any REST call and without credentials.
    -ReportOnly -InputJson <paths> delegates to New-PerfDBBenchmarkReport.ps1.

    Profiles: Full = 6 repetitions + R0; Quick = 2 repetitions + R0 at WorkScale 0.5 (preliminary, not publishable);
    DryRun = 1 full-size repetition, no R0 (with -WriteCalibration, -Diagnostics and -ApiReadCheck);
    Smoke = 1 repetition at WorkScale 0.1, PassesOverride 1, WarmUpPassesOverride 0, no R0.
    Block D is refused unless -BackupsVerified is given and the SPEC 6.5 backup artefacts exist.
    -EnvironmentScript none disables the pre-flight and the environment captures (default: Get-PerfEnvironment.ps1
    next to this script). List parameters also accept one comma-separated string (powershell -File callers);
    -Rotation entries use ">" between instance names, for example "PerfPG>PerfMySQL>PerfSQL".
    -PreflightAllow <regex[]> is passed to Get-PerfEnvironment -Preflight (several patterns: separate them with ";").
    At campaign start (the first block of an invocation) a pre-flight that cannot run or cannot check an engine stops
    the suite like a failed one (gate G6), unless -AllowUncheckedPreflight is given.
    With -WriteCalibration (DryRun), -CalibrationFile is the output path only; the dry run itself uses no budgets.
    Exit codes: 0 done; 1 error; 3 campaign aborted by a gate (G1/G4); 4 pre-flight failed at campaign start.

    The password is only used in memory for the REST login. It is never printed or written to disk.
    Database credentials are used only by Get-PerfEnvironment.ps1 (through --defaults-extra-file and PGPASSFILE).

.EXAMPLE
    .\scripts\Run-PerfDBBenchmarkEndpointSuite.ps1 -PlanOnly -Profile Full

.EXAMPLE
    .\scripts\Run-PerfDBBenchmarkEndpointSuite.ps1 -Profile Smoke -Blocks A,B,C -Username admin -Password $pw

.EXAMPLE
    .\scripts\Run-PerfDBBenchmarkEndpointSuite.ps1 -Profile Full -Blocks D -BackupsVerified -CampaignId $cid -CalibrationFile "$dry\calibration.json"
#>
[CmdletBinding()]
param(
    [string[]]$Instances = @("PerfPG", "PerfMySQL", "PerfSQL"),
    [string]$InstanceRoot = "D:\Instances\26.200.0334",
    [string]$BaseHost = "http://localhost",
    [string]$Username = "",
    [string]$Password = "",
    [string]$Tenant = "",
    [string]$Branch = "",
    [string]$Locale = "en-US",
    [string]$EndpointName = "PerfDBBenchmark",
    [string]$EndpointVersion = "26.200.001",
    [int]$SetupID = 1,

    [string]$CampaignId = "",
    [string[]]$Blocks = @("A", "B", "C", "D"),
    [ValidateSet("Full", "Quick", "DryRun", "Smoke")]
    [string]$Profile = "Full",
    [ValidateRange(1, 50)]
    [int]$Repetitions = 6,
    [switch]$NoWarmUpRepetition,
    [string[]]$Rotation = @(),
    [ValidateSet("TestMajor", "InstanceMajor")]
    [string]$Interleave = "TestMajor",
    [switch]$IncludeOptional = $true,
    [switch]$ExcludeOptional,
    [string[]]$IncludeTests = @(),
    [string[]]$ExcludeTests = @(),
    [int]$CoreRecords = 10000,
    [int]$CoreIterations = 3,
    [int]$CoreChunkSize = 250,

    [double]$SettleCpuPct = 10,
    [double]$SettleDiskMBps = 20,
    [int]$SettleWindowSec = 3,
    [int]$SettleMinWaitSec = 3,
    [int]$SettleTimeoutSec = 60,
    [double]$SettleOtherDbCpuPctOfCore = 3,
    [double]$SettleOtherDbIoMBps = 5,
    [int]$SettleTimeoutSecBCD = 90,
    [int]$CoolDownSecAfterMultiUser = 20,
    [int]$PollFastSec = 1,
    [int]$PollFastForSec = 10,
    [int]$PollSlowSec = 3,

    [string]$CalibrationFile = "",
    [switch]$WriteCalibration,
    [switch]$NoRerun,
    [switch]$Diagnostics,
    [switch]$ApiReadCheck,
    [string]$ApiReadEndpoint = "Default/26.200.001",
    [int]$ApiReadWarmUp = 5,
    [int]$ApiReadCount = 50,
    [string]$EnvironmentScript = "",
    [string]$MySqlDefaultsFile = "",
    [string]$PgPassFile = "",
    [string[]]$PreflightAllow = @(),
    [switch]$AllowUncheckedPreflight,
    [switch]$PlanOnly,
    [switch]$PlanDetail,
    [switch]$ReportOnly,
    [string[]]$InputJson = @(),
    [string]$ReportScript = "",
    [string]$BetweenBlocksCommand = "",
    [int]$BetweenBlocksTimeoutSec = 3600,
    [int]$BlockPauseSec = 120,
    [switch]$BackupsVerified,
    [string]$BackupFolder = "C:\PerfBackups",
    [string]$PsqlExe = "C:\Program Files\PostgreSQL\18\bin\psql.exe",
    [switch]$ClearExistingData,
    [int]$RequestStartTimeoutSeconds = 30,
    [int]$ActionTimeoutMinutes = 30,
    [int]$WaitLimitExtraSec = 300,
    [int]$AbortWaitSec = 120,
    [int]$LoginLimitTimeoutMinutes = 60,
    [switch]$StopOnFailure,
    [switch]$AllowInsecureSsl,
    [switch]$OpenReport,
    [string]$ReportsDirectory = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Windows PowerShell 5.1 serializes some arrays as {"value":[...],"Count":n}; removing the ETS type data fixes it.
Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue

$script:SuiteVersion = 2
$script:MethodologyVersion = "2026R2-M2"
$script:EnvCaptureCode = "ENV_CAPTURE"
$script:BlockOrder = @("A", "B", "C", "D")
$script:BlockNames = @{
    A = "Everyday screens + Reports (read-only)"
    B = "Core: bulk record work and joins"
    C = "Order entry + Many users (self-cleaning)"
    D = "Invoice release to GL (permanent; after backups)"
    G = "Environment"
}
$script:EngineProcessGroup = @{ SQLServer = "sqlservr"; MySQL = "mysqld"; PostgreSQL = "postgres" }
$script:ProfileName = $Profile

# List parameters arrive as one comma-separated string when the script is started with "powershell -File".
function Split-ListParameter {
    param([AllowNull()][string[]]$Values, [string]$Separators = ',')
    $items = foreach ($v in @($Values)) {
        if ($null -eq $v) { continue }
        foreach ($part in ([string]$v -split ("[" + [regex]::Escape($Separators) + "]"))) {
            $trimmed = $part.Trim()
            if ($trimmed -ne "") { $trimmed }
        }
    }
    return , @($items)
}
$Instances = [string[]](Split-ListParameter -Values $Instances)
$Blocks = [string[]](Split-ListParameter -Values $Blocks -Separators ', ')
$IncludeTests = [string[]](Split-ListParameter -Values $IncludeTests)
$ExcludeTests = [string[]](Split-ListParameter -Values $ExcludeTests)
$InputJson = [string[]](Split-ListParameter -Values $InputJson -Separators ';')
# Pre-flight allow patterns are regular expressions (they may contain commas): only ";" separates them.
$PreflightAllow = [string[]](Split-ListParameter -Values $PreflightAllow -Separators ';')
# Rotation entries: "PerfPG>PerfMySQL>PerfSQL"; several entries are separated by "," or "|".
$Rotation = [string[]]@(foreach ($entry in @($Rotation)) { if ([string]$entry -match '>') { foreach ($piece in (Split-ListParameter -Values @($entry) -Separators ',|')) { $piece } } elseif (-not [string]::IsNullOrWhiteSpace([string]$entry)) { [string]$entry } })
# -ExcludeOptional: the same as -IncludeOptional:$false (which powershell -File cannot pass).
if ($ExcludeOptional) { $IncludeOptional = [switch]$false }
foreach ($b in $Blocks) {
    if (@("A", "B", "C", "D") -notcontains $b.ToUpperInvariant()) { throw "-Blocks accepts A, B, C and D only (got '$b')." }
}
if (@($Instances).Count -eq 0) { throw "-Instances is empty." }

$repoRoot = Split-Path -Parent $PSScriptRoot
$defaultReportsDirectory = Join-Path $repoRoot "artifacts\benchmark-reports"
$reportsDirectory = if ([string]::IsNullOrWhiteSpace($ReportsDirectory)) { $defaultReportsDirectory } else { $ReportsDirectory }
$script:EnvironmentScriptDisabled = $false
if (-not $PSBoundParameters.ContainsKey("EnvironmentScript")) {
    $EnvironmentScript = Join-Path $PSScriptRoot "Get-PerfEnvironment.ps1"
}
elseif ($EnvironmentScript -ieq "none" -or [string]::IsNullOrWhiteSpace($EnvironmentScript)) {
    # "-EnvironmentScript none" disables the pre-flight and environment captures (an empty string cannot be passed through powershell -File).
    $EnvironmentScript = ""
    $script:EnvironmentScriptDisabled = $true
}
if ([string]::IsNullOrWhiteSpace($ReportScript)) {
    $ReportScript = Join-Path $PSScriptRoot "New-PerfDBBenchmarkReport.ps1"
}
if ([string]::IsNullOrWhiteSpace($MySqlDefaultsFile)) {
    $candidate = Join-Path $repoRoot "Exceptions\mysql-root.cnf"
    if (Test-Path -LiteralPath $candidate) { $MySqlDefaultsFile = $candidate }
}
if ([string]::IsNullOrWhiteSpace($PgPassFile)) {
    $candidate = Join-Path $repoRoot "Exceptions\pgpass.conf"
    if (Test-Path -LiteralPath $candidate) { $PgPassFile = $candidate }
}

$legacyServerCertificateCallback = $null
if ($AllowInsecureSsl) {
    $legacyServerCertificateCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

$script:LogPath = $null
$script:State = $null
$script:SuiteInstances = @()
$script:InstancesByName = @{}
$script:Catalog = @()
$script:EnvTest = $null
$script:Credential = $null
$script:CalibrationBudgets = @{}
$script:CalibrationWriteOnly = $false
$script:LastRunUserCount = 0
$script:HostCounters = $null
$script:ThermalAvailable = $true
$script:ThermalSampleSec = 15
$script:PostedRun = $null
$script:InvocationBlocks = @()
$script:BlockOutcome = [ordered]@{}

#region General helpers

function Write-SuiteLog {
    param([string]$Message, [string]$Color = "Gray")
    Write-Host $Message -ForegroundColor $Color
    if ($null -ne $script:LogPath) {
        try {
            [System.IO.File]::AppendAllText($script:LogPath, ("{0:yyyy-MM-dd HH:mm:ss} {1}{2}" -f (Get-Date), $Message, [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
        }
    }
}

function New-SuiteStop {
    param([string]$Kind, [string]$Message)
    $ex = New-Object System.Exception($Message)
    $ex.Data["SuiteStop"] = $Kind
    return $ex
}

function Get-Prop {
    param([AllowNull()]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [string] -or $Object -is [ValueType]) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { Write-Output -NoEnumerate $Object[$Name] }
        else { return $null }
        return
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    Write-Output -NoEnumerate $p.Value
}

function Set-RecordValue {
    param([Parameter(Mandatory = $true)]$Record, [string]$Name, [AllowNull()]$Value)
    if ($Record -is [System.Collections.IDictionary]) {
        $Record[$Name] = $Value
        return
    }
    $p = $Record.PSObject.Properties[$Name]
    if ($null -eq $p) {
        Add-Member -InputObject $Record -MemberType NoteProperty -Name $Name -Value $Value
    }
    else {
        $p.Value = $Value
    }
}

function Test-IsScalar {
    param([AllowNull()]$Value)
    return ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType])
}

function Find-JsonValue {
    # Breadth-first search for the first property named $Name (case-insensitive) in a parsed JSON tree.
    param([AllowNull()]$Node, [Parameter(Mandatory = $true)][string]$Name)
    if (Test-IsScalar $Node) { return $null }
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue($Node)
    $visited = 0
    while ($queue.Count -gt 0 -and $visited -lt 5000) {
        $current = $queue.Dequeue()
        $visited++
        if (Test-IsScalar $current) { continue }
        if ($current -is [System.Collections.IDictionary]) {
            foreach ($k in @($current.Keys)) {
                if ([string]$k -ieq $Name) { Write-Output -NoEnumerate $current[$k]; return }
            }
            foreach ($k in @($current.Keys)) { if (-not (Test-IsScalar $current[$k])) { $queue.Enqueue($current[$k]) } }
            continue
        }
        if ($current -is [System.Collections.IEnumerable]) {
            foreach ($item in $current) { if (-not (Test-IsScalar $item)) { $queue.Enqueue($item) } }
            continue
        }
        foreach ($p in $current.PSObject.Properties) {
            if ($p.Name -ieq $Name) { Write-Output -NoEnumerate $p.Value; return }
        }
        foreach ($p in $current.PSObject.Properties) {
            if (-not (Test-IsScalar $p.Value)) { $queue.Enqueue($p.Value) }
        }
    }
    return $null
}

function Get-JsonLeaves {
    # Flattens a parsed JSON tree into path -> scalar value.
    param([AllowNull()]$Node, [string]$Prefix = "", [System.Collections.Specialized.OrderedDictionary]$Into = $null, [int]$Depth = 0)
    if ($null -eq $Into) { $Into = [ordered]@{} }
    if ($Depth -gt 15) { return $Into }
    if (Test-IsScalar $Node) {
        if ($Prefix -ne "") { $Into[$Prefix] = $Node }
        return $Into
    }
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($k in @($Node.Keys)) {
            $path = if ($Prefix -eq "") { [string]$k } else { $Prefix + "." + [string]$k }
            [void](Get-JsonLeaves -Node $Node[$k] -Prefix $path -Into $Into -Depth ($Depth + 1))
        }
        return $Into
    }
    if ($Node -is [System.Collections.IEnumerable]) {
        $i = 0
        foreach ($item in $Node) {
            [void](Get-JsonLeaves -Node $item -Prefix ("{0}[{1}]" -f $Prefix, $i) -Into $Into -Depth ($Depth + 1))
            $i++
        }
        return $Into
    }
    foreach ($p in $Node.PSObject.Properties) {
        $path = if ($Prefix -eq "") { $p.Name } else { $Prefix + "." + $p.Name }
        [void](Get-JsonLeaves -Node $p.Value -Prefix $path -Into $Into -Depth ($Depth + 1))
    }
    return $Into
}

function Convert-ToNullableInt {
    param([AllowNull()]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    return [int][double]$Value
}

function Convert-ToNullableLong {
    param([AllowNull()]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    return [long][double]$Value
}

function Convert-ToNullableDouble {
    param([AllowNull()]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    return [double]$Value
}

function Convert-ToNullableBool {
    param([AllowNull()]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    if ($Value -is [bool]) { return $Value }
    return ([string]$Value -match '^(?i:true|1|yes)$')
}

function Convert-ToNullableDateTime {
    # Returns a UTC DateTime. Strings without an offset are treated as UTC.
    # -WallClockUtc: the value is a UTC wall-clock time that the REST layer serialized with the session's time-zone
    # offset (a DateTimeValue field stored as UTC with UseTimeZone = false, e.g. LastRequestStartedAtUtc: the 26 R2
    # serializer writes new DateTimeOffset(value, <session zone offset>)). The offset is ignored and the wall-clock
    # part is taken as UTC.
    param([AllowNull()]$Value, [switch]$WallClockUtc)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    if ($Value -is [DateTime]) { $dt = $Value; if ($WallClockUtc) { return [DateTime]::SpecifyKind($dt, [DateTimeKind]::Utc) } }
    else {
        $dto = [DateTimeOffset]::MinValue
        $text = [string]$Value
        if ($text -match '(Z|[+-]\d{2}:?\d{2})$' -and [DateTimeOffset]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dto)) {
            if ($WallClockUtc) { return [DateTime]::SpecifyKind($dto.DateTime, [DateTimeKind]::Utc) }
            return $dto.UtcDateTime
        }
        $dt = [DateTime]::Parse($text, [Globalization.CultureInfo]::InvariantCulture)
    }
    if ($dt.Kind -eq [DateTimeKind]::Local) { return $dt.ToUniversalTime() }
    return [DateTime]::SpecifyKind($dt, [DateTimeKind]::Utc)
}

function Convert-ToNullableGuid {
    param([AllowNull()]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    return [Guid]$Value
}

function Format-Duration {
    param([AllowNull()]$Milliseconds)
    if ($null -eq $Milliseconds) { return "n/a" }
    $duration = [TimeSpan]::FromMilliseconds([double]$Milliseconds)
    if ($duration.TotalHours -ge 1) { return $duration.ToString("hh\:mm\:ss") }
    if ($duration.TotalMinutes -ge 1) { return $duration.ToString("mm\:ss") }
    if ($duration.TotalSeconds -ge 1) { return ("{0:0.##} sec" -f $duration.TotalSeconds) }
    return ("{0:0.###} ms" -f $duration.TotalMilliseconds)
}

function Get-Median {
    param([double[]]$Values)
    $sorted = @($Values | Sort-Object)
    $n = $sorted.Count
    if ($n -eq 0) { return $null }
    if ($n % 2 -eq 1) { return [double]$sorted[($n - 1) / 2] }
    return ([double]$sorted[$n / 2 - 1] + [double]$sorted[$n / 2]) / 2.0
}

function Get-Average {
    param([AllowNull()][object[]]$Values)
    $list = @($Values | Where-Object { $null -ne $_ })
    if ($list.Count -eq 0) { return $null }
    return [Math]::Round((($list | Measure-Object -Average).Average), 2)
}

function Invoke-NativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string]$Arguments = "",
        [AllowNull()][string]$StdIn = $null,
        [hashtable]$Environment = @{},
        [int]$TimeoutSec = 60
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    foreach ($key in $Environment.Keys) { $psi.EnvironmentVariables[[string]$key] = [string]$Environment[$key] }
    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        if ($null -ne $StdIn) { $process.StandardInput.Write($StdIn) }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutSec * 1000)) {
            try { $process.Kill() } catch { }
            throw ("{0} did not finish within {1} s" -f [IO.Path]::GetFileName($FilePath), $TimeoutSec)
        }
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $outTask.Result; StdErr = $errTask.Result }
    }
    finally {
        $process.Dispose()
    }
}

#endregion

#region Credentials, instances and REST helpers (kept from the 26 R1 suite)

function Get-PlainTextPassword {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
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
        [AllowEmptyString()]
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

function Get-ErrorStatusCode {
    param([AllowNull()]$ErrorRecord)
    if ($null -eq $ErrorRecord) { return 0 }
    $ex = $ErrorRecord
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ex = $ErrorRecord.Exception }
    if ($null -ne $ex -and $ex.Data.Contains("StatusCode")) { return [int]$ex.Data["StatusCode"] }
    return 0
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
        TimeoutSec = 120
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
    $lastStatusCode = 0
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $response = Invoke-WebRequest @parameters
            break
        }
        catch [System.Net.WebException] {
            $content = Get-ResponseContentText -Exception $_.Exception
            $lastStatusCode = 0
            if ($null -ne $_.Exception.Response) {
                try { $lastStatusCode = [int]$_.Exception.Response.StatusCode } catch { $lastStatusCode = 0 }
            }
            # Never echo a request body (the login body holds the password); only the URI and the server's answer.
            $lastErrorMessage = "HTTP $Method $Uri failed ($lastStatusCode). $content"
            $retryable = ($lastStatusCode -eq 0 -or $lastStatusCode -ge 500 -or $lastStatusCode -eq 408 -or $lastStatusCode -eq 429)
            if ($attempt -ge $maxAttempts -or -not $retryable) {
                throw (New-HttpError -Message $lastErrorMessage -StatusCode $lastStatusCode)
            }

            Start-Sleep -Seconds ([Math]::Min(8, $attempt * 2))
        }
    }

    if ($null -eq $response) {
        if ([string]::IsNullOrWhiteSpace([string]$lastErrorMessage)) {
            throw "HTTP $Method $Uri failed."
        }

        throw (New-HttpError -Message $lastErrorMessage -StatusCode $lastStatusCode)
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

function New-HttpError {
    param([string]$Message, [int]$StatusCode)
    $ex = New-Object System.Exception($Message)
    $ex.Data["StatusCode"] = $StatusCode
    return $ex
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
        return , $value
    }

    if ($null -ne $value.PSObject.Properties["value"]) {
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
        return , @()
    }

    return , @($detail)
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

#endregion

#region Instance sessions (one REST session per instance for the whole campaign)

function Connect-SuiteInstance {
    # Logs in, retrying an "API login limit" answer with backoff up to the session time-out (SPEC 5.4 item 16).
    param([Parameter(Mandatory = $true)]$Inst)
    $deadline = [DateTime]::UtcNow.AddMinutes($LoginLimitTimeoutMinutes)
    $delay = 10
    while ($true) {
        try {
            $connection = Connect-AcumaticaInstance -InstanceDefinition $Inst.Definition -ResolvedUsername $script:Credential.User -ResolvedPassword $script:Credential.Password -TenantName $Tenant -BranchId $Branch -UserLocale $Locale
            $Inst.BaseUrl = $connection.BaseUrl
            $Inst.Session = $connection.Session
            return
        }
        catch {
            $message = $_.Exception.Message
            $isLoginLimit = $message -match '(?i)login limit|api login|maximum number of (api )?(users|logins|sessions)|too many (users|logins|sessions)|\(429\)'
            if (-not $isLoginLimit -or [DateTime]::UtcNow -ge $deadline) {
                throw
            }
            Add-SuiteEvent -Kind "LoginLimit" -Instance $Inst.Name -Detail ("login limit reached; retrying in {0} s" -f $delay)
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min(120, $delay * 2)
        }
    }
}

function Invoke-InstanceRequest {
    # One retry after re-login when the session expired (401), e.g. after an application restart.
    param(
        [Parameter(Mandatory = $true)]$Inst,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$RelativeUri,
        [AllowNull()]$Body = $null
    )
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $uri = (Get-EntityRootUrl -BaseUrl $Inst.BaseUrl) + $RelativeUri
        try {
            return (Invoke-AcumaticaRequest -Method $Method -Uri $uri -Session $Inst.Session -Body $Body)
        }
        catch {
            if ((Get-ErrorStatusCode $_) -eq 401 -and $attempt -eq 1) {
                Write-SuiteLog ("  {0}: session expired (401); logging in again" -f $Inst.Name) "DarkYellow"
                Connect-SuiteInstance -Inst $Inst
                continue
            }
            throw
        }
    }
}

function Invoke-InstanceAction {
    param([Parameter(Mandatory = $true)]$Inst, [Parameter(Mandatory = $true)][string]$ActionName)
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            return (Invoke-ControlAction -BaseUrl $Inst.BaseUrl -Session $Inst.Session -ActionName $ActionName -ControlIdentity $Inst.Identity)
        }
        catch {
            if ((Get-ErrorStatusCode $_) -eq 401 -and $attempt -eq 1) {
                Connect-SuiteInstance -Inst $Inst
                continue
            }
            throw
        }
    }
}

function Get-BenchmarkControl {
    param([Parameter(Mandatory = $true)]$Inst, [switch]$WithCatalog)
    $query = '?$top=1'
    if ($WithCatalog) { $query += '&$expand=BenchmarkCatalog' }
    $response = Invoke-InstanceRequest -Inst $Inst -Method GET -RelativeUri ("/BenchmarkControl" + $query)
    $record = Get-FirstRecord -Json $response.Json
    if ($null -eq $record) {
        throw ("BenchmarkControl was not returned by {0}" -f $Inst.Name)
    }
    return $record
}

function Get-ControlFields {
    param([AllowNull()]$Control)
    return [pscustomobject]@{
        Status = [string](Get-RecordFieldValue -Record $Control -FieldName "LastRequestStatus")
        TestCode = [string](Get-RecordFieldValue -Record $Control -FieldName "LastRequestedTestCode")
        RequestId = Convert-ToNullableGuid (Get-RecordFieldValue -Record $Control -FieldName "LastRequestID")
        StartedAtUtc = Convert-ToNullableDateTime (Get-RecordFieldValue -Record $Control -FieldName "LastRequestStartedAtUtc") -WallClockUtc
        CompletedAtUtc = Convert-ToNullableDateTime (Get-RecordFieldValue -Record $Control -FieldName "LastRequestCompletedAtUtc") -WallClockUtc
        Message = [string](Get-RecordFieldValue -Record $Control -FieldName "LastRequestMessage")
        AppStart = [string](Get-RecordFieldValue -Record $Control -FieldName "ServerAppStartUtc")
        DllSha = [string](Get-RecordFieldValue -Record $Control -FieldName "ServerDllSha256")
        Methodology = [string](Get-RecordFieldValue -Record $Control -FieldName "ServerMethodologyVersion")
        CurrentDatabase = [string](Get-RecordFieldValue -Record $Control -FieldName "CurrentDatabase")
        CurrentInstance = [string](Get-RecordFieldValue -Record $Control -FieldName "CurrentInstance")
    }
}

function Update-InstanceFromControl {
    # Tracks the server facts used by restart detection (item 7) and gate G4.
    param([Parameter(Mandatory = $true)]$Inst, [Parameter(Mandatory = $true)]$Fields)
    if (-not [string]::IsNullOrWhiteSpace($Fields.DllSha)) { $Inst.LastDllSha = $Fields.DllSha }
    if (-not [string]::IsNullOrWhiteSpace($Fields.Methodology)) { $Inst.LastMethodology = $Fields.Methodology }
}

function Test-ControlRunning {
    # True when the control row says Running for a request that is still alive. A Running row written
    # before the current application start (AppDomain) is stale: that run died with the old AppDomain.
    param([Parameter(Mandatory = $true)]$Inst, [Parameter(Mandatory = $true)]$Fields)
    if ($Fields.Status -ne "Running") { return $false }
    if (-not [string]::IsNullOrWhiteSpace($Inst.RunningRequestAppStart) -and -not [string]::IsNullOrWhiteSpace($Fields.AppStart) -and $Fields.RequestId -eq $Inst.RunningRequestId -and $Fields.AppStart -ne $Inst.RunningRequestAppStart) {
        return $false
    }
    $appStart = $null
    try { $appStart = Convert-ToNullableDateTime $Fields.AppStart } catch { $appStart = $null }
    # Both values are written by the server, so no client clock skew is involved; 1 s covers DATETIME(0) truncation.
    if ($null -ne $appStart -and $null -ne $Fields.StartedAtUtc -and $appStart -gt $Fields.StartedAtUtc.AddSeconds(1)) {
        return $false
    }
    return $true
}

function Wait-ForLongAction {
    # Acumatica answers a long-running action with 202 and a Location to poll (202 = running, 204/200 = done).
    param([Parameter(Mandatory = $true)]$Inst, [AllowNull()]$Response, [int]$TimeoutSec)
    if ($null -eq $Response -or $Response.StatusCode -ne 202) { return $true }
    $location = $null
    try { $location = [string]$Response.Headers["Location"] } catch { $location = $null }
    if ([string]::IsNullOrWhiteSpace($location)) { return $true }
    if ($location.StartsWith("/")) {
        $baseUri = [Uri]$Inst.BaseUrl
        $location = $baseUri.GetLeftPart([UriPartial]::Authority) + $location
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 2
        try {
            $r = Invoke-AcumaticaRequest -Method GET -Uri $location -Session $Inst.Session
            if ($r.StatusCode -ne 202) { return $true }
        }
        catch {
            $code = Get-ErrorStatusCode $_
            if ($code -eq 404 -or $code -eq 204) { return $true }
            throw
        }
    }
    return $false
}

function Wait-ForBenchmarkDataClear {
    param(
        [Parameter(Mandatory = $true)]$Inst,
        [int]$TimeoutSeconds = 1800,
        [AllowNull()]
        [string]$ActionInvocationErrorMessage
    )

    $deadlineUtc = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastPollErrorMessage = $null

    while ([DateTime]::UtcNow -lt $deadlineUtc) {
        try {
            $control = Get-BenchmarkControl -Inst $Inst
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
            ([string]::IsNullOrWhiteSpace($lastRequestStatus) -or $lastRequestStatus -eq "Idle") -and
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

    throw "Timed out waiting for benchmark data cleanup on $($Inst.Name)."
}

function Clear-BenchmarkData {
    # ClearTestData: removes PerfTestRecord AND PerfTestResult rows (P1/P3 only, never during a campaign).
    param([Parameter(Mandatory = $true)]$Inst)
    $actionInvocationErrorMessage = $null
    $response = $null
    try {
        $response = Invoke-InstanceAction -Inst $Inst -ActionName "ClearTestData"
    }
    catch {
        $actionInvocationErrorMessage = $_.Exception.Message
    }
    if ($null -eq $actionInvocationErrorMessage) {
        [void](Wait-ForLongAction -Inst $Inst -Response $response -TimeoutSec ($ActionTimeoutMinutes * 60))
    }
    return Wait-ForBenchmarkDataClear -Inst $Inst -TimeoutSeconds ($ActionTimeoutMinutes * 60) -ActionInvocationErrorMessage $actionInvocationErrorMessage
}

function Invoke-ClearTestRecords {
    # ClearTestRecords: deletes PerfTestRecord rows other than the two seeds and runs every leftover cleaner (SPEC 5.4 item 11).
    param([Parameter(Mandatory = $true)]$Inst)
    Write-SuiteLog ("  {0}: ClearTestRecords" -f $Inst.Name) "DarkGray"
    try {
        $fields = Get-ControlFields (Get-BenchmarkControl -Inst $Inst)
        if (Test-ControlRunning -Inst $Inst -Fields $fields) {
            Add-SuiteEvent -Kind "GateWarning" -Instance $Inst.Name -Detail "ClearTestRecords skipped: a run is in progress"
            return $false
        }
        $response = Invoke-InstanceAction -Inst $Inst -ActionName "ClearTestRecords"
        $done = Wait-ForLongAction -Inst $Inst -Response $response -TimeoutSec ($ActionTimeoutMinutes * 60)
        if (-not $done) {
            Add-SuiteEvent -Kind "GateWarning" -Instance $Inst.Name -Detail ("ClearTestRecords did not finish within {0} min" -f $ActionTimeoutMinutes)
        }
        return $done
    }
    catch {
        Add-SuiteEvent -Kind "GateWarning" -Instance $Inst.Name -Detail ("ClearTestRecords failed: " + $_.Exception.Message)
        return $false
    }
}

#endregion

#region Catalog

function Convert-CatalogRow {
    param([Parameter(Mandatory = $true)]$Row)
    $get = { param($name) Get-RecordFieldValue -Record $Row -FieldName $name }
    return [pscustomobject][ordered]@{
        TestCode = [string](& $get "TestCode")
        DisplayName = [string](& $get "DisplayName")
        ActionName = [string](& $get "ActionName")
        Category = [string](& $get "Category")
        ExecutionMode = [string](& $get "ExecutionMode")
        ShortDescription = [string](& $get "ShortDescription")
        SortOrder = Convert-ToNullableInt (& $get "SortOrder")
        Family = [string](& $get "Family")
        RunBlock = ([string](& $get "RunBlock")).ToUpperInvariant()
        ShortLabel = [string](& $get "ShortLabel")
        Question = [string](& $get "Question")
        WhatItSimulates = [string](& $get "WhatItSimulates")
        WhyItMatters = [string](& $get "WhyItMatters")
        ReaderUnit = [string](& $get "ReaderUnit")
        UserCount = Convert-ToNullableInt (& $get "UserCount")
        HeadlineKind = [string](& $get "HeadlineKind")
        HeadlineUnit = [string](& $get "HeadlineUnit")
        HigherIsBetter = Convert-ToNullableBool (& $get "HigherIsBetter")
        OpsUnit = [string](& $get "OpsUnit")
        ParityExpected = Convert-ToNullableBool (& $get "ParityExpected")
        IsDestructive = Convert-ToNullableBool (& $get "IsDestructive")
        IsOptional = Convert-ToNullableBool (& $get "IsOptional")
        ExcludeFromComparison = Convert-ToNullableBool (& $get "ExcludeFromComparison")
        LegacyTestCode = [string](& $get "LegacyTestCode")
        ScenarioVersion = Convert-ToNullableInt (& $get "ScenarioVersion")
        DefaultOpsPerPass = Convert-ToNullableInt (& $get "DefaultOpsPerPass")
        DefaultPasses = Convert-ToNullableInt (& $get "DefaultPasses")
        DefaultWarmUpPasses = Convert-ToNullableInt (& $get "DefaultWarmUpPasses")
    }
}

function Convert-BenchmarkCatalog {
    param(
        [Parameter(Mandatory = $true)]
        $ControlRecord
    )

    $catalogRows = Get-RecordDetailRows -Record $ControlRecord -FieldName "BenchmarkCatalog"
    $items = foreach ($row in $catalogRows) {
        $item = Convert-CatalogRow -Row $row
        if (-not [string]::IsNullOrWhiteSpace($item.TestCode)) { $item }
    }

    return , @($items | Sort-Object SortOrder, TestCode)
}

function New-OfflineTest {
    param([string]$Code, [int]$Sort, [string]$Label, [string]$Category, [string]$Family, [string]$Block, [int]$Users, [string]$Kind,
        [string]$ReaderUnit, [string]$OpsUnit, [int]$Ops, [int]$Passes, [int]$WarmUpPasses, [int]$WarmUpOps, [bool]$Destructive, [bool]$Optional,
        [bool]$ErrorsInvalidate, [string]$Legacy, [string]$DisplayName)
    $higher = ($Kind -eq "OpsPerMin")
    return [pscustomobject][ordered]@{
        TestCode = $Code
        DisplayName = $DisplayName
        ActionName = "RunBenchmark"
        Category = $Category
        ExecutionMode = if ($Users -gt 1) { "Parallel" } else { "Sequential" }
        ShortDescription = $null
        SortOrder = $Sort
        Family = $Family
        RunBlock = $Block
        ShortLabel = $Label
        Question = $null
        WhatItSimulates = $null
        WhyItMatters = $null
        ReaderUnit = $ReaderUnit
        UserCount = $Users
        HeadlineKind = $Kind
        HeadlineUnit = if ($Kind -eq "OpsPerMin") { "ops/min" } elseif ($Kind -eq "None") { $null } else { "ms" }
        HigherIsBetter = $higher
        OpsUnit = $OpsUnit
        ParityExpected = ($Code -ne "ENV_CAPTURE")
        IsDestructive = $Destructive
        IsOptional = $Optional
        ExcludeFromComparison = ($Family -eq "Environment")
        LegacyTestCode = $Legacy
        ScenarioVersion = 1
        DefaultOpsPerPass = $Ops
        DefaultPasses = $Passes
        DefaultWarmUpPasses = $WarmUpPasses
        DefaultWarmUpOpsPerWorker = $WarmUpOps
        ErrorsInvalidate = $ErrorsInvalidate
    }
}

function Get-DefaultBenchmarkCatalog {
    # Offline copy of SPEC section 1.1-1.2, used by -PlanOnly only. A live campaign always uses the server catalog.
    $d = [string][char]0x2013
    $one = "one job shared by 8 parallel workers"
    $list = @(
        (New-OfflineTest SCR_OPEN_SALES_ORDER 110 "Open SO" Screen Screens A 1 MedianOpMs "ms per order opened" screens 500 1 1 0 $false $false $true $null "Open a sales order"),
        (New-OfflineTest SCR_CUSTOMER_ORDER_HISTORY 120 "Cust orders" Screen Screens A 1 MedianOpMs "ms per lookup" lookups 78 2 1 0 $false $false $true $null "A customer's order history"),
        (New-OfflineTest SCR_ITEM_BUYERS 130 "Item buyers" Screen Screens A 1 MedianOpMs "ms per lookup" lookups 91 2 1 0 $false $false $true $null "Who bought this item?"),
        (New-OfflineTest SCR_CUSTOMER_SEARCH 140 "Cust search" Screen Screens A 1 MedianOpMs "ms per search" searches 100 1 1 0 $false $false $true $null "Find a customer by part of the name"),
        (New-OfflineTest RPT_SALES_BY_CUSTOMER_MONTH 210 "Sales/month" Report Reports A 1 MedianOpMs "ms per yearly report" reports 14 3 1 0 $false $false $true $null "Sales by customer and month"),
        (New-OfflineTest RPT_TRIAL_BALANCE 220 "Trial bal." Report Reports A 1 MedianOpMs "ms per period" reports 12 3 1 0 $false $false $true $null "Trial balance"),
        (New-OfflineTest RPT_GL_ACCOUNT_DETAILS 230 "Acct details" Report Reports A 1 MedianOpMs "ms per account" reports 56 2 1 0 $false $false $true $null "GL account details for a year"),
        (New-OfflineTest RPT_LARGE_LIST_PAGING 240 "Paging+count" Report Reports A 1 MedianPassMs "s per pass of 12 requests" requests 12 3 1 0 $false $false $true $null "Deep paging and counting in a 300,000-line journal"),
        (New-OfflineTest ORD_SO_ENTRY_U01 310 "SO 1u" Order OrderEntry C 1 MedianOpMs "ms per order saved" orders 60 1 0 10 $false $false $true $null "Enter sales orders $d 1 clerk"),
        (New-OfflineTest ORD_SO_ENTRY_U04 320 "SO 4u" Order ManyUsers C 4 OpsPerMin "orders per minute" orders 80 1 0 5 $false $false $false $null "Enter sales orders $d 4 clerks working non-stop"),
        (New-OfflineTest ORD_SO_ENTRY_U08 330 "SO 8u" Order ManyUsers C 8 OpsPerMin "orders per minute" orders 160 1 0 5 $false $false $false $null "Enter sales orders $d 8 clerks working non-stop"),
        (New-OfflineTest ORD_SO_ENTRY_U16 340 "SO 16u" Order ManyUsers C 16 OpsPerMin "orders per minute" orders 320 1 0 5 $false $false $false $null "Enter sales orders $d 16 clerks working non-stop"),
        (New-OfflineTest ORD_SO_HOTITEM_U04 350 "Hot 4u" Order ManyUsers C 4 OpsPerMin "orders per minute" orders 80 1 0 5 $false $false $false $null "Everyone sells the best-seller $d 4 clerks working non-stop"),
        (New-OfflineTest ORD_SO_HOTITEM_U08 360 "Hot 8u" Order ManyUsers C 8 OpsPerMin "orders per minute" orders 160 1 0 5 $false $false $false $null "Everyone sells the best-seller $d 8 clerks working non-stop"),
        (New-OfflineTest ORD_SO_HOTITEM_U16 370 "Hot 16u" Order ManyUsers C 16 OpsPerMin "orders per minute" orders 320 1 0 5 $false $false $false $null "Everyone sells the best-seller $d 16 clerks working non-stop"),
        (New-OfflineTest INV_RELEASE_TO_GL_U01 410 "Invoice 1u" Invoice InvoiceRelease D 1 MedianOpMs "ms per invoice" invoices 40 1 0 10 $true $false $true $null "Create and release invoices to the GL $d 1 person"),
        (New-OfflineTest INV_RELEASE_TO_GL_U04 420 "Invoice 4u" Invoice InvoiceRelease D 4 OpsPerMin "invoices per minute" invoices 60 1 0 3 $true $true $false $null "Create and release invoices to the GL $d 4 people working non-stop"),
        (New-OfflineTest CORE_READ_1U 510 "Load 1u" Read Core B 1 MedianPassMs "s per 10,000-record job" chunks 40 3 1 0 $false $false $true "SEQ_READ" "Load 10,000 records $d 1 worker"),
        (New-OfflineTest CORE_READ_8U 515 "Load 8u" Read Core B 8 MedianPassMs "s per 10,000-record job" chunks 40 3 1 0 $false $false $true "PAR_READ" "Load 10,000 records $d $one"),
        (New-OfflineTest CORE_INSERT_1U 520 "Insert 1u" Write Core B 1 MedianPassMs "s per 10,000-record job" chunks 40 3 1 0 $false $false $true "SEQ_WRITE" "Save 10,000 new records $d 1 worker"),
        (New-OfflineTest CORE_INSERT_8U 525 "Insert 8u" Write Core B 8 MedianPassMs "s per 10,000-record job" chunks 40 3 1 0 $false $false $true "PAR_WRITE" "Save 10,000 new records $d $one"),
        (New-OfflineTest CORE_UPDATE_1U 530 "Update 1u" Update Core B 1 MedianPassMs "s per 10,000-record job" chunks 40 3 1 0 $false $false $true "SEQ_UPDATE" "Change 10,000 records $d 1 worker"),
        (New-OfflineTest CORE_UPDATE_8U 535 "Update 8u" Update Core B 8 MedianPassMs "s per 10,000-record job" chunks 40 3 1 0 $false $false $true "PAR_UPDATE" "Change 10,000 records $d $one"),
        (New-OfflineTest CORE_DELETE_1U 540 "Delete 1u" Delete Core B 1 MedianPassMs "s per 10,000-record job" chunks 40 3 1 0 $false $false $true "SEQ_DELETE" "Delete 10,000 records $d 1 worker"),
        (New-OfflineTest CORE_DELETE_8U 545 "Delete 8u" Delete Core B 8 MedianPassMs "s per 10,000-record job" chunks 40 3 1 0 $false $false $true "PAR_DELETE" "Delete 10,000 records $d $one"),
        (New-OfflineTest CORE_JOIN_FULL_1U 550 "Join 1u" Join Core B 1 MedianPassMs "ms per list page" pages 80 3 1 0 $false $false $true "SEQ_COMPLEX" "Stock availability list, all columns $d 1 worker"),
        (New-OfflineTest CORE_JOIN_FULL_8U 555 "Join 8u" Join Core B 8 MedianPassMs "ms per list page" pages 80 3 1 0 $false $false $true "PAR_COMPLEX" "Stock availability list, all columns $d $one"),
        (New-OfflineTest CORE_JOIN_SLIM_1U 560 "Slim join 1u" SlimJoin Core B 1 MedianPassMs "ms per list page" pages 80 3 1 0 $false $false $true "SEQ_PROJECTION" "Stock availability list, only the needed columns $d 1 worker"),
        (New-OfflineTest CORE_JOIN_SLIM_8U 565 "Slim join 8u" SlimJoin Core B 8 MedianPassMs "ms per list page" pages 80 3 1 0 $false $false $true "PAR_PROJECTION" "Stock availability list, only the needed columns $d $one"),
        (New-OfflineTest ENV_CAPTURE 900 "Env" Environment Environment G 1 None $null $null 0 1 0 0 $false $false $true $null "Environment capture"),
        (New-OfflineTest ENV_WORKERS_PROBE 910 "Workers probe" Environment Environment G 16 None $null $null 16 1 0 0 $false $false $true $null "Worker probe (diagnostic)")
    )
    return , @($list | Sort-Object SortOrder)
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

        if ($Benchmark.TestCode -ieq $selector -or $Benchmark.DisplayName -ieq $selector -or $Benchmark.Family -ieq $selector -or
            (-not [string]::IsNullOrWhiteSpace([string]$Benchmark.LegacyTestCode) -and $Benchmark.LegacyTestCode -ieq $selector) -or
            (-not [string]::IsNullOrWhiteSpace([string]$Benchmark.ShortLabel) -and $Benchmark.ShortLabel -ieq $selector)) {
            return $true
        }
    }

    return $false
}

function Resolve-BenchmarkSelection {
    # Campaign tests: blocks A-D only (ENV_CAPTURE and the block G diagnostics are run separately or not at all).
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Catalog,
        [string[]]$IncludedSelectors,
        [string[]]$ExcludedSelectors
    )

    $selected = @($Catalog | Where-Object { $script:BlockOrder -contains [string]$_.RunBlock -and $_.TestCode -ne $script:EnvCaptureCode })
    if (-not $IncludeOptional) {
        $selected = @($selected | Where-Object { -not [bool]$_.IsOptional })
    }
    if (@($IncludedSelectors).Count -gt 0) {
        $selected = @($selected | Where-Object { Test-BenchmarkMatch -Benchmark $_ -Selectors $IncludedSelectors })
    }
    if (@($ExcludedSelectors).Count -gt 0) {
        $selected = @($selected | Where-Object { -not (Test-BenchmarkMatch -Benchmark $_ -Selectors $ExcludedSelectors) })
    }
    return , @($selected | Sort-Object SortOrder, TestCode)
}

function Get-EnvCaptureTest {
    param([object[]]$Catalog)
    $found = @($Catalog | Where-Object { $_.TestCode -eq $script:EnvCaptureCode })
    if ($found.Count -gt 0) { return $found[0] }
    return (New-OfflineTest ENV_CAPTURE 900 "Env" Environment Environment G 1 None $null $null 0 1 0 0 $false $false $true $null "Environment capture")
}

#endregion

#region Plan

function Get-ProfileSettings {
    param([string]$Name)
    $s = switch ($Name) {
        "Full" { [ordered]@{ repetitions = 6; warmUpRepetition = $true; workScale = 1.0; passesOverride = 0; warmUpPassesOverride = $null; preliminary = $false; publishable = $true; description = "6 repetitions + warm-up repetition R0, full size" } }
        "Quick" { [ordered]@{ repetitions = 2; warmUpRepetition = $true; workScale = 0.5; passesOverride = 0; warmUpPassesOverride = $null; preliminary = $true; publishable = $false; description = "2 repetitions + R0, WorkScale 0.5; preliminary, not publishable" } }
        "DryRun" { [ordered]@{ repetitions = 1; warmUpRepetition = $false; workScale = 1.0; passesOverride = 0; warmUpPassesOverride = $null; preliminary = $true; publishable = $false; description = "1 repetition, full size, no R0" } }
        "Smoke" { [ordered]@{ repetitions = 1; warmUpRepetition = $false; workScale = 0.1; passesOverride = 1; warmUpPassesOverride = 0; preliminary = $true; publishable = $false; description = "1 repetition, WorkScale 0.1, PassesOverride 1, WarmUpPassesOverride 0, no R0" } }
    }
    if ($script:RepetitionsExplicit) { $s.repetitions = $Repetitions }
    if ($NoWarmUpRepetition) { $s.warmUpRepetition = $false }
    return $s
}

function Get-RotationOrders {
    # Default: the 6 orders of SPEC section 3.9 for the default instance order (PerfPG, PerfMySQL, PerfSQL).
    param([string[]]$Names)
    $orders = New-Object System.Collections.Generic.List[object]
    if (@($Rotation).Count -gt 0) {
        foreach ($entry in $Rotation) {
            $parts = @(([string]$entry) -split '[,>;\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $resolved = foreach ($p in $parts) {
                $match = @($Names | Where-Object { $_ -ieq $p })
                if ($match.Count -eq 0) { throw "Rotation entry '$entry' names '$p', which is not one of: $($Names -join ', ')" }
                $match[0]
            }
            $resolved = @($resolved)
            if ($resolved.Count -ne $Names.Count -or @($resolved | Select-Object -Unique).Count -ne $Names.Count) {
                throw "Rotation entry '$entry' must name every instance exactly once ($($Names -join ', '))."
            }
            $orders.Add([string[]]$resolved)
        }
        return , $orders.ToArray()
    }
    if ($Names.Count -eq 3) {
        foreach ($pattern in @(@(0, 1, 2), @(1, 2, 0), @(2, 0, 1), @(2, 1, 0), @(1, 0, 2), @(0, 2, 1))) {
            $orders.Add([string[]]@($pattern | ForEach-Object { $Names[$_] }))
        }
        return , $orders.ToArray()
    }
    for ($shift = 0; $shift -lt $Names.Count; $shift++) {
        $orders.Add([string[]]@(for ($i = 0; $i -lt $Names.Count; $i++) { $Names[($i + $shift) % $Names.Count] }))
    }
    return , $orders.ToArray()
}

function Get-RepetitionOrder {
    param([int]$Rep, [object[]]$Orders)
    if ($Rep -le 0) { return , [string[]]$Orders[0] }
    return , [string[]]$Orders[($Rep - 1) % $Orders.Count]
}

function New-CampaignPlan {
    param([object[]]$Tests, [string[]]$SelectedBlocks, $ProfileSettings, [object[]]$Orders, [string[]]$InstanceNames)
    $planBlocks = New-Object System.Collections.Generic.List[object]
    foreach ($letter in $script:BlockOrder) {
        if ($SelectedBlocks -notcontains $letter) { continue }
        $blockTests = @($Tests | Where-Object { [string]$_.RunBlock -eq $letter } | Sort-Object SortOrder, TestCode)
        if ($blockTests.Count -eq 0) { continue }
        $reps = New-Object System.Collections.Generic.List[object]
        $first = if ($ProfileSettings.warmUpRepetition) { 0 } else { 1 }
        for ($rep = $first; $rep -le $ProfileSettings.repetitions; $rep++) {
            $reps.Add([pscustomobject]@{ Rep = $rep; IsWarmup = ($rep -eq 0); Order = (Get-RepetitionOrder -Rep $rep -Orders $Orders) })
        }
        $planBlocks.Add([pscustomobject]@{ Block = $letter; Tests = $blockTests; Reps = $reps.ToArray(); Instances = $InstanceNames })
    }
    return , $planBlocks.ToArray()
}

function Get-RunParameters {
    # R0: WorkScale 0.25 (block D: 0.05), PassesOverride 1, WarmUpPassesOverride 0, IsWarmup true (SPEC 5.4 item 4).
    param([Parameter(Mandatory = $true)]$Test, [string]$Block, [string]$ParamProfile, $ProfileSettings)
    if ($ParamProfile -eq "env") {
        return [pscustomobject]@{ WorkScale = $null; PassesOverride = $null; WarmUpPassesOverride = $null; IsWarmup = $false }
    }
    if ($ParamProfile -eq "r0") {
        $scale = if ($Block -eq "D") { 0.05 } else { 0.25 }
        return [pscustomobject]@{ WorkScale = [decimal]$scale; PassesOverride = 1; WarmUpPassesOverride = 0; IsWarmup = $true }
    }
    $warmUps = $ProfileSettings.warmUpPassesOverride
    if ($null -eq $warmUps) {
        # "test default" is sent as the descriptor's own value, which gives the same effective plan and ParamsHash
        $warmUps = $Test.DefaultWarmUpPasses
    }
    return [pscustomobject]@{ WorkScale = [decimal]$ProfileSettings.workScale; PassesOverride = [int]$ProfileSettings.passesOverride; WarmUpPassesOverride = $warmUps; IsWarmup = $false }
}

function Get-RunBudgetSec {
    param([string]$TestCode)
    if ($script:CalibrationBudgets.ContainsKey($TestCode)) { return [int]$script:CalibrationBudgets[$TestCode] }
    return $null
}

function Get-WaitLimitSec {
    # Wait limit = RunBudgetSec (or the engine default 900 s) + 5 min (SPEC 5.4 item 14; -WaitLimitExtraSec).
    param([string]$TestCode)
    $budget = Get-RunBudgetSec -TestCode $TestCode
    if ($null -eq $budget -or $budget -le 0) { $budget = 900 }
    return ($budget + $WaitLimitExtraSec)
}

function Get-RerunTripleOrder {
    # A re-run is always a triple: every instance, in the order of the slot's repetition (SPEC 5.4 item 8).
    param([int]$Rep, [object[]]$Orders)
    return , (Get-RepetitionOrder -Rep $Rep -Orders $Orders)
}

function Test-BackupArtefacts {
    # The artefacts of SPEC section 6.5. Returns a list of { item, ok, detail }.
    param([switch]$NoDatabaseCheck)
    $checks = New-Object System.Collections.Generic.List[object]
    foreach ($item in @(
            @{ name = "PerfSQL_precampaign.bak"; path = (Join-Path $BackupFolder "PerfSQL_precampaign.bak") },
            @{ name = "MySQL80-Data-precampaign\"; path = (Join-Path $BackupFolder "MySQL80-Data-precampaign") },
            @{ name = "perfmysql_precampaign.sql"; path = (Join-Path $BackupFolder "perfmysql_precampaign.sql") },
            @{ name = "PerfPG_precampaign.dump"; path = (Join-Path $BackupFolder "PerfPG_precampaign.dump") })) {
        $ok = Test-Path -LiteralPath $item.path
        $checks.Add([pscustomobject]@{ item = $item.name; ok = $ok; detail = $(if ($ok) { "found" } else { "missing: " + $item.path }) })
    }

    $pgOk = $false
    $pgDetail = $null
    if ($NoDatabaseCheck) {
        $pgDetail = "not checked in -PlanOnly (no database access)"
    }
    elseif ([string]::IsNullOrWhiteSpace($PgPassFile) -or -not (Test-Path -LiteralPath $PgPassFile)) {
        $pgDetail = "cannot verify the perfpg_precampaign database: pass -PgPassFile"
    }
    elseif (-not (Test-Path -LiteralPath $PsqlExe)) {
        $pgDetail = "cannot verify the perfpg_precampaign database: psql.exe not found (-PsqlExe)"
    }
    else {
        try {
            $r = Invoke-NativeProcess -FilePath $PsqlExe -Arguments "-X -A -t -q -w -h localhost -U postgres -d postgres" -StdIn "SELECT count(*) FROM pg_database WHERE datname = 'perfpg_precampaign';`n" -Environment @{ PGPASSFILE = $PgPassFile; PGCONNECT_TIMEOUT = "10" } -TimeoutSec 30
            $pgOk = ($r.ExitCode -eq 0 -and $r.StdOut.Trim() -eq "1")
            $pgDetail = if ($pgOk) { "found" } elseif ($r.ExitCode -ne 0) { "psql failed: " + $r.StdErr.Trim() } else { "database perfpg_precampaign not found" }
        }
        catch {
            $pgDetail = "psql failed: " + $_.Exception.Message
        }
    }
    $checks.Add([pscustomobject]@{ item = "perfpg_precampaign database"; ok = $pgOk; detail = $pgDetail })
    return , $checks.ToArray()
}

function Write-PlanReport {
    param([object[]]$Plan, $ProfileSettings, [object[]]$Orders, [string[]]$InstanceNames, [string]$CatalogSource)
    $line = "=" * 100
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host "PerfDBBenchmark campaign plan (PlanOnly: no REST call, no credentials, nothing written)" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor DarkCyan
    $cid = if ([string]::IsNullOrWhiteSpace($CampaignId)) { "(a new GUID is created at start)" } else { $CampaignId }
    Write-Host ("Campaign id   : {0}" -f $cid)
    Write-Host ("Profile       : {0} ({1})" -f $script:ProfileName, $ProfileSettings.description)
    Write-Host ("Catalog       : {0}" -f $CatalogSource)
    Write-Host ("Endpoint      : {0}/{1}" -f $EndpointName, $EndpointVersion)
    Write-Host ("Instances     : {0}" -f ($InstanceNames -join ", "))
    Write-Host ("Interleave    : {0}" -f $Interleave)
    for ($i = 0; $i -lt $Orders.Count; $i++) {
        Write-Host ("Rotation R{0}   : {1}" -f ($i + 1), ($Orders[$i] -join " > "))
    }
    Write-Host ("R0 parameters : WorkScale 0.25 (Block D 0.05), PassesOverride 1, WarmUpPassesOverride 0, IsWarmup true; order = R1's")
    Write-Host ("Run size      : WorkScale {0}; PassesOverride {1}; WarmUpPassesOverride {2}" -f $ProfileSettings.workScale, $(if ($ProfileSettings.passesOverride -gt 0) { $ProfileSettings.passesOverride } else { "test default" }), $(if ($null -eq $ProfileSettings.warmUpPassesOverride) { "test default" } else { $ProfileSettings.warmUpPassesOverride }))
    Write-Host ("Core params   : records {0}, chunk {1}, iterations {2}" -f $CoreRecords, $CoreChunkSize, $CoreIterations)
    $budgetText = if ($script:CalibrationBudgets.Count -gt 0) { "calibration file: per-test RunBudgetSec (" + $script:CalibrationBudgets.Count + " tests)" } else { ("no calibration file: RunBudgetSec empty (engine default 900 s); wait limit {0} s" -f (900 + $WaitLimitExtraSec)) }
    Write-Host ("Run budgets   : {0}" -f $budgetText)
    Write-Host ("Settle gate   : wait >= {0} s; {1} s window: CPU < {2}%, disk < {3} MB/s; timeout {4} s (A) / {5} s (B-D, plus other DB processes < {6}% of a core and < {7} MB/s); cool-down {8} s after runs with >= 8 workers" -f $SettleMinWaitSec, $SettleWindowSec, $SettleCpuPct, $SettleDiskMBps, $SettleTimeoutSec, $SettleTimeoutSecBCD, $SettleOtherDbCpuPctOfCore, $SettleOtherDbIoMBps, $CoolDownSecAfterMultiUser)
    Write-Host ("Poll          : {0} s for the first {1} s of a run, then {2} s" -f $PollFastSec, $PollFastForSec, $PollSlowSec)
    Write-Host ("Re-runs       : {0}" -f $(if ($NoRerun) { "disabled (-NoRerun)" } else { "triples (all instances, the repetition's order) at the end of each block; at most 2 rounds per slot" }))
    Write-Host ""

    $totalRuns = 0
    $totalEnv = 0
    $testCount = 0
    $repsPerBlock = New-Object System.Collections.Generic.List[int]
    foreach ($b in $Plan) {
        $tests = @($b.Tests)
        $testCount += $tests.Count
        $instanceCount = $InstanceNames.Count
        $blockRuns = 0
        $blockEnv = 0
        Write-Host ("Block {0} - {1} ({2} tests)" -f $b.Block, $script:BlockNames[$b.Block], $tests.Count) -ForegroundColor Cyan
        foreach ($t in $tests) {
            $users = if ($null -ne $t.UserCount) { [int]$t.UserCount } else { 1 }
            $flags = @()
            if ([bool]$t.IsDestructive) { $flags += "permanent" }
            if ([bool]$t.IsOptional) { $flags += "optional" }
            $budget = Get-RunBudgetSec -TestCode $t.TestCode
            if ($null -ne $budget) { $flags += ("RunBudgetSec {0}" -f $budget) }
            Write-Host ("  {0,4} {1,-28} {2,-2} worker(s)  {3}{4}" -f $t.SortOrder, $t.TestCode, $users, $t.DisplayName, $(if ($flags.Count -gt 0) { "  [" + ($flags -join ", ") + "]" } else { "" }))
        }
        foreach ($r in $b.Reps) {
            $runs = $tests.Count * $instanceCount
            $blockRuns += $runs
            $blockEnv += $instanceCount
            $label = if ($r.IsWarmup) { "R0 (warm-up)" } else { "R{0}" -f $r.Rep }
            $gates = if ($b.Block -eq "D" -and -not $r.IsWarmup) { "G1 G2d G3 G4 G7" } elseif ($b.Block -eq "A") { "G1 G2 G3 G4 G5 G7" } else { "G1 G2 G3 G4 G7" }
            Write-Host ("  {0,-13} order {1,-32} ENV_CAPTURE x{2}; gates {3}; {4} tests x {5} instances = {6} runs" -f $label, ($r.Order -join " > "), $instanceCount, $gates, $tests.Count, $instanceCount, $runs)
            if ($PlanDetail) {
                $pos = 0
                if ($Interleave -eq "TestMajor") {
                    foreach ($t in $tests) { $pos = 0; foreach ($n in $r.Order) { $pos++; Write-Host ("      {0} {1,-28} @ {2} (position {3})" -f $label, $t.TestCode, $n, $pos) -ForegroundColor DarkGray } }
                }
                else {
                    foreach ($n in $r.Order) { $pos++; foreach ($t in $tests) { Write-Host ("      {0} {1,-28} @ {2} (position {3})" -f $label, $t.TestCode, $n, $pos) -ForegroundColor DarkGray } }
                }
            }
        }
        $repsPerBlock.Add(@($b.Reps).Count)
        Write-Host ("  Block {0} total: {1} benchmark runs + {2} ENV_CAPTURE runs" -f $b.Block, $blockRuns, $blockEnv)
        if ($b.Block -eq "B" -or $b.Block -eq "C") {
            Write-Host ("  Before the block: ClearTestRecords on every instance") -ForegroundColor DarkGray
        }
        if (-not $NoRerun) {
            $exampleRep = [Math]::Min(3, $ProfileSettings.repetitions)
            $exampleTest = $tests[0].TestCode
            $triple = Get-RerunTripleOrder -Rep $exampleRep -Orders $Orders
            Write-Host ("  Conditional re-run (example): if {0} R{1} had an Invalid run on {2}, the re-run is the triple {3} (all {4} instances, R{1}'s order), after the regular repetitions" -f $exampleTest, $exampleRep, $InstanceNames[-1], ($triple -join " > "), $instanceCount) -ForegroundColor DarkGray
        }
        if ($b.Block -eq "D") {
            $singles = 0
            foreach ($r in $b.Reps) {
                if (@($r.Order).Count -ne $instanceCount) { $singles += $tests.Count }
            }
            Write-Host ("  Block D re-runs: triples only (every instance gets the same extra invoices); single-instance runs planned in Block D: {0}; re-warm runs after an application restart: none in Block D; resume never repeats a completed (test, instance) run" -f $singles) -ForegroundColor Yellow
            $backupChecks = Test-BackupArtefacts -NoDatabaseCheck:([bool]$PlanOnly)
            $missing = @($backupChecks | Where-Object { -not $_.ok })
            $state = if (-not $BackupsVerified) { "would be REFUSED: -BackupsVerified not given" } elseif ($missing.Count -gt 0) { "would be REFUSED: backup artefacts missing" } else { "allowed (backups verified)" }
            Write-Host ("  Block D start check: {0}" -f $state) -ForegroundColor Yellow
            foreach ($c in $backupChecks) { Write-Host ("    {0,-30} {1}" -f $c.item, $c.detail) -ForegroundColor DarkGray }
        }
        Write-Host ""
        $totalRuns += $blockRuns
        $totalEnv += $blockEnv
    }

    $instanceCountTotal = $InstanceNames.Count
    $uniformReps = @($repsPerBlock | Select-Object -Unique)
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host ("Planned: {0} benchmark runs + {1} ENV_CAPTURE runs = {2} runs" -f $totalRuns, $totalEnv, ($totalRuns + $totalEnv)) -ForegroundColor Green
    if ($uniformReps.Count -eq 1 -and $Plan.Count -gt 0) {
        Write-Host ("         ({0} tests x {1} instances x {2} repetitions = {3}; {4} blocks x {2} repetitions x {1} instances = {5})" -f $testCount, $instanceCountTotal, $uniformReps[0], $totalRuns, $Plan.Count, $totalEnv) -ForegroundColor Green
    }
    Write-Host ("Not counted: triple re-runs at block end, re-warm runs after an application restart (Blocks A-C only), ClearTestRecords before Blocks B and C, pre-flight checks before every block.") -ForegroundColor DarkGray
    Write-Host $line -ForegroundColor DarkCyan
    return [pscustomobject]@{ BenchmarkRuns = $totalRuns; EnvCaptureRuns = $totalEnv; Tests = $testCount }
}

#endregion

#region Host counters (settle gate, per-process counters, run sampling)

function Initialize-HostCounters {
    $c = @{ Cpu = $null; Disk = $null; ProcPerf = $null; Notes = New-Object System.Collections.Generic.List[string] }
    try { $c.Cpu = New-Object System.Diagnostics.PerformanceCounter("Processor", "% Processor Time", "_Total", $true); [void]$c.Cpu.NextValue() } catch { $c.Notes.Add("Processor(_Total)\% Processor Time unavailable") }
    try { $c.Disk = New-Object System.Diagnostics.PerformanceCounter("PhysicalDisk", "Disk Bytes/sec", "_Total", $true); [void]$c.Disk.NextValue() } catch { $c.Notes.Add("PhysicalDisk(_Total)\Disk Bytes/sec unavailable") }
    try { $c.ProcPerf = New-Object System.Diagnostics.PerformanceCounter("Processor Information", "% Processor Performance", "_Total", $true); [void]$c.ProcPerf.NextValue() } catch { $c.Notes.Add("Processor Information(_Total)\% Processor Performance unavailable") }
    $script:HostCounters = $c
    foreach ($n in $c.Notes) { Write-SuiteLog ("Counters: " + $n) "DarkYellow" }
}

function Read-HostCounter {
    param([string]$Name)
    if ($null -eq $script:HostCounters) { return $null }
    $counter = $script:HostCounters[$Name]
    if ($null -eq $counter) { return $null }
    try { return [double]$counter.NextValue() } catch { return $null }
}

function Get-ThermalC {
    if (-not $script:ThermalAvailable) { return $null }
    try {
        $zones = @(Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ThermalZoneInformation -Property Name, Temperature -ErrorAction Stop)
        $values = @($zones | ForEach-Object { [double]$_.Temperature } | Where-Object { $_ -gt 0 })
        if ($values.Count -eq 0) { return $null }
        return [Math]::Round((($values | Measure-Object -Maximum).Maximum) - 273.15, 1)
    }
    catch {
        $script:ThermalAvailable = $false
        return $null
    }
}

function Get-W3wpPoolMap {
    # PID -> app pool. First the IIS performance-counter category W3SVC_W3WP (instance names "<PID>_<AppPool>"),
    # which a non-elevated user can read; then appcmd (needs elevation) and the w3wp command line (empty for
    # processes of another identity when not elevated).
    $map = @{}
    try {
        $category = New-Object System.Diagnostics.PerformanceCounterCategory("W3SVC_W3WP")
        foreach ($name in @($category.GetInstanceNames())) {
            $m = [regex]::Match([string]$name, '^(\d+)_(.+)$')
            if ($m.Success) { $map[[int]$m.Groups[1].Value] = $m.Groups[2].Value }
        }
    }
    catch {
    }
    if ($map.Count -gt 0) { return $map }
    $appcmd = Join-Path $env:windir "System32\inetsrv\appcmd.exe"
    if (Test-Path -LiteralPath $appcmd) {
        try {
            $r = Invoke-NativeProcess -FilePath $appcmd -Arguments "list wp" -TimeoutSec 15
            foreach ($line in ($r.StdOut -split "`r?`n")) {
                $m = [regex]::Match($line, 'WP "(\d+)" \(applicationPool:([^\)]+)\)')
                if ($m.Success) { $map[[int]$m.Groups[1].Value] = $m.Groups[2].Value }
            }
        }
        catch {
        }
    }
    if ($map.Count -eq 0) {
        try {
            foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='w3wp.exe'" -Property ProcessId, CommandLine -ErrorAction Stop)) {
                $m = [regex]::Match([string]$p.CommandLine, '-ap "([^"]+)"')
                if ($m.Success) { $map[[int]$p.ProcessId] = $m.Groups[1].Value }
            }
        }
        catch {
        }
    }
    return $map
}

function Get-ProcessRawSnapshot {
    # Cumulative CPU (100 ns units) and I/O bytes per process of sqlservr, mysqld, postgres and w3wp (SPEC 5.4 item 15).
    param([switch]$DatabaseOnly)
    $filter = "Name LIKE 'sqlservr%' OR Name LIKE 'mysqld%' OR Name LIKE 'postgres%'"
    if (-not $DatabaseOnly) { $filter += " OR Name LIKE 'w3wp%'" }
    $poolMap = if ($DatabaseOnly) { @{} } else { Get-W3wpPoolMap }
    $byPid = @{}
    $stamp = [System.Diagnostics.Stopwatch]::GetTimestamp()
    try {
        $rows = @(Get-CimInstance -ClassName Win32_PerfRawData_PerfProc_Process -Filter $filter -Property Name, IDProcess, PercentProcessorTime, IODataBytesPersec -ErrorAction Stop)
    }
    catch {
        return @{ ok = $false; error = $_.Exception.Message; at = $stamp; pids = @{} }
    }
    foreach ($row in $rows) {
        $name = ([string]$row.Name) -replace '#\d+$', ''
        $procId = [int]$row.IDProcess
        if ($procId -eq 0) { continue }
        $group = $null
        switch ($name.ToLowerInvariant()) {
            "sqlservr" { $group = "sqlservr" }
            "mysqld" { $group = "mysqld" }
            "postgres" { $group = "postgres" }
            "w3wp" { $group = if ($poolMap.ContainsKey($procId)) { "w3wp:" + $poolMap[$procId] } else { "w3wp:unknown" } }
        }
        if ($null -eq $group) { continue }
        $byPid[$procId] = @{ group = $group; cpu = [double]$row.PercentProcessorTime; io = [double]$row.IODataBytesPersec }
    }
    return @{ ok = $true; error = $null; at = $stamp; pids = $byPid }
}

function Get-SnapshotGroups {
    param($Snapshot)
    $groups = [ordered]@{}
    if ($null -eq $Snapshot) { return $groups }
    foreach ($procId in @($Snapshot.pids.Keys | Sort-Object)) {
        $p = $Snapshot.pids[$procId]
        if (-not $groups.Contains($p.group)) { $groups[$p.group] = [ordered]@{ cpuMs = 0.0; ioBytes = 0.0; processes = 0 } }
        $g = $groups[$p.group]
        $g["cpuMs"] = $g["cpuMs"] + $p.cpu / 10000.0
        $g["ioBytes"] = $g["ioBytes"] + $p.io
        $g["processes"] = $g["processes"] + 1
    }
    foreach ($k in @($groups.Keys)) { $groups[$k]["cpuMs"] = [Math]::Round($groups[$k]["cpuMs"], 1) }
    return $groups
}

function Get-SnapshotDelta {
    # Per-process deltas summed by group; a process that appeared during the interval counts in full.
    # A failed snapshot (WMI error: ok = false, no processes) gives no delta: otherwise every process of the other
    # snapshot would count as new and add its whole-lifetime CPU.
    param($Start, $End, [string[]]$Groups = $null)
    $delta = [ordered]@{}
    if ($null -eq $Start -or $null -eq $End) { return $delta }
    if (-not [bool]$Start["ok"] -or -not [bool]$End["ok"]) { return $delta }
    foreach ($procId in @($End.pids.Keys)) {
        $e = $End.pids[$procId]
        if ($null -ne $Groups -and $Groups -notcontains $e.group) { continue }
        $s = if ($Start.pids.ContainsKey($procId)) { $Start.pids[$procId] } else { $null }
        $sameProcess = ($null -ne $s -and $s.group -eq $e.group -and $e.cpu -ge $s.cpu -and $e.io -ge $s.io)
        $dc = if ($sameProcess) { $e.cpu - $s.cpu } else { $e.cpu }
        $di = if ($sameProcess) { $e.io - $s.io } else { $e.io }
        if (-not $delta.Contains($e.group)) { $delta[$e.group] = [ordered]@{ cpuMs = 0.0; ioBytes = 0.0 } }
        $delta[$e.group]["cpuMs"] = $delta[$e.group]["cpuMs"] + $dc / 10000.0
        $delta[$e.group]["ioBytes"] = $delta[$e.group]["ioBytes"] + $di
    }
    foreach ($k in @($delta.Keys)) { $delta[$k]["cpuMs"] = [Math]::Round($delta[$k]["cpuMs"], 1) }
    return $delta
}

function Get-OtherDatabaseGroups {
    param([string]$EngineAboutToRun)
    $groups = foreach ($engine in $script:EngineProcessGroup.Keys) {
        if ($engine -ne $EngineAboutToRun) { $script:EngineProcessGroup[$engine] }
    }
    return , @($groups)
}

function Invoke-SettleGate {
    # SPEC 5.4 item 9: cool-down after >= 8 workers, minimum wait, then a trailing window of total CPU and disk;
    # Blocks B-D also require the other engines' database processes to be quiet.
    param([string]$Block, [string]$EngineAboutToRun, [int]$CoolDownSec)
    $result = [ordered]@{
        timedOut = $false; waitedSec = 0.0; cpuBeforePct = $null; cpuAvgPct = $null; perfAvgPct = $null
        otherDbCpuPctOfCore = $null; otherDbIoMBps = $null; coolDownSec = $CoolDownSec; tempC = $null
        diskBeforeMBps = $null; checkedOtherDb = $false; tempBeforeC = $null
    }
    if ($CoolDownSec -gt 0) { Start-Sleep -Seconds $CoolDownSec }

    $checkOtherDb = ($Block -ne "A")
    $timeout = if ($checkOtherDb) { $SettleTimeoutSecBCD } else { $SettleTimeoutSec }
    $otherGroups = Get-OtherDatabaseGroups -EngineAboutToRun $EngineAboutToRun
    $result.checkedOtherDb = $checkOtherDb
    $window = [Math]::Max(1, $SettleWindowSec)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if ($SettleMinWaitSec -gt 0) { Start-Sleep -Seconds $SettleMinWaitSec }
    [void](Read-HostCounter -Name "Cpu")
    [void](Read-HostCounter -Name "Disk")
    $samples = New-Object System.Collections.Generic.List[object]
    $samples.Add(@{ cpu = $null; disk = $null; t = $sw.Elapsed.TotalSeconds; snap = $(if ($checkOtherDb) { Get-ProcessRawSnapshot -DatabaseOnly } else { $null }) })

    while ($true) {
        Start-Sleep -Seconds 1
        $disk = Read-HostCounter -Name "Disk"
        $sample = @{
            cpu = (Read-HostCounter -Name "Cpu")
            disk = $(if ($null -ne $disk) { $disk / 1MB } else { $null })
            t = $sw.Elapsed.TotalSeconds
            snap = $(if ($checkOtherDb) { Get-ProcessRawSnapshot -DatabaseOnly } else { $null })
        }
        $samples.Add($sample)
        $n = $samples.Count - 1
        if ($n -ge $window) {
            $last = @($samples.GetRange($samples.Count - $window, $window))
            $cpuValues = @($last | ForEach-Object { $_.cpu } | Where-Object { $null -ne $_ })
            $diskValues = @($last | ForEach-Object { $_.disk } | Where-Object { $null -ne $_ })
            $cpuAvg = if ($cpuValues.Count -gt 0) { ($cpuValues | Measure-Object -Average).Average } else { 0.0 }
            $diskAvg = if ($diskValues.Count -gt 0) { ($diskValues | Measure-Object -Average).Average } else { 0.0 }
            $result.cpuBeforePct = [Math]::Round($cpuAvg, 2)
            $result.diskBeforeMBps = [Math]::Round($diskAvg, 2)
            $quietOtherDb = $true
            if ($checkOtherDb -and (-not [bool]$samples[$n - $window].snap["ok"] -or -not [bool]$sample.snap["ok"])) {
                # A process snapshot failed (WMI error): the other-database criterion cannot be evaluated for this
                # window; the CPU and disk criteria still apply.
                $result.otherDbCpuPctOfCore = $null
                $result.otherDbIoMBps = $null
            }
            elseif ($checkOtherDb) {
                $base = $samples[$n - $window]
                $secs = [Math]::Max(0.001, $sample.t - $base.t)
                $delta = Get-SnapshotDelta -Start $base.snap -End $sample.snap -Groups $otherGroups
                $cpuMs = 0.0
                $io = 0.0
                foreach ($k in @($delta.Keys)) { $cpuMs += $delta[$k]["cpuMs"]; $io += $delta[$k]["ioBytes"] }
                $result.otherDbCpuPctOfCore = [Math]::Round($cpuMs / ($secs * 1000.0) * 100.0, 2)
                $result.otherDbIoMBps = [Math]::Round($io / $secs / 1MB, 3)
                $quietOtherDb = ($result.otherDbCpuPctOfCore -lt $SettleOtherDbCpuPctOfCore -and $result.otherDbIoMBps -lt $SettleOtherDbIoMBps)
            }
            if ($cpuAvg -lt $SettleCpuPct -and $diskAvg -lt $SettleDiskMBps -and $quietOtherDb) { break }
        }
        if ($sw.Elapsed.TotalSeconds -ge $timeout) {
            $result.timedOut = $true
            break
        }
    }
    $result.waitedSec = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
    $result.tempBeforeC = Get-ThermalC
    return $result
}

function New-RunSampler {
    [void](Read-HostCounter -Name "Cpu")
    [void](Read-HostCounter -Name "ProcPerf")
    return @{ cpu = (New-Object System.Collections.Generic.List[object]); perf = (New-Object System.Collections.Generic.List[object]); temp = (New-Object System.Collections.Generic.List[object]); tempClock = $null }
}

function Add-RunSample {
    # Two cheap counter reads at every poll; the thermal-zone CIM query (WmiPrvSE work on the host under test) at
    # most every $script:ThermalSampleSec seconds while a run is measured.
    param($Sampler)
    if ($null -eq $Sampler) { return }
    $Sampler.cpu.Add((Read-HostCounter -Name "Cpu"))
    $Sampler.perf.Add((Read-HostCounter -Name "ProcPerf"))
    if ($null -eq $Sampler.tempClock -or $Sampler.tempClock.Elapsed.TotalSeconds -ge $script:ThermalSampleSec) {
        $Sampler.temp.Add((Get-ThermalC))
        $Sampler.tempClock = [System.Diagnostics.Stopwatch]::StartNew()
    }
}

#endregion

#region Campaign state (JSON v2, SPEC section 3.9)

function ConvertTo-OrderedMap {
    param([AllowNull()]$Object)
    $map = [ordered]@{}
    if ($null -eq $Object) { return $map }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($k in @($Object.Keys)) { $map[[string]$k] = $Object[$k] }
        return $map
    }
    foreach ($p in $Object.PSObject.Properties) { $map[$p.Name] = $p.Value }
    return $map
}

function ConvertTo-ObjectList {
    param([AllowNull()]$Items)
    $list = New-Object System.Collections.Generic.List[object]
    if ($null -ne $Items) {
        foreach ($item in @($Items)) { if ($null -ne $item) { $list.Add($item) } }
    }
    return , $list
}

function New-CampaignState {
    param([Guid]$Id, $ProfileSettings, [object[]]$Orders, [string]$CampaignFolder)
    $campaign = [ordered]@{
        id = $Id.ToString()
        methodologyVersion = $script:MethodologyVersion
        profile = $script:ProfileName
        startedAtUtc = [DateTime]::UtcNow.ToString("o")
        completedAtUtc = $null
        repetitions = $ProfileSettings.repetitions
        warmUpRepetition = [bool]$ProfileSettings.warmUpRepetition
        rotation = @($Orders | ForEach-Object { , @($_) })
        blocks = @()
        interleave = $Interleave
        coreParams = [ordered]@{ records = $CoreRecords; chunkSize = $CoreChunkSize; iterations = $CoreIterations }
        settleGate = [ordered]@{
            cpuPct = $SettleCpuPct; diskMBps = $SettleDiskMBps; windowSec = $SettleWindowSec; minWaitSec = $SettleMinWaitSec; timeoutSec = $SettleTimeoutSec
            blocksBCD = [ordered]@{ otherDbCpuPctOfCore = $SettleOtherDbCpuPctOfCore; otherDbIoMBps = $SettleOtherDbIoMBps; timeoutSec = $SettleTimeoutSecBCD }
            coolDownSecAfterMultiUser = $CoolDownSecAfterMultiUser
        }
        calibrationFile = $(if ([string]::IsNullOrWhiteSpace($CalibrationFile) -or $script:CalibrationWriteOnly) { $null } else { $CalibrationFile })
        noRerun = [bool]$NoRerun
        clientConnection = [ordered]@{}
        poll = [ordered]@{ fastSec = $PollFastSec; fastForSec = $PollFastForSec; slowSec = $PollSlowSec }
        endpoint = "$EndpointName/$EndpointVersion"
        repoCommit = (Get-RepoCommit)
        operator = $env:USERNAME
        suiteVersion = $script:SuiteVersion
        backupsVerified = [bool]$BackupsVerified
        notes = @()
        preliminary = [bool]$ProfileSettings.preliminary
        publishable = [bool]$ProfileSettings.publishable
        workScale = $ProfileSettings.workScale
    }
    if ($ProfileSettings.preliminary -and $script:ProfileName -eq "Quick") {
        $campaign.notes = @("Quick profile: preliminary results, not publishable.")
    }
    return [ordered]@{
        schemaVersion = 2
        campaign = $campaign
        instances = @()
        tests = @()
        environment = [ordered]@{ start = $null; end = $null; envCaptures = (New-Object System.Collections.Generic.List[object]) }
        runs = (New-Object System.Collections.Generic.List[object])
        events = (New-Object System.Collections.Generic.List[object])
        suiteState = [ordered]@{
            blockState = [ordered]@{}
            expectedParamsHash = [ordered]@{}
            instanceState = [ordered]@{}
            skipped = (New-Object System.Collections.Generic.List[object])
            inFlight = $null
            invocations = (New-Object System.Collections.Generic.List[object])
            serverDllSha256 = $null
            serverMethodologyVersion = $null
            settleTimeouts = [ordered]@{}
            path = $null
        }
    }
}

function Import-CampaignState {
    param([string]$Path)
    $doc = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if ([int](Get-Prop $doc "schemaVersion") -ne 2) { throw "Campaign file '$Path' is not schema version 2." }
    $env = Get-Prop $doc "environment"
    $suite = ConvertTo-OrderedMap (Get-Prop $doc "suiteState")
    $state = [ordered]@{
        schemaVersion = 2
        campaign = (ConvertTo-OrderedMap (Get-Prop $doc "campaign"))
        instances = @((Get-Prop $doc "instances") | Where-Object { $null -ne $_ })
        tests = @((Get-Prop $doc "tests") | Where-Object { $null -ne $_ })
        environment = [ordered]@{ start = (Get-Prop $env "start"); end = (Get-Prop $env "end"); envCaptures = (ConvertTo-ObjectList (Get-Prop $env "envCaptures")); tableCounts = (Get-Prop $env "tableCounts") }
        runs = (ConvertTo-ObjectList (Get-Prop $doc "runs"))
        events = (ConvertTo-ObjectList (Get-Prop $doc "events"))
        suiteState = $suite
    }
    if ($null -ne (Get-Prop $doc "diagnostics")) { $state["diagnostics"] = ConvertTo-OrderedMap (Get-Prop $doc "diagnostics") }
    $state.campaign["clientConnection"] = ConvertTo-OrderedMap $state.campaign["clientConnection"]
    $suite["blockState"] = ConvertTo-OrderedMap (Get-Prop $suite "blockState")
    $suite["expectedParamsHash"] = ConvertTo-OrderedMap (Get-Prop $suite "expectedParamsHash")
    $settleTimeouts = [ordered]@{}
    foreach ($p in @((ConvertTo-OrderedMap (Get-Prop $suite "settleTimeouts")).GetEnumerator())) { $settleTimeouts[$p.Key] = ConvertTo-OrderedMap $p.Value }
    $suite["settleTimeouts"] = $settleTimeouts
    $instanceState = [ordered]@{}
    foreach ($p in @((ConvertTo-OrderedMap (Get-Prop $suite "instanceState")).GetEnumerator())) { $instanceState[$p.Key] = ConvertTo-OrderedMap $p.Value }
    $suite["instanceState"] = $instanceState
    $suite["skipped"] = ConvertTo-ObjectList (Get-Prop $suite "skipped")
    $suite["invocations"] = ConvertTo-ObjectList (Get-Prop $suite "invocations")
    foreach ($key in @("inFlight", "pendingInFlight", "serverDllSha256", "serverMethodologyVersion", "path")) {
        if (-not $suite.Contains($key)) { $suite[$key] = $null }
    }
    # A Block D benchmark run that was in flight when the suite stopped may have finished on the server. Keep its
    # marker apart (the next run overwrites "inFlight") until Resolve-InFlightRun has looked for its result.
    $inFlight = $suite["inFlight"]
    if ($null -ne $inFlight -and [string](Get-Prop $inFlight "block") -eq "D" -and [string](Get-Prop $inFlight "testCode") -ne $script:EnvCaptureCode -and [string](Get-Prop $inFlight "role") -ne "rewarm") {
        $suite["pendingInFlight"] = $inFlight
    }
    $suite["inFlight"] = $null
    return $state
}

function Save-CampaignState {
    if ($null -eq $script:State -or [string]::IsNullOrWhiteSpace($script:State.suiteState["path"])) { return }
    $path = $script:State.suiteState["path"]
    $doc = [ordered]@{
        schemaVersion = 2
        campaign = $script:State.campaign
        instances = @($script:State.instances)
        tests = @($script:State.tests)
        environment = [ordered]@{
            start = $script:State.environment.start
            end = $script:State.environment.end
            envCaptures = $script:State.environment.envCaptures.ToArray()
        }
        runs = $script:State.runs.ToArray()
        events = $script:State.events.ToArray()
    }
    if ($script:State.environment.Contains("tableCounts") -and $null -ne $script:State.environment["tableCounts"]) { $doc.environment["tableCounts"] = $script:State.environment["tableCounts"] }
    if ($script:State.Contains("diagnostics")) { $doc["diagnostics"] = $script:State["diagnostics"] }
    $doc["suiteState"] = $script:State.suiteState
    $json = $doc | ConvertTo-Json -Depth 40
    $tmp = $path + ".tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Add-SuiteEvent {
    param([Parameter(Mandatory = $true)][string]$Kind, [AllowNull()][string]$Instance, [AllowNull()][string]$Detail)
    $color = switch ($Kind) { "GateFailed" { "Red" } "Stuck" { "Red" } "Abort" { "Red" } "AppRestart" { "Yellow" } "ParamsMismatch" { "Yellow" } "GateWarning" { "Yellow" } "Preflight" { "Yellow" } "LoginLimit" { "Yellow" } default { "DarkYellow" } }
    Write-SuiteLog ("  [{0}] {1}{2}" -f $Kind, $(if ([string]::IsNullOrWhiteSpace($Instance)) { "" } else { $Instance + ": " }), $Detail) $color
    if ($null -eq $script:State) { return }
    $script:State.events.Add([pscustomobject][ordered]@{ atUtc = [DateTime]::UtcNow.ToString("o"); kind = $Kind; instance = $Instance; detail = $Detail })
}

function Get-RepoCommit {
    try {
        $git = Get-Command git -ErrorAction Stop
        $r = Invoke-NativeProcess -FilePath $git.Source -Arguments ("-C `"{0}`" rev-parse HEAD" -f $repoRoot) -TimeoutSec 30
        if ($r.ExitCode -eq 0) { return $r.StdOut.Trim() }
    }
    catch {
    }
    return $null
}

function Get-InstanceStateEntry {
    param([string]$Name)
    $all = $script:State.suiteState["instanceState"]
    if (-not $all.Contains($Name)) {
        $all[$Name] = [ordered]@{ lastAppStartUtc = $null; stuckBlock = $null; needsRewarm = $false }
    }
    return $all[$Name]
}

function Save-InstanceState {
    param($Inst)
    $entry = Get-InstanceStateEntry -Name $Inst.Name
    $entry["lastAppStartUtc"] = $Inst.LastAppStartUtc
    $entry["stuckBlock"] = $Inst.StuckBlock
    $entry["needsRewarm"] = [bool]$Inst.NeedsRewarm
}

#endregion

#region Run records

function Test-RepEqual {
    param([AllowNull()]$A, [AllowNull()]$B)
    if ($null -eq $A -and $null -eq $B) { return $true }
    if ($null -eq $A -or $null -eq $B) { return $false }
    return ([int]$A -eq [int]$B)
}

function Test-RecordActive {
    # A record that has not been superseded by a resume.
    param($Record)
    return [string]::IsNullOrEmpty([string](Get-Prop $Record "supersedeReason"))
}

function Get-RecordRole {
    param($Record)
    return [string](Get-Prop (Get-Prop $Record "slot") "role")
}

function Get-RecordRound {
    param($Record)
    $round = Get-Prop (Get-Prop $Record "slot") "rerunRound"
    if ($null -eq $round) { return 0 }
    return [int]$round
}

function Test-RecordValid {
    # Valid for the analysis set: Completed or Capped, not a warm-up, not an AppRestart or ParamsHashMismatch run.
    param($Record)
    $status = [string](Get-Prop $Record "status")
    if ($status -ne "Completed" -and $status -ne "Capped") { return $false }
    if ([bool](Get-Prop $Record "isWarmup")) { return $false }
    $reason = [string](Get-Prop $Record "invalidReason")
    if ($reason -eq "AppRestart" -or $reason -eq "ParamsHashMismatch") { return $false }
    return $true
}

function New-RunRecord {
    param($Inst, $Test, [string]$Block, $Rep, $OrderPosition, [bool]$IsWarmup, [string]$Role, [int]$RerunRound, $RerunOf, $RunParams, $RunBudgetSec)
    return [pscustomobject][ordered]@{
        campaignId = $script:State.campaign["id"]
        block = $Block
        repetitionNo = $Rep
        isWarmup = $IsWarmup
        orderPosition = $OrderPosition
        instance = $Inst.Name
        dbEngine = $Inst.DbEngine
        testCode = $Test.TestCode
        family = $Test.Family
        status = "Failed"
        invalidReason = $null
        requestId = $null
        startedAtUtc = $null
        completedAtUtc = $null
        suiteWallMs = $null
        elapsedMsPrecise = $null
        headlineValue = $null
        headlineUnit = $Test.HeadlineUnit
        higherIsBetter = $Test.HigherIsBetter
        opsCount = $null
        opsPerSec = $null
        p50Ms = $null
        p95Ms = $null
        p99Ms = $null
        maxOpMs = $null
        rowsReturned = $null
        checksum = $null
        paramsHash = $null
        methodologyVersion = $null
        userCount = $Test.UserCount
        workersObservedPeak = $null
        errorCount = $null
        deadlockCount = $null
        retryCount = $null
        lockViolationCount = $null
        timeoutCount = $null
        dllSha256 = $null
        appDomainStartUtc = $null
        settle = $null
        runBudgetSec = $RunBudgetSec
        stuck = $false
        slot = [pscustomobject][ordered]@{ repetitionNo = $Rep; role = $Role; rerunRound = $RerunRound; usedInAnalysis = $false }
        supersededBy = $null
        supersedeReason = $null
        isRerun = ($Role -eq "rerun")
        rerunOf = $RerunOf
        procCounters = $null
        diagnostics = $null
        result = $null
        message = $null
        displayName = $Test.DisplayName
        sortOrder = $Test.SortOrder
        serverStatus = $null
        outlier = $false
        workScale = $RunParams.WorkScale
        passesOverride = $RunParams.PassesOverride
        warmUpPassesOverride = $RunParams.WarmUpPassesOverride
        serverAppStartBefore = $null
        serverAppStartAfter = $null
        recoveredFromServer = $false
    }
}

function Update-RecordFromResultRow {
    param($Record, $Row)
    $get = { param($name) Get-RecordFieldValue -Record $Row -FieldName $name }
    $Record.serverStatus = [string](& $get "Status")
    $Record.status = if ([string]::IsNullOrWhiteSpace($Record.serverStatus)) { "Completed" } else { $Record.serverStatus }
    $reason = [string](& $get "InvalidReason")
    $Record.invalidReason = if ([string]::IsNullOrWhiteSpace($reason)) { $null } else { $reason }
    $Record.elapsedMsPrecise = Convert-ToNullableDouble (& $get "ElapsedMsPrecise")
    if ($null -eq $Record.elapsedMsPrecise) { $Record.elapsedMsPrecise = Convert-ToNullableDouble (& $get "ElapsedMs") }
    $Record.headlineValue = Convert-ToNullableDouble (& $get "HeadlineValue")
    $unit = [string](& $get "HeadlineUnit")
    if (-not [string]::IsNullOrWhiteSpace($unit)) { $Record.headlineUnit = $unit }
    $higher = Convert-ToNullableBool (& $get "HigherIsBetter")
    if ($null -ne $higher) { $Record.higherIsBetter = $higher }
    $Record.opsCount = Convert-ToNullableInt (& $get "OpsCount")
    $Record.opsPerSec = Convert-ToNullableDouble (& $get "OpsPerSec")
    $Record.p50Ms = Convert-ToNullableDouble (& $get "P50Ms")
    $Record.p95Ms = Convert-ToNullableDouble (& $get "P95Ms")
    $Record.p99Ms = Convert-ToNullableDouble (& $get "P99Ms")
    $Record.maxOpMs = Convert-ToNullableDouble (& $get "MaxOpMs")
    $Record.rowsReturned = Convert-ToNullableLong (& $get "RowsReturned")
    $checksum = [string](& $get "Checksum")
    $Record.checksum = if ([string]::IsNullOrWhiteSpace($checksum)) { $null } else { $checksum }
    $Record.paramsHash = [string](& $get "ParamsHash")
    $Record.methodologyVersion = [string](& $get "MethodologyVersion")
    $users = Convert-ToNullableInt (& $get "UserCount")
    if ($null -ne $users) { $Record.userCount = $users }
    $Record.workersObservedPeak = Convert-ToNullableInt (& $get "WorkersObservedPeak")
    $Record.errorCount = Convert-ToNullableInt (& $get "ErrorCount")
    $Record.deadlockCount = Convert-ToNullableInt (& $get "DeadlockCount")
    $Record.retryCount = Convert-ToNullableInt (& $get "RetryCount")
    $Record.lockViolationCount = Convert-ToNullableInt (& $get "LockViolationCount")
    $Record.timeoutCount = Convert-ToNullableInt (& $get "TimeoutCount")
    $Record.dllSha256 = [string](& $get "DllSha256")
    $Record.appDomainStartUtc = [string](& $get "AppDomainStartUtc")
    $family = [string](& $get "Family")
    if (-not [string]::IsNullOrWhiteSpace($family)) { $Record.family = $family }
    $resultJson = [string](& $get "ResultJson")
    if (-not [string]::IsNullOrWhiteSpace($resultJson)) {
        try {
            $Record.result = $resultJson | ConvertFrom-Json
        }
        catch {
            # Keep the raw text (for example keys that differ only in case, which Windows PowerShell 5.1 cannot turn
            # into an object): the report parses it with a case-sensitive reader, and nothing is lost.
            $Record.message = ("ResultJson could not be parsed: " + $_.Exception.Message)
            Set-RecordValue -Record $Record -Name "resultJsonRaw" -Value $resultJson
        }
    }
    $server = Get-Prop $Record.result "server"
    $engine = [string](Get-Prop $server "dbEngine")
    if (-not [string]::IsNullOrWhiteSpace($engine) -and $engine -ne "Unknown") { $Record.dbEngine = $engine }
}

function Get-ResultRows {
    param($Inst, [string]$Query)
    $response = Invoke-InstanceRequest -Inst $Inst -Method GET -RelativeUri ("/BenchmarkResult?" + $Query)
    if ($null -eq $response.Json) { return , @() }
    return , @($response.Json)
}

function Get-ResultRowForRun {
    # Primary: $filter=RunID; fallback (SPEC section 8 R7): filter by TestCode and match RunID on the client.
    param($Inst, [Guid]$RequestId, [string]$TestCode)
    $queries = @(
        ('$filter=' + [Uri]::EscapeDataString("RunID eq guid'$RequestId'")),
        ('$filter=' + [Uri]::EscapeDataString("TestCode eq '$TestCode'") + '&$top=20'),
        '$top=50'
    )
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        foreach ($query in $queries) {
            try {
                foreach ($row in (Get-ResultRows -Inst $Inst -Query $query)) {
                    $runId = Convert-ToNullableGuid (Get-RecordFieldValue -Record $row -FieldName "RunID")
                    if ($runId -eq $RequestId) { return $row }
                }
            }
            catch {
            }
        }
        Start-Sleep -Seconds 1
    }
    return $null
}

function Add-RunRecord {
    param($Record)
    $script:State.runs.Add($Record)
    $script:State.suiteState["inFlight"] = $null
    Save-CampaignState
}

function Write-RunLine {
    param($Record, [string]$Prefix)
    $value = "n/a"
    if ($null -ne $Record.headlineValue) {
        if ([string]$Record.headlineUnit -eq "ops/min") { $value = "{0:0.##} ops/min" -f $Record.headlineValue }
        else { $value = Format-Duration -Milliseconds $Record.headlineValue }
    }
    $wall = if ($null -ne $Record.suiteWallMs) { Format-Duration -Milliseconds $Record.suiteWallMs } else { "n/a" }
    $settleText = ""
    $settle = Get-Prop $Record "settle"
    if ($null -ne $settle) { $settleText = (" settle {0:0.#} s{1}" -f (Get-Prop $settle "waitedSec"), $(if ([bool](Get-Prop $settle "timedOut")) { " (timed out)" } else { "" })) }
    $reason = if ([string]::IsNullOrWhiteSpace([string]$Record.invalidReason)) { "" } else { " [" + $Record.invalidReason + "]" }
    $line = "{0} {1,-10} {2,-28} {3,-9} {4,14}  wall {5}{6}{7}" -f $Prefix, $Record.instance, $Record.testCode, $Record.status, $value, $wall, $settleText, $reason
    $color = switch ([string]$Record.status) { "Completed" { "Green" } "Capped" { "Yellow" } "Invalid" { "Yellow" } default { "Red" } }
    if ([bool]$Record.isWarmup -and $Record.status -eq "Completed") { $color = "DarkGreen" }
    Write-SuiteLog $line $color
    if ($Record.status -ne "Completed" -and -not [string]::IsNullOrWhiteSpace([string]$Record.message)) {
        Write-SuiteLog ("    " + $Record.message) "DarkGray"
    }
}

#endregion

#region Environment script (pre-flight, environment capture, engine counters)

function Invoke-EnvironmentScript {
    # Runs Get-PerfEnvironment.ps1 in-process and returns its parsed JSON (or $null). Never throws.
    param([ValidateSet("environment", "preflight", "engineCounters", "tableCounts")][string]$Mode, [string]$OutFile, [string[]]$InstanceNames)
    if ([string]::IsNullOrWhiteSpace($EnvironmentScript) -or -not (Test-Path -LiteralPath $EnvironmentScript)) {
        return $null
    }
    $arguments = @{
        OutFile = $OutFile
        InstanceRoot = $InstanceRoot
        Instances = $InstanceNames
        Quiet = $true
    }
    if ($null -ne $script:State) { $arguments["CampaignDir"] = (Split-Path -Parent $script:State.suiteState["path"]) }
    if (-not [string]::IsNullOrWhiteSpace($MySqlDefaultsFile)) { $arguments["MySqlDefaultsFile"] = $MySqlDefaultsFile }
    if (-not [string]::IsNullOrWhiteSpace($PgPassFile)) { $arguments["PgPassFile"] = $PgPassFile }
    switch ($Mode) {
        "preflight" {
            $arguments["Preflight"] = $true
            if (@($PreflightAllow).Count -gt 0) { $arguments["PreflightAllow"] = [string[]]$PreflightAllow }
        }
        "engineCounters" { $arguments["EngineCounters"] = $true }
        "tableCounts" { $arguments["TableCounts"] = $true }
    }
    try {
        & $EnvironmentScript @arguments *> $null
        if (Test-Path -LiteralPath $OutFile) {
            return ([System.IO.File]::ReadAllText($OutFile) | ConvertFrom-Json)
        }
    }
    catch {
        Write-SuiteLog ("  Get-PerfEnvironment ({0}) failed: {1}" -f $Mode, $_.Exception.Message) "DarkYellow"
    }
    return $null
}

function Get-SiteNames {
    return , @($script:SuiteInstances | ForEach-Object { $_.Name })
}

function Add-TableCountsToState {
    # SPEC 5.4 item 19 and 6.9 step 1: embed the table-count captures found in the campaign folder
    # (Get-PerfEnvironment -TableCounts -> table-counts-<label>.json) under environment.tableCounts, in compact form:
    # the tables whose row count changed against the capture's baseline, and the soft-deleted ARRegister/Batch rows.
    # The report lists them as residue tables.
    param([string]$Folder)
    if ([string]::IsNullOrWhiteSpace($Folder) -or -not (Test-Path -LiteralPath $Folder)) { return }
    $files = @(Get-ChildItem -LiteralPath $Folder -Filter "table-counts-*.json" -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($files.Count -eq 0) { return }
    $map = [ordered]@{}
    foreach ($file in $files) {
        try {
            $doc = [System.IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
            $soft = [ordered]@{}
            $engines = Get-Prop $doc "engines"
            if ($null -ne $engines) {
                foreach ($p in $engines.PSObject.Properties) { $soft[$p.Name] = Get-Prop $p.Value "softDeleted" }
            }
            $map[$file.Name] = [ordered]@{
                label = Get-Prop $doc "label"
                capturedAtUtc = Get-Prop $doc "capturedAtUtc"
                baselineFile = Get-Prop $doc "baselineFile"
                changedTables = Get-Prop $doc "changedTables"
                softDeleted = $soft
            }
        }
        catch {
            Write-SuiteLog ("  {0} could not be embedded: {1}" -f $file.Name, $_.Exception.Message) "DarkYellow"
        }
    }
    if ($map.Count -gt 0) { $script:State.environment["tableCounts"] = $map }
}

function Test-StartEnvironment {
    # Warnings for the operator (SPEC 6.4): a dirty working tree or DLL hashes that differ between the build and the
    # three sites, as recorded by Get-PerfEnvironment in environment-start.json.
    param($StartEnv)
    if ($null -eq $StartEnv) { return }
    $git = Get-Prop (Get-Prop $StartEnv "repo") "git"
    $clean = Get-Prop $git "clean"
    if ($null -ne $clean -and -not [bool]$clean) {
        Add-SuiteEvent -Kind "GateWarning" -Instance $null -Detail ("environment-start: the repository working tree is not clean ({0} changed file(s)); the published results must come from a committed state" -f (Get-Prop $git "porcelainLines"))
    }
    $dll = Get-Prop (Get-Prop $StartEnv "repo") "dll"
    $allEqual = Get-Prop $dll "allEqual"
    if ($null -ne $allEqual -and -not [bool]$allEqual) {
        Add-SuiteEvent -Kind "GateWarning" -Instance $null -Detail "environment-start: the PerfDBBenchmark.Core.dll hashes of the build and the three sites are not all equal (repo.dll.sha256)"
    }
}

function Invoke-PreflightGate {
    # SPEC 5.4 item 17 / gate G6: at P4 start a failure stops the suite; before later blocks wait up to 5 min, then warn.
    # At campaign start a pre-flight that cannot run, or cannot check an engine (for example no credential file), is
    # not a pass: it stops the suite too, unless -AllowUncheckedPreflight. Later blocks only log it.
    param([string]$Block, [bool]$IsFirstBlock)
    $strict = $IsFirstBlock -and -not $AllowUncheckedPreflight
    $uncheckedStop = {
        param([string]$Why)
        $text = "Block {0}: {1}" -f $Block, $Why
        Add-SuiteEvent -Kind "Preflight" -Instance $null -Detail $text
        if ($strict) {
            throw (New-SuiteStop -Kind "preflight" -Message ("Pre-flight could not verify the database clients at campaign start (gate G6). Fix it, or start again with -AllowUncheckedPreflight to accept an unchecked pre-flight. " + $text))
        }
    }
    if ($script:EnvironmentScriptDisabled) {
        Add-SuiteEvent -Kind "Preflight" -Instance $null -Detail ("Block {0}: pre-flight skipped (-EnvironmentScript none)" -f $Block)
        return
    }
    if ([string]::IsNullOrWhiteSpace($EnvironmentScript) -or -not (Test-Path -LiteralPath $EnvironmentScript)) {
        & $uncheckedStop ("pre-flight skipped: environment script not found ({0})" -f $EnvironmentScript)
        return
    }
    $folder = Split-Path -Parent $script:State.suiteState["path"]
    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    $attempt = 0
    while ($true) {
        $attempt++
        $outFile = Join-Path $folder ("preflight-{0}-{1:yyyyMMdd-HHmmss}.json" -f $Block, (Get-Date))
        $result = Invoke-EnvironmentScript -Mode "preflight" -OutFile $outFile -InstanceNames (Get-SiteNames)
        if ($null -eq $result) {
            & $uncheckedStop "pre-flight could not run"
            return
        }
        $offenders = New-Object System.Collections.Generic.List[string]
        $unchecked = New-Object System.Collections.Generic.List[string]
        $checks = Get-Prop $result "checks"
        if ($null -ne $checks) {
            foreach ($p in $checks.PSObject.Properties) {
                foreach ($o in @((Get-Prop $p.Value "offenders") | Where-Object { $null -ne $_ })) {
                    if ($null -ne $o) { $offenders.Add(("{0}: {1} x{2}" -f $p.Name, (Get-Prop $o "client"), (Get-Prop $o "sessions"))) }
                }
                if (-not [bool](Get-Prop $p.Value "checked")) {
                    $unchecked.Add(("{0} ({1})" -f $p.Name, (Get-Prop $p.Value "note")))
                    if ($attempt -eq 1) { Write-SuiteLog ("  Pre-flight {0}: {1}" -f $p.Name, (Get-Prop $p.Value "note")) "DarkYellow" }
                }
            }
        }
        else {
            $unchecked.Add("no checks in the pre-flight output")
        }
        if ($attempt -eq 1 -and $unchecked.Count -gt 0) {
            & $uncheckedStop ("pre-flight could not check: " + ($unchecked -join "; "))
        }
        if ($offenders.Count -eq 0) {
            Write-SuiteLog ("  Pre-flight before Block {0}: OK" -f $Block) "DarkGray"
            return
        }
        $detail = "Block {0}: unexpected database clients: {1}" -f $Block, ($offenders -join "; ")
        if ($IsFirstBlock) {
            Add-SuiteEvent -Kind "Preflight" -Instance $null -Detail $detail
            throw (New-SuiteStop -Kind "preflight" -Message ("Pre-flight failed at campaign start. Close the other clients (or allow them with -PreflightAllow <regex>, which is passed to Get-PerfEnvironment) and start again. " + $detail))
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            Add-SuiteEvent -Kind "Preflight" -Instance $null -Detail ($detail + " (continuing after 5 min)")
            return
        }
        if ($attempt -eq 1) { Add-SuiteEvent -Kind "Preflight" -Instance $null -Detail ($detail + " (waiting up to 5 min)") }
        Start-Sleep -Seconds 30
    }
}

function Get-EngineCounterDelta {
    param($Start, $End)
    $delta = [ordered]@{}
    if ($null -eq $Start -or $null -eq $End) { return $delta }
    foreach ($p in $End.PSObject.Properties) {
        $s = Get-Prop $Start $p.Name
        $sv = 0.0; $ev = 0.0
        if ([double]::TryParse([string]$p.Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$ev) -and
            [double]::TryParse([string]$s, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$sv)) {
            $delta[$p.Name] = $ev - $sv
        }
    }
    return $delta
}

function Read-EngineCounters {
    param($Inst, [string]$Label)
    $folder = Join-Path (Split-Path -Parent $script:State.suiteState["path"]) "diagnostics"
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $file = Join-Path $folder ("engine-counters-{0}-{1}-{2:yyyyMMdd-HHmmss-fff}.json" -f $Inst.Name, $Label, (Get-Date))
    $doc = Invoke-EnvironmentScript -Mode "engineCounters" -OutFile $file -InstanceNames @($Inst.Name)
    if ($null -eq $doc) { return $null }
    return (Get-Prop (Get-Prop $doc "engines") $Inst.DbEngine)
}

#endregion

#region One run (PUT, verify, POST, wait, fetch)

function Set-RunParameters {
    # PUT BenchmarkControl, then GET and compare the effective values (SPEC 3.10 layer 2).
    param($Inst, $Test, [string]$Block, $Rep, $OrderPosition, $RunParams, $RunBudgetSec, [bool]$IsEnv)
    $body = [ordered]@{}
    if ($Inst.Identity.ContainsKey("id")) { $body["id"] = $Inst.Identity["id"] }
    $body["SetupID"] = @{ value = $SetupID }
    $body["SelectedTestCode"] = @{ value = $Test.TestCode }
    $body["CampaignID"] = @{ value = $script:State.campaign["id"] }
    if ($null -ne $Rep) { $body["RepetitionNo"] = @{ value = [int]$Rep } }
    $body["IsWarmup"] = @{ value = [bool]$RunParams.IsWarmup }
    $body["RunBlock"] = @{ value = $Block }
    if ($null -ne $OrderPosition) { $body["OrderPosition"] = @{ value = [int]$OrderPosition } }
    if (-not $IsEnv) {
        $body["WorkScale"] = @{ value = $RunParams.WorkScale }
        $body["PassesOverride"] = @{ value = $RunParams.PassesOverride }
        $body["WarmUpPassesOverride"] = @{ value = $RunParams.WarmUpPassesOverride }
        $body["RunBudgetSec"] = @{ value = $(if ($null -eq $RunBudgetSec) { 0 } else { [int]$RunBudgetSec }) }
        $body["NumberOfRecords"] = @{ value = $CoreRecords }
        $body["Iterations"] = @{ value = $CoreIterations }
        $body["ParallelBatchSize"] = @{ value = $CoreChunkSize }
    }
    [void](Invoke-InstanceRequest -Inst $Inst -Method PUT -RelativeUri "/BenchmarkControl" -Body $body)

    $control = Get-BenchmarkControl -Inst $Inst
    $get = { param($name) Get-RecordFieldValue -Record $control -FieldName $name }
    $mismatches = New-Object System.Collections.Generic.List[string]
    $compareText = {
        param($name, $expected, $actual)
        if ([string]$expected -ne [string]$actual) { $mismatches.Add(("{0}: sent '{1}', got '{2}'" -f $name, $expected, $actual)) }
    }
    $compareNumber = {
        param($name, $expected, $actual, $nullAs)
        $e = if ($null -eq $expected -or [string]::IsNullOrWhiteSpace([string]$expected)) { $nullAs } else { [double]$expected }
        $a = if ($null -eq $actual -or [string]::IsNullOrWhiteSpace([string]$actual)) { $nullAs } else { [double]$actual }
        if ($null -eq $e -and $null -eq $a) { return }
        if ($null -eq $e -or $null -eq $a -or [Math]::Abs([double]$e - [double]$a) -gt 0.00005) { $mismatches.Add(("{0}: sent '{1}', got '{2}'" -f $name, $expected, $actual)) }
    }
    & $compareText "SelectedTestCode" $Test.TestCode ([string](& $get "SelectedTestCode"))
    $gotCampaign = Convert-ToNullableGuid (& $get "CampaignID")
    if ($gotCampaign -ne [Guid]$script:State.campaign["id"]) { $mismatches.Add(("CampaignID: sent '{0}', got '{1}'" -f $script:State.campaign["id"], $gotCampaign)) }
    if (-not $IsEnv) {
        & $compareNumber "RepetitionNo" $Rep (& $get "RepetitionNo") $null
        & $compareNumber "NumberOfRecords" $CoreRecords (& $get "NumberOfRecords") $null
        & $compareNumber "Iterations" $CoreIterations (& $get "Iterations") $null
        & $compareNumber "ParallelBatchSize" $CoreChunkSize (& $get "ParallelBatchSize") $null
        & $compareNumber "WorkScale" $RunParams.WorkScale (& $get "WorkScale") 1.0
        & $compareNumber "PassesOverride" $RunParams.PassesOverride (& $get "PassesOverride") 0.0
        & $compareNumber "WarmUpPassesOverride" $RunParams.WarmUpPassesOverride (& $get "WarmUpPassesOverride") $null
        & $compareNumber "RunBudgetSec" $RunBudgetSec (& $get "RunBudgetSec") 0.0
    }
    $fields = Get-ControlFields $control
    Update-InstanceFromControl -Inst $Inst -Fields $fields
    if (-not [string]::IsNullOrWhiteSpace($script:State.suiteState["serverDllSha256"]) -and $fields.DllSha -ne $script:State.suiteState["serverDllSha256"]) {
        throw (New-SuiteStop -Kind "campaign" -Message ("Gate G4: {0} ServerDllSha256 changed during the campaign (someone republished)." -f $Inst.Name))
    }
    if (-not [string]::IsNullOrWhiteSpace($script:State.suiteState["serverMethodologyVersion"]) -and $fields.Methodology -ne $script:State.suiteState["serverMethodologyVersion"]) {
        throw (New-SuiteStop -Kind "campaign" -Message ("Gate G4: {0} ServerMethodologyVersion changed during the campaign." -f $Inst.Name))
    }
    return [pscustomobject]@{ Mismatches = $mismatches.ToArray(); Control = $control; Fields = $fields }
}

function Get-PendingInFlightDeadline {
    # Block D resume: the run that was in flight when the suite stopped may still be running on the server. It is
    # never aborted while it is within its own wait limit (run budget + 5 min, counted from its request time), because
    # an aborted invoice run leaves a partial set of permanent invoices on one engine only.
    param($Inst)
    $pending = $script:State.suiteState["pendingInFlight"]
    if ($null -eq $pending -or [string](Get-Prop $pending "instance") -ne $Inst.Name) { return $null }
    $limit = Get-WaitLimitSec -TestCode ([string](Get-Prop $pending "testCode"))
    $requested = $null
    try { $requested = Convert-ToNullableDateTime (Get-Prop $pending "requestedAtUtc") } catch { $requested = $null }
    $fromNow = [DateTime]::UtcNow.AddSeconds($limit)
    if ($null -eq $requested) { return $fromNow }
    $fromRequest = $requested.AddSeconds($limit)
    # A clock or marker problem must not make the wait unbounded: at most the wait limit from now.
    if ($fromRequest -gt $fromNow) { return $fromNow }
    return $fromRequest
}

function Wait-InstanceIdle {
    # Never send RunBenchmark to an instance whose control row says Running (SPEC 5.4 item 14).
    param($Inst, [string]$Block)
    $deadline = [DateTime]::UtcNow.AddSeconds($AbortWaitSec)
    $pendingDeadline = Get-PendingInFlightDeadline -Inst $Inst
    $abortSent = $false
    while ($true) {
        $fields = Get-ControlFields (Get-BenchmarkControl -Inst $Inst)
        Update-InstanceFromControl -Inst $Inst -Fields $fields
        if (-not (Test-ControlRunning -Inst $Inst -Fields $fields)) { return $true }
        if ($null -ne $pendingDeadline -and $pendingDeadline -gt $deadline) {
            $deadline = $pendingDeadline
            Add-SuiteEvent -Kind "Resume" -Instance $Inst.Name -Detail ("the interrupted Block D run of {0} is still in progress; waiting for it until {1:HH:mm:ss} UTC before any AbortBenchmark" -f [string](Get-Prop $script:State.suiteState["pendingInFlight"] "testCode"), $deadline)
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            if (-not $abortSent) {
                try { [void](Invoke-InstanceAction -Inst $Inst -ActionName "AbortBenchmark") } catch { }
                Add-SuiteEvent -Kind "Abort" -Instance $Inst.Name -Detail ("a run of {0} was still in progress before the next run; AbortBenchmark sent" -f $fields.TestCode)
                $abortSent = $true
                $deadline = [DateTime]::UtcNow.AddSeconds($AbortWaitSec)
            }
            else {
                $Inst.StuckBlock = $Block
                Save-InstanceState -Inst $Inst
                Add-SuiteEvent -Kind "Stuck" -Instance $Inst.Name -Detail ("still Running 2 min after AbortBenchmark; instance skipped for the rest of Block {0}" -f $Block)
                return $false
            }
        }
        Start-Sleep -Seconds 3
    }
}

function Wait-ForBenchmarkExecution {
    # Polls the control row: start check on LastRequestedTestCode plus a new LastRequestID, then completion.
    # Poll interval: PollFastSec for the first PollFastForSec seconds of the run, then PollSlowSec.
    # At the wait limit: AbortBenchmark, then 2 more minutes, then Stuck (SPEC 5.4 item 14).
    param(
        [Parameter(Mandatory = $true)]$Inst,
        [Parameter(Mandatory = $true)]$Benchmark,
        [Parameter(Mandatory = $true)][DateTime]$InvocationStartedUtc,
        [AllowNull()]$PreviousRequestId,
        [AllowNull()][string]$AppStartBefore,
        [int]$WaitLimitSec,
        [AllowNull()]$Sampler,
        [AllowNull()][string]$ActionInvocationErrorMessage
    )

    $startDeadlineUtc = $InvocationStartedUtc.AddSeconds($RequestStartTimeoutSeconds)
    $waitDeadlineUtc = $InvocationStartedUtc.AddSeconds($WaitLimitSec)
    $requestId = $null
    $latestControl = $null
    $lastPollErrorMessage = $null
    $runSeenAtUtc = $null
    $abortSentAtUtc = $null
    $outcome = { param($kind, $message) [pscustomobject]@{ Outcome = $kind; RequestID = $requestId; Control = $latestControl; Message = $message; Aborted = ($null -ne $abortSentAtUtc) } }

    while ($true) {
        $nowUtc = [DateTime]::UtcNow
        $pollOk = $true
        try {
            $latestControl = Get-BenchmarkControl -Inst $Inst
            $lastPollErrorMessage = $null
        }
        catch {
            $lastPollErrorMessage = $_.Exception.Message
            $pollOk = $false
        }

        if ($pollOk) {
            Add-RunSample -Sampler $Sampler
            $f = Get-ControlFields $latestControl
            Update-InstanceFromControl -Inst $Inst -Fields $f
            Write-Progress -Id 2 -Activity ("{0} on {1}" -f $Benchmark.TestCode, $Inst.Name) -Status ("{0}; elapsed {1}" -f $(if ($null -eq $requestId) { "waiting for the long operation to start" } else { "running" }), (Format-Duration -Milliseconds ($nowUtc - $InvocationStartedUtc).TotalMilliseconds))

            if (-not [string]::IsNullOrWhiteSpace($AppStartBefore) -and -not [string]::IsNullOrWhiteSpace($f.AppStart) -and $f.AppStart -ne $AppStartBefore) {
                # Remember the request even if its start was not matched yet: its Running row is stale from now on.
                if ($null -eq $requestId -and $f.TestCode -eq $Benchmark.TestCode -and $null -ne $f.RequestId -and ($null -eq $PreviousRequestId -or $f.RequestId -ne $PreviousRequestId)) {
                    $requestId = $f.RequestId
                }
                return (& $outcome "AppRestart" ("the application restarted during the run (ServerAppStartUtc {0} -> {1})" -f $AppStartBefore, $f.AppStart))
            }

            if ($null -eq $requestId) {
                $matchingStart = ($f.TestCode -eq $Benchmark.TestCode) -and ($null -ne $f.RequestId) -and ($null -eq $PreviousRequestId -or $f.RequestId -ne $PreviousRequestId)
                if ($matchingStart) {
                    $requestId = $f.RequestId
                    $runSeenAtUtc = $nowUtc
                }
            }

            if ($null -ne $requestId -and $f.RequestId -eq $requestId) {
                if ($f.Status -eq "Completed") { return (& $outcome "Completed" $f.Message) }
                if ($f.Status -eq "Failed") { return (& $outcome "Failed" ("Benchmark '{0}' failed on {1}. {2}" -f $Benchmark.TestCode, $Inst.Name, $f.Message)) }
            }
        }

        if ($null -eq $requestId -and $nowUtc -gt $startDeadlineUtc) {
            $message = if (-not [string]::IsNullOrWhiteSpace([string]$ActionInvocationErrorMessage)) { $ActionInvocationErrorMessage }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$lastPollErrorMessage)) { $lastPollErrorMessage }
            else { "Timed out waiting for benchmark '$($Benchmark.TestCode)' to start on $($Inst.Name)." }
            return (& $outcome "StartTimeout" $message)
        }

        if ($nowUtc -gt $waitDeadlineUtc) {
            if ($null -eq $abortSentAtUtc) {
                try { [void](Invoke-InstanceAction -Inst $Inst -ActionName "AbortBenchmark") } catch { }
                $abortSentAtUtc = $nowUtc
                Add-SuiteEvent -Kind "Abort" -Instance $Inst.Name -Detail ("{0}: wait limit of {1} s reached; AbortBenchmark sent" -f $Benchmark.TestCode, $WaitLimitSec)
            }
            elseif (($nowUtc - $abortSentAtUtc).TotalSeconds -ge $AbortWaitSec) {
                return (& $outcome "Stuck" ("{0} was still Running {1} s after AbortBenchmark" -f $Benchmark.TestCode, $AbortWaitSec))
            }
        }

        $sinceStart = if ($null -ne $runSeenAtUtc) { ($nowUtc - $runSeenAtUtc).TotalSeconds } else { 0 }
        $interval = if ($sinceStart -lt $PollFastForSec) { $PollFastSec } else { $PollSlowSec }
        Start-Sleep -Seconds ([Math]::Max(1, $interval))
    }
}

function Invoke-SuiteRun {
    # One run on one instance: restart check, idle check, re-warm, cool-down + settle gate, counters,
    # PUT + verify, POST RunBenchmark, wait, fetch the result row, restart check, ParamsHash check, append.
    param(
        [Parameter(Mandatory = $true)]$Inst,
        [Parameter(Mandatory = $true)]$Test,
        [Parameter(Mandatory = $true)][string]$Block,
        [AllowNull()]$Rep,
        [AllowNull()]$OrderPosition,
        [Parameter(Mandatory = $true)][string]$Role,
        [int]$RerunRound = 0,
        [ValidateSet("regular", "r0", "env")][string]$ParamProfile = "regular",
        [AllowNull()]$RerunOf = $null,
        $ProfileSettings,
        [string]$ProgressPrefix = ""
    )

    $isEnv = ($Test.TestCode -eq $script:EnvCaptureCode)
    if ($Inst.StuckBlock -eq $Block) { return $null }

    # Restart between runs, and an instance that is still busy.
    $preFields = Get-ControlFields (Get-BenchmarkControl -Inst $Inst)
    Update-InstanceFromControl -Inst $Inst -Fields $preFields
    if (-not [string]::IsNullOrWhiteSpace($Inst.LastAppStartUtc) -and -not [string]::IsNullOrWhiteSpace($preFields.AppStart) -and $preFields.AppStart -ne $Inst.LastAppStartUtc) {
        Add-SuiteEvent -Kind "AppRestart" -Instance $Inst.Name -Detail ("the application restarted between runs (ServerAppStartUtc {0} -> {1})" -f $Inst.LastAppStartUtc, $preFields.AppStart)
        if ($Block -ne "D") { $Inst.NeedsRewarm = $true }
    }
    if (-not [string]::IsNullOrWhiteSpace($preFields.AppStart)) { $Inst.LastAppStartUtc = $preFields.AppStart }
    Save-InstanceState -Inst $Inst
    if (Test-ControlRunning -Inst $Inst -Fields $preFields) {
        if (-not (Wait-InstanceIdle -Inst $Inst -Block $Block)) { return $null }
        $preFields = Get-ControlFields (Get-BenchmarkControl -Inst $Inst)
    }

    # Blocks A-C: one re-warm run (R0 profile) before the next run after an application restart (SPEC 5.4 item 7).
    if ($Inst.NeedsRewarm -and -not $isEnv -and $Role -ne "rewarm") {
        $Inst.NeedsRewarm = $false
        Save-InstanceState -Inst $Inst
        if ($Block -ne "D") {
            Write-SuiteLog ("  {0}: re-warm run of {1} after an application restart" -f $Inst.Name, $Test.TestCode) "DarkYellow"
            [void](Invoke-SuiteRun -Inst $Inst -Test $Test -Block $Block -Rep $Rep -OrderPosition $OrderPosition -Role "rewarm" -ParamProfile "r0" -ProfileSettings $ProfileSettings -ProgressPrefix "  re-warm")
            if ($Inst.StuckBlock -eq $Block) { return $null }
            $preFields = Get-ControlFields (Get-BenchmarkControl -Inst $Inst)
        }
    }

    $runParams = Get-RunParameters -Test $Test -Block $Block -ParamProfile $ParamProfile -ProfileSettings $ProfileSettings
    $budget = if ($isEnv) { $null } else { Get-RunBudgetSec -TestCode $Test.TestCode }
    $isWarmup = [bool]$runParams.IsWarmup -or $Role -eq "rewarm"
    $record = New-RunRecord -Inst $Inst -Test $Test -Block $Block -Rep $Rep -OrderPosition $OrderPosition -IsWarmup $isWarmup -Role $Role -RerunRound $RerunRound -RerunOf $RerunOf -RunParams $runParams -RunBudgetSec $budget

    # Parameters (SPEC 3.10 layer 2).
    $verify = Set-RunParameters -Inst $Inst -Test $Test -Block $Block -Rep $Rep -OrderPosition $OrderPosition -RunParams $runParams -RunBudgetSec $budget -IsEnv $isEnv
    $record.serverAppStartBefore = $verify.Fields.AppStart
    if (@($verify.Mismatches).Count -gt 0) {
        $record.status = "Failed"
        $record.invalidReason = "ParamsMismatch"
        $record.message = "Not started: " + (@($verify.Mismatches) -join "; ")
        Add-SuiteEvent -Kind "ParamsMismatch" -Instance $Inst.Name -Detail ("{0}: {1}" -f $Test.TestCode, (@($verify.Mismatches) -join "; "))
        Add-RunRecord -Record $record
        Write-RunLine -Record $record -Prefix $ProgressPrefix
        return $record
    }

    # Engine counters (DryRun -Diagnostics) and the in-flight mark are taken before the settle gate, so that
    # neither the counter queries nor the JSON rewrite run just before the timed run.
    $diagStart = $null
    if (-not $isEnv -and $script:DiagnosticsEnabled) { $diagStart = Read-EngineCounters -Inst $Inst -Label "start" }

    # Mark the run in flight (resume uses it to recover a run whose result the suite never saw).
    $script:State.suiteState["inFlight"] = [ordered]@{ instance = $Inst.Name; testCode = $Test.TestCode; block = $Block; repetitionNo = $Rep; rerunRound = $RerunRound; role = $Role; requestedAtUtc = [DateTime]::UtcNow.ToString("o") }
    Save-CampaignState

    # Cool-down + settle gate (benchmark runs only), immediately before the run.
    $sampler = $null
    if (-not $isEnv) {
        $coolDown = if ($script:LastRunUserCount -ge 8) { $CoolDownSecAfterMultiUser } else { 0 }
        $record.settle = Invoke-SettleGate -Block $Block -EngineAboutToRun $Inst.DbEngine -CoolDownSec $coolDown
        $timeouts = $script:State.suiteState["settleTimeouts"]
        if (-not $timeouts.Contains($Block)) { $timeouts[$Block] = [ordered]@{ runs = 0; timedOut = 0 } }
        $timeouts[$Block]["runs"] = [int]$timeouts[$Block]["runs"] + 1
        if ([bool]$record.settle["timedOut"]) {
            $timeouts[$Block]["timedOut"] = [int]$timeouts[$Block]["timedOut"] + 1
            $otherText = if ([bool]$record.settle["checkedOtherDb"]) { ", other DB {0}% of a core / {1} MB/s" -f $record.settle["otherDbCpuPctOfCore"], $record.settle["otherDbIoMBps"] } else { "" }
            Add-SuiteEvent -Kind "SettleTimeout" -Instance $Inst.Name -Detail ("{0} {1}: CPU {2}%, disk {3} MB/s{4}" -f $Block, $Test.TestCode, $record.settle["cpuBeforePct"], $record.settle["diskBeforeMBps"], $otherText)
        }
    }

    $procStart = $null
    if (-not $isEnv) {
        $procStart = Get-ProcessRawSnapshot
        $sampler = New-RunSampler
    }

    $invocationStartedUtc = [DateTime]::UtcNow
    $record.startedAtUtc = $invocationStartedUtc.ToString("o")
    $actionInvocationErrorMessage = $null
    $Inst.RunningRequestAppStart = $verify.Fields.AppStart
    # From here on the server may run (and, in Block D, create permanent invoices) even if this suite fails:
    # Invoke-GroupRuns then keeps the in-flight marker for the resume instead of recording a Failed run.
    $script:PostedRun = [ordered]@{ instance = $Inst.Name; testCode = $Test.TestCode; block = $Block }
    try {
        [void](Invoke-InstanceAction -Inst $Inst -ActionName "RunBenchmark")
    }
    catch {
        $actionInvocationErrorMessage = $_.Exception.Message
    }
    $wait = Wait-ForBenchmarkExecution -Inst $Inst -Benchmark $Test -InvocationStartedUtc $invocationStartedUtc -PreviousRequestId $preFields.RequestId -AppStartBefore $verify.Fields.AppStart -WaitLimitSec (Get-WaitLimitSec -TestCode $Test.TestCode) -Sampler $sampler -ActionInvocationErrorMessage $actionInvocationErrorMessage
    Write-Progress -Id 2 -Activity "run" -Completed
    $Inst.RunningRequestId = $wait.RequestID
    $completedUtc = [DateTime]::UtcNow
    $record.completedAtUtc = $completedUtc.ToString("o")
    $record.suiteWallMs = [Math]::Round(($completedUtc - $invocationStartedUtc).TotalMilliseconds, 1)
    $record.requestId = if ($null -ne $wait.RequestID) { $wait.RequestID.ToString() } else { $null }
    $record.message = $wait.Message

    if (-not $isEnv) {
        $procEnd = Get-ProcessRawSnapshot
        $elapsedMs = [Math]::Round(([double]($procEnd.at - $procStart.at) / [System.Diagnostics.Stopwatch]::Frequency) * 1000.0, 1)
        $record.procCounters = [ordered]@{
            start = (Get-SnapshotGroups -Snapshot $procStart)
            end = (Get-SnapshotGroups -Snapshot $procEnd)
            delta = (Get-SnapshotDelta -Start $procStart -End $procEnd)
            elapsedMs = $elapsedMs
            available = ([bool]$procStart.ok -and [bool]$procEnd.ok)
        }
        if ($script:DiagnosticsEnabled) {
            $diagEnd = Read-EngineCounters -Inst $Inst -Label "end"
            $record.diagnostics = [ordered]@{ engine = $Inst.DbEngine; start = $diagStart; end = $diagEnd; delta = (Get-EngineCounterDelta -Start $diagStart -End $diagEnd) }
        }
        $record.settle["cpuAvgPct"] = Get-Average -Values $sampler.cpu.ToArray()
        $record.settle["perfAvgPct"] = Get-Average -Values $sampler.perf.ToArray()
        $temps = @($sampler.temp | Where-Object { $null -ne $_ })
        $record.settle["tempC"] = if ($temps.Count -gt 0) { ($temps | Measure-Object -Maximum).Maximum } else { $null }
    }

    # Result row (no fallback to LastRequestElapsedMs; SPEC 5.4 item 6).
    if ($null -ne $wait.RequestID -and ($wait.Outcome -eq "Completed" -or $wait.Outcome -eq "AppRestart" -or $wait.Outcome -eq "Failed" -or $wait.Outcome -eq "Stuck")) {
        $row = $null
        if ($wait.Outcome -eq "Completed" -or $wait.Outcome -eq "AppRestart") {
            $row = Get-ResultRowForRun -Inst $Inst -RequestId $wait.RequestID -TestCode $Test.TestCode
        }
        if ($null -ne $row) {
            Update-RecordFromResultRow -Record $record -Row $row
        }
        elseif ($wait.Outcome -eq "Completed") {
            $record.status = "Failed"
            $record.message = "The run completed but its BenchmarkResult row was not found (RunID " + $record.requestId + "). " + [string]$wait.Message
        }
    }
    if ($wait.Outcome -ne "Completed" -and $null -eq $record.serverStatus) {
        $record.status = "Failed"
    }
    if ($wait.Outcome -eq "Stuck") {
        $record.stuck = $true
        $Inst.StuckBlock = $Block
        Add-SuiteEvent -Kind "Stuck" -Instance $Inst.Name -Detail ("{0}: {1}; instance skipped for the rest of Block {2}" -f $Test.TestCode, $wait.Message, $Block)
    }

    # Restart during the run (SPEC 5.4 item 7).
    $afterFields = $null
    try { $afterFields = Get-ControlFields (Get-BenchmarkControl -Inst $Inst) } catch { $afterFields = $null }
    $appAfter = if ($null -ne $afterFields) { $afterFields.AppStart } else { $null }
    $record.serverAppStartAfter = $appAfter
    $restarted = ($wait.Outcome -eq "AppRestart") -or (-not [string]::IsNullOrWhiteSpace($verify.Fields.AppStart) -and -not [string]::IsNullOrWhiteSpace($appAfter) -and $appAfter -ne $verify.Fields.AppStart)
    if ($restarted) {
        $record.isWarmup = $true
        $record.invalidReason = "AppRestart"
        if ($wait.Outcome -ne "AppRestart") {
            Add-SuiteEvent -Kind "AppRestart" -Instance $Inst.Name -Detail ("{0}: ServerAppStartUtc changed during the run ({1} -> {2})" -f $Test.TestCode, $verify.Fields.AppStart, $appAfter)
        }
        else {
            Add-SuiteEvent -Kind "AppRestart" -Instance $Inst.Name -Detail ("{0}: {1}" -f $Test.TestCode, $wait.Message)
        }
        if ($Block -ne "D" -and -not $isEnv) { $Inst.NeedsRewarm = $true }
    }
    if (-not [string]::IsNullOrWhiteSpace($appAfter)) { $Inst.LastAppStartUtc = $appAfter }
    Save-InstanceState -Inst $Inst

    # ParamsHash (SPEC 3.10 layer 3): the first valid non-warm-up run of a test fixes the expected hash.
    if (-not $isEnv -and -not $record.isWarmup -and ($record.status -eq "Completed" -or $record.status -eq "Capped") -and -not [string]::IsNullOrWhiteSpace([string]$record.paramsHash)) {
        $expected = $script:State.suiteState["expectedParamsHash"]
        if (-not $expected.Contains($Test.TestCode)) {
            $expected[$Test.TestCode] = $record.paramsHash
        }
        elseif ($expected[$Test.TestCode] -ne $record.paramsHash) {
            $record.status = "Invalid"
            $record.invalidReason = "ParamsHashMismatch"
            $record.message = ("ParamsHash {0} differs from the campaign's {1} for {2}" -f $record.paramsHash, $expected[$Test.TestCode], $Test.TestCode)
            Add-SuiteEvent -Kind "ParamsMismatch" -Instance $Inst.Name -Detail $record.message
        }
    }
    if (Test-RecordValid $record) { $record.slot.usedInAnalysis = ($Role -in @("original", "resume", "rerun")) }

    if (-not $isEnv) { $script:LastRunUserCount = if ($null -ne $record.userCount) { [int]$record.userCount } else { 1 } }
    Add-RunRecord -Record $record
    $script:PostedRun = $null
    Write-RunLine -Record $record -Prefix $ProgressPrefix
    if ($StopOnFailure -and $record.status -eq "Failed") {
        throw (New-SuiteStop -Kind "failure" -Message ("-StopOnFailure: {0} failed on {1}: {2}" -f $Test.TestCode, $Inst.Name, $record.message))
    }
    return $record
}

#endregion

#region Environment captures and gates (SPEC section 6.7)

function Get-EnvFacts {
    param([AllowNull()]$Env)
    $facts = [ordered]@{ present = ($null -ne $Env); masterDataHash = $null; dataFingerprintHash = $null; dataFingerprintStaticHash = $null; leftovers = $null; archived = $null; dAffected = [ordered]@{}; connection = $null }
    if ($null -eq $Env) { return $facts }
    $facts.masterDataHash = [string](Find-JsonValue -Node $Env -Name "masterDataHash")
    $facts.dataFingerprintHash = [string](Find-JsonValue -Node $Env -Name "dataFingerprintHash")
    $facts.dataFingerprintStaticHash = [string](Find-JsonValue -Node $Env -Name "dataFingerprintStaticHash")

    $leftovers = Find-JsonValue -Node $Env -Name "leftovers"
    if ($null -ne $leftovers) {
        if (Test-IsScalar $leftovers) {
            $value = 0.0
            if ([double]::TryParse([string]$leftovers, [ref]$value)) { $facts.leftovers = $value }
        }
        elseif ($null -ne (Get-Prop $leftovers "total")) {
            # ENV_CAPTURE writes leftovers.total next to its parts: use it, so the parts are not counted twice.
            # A non-numeric total ("unavailable") means a part could not be read: leave it unread (G3 warning).
            $value = 0.0
            $total = Get-Prop $leftovers "total"
            if ($total -isnot [bool] -and [double]::TryParse([string]$total, [ref]$value)) { $facts.leftovers = $value }
        }
        else {
            $sum = 0.0
            foreach ($entry in (Get-JsonLeaves -Node $leftovers).GetEnumerator()) {
                $value = 0.0
                if ($entry.Value -isnot [bool] -and [double]::TryParse([string]$entry.Value, [ref]$value)) { $sum += $value }
            }
            $facts.leftovers = $sum
        }
    }

    $fingerprint = Find-JsonValue -Node $Env -Name "dataFingerprint"
    $leaves = Get-JsonLeaves -Node $(if ($null -ne $fingerprint) { $fingerprint } else { $Env })
    foreach ($entry in $leaves.GetEnumerator()) {
        if ($null -eq $facts.archived -and $entry.Key -match '(?i)archived') {
            $value = 0.0
            if ([double]::TryParse([string]$entry.Value, [ref]$value)) { $facts.archived = $value }
        }
        if ($null -ne $fingerprint -and $entry.Key -match '(?i)GLTran|GLHistory|ARTran|ARRegister' -and $entry.Key -notmatch '(?i)hash$') {
            $facts.dAffected[$entry.Key] = [string]$entry.Value
        }
    }

    $db = Find-JsonValue -Node $Env -Name "db"
    $connectionLeaves = Get-JsonLeaves -Node $(if ($null -ne $db) { $db } else { $Env })
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $connectionLeaves.GetEnumerator()) {
        $leafName = ($entry.Key -split '\.')[-1]
        if ($entry.Key -notmatch '(?i)webConfig' -and $leafName -match '(?i)transport|protocol|encrypt|ssl|cipher|isolation') {
            $parts.Add(("{0}={1}" -f $entry.Key, $entry.Value))
        }
    }
    $facts.connection = if ($parts.Count -gt 0) { (@($parts | Sort-Object) -join "; ") } else { $null }
    return $facts
}

function Add-EnvCapture {
    param([string]$Instance, [string]$Block, $Rep, [int]$RerunRound, $Record, $Env)
    $script:State.environment.envCaptures.Add([pscustomobject][ordered]@{
            instance = $Instance
            block = $Block
            repetitionNo = $Rep
            rerunRound = $RerunRound
            runId = $Record.requestId
            capturedAtUtc = $Record.completedAtUtc
            env = $Env
        })
}

function Invoke-EnvCapture {
    # ENV_CAPTURE on one instance (retried once). Returns the env object or $null.
    param($Inst, [string]$Block, $Rep, $OrderPosition, [int]$RerunRound, $ProfileSettings)
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        if ($Inst.StuckBlock -eq $Block) { return $null }
        try {
            $record = Invoke-SuiteRun -Inst $Inst -Test $script:EnvTest -Block $Block -Rep $Rep -OrderPosition $OrderPosition -Role "gate" -RerunRound $RerunRound -ParamProfile "env" -ProfileSettings $ProfileSettings -ProgressPrefix "  env"
        }
        catch {
            # A REST error must not end the campaign (SPEC 5.4 item 14): the gates skip this instance for the
            # repetition; an unreadable control row marks it Stuck for the block.
            if (Test-SuiteStopError $_) { throw }
            $script:PostedRun = $null
            if ($null -ne $script:State.suiteState["inFlight"] -and [string](Get-Prop $script:State.suiteState["inFlight"] "testCode") -eq $script:EnvCaptureCode) { $script:State.suiteState["inFlight"] = $null }
            Add-SuiteEvent -Kind "GateWarning" -Instance $Inst.Name -Detail ("ENV_CAPTURE attempt {0} failed: {1}" -f $attempt, $_.Exception.Message)
            if (-not (Test-InstanceReachable -Inst $Inst)) {
                $Inst.StuckBlock = $Block
                Save-InstanceState -Inst $Inst
                Add-SuiteEvent -Kind "Stuck" -Instance $Inst.Name -Detail ("control row not readable after an ENV_CAPTURE error; instance skipped for the rest of Block {0}" -f $Block)
            }
            Save-CampaignState
            continue
        }
        if ($null -eq $record) { continue }
        $env = Get-Prop $record.result "env"
        if ($null -ne $env) {
            Add-EnvCapture -Instance $Inst.Name -Block $Block -Rep $Rep -RerunRound $RerunRound -Record $record -Env $env
            Set-RecordValue -Record $record.result -Name "env" -Value "(stored in environment.envCaptures)"
            Save-CampaignState
            Write-Output -NoEnumerate $env
            return
        }
    }
    return $null
}

function Invoke-EnvCaptureRound {
    param([string]$Block, $Rep, [string[]]$Order, [int]$RerunRound, $ProfileSettings)
    $envs = [ordered]@{}
    $position = 0
    foreach ($name in $Order) {
        $position++
        $inst = $script:InstancesByName[$name]
        if ($inst.StuckBlock -eq $Block) { $envs[$name] = $null; continue }
        $envs[$name] = Invoke-EnvCapture -Inst $inst -Block $Block -Rep $Rep -OrderPosition $position -RerunRound $RerunRound -ProfileSettings $ProfileSettings
    }
    return $envs
}

function Get-DistinctValues {
    param([object[]]$Values)
    return , @($Values | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
}

function Test-RepetitionGates {
    param([string]$Block, $Rep, [string[]]$Order, $Envs, [int]$RerunRound, $ProfileSettings)
    $out = [pscustomobject]@{ AbortCampaign = $null; AbortBlock = $null; Skip = (New-Object System.Collections.Generic.List[string]) }
    $label = if ($RerunRound -gt 0) { "Block {0} re-run round {1}" -f $Block, $RerunRound } else { "Block {0} R{1}" -f $Block, $Rep }
    $facts = [ordered]@{}

    foreach ($name in $Order) {
        $inst = $script:InstancesByName[$name]
        if ($inst.StuckBlock -eq $Block) {
            $out.Skip.Add($name)
            continue
        }
        if ($null -eq $Envs[$name]) {
            Add-SuiteEvent -Kind "GateFailed" -Instance $name -Detail ("{0}: ENV_CAPTURE failed; instance skipped for this repetition" -f $label)
            $out.Skip.Add($name)
            continue
        }
        $facts[$name] = Get-EnvFacts -Env $Envs[$name]
    }

    # G4: deployment unchanged.
    foreach ($name in $Order) {
        $inst = $script:InstancesByName[$name]
        if ($inst.LastDllSha -ne $script:State.suiteState["serverDllSha256"] -or $inst.LastMethodology -ne $script:State.suiteState["serverMethodologyVersion"]) {
            $out.AbortCampaign = ("Gate G4 ({0}): {1} reports ServerDllSha256/ServerMethodologyVersion different from the campaign values (someone republished)." -f $label, $name)
            return $out
        }
    }

    # G3: leftovers = 0, otherwise ClearTestRecords and recapture; still failing -> skip the instance for this repetition.
    $position = 0
    foreach ($name in $Order) {
        $position++
        if (-not $facts.Contains($name)) { continue }
        $f = $facts[$name]
        if ($null -eq $f.leftovers) {
            Add-SuiteEvent -Kind "GateWarning" -Instance $name -Detail ("{0}: gate G3 could not read the leftovers from ENV_CAPTURE" -f $label)
            continue
        }
        if ($f.leftovers -gt 0) {
            Add-SuiteEvent -Kind "GateFailed" -Instance $name -Detail ("{0}: gate G3 leftovers = {1}; running ClearTestRecords and capturing again" -f $label, $f.leftovers)
            $inst = $script:InstancesByName[$name]
            [void](Invoke-ClearTestRecords -Inst $inst)
            $env = Invoke-EnvCapture -Inst $inst -Block $Block -Rep $Rep -OrderPosition $position -RerunRound $RerunRound -ProfileSettings $ProfileSettings
            $Envs[$name] = $env
            $f = Get-EnvFacts -Env $env
            $facts[$name] = $f
            if (-not $f.present -or $null -eq $f.leftovers -or $f.leftovers -gt 0) {
                Add-SuiteEvent -Kind "GateFailed" -Instance $name -Detail ("{0}: gate G3 still failing (leftovers {1}); instance skipped for this repetition" -f $label, $f.leftovers)
                $out.Skip.Add($name)
            }
        }
    }

    # Instances skipped by G3 (leftovers that ClearTestRecords could not remove) do not run in this repetition: their
    # leftover documents change the pools behind masterDataHash and the counts behind dataFingerprintHash, so they
    # are left out of G1, G2/G2d, G5 and G7 instead of aborting the campaign or the block for everyone.
    $present = @($facts.Keys | Where-Object { $facts[$_].present -and $out.Skip -notcontains $_ })
    foreach ($name in @($out.Skip | Select-Object -Unique)) {
        if ($facts.Contains($name) -and $facts[$name].present) {
            Add-SuiteEvent -Kind "GateWarning" -Instance $name -Detail ("{0}: skipped by G3, so not compared by G1/G2 (masterDataHash {1}, dataFingerprintHash {2})" -f $label, $facts[$name].masterDataHash, $facts[$name].dataFingerprintHash)
        }
    }
    if ($present.Count -lt 2) {
        $out.AbortBlock = ("{0}: fewer than two environment captures; the gates cannot compare instances" -f $label)
        return $out
    }

    # G1: master data identical.
    $master = Get-DistinctValues -Values @($present | ForEach-Object { $facts[$_].masterDataHash })
    if (@($present | Where-Object { [string]::IsNullOrWhiteSpace([string]$facts[$_].masterDataHash) }).Count -gt 0) {
        Add-SuiteEvent -Kind "GateWarning" -Instance $null -Detail ("{0}: masterDataHash missing in ENV_CAPTURE on at least one instance" -f $label)
    }
    if ($master.Count -gt 1) {
        $out.AbortCampaign = ("Gate G1 ({0}): masterDataHash differs: {1}" -f $label, (($present | ForEach-Object { "{0}={1}" -f $_, $facts[$_].masterDataHash }) -join ", "))
        return $out
    }

    # G2 (Blocks A-C, and Block D before its first benchmark run) or G2d (Block D afterwards).
    # A pending in-flight Block D run (resume) may already have changed the data on its instance.
    $dRunsExist = (@($script:State.runs | Where-Object { $_.block -eq "D" -and $_.testCode -ne $script:EnvCaptureCode }).Count -gt 0) -or ($null -ne $script:State.suiteState["pendingInFlight"])
    if ($Block -ne "D" -or -not $dRunsExist) {
        $hashes = Get-DistinctValues -Values @($present | ForEach-Object { $facts[$_].dataFingerprintHash })
        if ($hashes.Count -gt 1) {
            $out.AbortBlock = ("Gate G2 ({0}): dataFingerprintHash differs: {1}" -f $label, (($present | ForEach-Object { "{0}={1}" -f $_, $facts[$_].dataFingerprintHash }) -join ", "))
            return $out
        }
    }
    else {
        $static = Get-DistinctValues -Values @($present | ForEach-Object { $facts[$_].dataFingerprintStaticHash })
        if ($static.Count -gt 1) {
            $out.AbortBlock = ("Gate G2d ({0}): dataFingerprintStaticHash differs: {1}" -f $label, (($present | ForEach-Object { "{0}={1}" -f $_, $facts[$_].dataFingerprintStaticHash }) -join ", "))
            return $out
        }
        $keys = @($present | ForEach-Object { @($facts[$_].dAffected.Keys) } | Select-Object -Unique)
        $differences = New-Object System.Collections.Generic.List[string]
        foreach ($key in $keys) {
            $values = @($present | ForEach-Object { $facts[$_].dAffected[$key] })
            if (@($values | Select-Object -Unique).Count -gt 1) {
                $differences.Add(("{0}: {1}" -f $key, (($present | ForEach-Object { "{0}={1}" -f $_, $facts[$_].dAffected[$key] }) -join ", ")))
            }
        }
        if ($differences.Count -gt 0) {
            $failed = New-Object System.Collections.Generic.List[string]
            foreach ($r in @($script:State.runs | Where-Object { $_.block -eq "D" -and $_.testCode -ne $script:EnvCaptureCode })) {
                $ops = @((Get-Prop (Get-Prop $r.result "errors") "failedOps") | Where-Object { $null -ne $_ })
                if ($ops.Count -gt 0 -and $null -ne $ops[0]) { $failed.Add(("{0} {1} R{2}: {3}" -f $r.instance, $r.testCode, $r.repetitionNo, ($ops -join ","))) }
            }
            $failedText = if ($failed.Count -gt 0) { " Failed operations: " + ($failed -join " | ") } else { " No failed operations recorded." }
            Add-SuiteEvent -Kind "GateWarning" -Instance $null -Detail ("Gate G2d ({0}): D-affected keys differ (disclosed, not an abort): {1}.{2}" -f $label, ($differences -join "; "), $failedText)
        }
    }

    # G5: Block A only, no archived SOOrder rows.
    if ($Block -eq "A") {
        foreach ($name in $present) {
            $archived = $facts[$name].archived
            if ($null -eq $archived) {
                Add-SuiteEvent -Kind "GateWarning" -Instance $name -Detail ("{0}: gate G5 could not read the archived SOOrder count" -f $label)
            }
            elseif ($archived -gt 0) {
                $out.AbortBlock = ("Gate G5 ({0}): {1} has {2} SOOrder rows with DatabaseRecordStatus <> 0" -f $label, $name, $archived)
                return $out
            }
        }
    }

    # G7: client connection and isolation unchanged since the start (item 20).
    foreach ($name in $present) {
        $connection = $facts[$name].connection
        if ([string]::IsNullOrWhiteSpace([string]$connection)) { continue }
        $reference = $script:State.campaign["clientConnection"]
        if (-not $reference.Contains($name) -or [string]::IsNullOrWhiteSpace([string]$reference[$name])) {
            $reference[$name] = $connection
        }
        elseif ([string]$reference[$name] -ne $connection) {
            Add-SuiteEvent -Kind "GateWarning" -Instance $name -Detail ("Gate G7 ({0}): client connection or isolation changed: '{1}' -> '{2}'" -f $label, $reference[$name], $connection)
        }
    }
    Save-CampaignState
    return $out
}

#endregion

#region Blocks, repetitions, re-runs and resume

function Get-SkippedEntries {
    param([string]$Block, [string]$TestCode, $Rep, [int]$Round)
    return , @($script:State.suiteState["skipped"] | Where-Object { $_.block -eq $Block -and $_.testCode -eq $TestCode -and (Test-RepEqual $_.repetitionNo $Rep) -and [int](Get-Prop $_ "rerunRound") -eq $Round })
}

function Add-SkippedEntry {
    param([string]$Block, [string]$TestCode, $Rep, [int]$Round, [string]$Instance, [string]$Reason)
    $script:State.suiteState["skipped"].Add([pscustomobject][ordered]@{ block = $Block; testCode = $TestCode; repetitionNo = $Rep; rerunRound = $Round; instance = $Instance; reason = $Reason; atUtc = [DateTime]::UtcNow.ToString("o") })
}

function Get-SlotRecords {
    # Active benchmark records (original, resume, rerun) of one (block, test, repetition) slot; $Round < 0 = every round.
    param([string]$Block, [string]$TestCode, $Rep, [int]$Round = -1)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($r in $script:State.runs) {
        if ($r.block -ne $Block -or $r.testCode -ne $TestCode) { continue }
        if (-not [string]::IsNullOrEmpty([string]$r.supersedeReason)) { continue }
        $slot = $r.slot
        $role = [string]$slot.role
        if ($role -ne "original" -and $role -ne "resume" -and $role -ne "rerun") { continue }
        # (PowerShell variable names are case-insensitive: never reuse a parameter name such as $Round for a local.)
        $recordRound = if ($null -eq $slot.rerunRound) { 0 } else { [int]$slot.rerunRound }
        if ($Round -ge 0 -and $recordRound -ne $Round) { continue }
        if (-not (Test-RepEqual $r.repetitionNo $Rep)) { continue }
        $list.Add($r)
    }
    return , $list.ToArray()
}

function Get-GroupRecords {
    # Active benchmark records of one (block, test, repetition, re-run round) group.
    param([string]$Block, [string]$TestCode, $Rep, [int]$Round)
    return , (Get-SlotRecords -Block $Block -TestCode $TestCode -Rep $Rep -Round $Round)
}

function Get-GroupDecision {
    # Resume rules (SPEC 5.4 item 10): Blocks A-C re-run an interrupted triple on all instances (earlier runs
    # superseded with reason "resume"); Block D never repeats a completed (test, instance) run.
    param([string]$Block, [string]$TestCode, [int]$Rep, [string[]]$Order, [int]$Round)
    $records = Get-GroupRecords -Block $Block -TestCode $TestCode -Rep $Rep -Round $Round
    $skipped = Get-SkippedEntries -Block $Block -TestCode $TestCode -Rep $Rep -Round $Round
    $done = @(@($records | ForEach-Object { $_.instance }) + @($skipped | ForEach-Object { $_.instance }) | Select-Object -Unique)
    $missing = @($Order | Where-Object { $done -notcontains $_ })
    $roleNew = if ($Round -eq 0) { "original" } else { "rerun" }
    if ($missing.Count -eq 0) {
        return [pscustomobject]@{ Action = "skip"; Instances = @(); Role = $roleNew; Supersede = @(); Partial = $false }
    }
    if ($done.Count -eq 0) {
        return [pscustomobject]@{ Action = "run"; Instances = $Order; Role = $roleNew; Supersede = @(); Partial = $false }
    }
    $roleResume = if ($Round -eq 0) { "resume" } else { "rerun" }
    if ($Block -eq "D") {
        return [pscustomobject]@{ Action = "run"; Instances = $missing; Role = $roleResume; Supersede = @(); Partial = $true }
    }
    return [pscustomobject]@{ Action = "run"; Instances = $Order; Role = $roleResume; Supersede = $records; Partial = $true }
}

function Invoke-SupersedeRecords {
    param([object[]]$Records, [string]$Reason)
    foreach ($r in $Records) {
        Set-RecordValue -Record $r -Name "supersedeReason" -Value $Reason
        Set-RecordValue -Record $r.slot -Name "usedInAnalysis" -Value $false
    }
    # skipped entries of the group are replaced by the new runs as well
    Save-CampaignState
}

function Set-SupersededBy {
    param([object[]]$Superseded, [string]$Instance, $NewRecord)
    if ($null -eq $NewRecord) { return }
    foreach ($r in @($Superseded | Where-Object { $_.instance -eq $Instance })) {
        Set-RecordValue -Record $r -Name "supersededBy" -Value $NewRecord.requestId
    }
}

function Resolve-InFlightRun {
    # Block D resume: the run that was in flight when the suite stopped may have finished on the server.
    # Adopt its result instead of running it again (never two runs of one (test, instance) slot in Block D).
    param($Inst, $Test, [string]$Block, [int]$Rep, [int]$Round, [string]$Role, $OrderPosition)
    $inFlight = $script:State.suiteState["pendingInFlight"]
    if ($null -eq $inFlight) { return $null }
    if ([string](Get-Prop $inFlight "instance") -ne $Inst.Name -or [string](Get-Prop $inFlight "testCode") -ne $Test.TestCode -or [string](Get-Prop $inFlight "block") -ne $Block -or -not (Test-RepEqual (Get-Prop $inFlight "repetitionNo") $Rep) -or [int](Get-Prop $inFlight "rerunRound") -ne $Round) {
        return $null
    }
    Write-SuiteLog ("  {0}: checking the server for the interrupted {1} run" -f $Inst.Name, $Test.TestCode) "DarkYellow"
    if (-not (Wait-InstanceIdle -Inst $Inst -Block $Block)) { return $null }
    $known = @{}
    foreach ($r in $script:State.runs) { if ($null -ne $r.requestId) { $known[[string]$r.requestId] = $true } }
    $row = $null
    $queriesOk = 0
    $query = '$filter=' + [Uri]::EscapeDataString(("CampaignID eq guid'{0}' and TestCode eq '{1}'" -f $script:State.campaign["id"], $Test.TestCode))
    foreach ($q in @($query, ('$filter=' + [Uri]::EscapeDataString("TestCode eq '$($Test.TestCode)'") + '&$top=20'))) {
        try {
            $candidates = Get-ResultRows -Inst $Inst -Query $q
            $queriesOk++
            foreach ($candidate in $candidates) {
                $runId = [string](Get-RecordFieldValue -Record $candidate -FieldName "RunID")
                $campaign = [string](Get-RecordFieldValue -Record $candidate -FieldName "CampaignID")
                $rowBlock = [string](Get-RecordFieldValue -Record $candidate -FieldName "RunBlock")
                $repNo = Convert-ToNullableInt (Get-RecordFieldValue -Record $candidate -FieldName "RepetitionNo")
                if ($known.ContainsKey($runId) -or $campaign -ne [string]$script:State.campaign["id"] -or $rowBlock -ne $Block -or -not (Test-RepEqual $repNo $Rep)) { continue }
                $row = $candidate
                break
            }
        }
        catch {
        }
        if ($null -ne $row) { break }
    }
    if ($queriesOk -eq 0) {
        # Never risk a second invoice run in Block D because the server could not be asked: stop and let the operator resume.
        throw (New-SuiteStop -Kind "failure" -Message ("Block D resume: the results of {0} could not be read to check the interrupted {1} run; resume again later." -f $Inst.Name, $Test.TestCode))
    }
    # The marker is consumed once the server has been checked (a crash before this point keeps it for the next resume).
    $script:State.suiteState["pendingInFlight"] = $null
    if ($null -eq $row) {
        Add-SuiteEvent -Kind "Resume" -Instance $Inst.Name -Detail ("Block D: the interrupted {0} R{1} run left no result on the server; it runs now" -f $Test.TestCode, $Rep)
        Save-CampaignState
        return $null
    }
    $paramProfile = if ($Rep -eq 0) { "r0" } else { "regular" }
    $runParams = Get-RunParameters -Test $Test -Block $Block -ParamProfile $paramProfile -ProfileSettings $script:ProfileSettings
    $record = New-RunRecord -Inst $Inst -Test $Test -Block $Block -Rep $Rep -OrderPosition $OrderPosition -IsWarmup ([bool]$runParams.IsWarmup) -Role $Role -RerunRound $Round -RerunOf $null -RunParams $runParams -RunBudgetSec (Get-RunBudgetSec -TestCode $Test.TestCode)
    $record.requestId = [string](Get-RecordFieldValue -Record $row -FieldName "RunID")
    $record.recoveredFromServer = $true
    Update-RecordFromResultRow -Record $record -Row $row
    $record.message = "Recovered from the server after an interruption (the suite did not see this run finish)."
    if (Test-RecordValid $record) { $record.slot.usedInAnalysis = $true }
    Add-SuiteEvent -Kind "Resume" -Instance $Inst.Name -Detail ("Block D: adopted the interrupted {0} R{1} run {2} instead of running it again" -f $Test.TestCode, $Rep, $record.requestId)
    Add-RunRecord -Record $record
    Write-RunLine -Record $record -Prefix "  recovered"
    return $record
}

function Test-SuiteStopError {
    # True for the exceptions that are meant to end the suite (New-SuiteStop: gates G1/G4, pre-flight, -StopOnFailure).
    param($ErrorRecord)
    $ex = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    while ($null -ne $ex) {
        if ($ex.Data.Contains("SuiteStop")) { return $true }
        $ex = $ex.InnerException
    }
    return $false
}

function Test-InstanceReachable {
    # After a suite error: can the control row be read again? 3 attempts, 30 s apart (each GET has its own retries).
    param($Inst)
    for ($i = 1; $i -le 3; $i++) {
        try {
            [void](Get-BenchmarkControl -Inst $Inst)
            return $true
        }
        catch {
            if ($i -lt 3) { Start-Sleep -Seconds 30 }
        }
    }
    return $false
}

function Register-SuiteRunError {
    # A REST or script error during one run (SPEC 5.4 item 14): record a Failed run (the slot gets its triple re-run at
    # the end of the block), and mark the instance Stuck for the block when its control row stays unreadable or the
    # errors repeat. Block D after RunBenchmark was sent (or while an interrupted run is being resolved) stops the
    # suite instead and keeps the in-flight marker, so the resume adopts that run and never repeats it.
    param($ErrorRecord, $Inst, $Test, [string]$Block, $Rep, $OrderPosition, [string]$Role, [int]$RerunRound, [string]$ParamProfile, $RerunOf, [string]$Prefix)
    if (Test-SuiteStopError $ErrorRecord) { throw $ErrorRecord }
    $message = $ErrorRecord.Exception.Message
    $posted = $script:PostedRun
    $script:PostedRun = $null
    $postedHere = ($null -ne $posted -and [string]$posted["instance"] -eq $Inst.Name)
    if ($Block -eq "D") {
        $pending = $script:State.suiteState["pendingInFlight"]
        $pendingHere = ($null -ne $pending -and [string](Get-Prop $pending "instance") -eq $Inst.Name)
        if ($postedHere -or $pendingHere) {
            Add-SuiteEvent -Kind "Abort" -Instance $Inst.Name -Detail ("Block D {0}: suite error after the run may have started: {1}" -f $Test.TestCode, $message)
            throw (New-SuiteStop -Kind "failure" -Message ("Block D: {0} on {1} failed after its run may have started ({2}). Resume with the same -CampaignId: the run is then adopted from the server, never repeated." -f $Test.TestCode, $Inst.Name, $message))
        }
    }
    $runParams = Get-RunParameters -Test $Test -Block $Block -ParamProfile $ParamProfile -ProfileSettings $script:ProfileSettings
    $record = New-RunRecord -Inst $Inst -Test $Test -Block $Block -Rep $Rep -OrderPosition $OrderPosition -IsWarmup ([bool]$runParams.IsWarmup) -Role $Role -RerunRound $RerunRound -RerunOf $RerunOf -RunParams $runParams -RunBudgetSec (Get-RunBudgetSec -TestCode $Test.TestCode)
    $record.status = "Failed"
    $record.invalidReason = "SuiteError"
    $record.completedAtUtc = [DateTime]::UtcNow.ToString("o")
    $record.message = "Suite error: " + $message + $(if ($postedHere) { " (RunBenchmark had been sent)" } else { " (the run was not started)" })
    Add-SuiteEvent -Kind "GateWarning" -Instance $Inst.Name -Detail ("{0}: suite error, run recorded as Failed (re-run at the end of the block): {1}" -f $Test.TestCode, $message)
    Add-RunRecord -Record $record
    Write-RunLine -Record $record -Prefix $Prefix
    $Inst.ConsecutiveSuiteErrors = [int]$Inst.ConsecutiveSuiteErrors + 1
    $stuckWhy = $null
    if (-not (Test-InstanceReachable -Inst $Inst)) { $stuckWhy = "control row not readable after a suite error" }
    elseif ($Inst.ConsecutiveSuiteErrors -ge 3) { $stuckWhy = ("{0} suite errors in a row" -f $Inst.ConsecutiveSuiteErrors) }
    if ($null -ne $stuckWhy) {
        $Inst.StuckBlock = $Block
        $Inst.ConsecutiveSuiteErrors = 0
        Save-InstanceState -Inst $Inst
        Add-SuiteEvent -Kind "Stuck" -Instance $Inst.Name -Detail ("{0}; instance skipped for the rest of Block {1}" -f $stuckWhy, $Block)
        Save-CampaignState
    }
    if ($StopOnFailure) {
        throw (New-SuiteStop -Kind "failure" -Message ("-StopOnFailure: {0} failed on {1}: {2}" -f $Test.TestCode, $Inst.Name, $record.message))
    }
    return $record
}

function Invoke-GroupRuns {
    # Runs one (test, repetition, round) group on the decided instances.
    param($BlockPlan, $Test, [int]$Rep, [string[]]$Order, [int]$Round, $Decision, [string[]]$SkipInstances, [bool]$IsWarmupRep, [string]$Prefix)
    $superseded = @($Decision.Supersede)
    if ($superseded.Count -gt 0) {
        Add-SuiteEvent -Kind "Resume" -Instance $null -Detail ("Block {0} {1} R{2} round {3}: interrupted triple; running it again on every instance" -f $BlockPlan.Block, $Test.TestCode, $Rep, $Round)
        Invoke-SupersedeRecords -Records $superseded -Reason "resume"
    }
    $position = 0
    foreach ($name in $Order) {
        $position++
        if (@($Decision.Instances) -notcontains $name) { continue }
        $inst = $script:InstancesByName[$name]
        if ($SkipInstances -contains $name) {
            Add-SkippedEntry -Block $BlockPlan.Block -TestCode $Test.TestCode -Rep $Rep -Round $Round -Instance $name -Reason "G3"
            continue
        }
        if ($inst.StuckBlock -eq $BlockPlan.Block) {
            Add-SkippedEntry -Block $BlockPlan.Block -TestCode $Test.TestCode -Rep $Rep -Round $Round -Instance $name -Reason "Stuck"
            continue
        }
        $rerunOf = $null
        if ($Round -gt 0) {
            $original = @((Get-GroupRecords -Block $BlockPlan.Block -TestCode $Test.TestCode -Rep $Rep -Round 0) | Where-Object { $_.instance -eq $name })
            if ($original.Count -gt 0) { $rerunOf = $original[0].requestId }
        }
        $record = $null
        $paramProfile = if ($IsWarmupRep) { "r0" } else { "regular" }
        try {
            if ($BlockPlan.Block -eq "D") {
                $record = Resolve-InFlightRun -Inst $inst -Test $Test -Block $BlockPlan.Block -Rep $Rep -Round $Round -Role $Decision.Role -OrderPosition $position
            }
            if ($null -eq $record) {
                $record = Invoke-SuiteRun -Inst $inst -Test $Test -Block $BlockPlan.Block -Rep $Rep -OrderPosition $position -Role $Decision.Role -RerunRound $Round -ParamProfile $paramProfile -RerunOf $rerunOf -ProfileSettings $script:ProfileSettings -ProgressPrefix $Prefix
            }
            $inst.ConsecutiveSuiteErrors = 0
        }
        catch {
            # SPEC 5.4 item 14: an instance that misbehaves (REST errors that outlast the request retries) must not end
            # the unattended campaign. Gate stops (G1, G4, pre-flight, -StopOnFailure) still end it.
            $record = Register-SuiteRunError -ErrorRecord $_ -Inst $inst -Test $Test -Block $BlockPlan.Block -Rep $Rep -OrderPosition $position -Role $Decision.Role -RerunRound $Round -ParamProfile $paramProfile -RerunOf $rerunOf -Prefix $Prefix
        }
        if ($null -eq $record) {
            Add-SkippedEntry -Block $BlockPlan.Block -TestCode $Test.TestCode -Rep $Rep -Round $Round -Instance $name -Reason "Stuck"
            Save-CampaignState
            continue
        }
        Set-SupersededBy -Superseded $superseded -Instance $name -NewRecord $record
    }
}

function Get-SlotStatus {
    param([string]$Block, [string]$TestCode, [int]$Rep, [string[]]$Order)
    $records = Get-SlotRecords -Block $Block -TestCode $TestCode -Rep $Rep -Round -1
    $roundsDone = 0
    foreach ($r in $records) { $roundsDone = [Math]::Max($roundsDone, (Get-RecordRound $r)) }
    $missing = New-Object System.Collections.Generic.List[string]
    $reasons = New-Object System.Collections.Generic.List[string]
    foreach ($name in $Order) {
        $mine = @($records | Where-Object { $_.instance -eq $name })
        if (@($mine | Where-Object { Test-RecordValid $_ }).Count -gt 0) { continue }
        $missing.Add($name)
        if ($mine.Count -gt 0) {
            $last = $mine[-1]
            $reasons.Add(("{0}: {1}{2}" -f $name, $last.status, $(if ([string]::IsNullOrWhiteSpace([string]$last.invalidReason)) { "" } else { " " + $last.invalidReason })))
        }
        else {
            $skips = @($script:State.suiteState["skipped"] | Where-Object { $_.block -eq $Block -and $_.testCode -eq $TestCode -and (Test-RepEqual $_.repetitionNo $Rep) -and $_.instance -eq $name })
            $reasons.Add(("{0}: {1}" -f $name, $(if ($skips.Count -gt 0) { "skipped (" + $skips[-1].reason + ")" } else { "no run" })))
        }
    }
    $g3Only = $false
    if ($missing.Count -gt 0) {
        $g3Only = $true
        foreach ($name in $missing) {
            $hasRecord = @($records | Where-Object { $_.instance -eq $name }).Count -gt 0
            $g3 = @($script:State.suiteState["skipped"] | Where-Object { $_.block -eq $Block -and $_.testCode -eq $TestCode -and (Test-RepEqual $_.repetitionNo $Rep) -and $_.instance -eq $name -and $_.reason -eq "G3" }).Count -gt 0
            if ($hasRecord -or -not $g3) { $g3Only = $false }
        }
    }
    return [pscustomobject]@{ Needs = ($missing.Count -gt 0); Missing = $missing.ToArray(); Reasons = $reasons.ToArray(); RoundsDone = $roundsDone; G3Only = $g3Only }
}

function Update-StuckInstances {
    # A Stuck instance is checked again before every block and before the re-runs of its block; when its run has
    # finished (or its application restarted) it takes part again, so its missing slots get their re-runs.
    param([string]$Block, [string]$When)
    foreach ($inst in $script:SuiteInstances) {
        if ([string]::IsNullOrWhiteSpace([string]$inst.StuckBlock)) { continue }
        try {
            $fields = Get-ControlFields (Get-BenchmarkControl -Inst $inst)
            if (-not (Test-ControlRunning -Inst $inst -Fields $fields)) {
                Write-SuiteLog ("  {0} is no longer Stuck ({1})" -f $inst.Name, $When) "DarkYellow"
                $inst.StuckBlock = $null
            }
            else {
                $inst.StuckBlock = $Block
                Add-SuiteEvent -Kind "Stuck" -Instance $inst.Name -Detail ("still Running {0}; skipped" -f $When)
            }
        }
        catch {
            $inst.StuckBlock = $Block
            Add-SuiteEvent -Kind "Stuck" -Instance $inst.Name -Detail ("control row not readable {0}: {1}" -f $When, $_.Exception.Message)
        }
        Save-InstanceState -Inst $inst
    }
}

function Invoke-RerunRounds {
    # SPEC 5.4 item 8: triples at the end of the block, at most 2 rounds per slot; outliers are never re-run.
    param($BlockPlan)
    if ($NoRerun) { return $true }
    $block = $BlockPlan.Block
    Update-StuckInstances -Block $block -When ("before the re-runs of Block {0}" -f $block)
    $listedD = @{}
    for ($round = 1; $round -le 2; $round++) {
        $work = New-Object System.Collections.Generic.List[object]
        foreach ($repPlan in @($BlockPlan.Reps | Where-Object { -not $_.IsWarmup })) {
            foreach ($test in $BlockPlan.Tests) {
                $order = Get-RerunTripleOrder -Rep $repPlan.Rep -Orders $script:RotationOrders
                $decision = Get-GroupDecision -Block $block -TestCode $test.TestCode -Rep $repPlan.Rep -Order $order -Round $round
                if ($decision.Action -eq "skip") { continue }
                $status = Get-SlotStatus -Block $block -TestCode $test.TestCode -Rep $repPlan.Rep -Order $order
                $include = $decision.Partial -or ($status.Needs -and $status.RoundsDone -eq ($round - 1))
                if (-not $include) { continue }
                $stuckNow = @($script:SuiteInstances | Where-Object { $_.StuckBlock -eq $block } | ForEach-Object { $_.Name })
                $fixable = @($status.Missing | Where-Object { $stuckNow -notcontains $_ })
                if (-not $decision.Partial -and $fixable.Count -eq 0) {
                    $key = "stuck|{0}|{1}" -f $test.TestCode, $repPlan.Rep
                    if (-not $listedD.ContainsKey($key)) {
                        $listedD[$key] = $true
                        Add-SuiteEvent -Kind "GateWarning" -Instance $null -Detail ("Block {0}: {1} R{2} not re-run: the instances without a valid run are Stuck ({3})" -f $block, $test.TestCode, $repPlan.Rep, ($status.Missing -join ", "))
                    }
                    continue
                }
                if ($block -eq "D" -and $status.G3Only -and -not $decision.Partial) {
                    $key = "{0}|{1}" -f $test.TestCode, $repPlan.Rep
                    if (-not $listedD.ContainsKey($key)) {
                        $listedD[$key] = $true
                        Add-SuiteEvent -Kind "GateWarning" -Instance $null -Detail ("Block D: missing runs not re-run (gate G3 skipped them): {0} R{1}: {2}" -f $test.TestCode, $repPlan.Rep, ($status.Reasons -join "; "))
                    }
                    continue
                }
                $work.Add([pscustomobject]@{ Test = $test; Rep = $repPlan.Rep; Order = $order; Decision = $decision; Status = $status })
            }
        }
        if ($work.Count -eq 0) { continue }

        $stuck = @($script:SuiteInstances | Where-Object { $_.StuckBlock -eq $block } | ForEach-Object { $_.Name })
        if ($block -eq "D" -and $stuck.Count -gt 0) {
            Add-SuiteEvent -Kind "GateWarning" -Instance $null -Detail ("Block D re-runs not started: {0} is Stuck, and a re-run must reach every instance. Missing slots: {1}" -f ($stuck -join ", "), (($work | ForEach-Object { "{0} R{1}" -f $_.Test.TestCode, $_.Rep }) -join ", "))
            return $true
        }

        Write-SuiteLog ("Block {0}: re-run round {1} ({2} slot(s))" -f $block, $round, $work.Count) "Cyan"
        $gateOrder = Get-RepetitionOrder -Rep 1 -Orders $script:RotationOrders
        $envs = Invoke-EnvCaptureRound -Block $block -Rep $null -Order $gateOrder -RerunRound $round -ProfileSettings $script:ProfileSettings
        $gates = Test-RepetitionGates -Block $block -Rep $null -Order $gateOrder -Envs $envs -RerunRound $round -ProfileSettings $script:ProfileSettings
        if ($null -ne $gates.AbortCampaign) { throw (New-SuiteStop -Kind "campaign" -Message $gates.AbortCampaign) }
        if ($null -ne $gates.AbortBlock) {
            Add-SuiteEvent -Kind "GateFailed" -Instance $null -Detail ($gates.AbortBlock + "; block aborted before its re-runs")
            return $false
        }
        foreach ($item in $work) {
            $reason = if ($item.Decision.Partial) { "resume of an interrupted re-run triple" } else { $item.Status.Reasons -join "; " }
            Add-SuiteEvent -Kind "Rerun" -Instance $null -Detail ("Block {0} {1} R{2} round {3} (triple {4}): {5}" -f $block, $item.Test.TestCode, $item.Rep, $round, ($item.Order -join " > "), $reason)
            Invoke-GroupRuns -BlockPlan $BlockPlan -Test $item.Test -Rep $item.Rep -Order $item.Order -Round $round -Decision $item.Decision -SkipInstances $gates.Skip.ToArray() -IsWarmupRep $false -Prefix ("  re-run {0} R{1}" -f $round, $item.Rep)
        }
    }
    return $true
}

function Update-AnalysisSet {
    # SPEC 7.2.0: each engine's slot value is its original run if valid, otherwise its first valid re-run.
    param([string]$Block)
    $groups = @{}
    foreach ($r in $script:State.runs) {
        if ($r.block -ne $Block -or $r.testCode -eq $script:EnvCaptureCode) { continue }
        $role = Get-RecordRole $r
        $eligible = (Test-RecordActive $r) -and (@("original", "resume", "rerun") -contains $role) -and ($null -ne $r.repetitionNo) -and [int]$r.repetitionNo -ge 1
        if (-not $eligible) {
            Set-RecordValue -Record $r.slot -Name "usedInAnalysis" -Value $false
            continue
        }
        $key = "{0}|{1}|{2}" -f $r.testCode, $r.repetitionNo, $r.instance
        if (-not $groups.ContainsKey($key)) { $groups[$key] = New-Object System.Collections.Generic.List[object] }
        $groups[$key].Add($r)
    }
    foreach ($key in @($groups.Keys)) {
        $found = $false
        foreach ($r in @($groups[$key] | Sort-Object @{ Expression = { Get-RecordRound $_ } }, @{ Expression = { [string]$_.startedAtUtc } })) {
            if (-not $found -and (Test-RecordValid $r)) {
                Set-RecordValue -Record $r.slot -Name "usedInAnalysis" -Value $true
                $found = $true
            }
            else {
                Set-RecordValue -Record $r.slot -Name "usedInAnalysis" -Value $false
            }
        }
    }
}

function Update-Outliers {
    # A run outside [0.67, 1.5] x the cell median is flagged; it is never re-run or dropped (SPEC 5.4 item 8).
    $cells = @{}
    foreach ($r in $script:State.runs) {
        Set-RecordValue -Record $r -Name "outlier" -Value $false
        if (-not [bool](Get-Prop $r.slot "usedInAnalysis") -or [string]$r.status -ne "Completed" -or $null -eq $r.headlineValue) { continue }
        $key = "{0}|{1}" -f $r.testCode, $r.instance
        if (-not $cells.ContainsKey($key)) { $cells[$key] = New-Object System.Collections.Generic.List[object] }
        $cells[$key].Add($r)
    }
    $count = 0
    foreach ($key in @($cells.Keys)) {
        $values = [double[]]@($cells[$key] | ForEach-Object { [double]$_.headlineValue })
        $median = Get-Median -Values $values
        if ($null -eq $median -or $median -le 0) { continue }
        foreach ($r in $cells[$key]) {
            $ratio = [double]$r.headlineValue / $median
            if ($ratio -lt 0.67 -or $ratio -gt 1.5) {
                Set-RecordValue -Record $r -Name "outlier" -Value $true
                $count++
            }
        }
    }
    return $count
}

function Test-BlockSettleShare {
    param([string]$Block)
    $t = $script:State.suiteState["settleTimeouts"]
    if (-not $t.Contains($Block)) { return }
    $runs = [int]$t[$Block]["runs"]
    $timedOut = [int]$t[$Block]["timedOut"]
    if ($runs -gt 0 -and ($timedOut / [double]$runs) -gt 0.2) {
        Add-SuiteEvent -Kind "GateWarning" -Instance $null -Detail ("Block {0}: settle gate timed out on {1} of {2} runs ({3:0}%), above 20%" -f $Block, $timedOut, $runs, (100.0 * $timedOut / $runs))
    }
}

function Test-RepetitionComplete {
    param($BlockPlan, $RepPlan)
    foreach ($test in $BlockPlan.Tests) {
        $d = Get-GroupDecision -Block $BlockPlan.Block -TestCode $test.TestCode -Rep $RepPlan.Rep -Order $RepPlan.Order -Round 0
        if ($d.Action -ne "skip") { return $false }
    }
    return $true
}

function Invoke-Block {
    param($BlockPlan, [bool]$IsFirstBlock)
    $block = $BlockPlan.Block
    $blockState = $script:State.suiteState["blockState"]
    if ($blockState.Contains($block) -and [string]$blockState[$block] -eq "completed") {
        Write-SuiteLog ("Block {0} is already completed in this campaign; skipped." -f $block) "DarkGray"
        return "completed"
    }
    $blockState[$block] = "inProgress"
    Write-SuiteLog ""
    Write-SuiteLog ("=" * 100) "DarkCyan"
    Write-SuiteLog ("Block {0} - {1}" -f $block, $script:BlockNames[$block]) "Cyan"
    Write-SuiteLog ("=" * 100) "DarkCyan"

    # Stuck instances are checked again before every block (SPEC 5.4 item 14).
    Update-StuckInstances -Block $block -When ("before Block {0}" -f $block)

    Invoke-PreflightGate -Block $block -IsFirstBlock $IsFirstBlock

    if ($block -eq "B" -or $block -eq "C") {
        $needClear = @($BlockPlan.Reps | Where-Object { -not (Test-RepetitionComplete -BlockPlan $BlockPlan -RepPlan $_) }).Count -gt 0
        if ($needClear) {
            foreach ($inst in $script:SuiteInstances) {
                if ($inst.StuckBlock -ne $block) { [void](Invoke-ClearTestRecords -Inst $inst) }
            }
        }
    }

    foreach ($repPlan in $BlockPlan.Reps) {
        if (Test-RepetitionComplete -BlockPlan $BlockPlan -RepPlan $repPlan) { continue }
        $label = if ($repPlan.IsWarmup) { "R0 (warm-up)" } else { "R{0}" -f $repPlan.Rep }
        Write-SuiteLog ("Block {0} {1}: order {2}" -f $block, $label, ($repPlan.Order -join " > ")) "Cyan"

        $envs = Invoke-EnvCaptureRound -Block $block -Rep $repPlan.Rep -Order $repPlan.Order -RerunRound 0 -ProfileSettings $script:ProfileSettings
        $gates = Test-RepetitionGates -Block $block -Rep $repPlan.Rep -Order $repPlan.Order -Envs $envs -RerunRound 0 -ProfileSettings $script:ProfileSettings
        if ($null -ne $gates.AbortCampaign) { throw (New-SuiteStop -Kind "campaign" -Message $gates.AbortCampaign) }
        if ($null -ne $gates.AbortBlock) {
            Add-SuiteEvent -Kind "GateFailed" -Instance $null -Detail ($gates.AbortBlock + "; block aborted")
            $blockState[$block] = "aborted"
            Save-CampaignState
            return "aborted"
        }
        $skip = $gates.Skip.ToArray()

        $decisions = @{}
        foreach ($test in $BlockPlan.Tests) {
            $decisions[$test.TestCode] = Get-GroupDecision -Block $block -TestCode $test.TestCode -Rep $repPlan.Rep -Order $repPlan.Order -Round 0
        }
        $prefix = "  {0}" -f $label
        if ($Interleave -eq "TestMajor") {
            foreach ($test in $BlockPlan.Tests) {
                $decision = $decisions[$test.TestCode]
                if ($decision.Action -eq "skip") { continue }
                Invoke-GroupRuns -BlockPlan $BlockPlan -Test $test -Rep $repPlan.Rep -Order $repPlan.Order -Round 0 -Decision $decision -SkipInstances $skip -IsWarmupRep $repPlan.IsWarmup -Prefix $prefix
            }
        }
        else {
            # InstanceMajor: every test on one instance, then the next instance (same decisions, different order).
            foreach ($test in $BlockPlan.Tests) {
                $superseded = @($decisions[$test.TestCode].Supersede)
                if ($superseded.Count -gt 0) { Invoke-SupersedeRecords -Records $superseded -Reason "resume" }
            }
            foreach ($name in $repPlan.Order) {
                foreach ($test in $BlockPlan.Tests) {
                    $decision = $decisions[$test.TestCode]
                    if ($decision.Action -eq "skip" -or @($decision.Instances) -notcontains $name) { continue }
                    $single = [pscustomobject]@{ Action = "run"; Instances = @($name); Role = $decision.Role; Supersede = @(); Partial = $decision.Partial }
                    Invoke-GroupRuns -BlockPlan $BlockPlan -Test $test -Rep $repPlan.Rep -Order $repPlan.Order -Round 0 -Decision $single -SkipInstances $skip -IsWarmupRep $repPlan.IsWarmup -Prefix $prefix
                    Set-SupersededBy -Superseded @($decision.Supersede) -Instance $name -NewRecord (@((Get-GroupRecords -Block $block -TestCode $test.TestCode -Rep $repPlan.Rep -Round 0) | Where-Object { $_.instance -eq $name }) | Select-Object -Last 1)
                }
            }
        }
        Save-CampaignState
    }

    $rerunOk = Invoke-RerunRounds -BlockPlan $BlockPlan
    Update-AnalysisSet -Block $block
    Test-BlockSettleShare -Block $block
    if (-not $rerunOk) {
        $blockState[$block] = "aborted"
        Save-CampaignState
        return "aborted"
    }
    $blockState[$block] = "completed"
    Save-CampaignState
    return "completed"
}

function Invoke-ApiReadCheck {
    # Dry-run step 3l (informational, never ranked): with the suite's API session, 5 untimed warm-up calls, then
    # 50 timed GET SalesOrder/SO/<nbr>?$expand=Details on the Default endpoint, for the order numbers in the
    # SCR_OPEN_SALES_ORDER run's notes.sampleOrderNbrs. Stored in diagnostics.apiReadMs of the campaign JSON.
    $results = [ordered]@{}
    foreach ($inst in $script:SuiteInstances) {
        $entry = [ordered]@{ endpoint = $ApiReadEndpoint; warmUp = $ApiReadWarmUp; n = 0; p50Ms = $null; p95Ms = $null; meanMs = $null; minMs = $null; maxMs = $null; errors = 0; orderNbrs = 0; note = $null }
        $source = @($script:State.runs | Where-Object { $_.instance -eq $inst.Name -and $_.testCode -eq "SCR_OPEN_SALES_ORDER" -and (Test-RecordActive $_) -and $null -ne $_.result } | Select-Object -Last 1)
        $raw = if ($source.Count -gt 0) { Get-Prop (Get-Prop $source[0].result "notes") "sampleOrderNbrs" } else { $null }
        $numbers = @(foreach ($item in @($raw)) { foreach ($part in ([string]$item -split '[,;\s]+')) { if ($part.Trim() -ne "") { $part.Trim() } } })
        $entry.orderNbrs = $numbers.Count
        if ($numbers.Count -eq 0) {
            $entry.note = "no notes.sampleOrderNbrs in this campaign's SCR_OPEN_SALES_ORDER run on this instance"
            $results[$inst.Name] = $entry
            continue
        }
        $root = $inst.BaseUrl + "/entity/" + $ApiReadEndpoint + "/SalesOrder/SO/"
        $times = New-Object System.Collections.Generic.List[double]
        for ($i = 0; $i -lt ($ApiReadWarmUp + $ApiReadCount); $i++) {
            $uri = $root + [Uri]::EscapeDataString($numbers[$i % $numbers.Count]) + '?$expand=Details'
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                [void](Invoke-WebRequest -Uri $uri -WebSession $inst.Session -Headers @{ Accept = "application/json" } -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop)
                $sw.Stop()
                if ($i -ge $ApiReadWarmUp) { $times.Add($sw.Elapsed.TotalMilliseconds) }
            }
            catch {
                $entry.errors++
                if ($null -eq $entry.note) { $entry.note = "first error: " + $_.Exception.Message }
            }
        }
        if ($times.Count -gt 0) {
            $sorted = @($times.ToArray() | Sort-Object)
            $entry.n = $sorted.Count
            $entry.p50Ms = [Math]::Round((Get-Median -Values ([double[]]$sorted)), 2)
            $entry.p95Ms = [Math]::Round([double]$sorted[[Math]::Min($sorted.Count - 1, [int][Math]::Ceiling(0.95 * $sorted.Count) - 1)], 2)
            $entry.meanMs = [Math]::Round((($sorted | Measure-Object -Average).Average), 2)
            $entry.minMs = [Math]::Round([double]$sorted[0], 2)
            $entry.maxMs = [Math]::Round([double]$sorted[-1], 2)
        }
        Write-SuiteLog ("  API read {0}: n={1}, p50 {2} ms, p95 {3} ms, errors {4}" -f $inst.Name, $entry.n, $entry.p50Ms, $entry.p95Ms, $entry.errors) "DarkGray"
        $results[$inst.Name] = $entry
    }
    $script:State["diagnostics"] = [ordered]@{ apiReadMs = $results }
    Save-CampaignState
}

function Invoke-BetweenBlocks {
    param([string]$NextBlock)
    Write-SuiteLog ("Pause of {0} s before Block {1}" -f $BlockPauseSec, $NextBlock) "DarkGray"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not [string]::IsNullOrWhiteSpace($BetweenBlocksCommand)) {
        try {
            # A child powershell.exe: a native tool that writes to stderr inside the command cannot stop it half-way
            # (the suite's ErrorActionPreference = Stop would turn the first stderr line into a terminating error).
            Write-SuiteLog ("  Between-blocks command: {0}" -f $BetweenBlocksCommand) "DarkGray"
            $shell = Join-Path $PSHOME "powershell.exe"
            if (-not (Test-Path -LiteralPath $shell)) { $shell = "powershell.exe" }
            $r = Invoke-NativeProcess -FilePath $shell -Arguments ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $BetweenBlocksCommand) -TimeoutSec $BetweenBlocksTimeoutSec
            foreach ($line in @(([string]$r.StdOut) -split "`r?`n" | Where-Object { $_ -ne "" })) { Write-SuiteLog ("    " + $line) "DarkGray" }
            foreach ($line in @(([string]$r.StdErr) -split "`r?`n" | Where-Object { $_ -ne "" })) { Write-SuiteLog ("    stderr: " + $line) "DarkYellow" }
            if ($r.ExitCode -ne 0) {
                Add-SuiteEvent -Kind "GateWarning" -Instance $null -Detail ("between-blocks command exited with code {0}" -f $r.ExitCode)
            }
        }
        catch {
            Add-SuiteEvent -Kind "GateWarning" -Instance $null -Detail ("between-blocks command failed: " + $_.Exception.Message)
        }
    }
    $remaining = $BlockPauseSec - [int]$sw.Elapsed.TotalSeconds
    if ($remaining -gt 0) { Start-Sleep -Seconds $remaining }
}

#endregion

#region Calibration and report

function Read-CalibrationFile {
    param([string]$Path)
    $budgets = @{}
    if ([string]::IsNullOrWhiteSpace($Path)) { return $budgets }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Calibration file not found: $Path" }
    $doc = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
    $tests = Get-Prop $doc "tests"
    if ($null -eq $tests) { $tests = $doc }
    foreach ($p in $tests.PSObject.Properties) {
        $value = if (Test-IsScalar $p.Value) { $p.Value } else { Get-Prop $p.Value "runBudgetSec" }
        $seconds = Convert-ToNullableInt $value
        if ($null -ne $seconds -and $seconds -gt 0) { $budgets[$p.Name] = $seconds }
    }
    return $budgets
}

function Write-CalibrationFile {
    # Budget per test = clamp(4 x the longest full-size run of that test on any engine, 2 min, 15 min) (SPEC 5.4 item 14).
    param([string]$Path)
    $tests = [ordered]@{}
    foreach ($group in @($script:State.runs | Where-Object {
                $_.testCode -ne $script:EnvCaptureCode -and -not [bool]$_.isWarmup -and (Test-RecordActive $_) -and
                ($null -eq $_.workScale -or [double]$_.workScale -eq 1.0) -and @("Completed", "Capped", "Invalid") -contains [string]$_.status
            } | Group-Object testCode)) {
        $longest = 0.0
        $engine = $null
        $basis = $null
        foreach ($r in $group.Group) {
            $total = Convert-ToNullableDouble (Get-Prop (Get-Prop $r.result "phasesMs") "total")
            $value = if ($null -ne $total) { $total } else { Convert-ToNullableDouble $r.suiteWallMs }
            if ($null -ne $value -and $value -gt $longest) {
                $longest = $value
                $engine = $r.dbEngine
                $basis = if ($null -ne $total) { "ResultJson.phasesMs.total" } else { "suiteWallMs" }
            }
        }
        if ($longest -le 0) { continue }
        $budget = [int][Math]::Ceiling([Math]::Min(900.0, [Math]::Max(120.0, 4.0 * $longest / 1000.0)))
        $tests[$group.Name] = [ordered]@{ runBudgetSec = $budget; longestRunMs = [Math]::Round($longest, 1); longestOn = $engine; basis = $basis }
    }
    $doc = [ordered]@{
        schemaVersion = 1
        campaignId = $script:State.campaign["id"]
        generatedAtUtc = [DateTime]::UtcNow.ToString("o")
        rule = "runBudgetSec = clamp(4 x longest full-size run on any engine, 120 s, 900 s)"
        tests = $tests
    }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, ($doc | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
    Write-SuiteLog ("Calibration written: {0} ({1} tests)" -f $Path, $tests.Count) "Green"
}

function Invoke-ReportScript {
    param([string[]]$Inputs, [string]$OutDir)
    if (-not (Test-Path -LiteralPath $ReportScript)) {
        Write-SuiteLog ("Report generator not found: {0} (the campaign JSON is complete; run the report later)." -f $ReportScript) "Yellow"
        return $null
    }
    $arguments = @{ InputJson = $Inputs }
    if (-not [string]::IsNullOrWhiteSpace($OutDir)) { $arguments["OutDir"] = $OutDir }
    $global:LASTEXITCODE = 0
    & $ReportScript @arguments | Out-Host
    return $LASTEXITCODE
}

#endregion

#region Main

function Invoke-Campaign {
    # The live campaign (everything except -PlanOnly and -ReportOnly).
    # (Parameter names are used with any casing below; PowerShell variable names are case-insensitive.)
    param([string[]]$SelectedBlocks, [object[]]$InstanceDefinitions, [string[]]$InstanceNames)

    # Block D needs verified backups (SPEC 5.4 item 2, section 6.5); checked before anything is written.
    if ($selectedBlocks -contains "D") {
        if (-not $BackupsVerified) { throw "Block D is refused without -BackupsVerified (SPEC 6.5: pristine backups of all three databases first)." }
        $missing = @((Test-BackupArtefacts) | Where-Object { -not $_.ok })
        if ($missing.Count -gt 0) {
            throw ("Block D is refused: backup artefacts not verified: " + (($missing | ForEach-Object { "{0} ({1})" -f $_.item, $_.detail }) -join "; "))
        }
    }
    # Campaign identity, folder and state (new or resume).
    $isNewCampaign = $true
    if ([string]::IsNullOrWhiteSpace($CampaignId)) {
        $campaignGuid = [Guid]::NewGuid()
    }
    else {
        $campaignGuid = [Guid]$CampaignId
    }
    $campaignFolder = Join-Path $reportsDirectory $campaignGuid.ToString()
    $jsonPath = Join-Path $campaignFolder ("PerfDBBenchmark-{0}.json" -f $campaignGuid)
    New-Item -ItemType Directory -Path $campaignFolder -Force | Out-Null
    $script:LogPath = Join-Path $campaignFolder "suite.log"

    if (Test-Path -LiteralPath $jsonPath) {
        $isNewCampaign = $false
        $script:State = Import-CampaignState -Path $jsonPath
        $stored = $script:State.campaign
        if ([string]$stored["profile"] -ne $script:ProfileName) { throw ("Resume: campaign {0} was started with profile {1}, not {2}." -f $campaignGuid, $stored["profile"], $script:ProfileName) }
        if ([int]$stored["repetitions"] -ne [int]$script:ProfileSettings.repetitions -or [bool]$stored["warmUpRepetition"] -ne [bool]$script:ProfileSettings.warmUpRepetition) {
            throw ("Resume: campaign {0} uses {1} repetitions (R0 {2}); this invocation asks for {3} (R0 {4})." -f $campaignGuid, $stored["repetitions"], $stored["warmUpRepetition"], $script:ProfileSettings.repetitions, $script:ProfileSettings.warmUpRepetition)
        }
        $storedRotation = @($stored["rotation"] | ForEach-Object { (@($_) -join ">") }) -join "|"
        $currentRotation = @($script:RotationOrders | ForEach-Object { (@($_) -join ">") }) -join "|"
        if ($storedRotation -ne $currentRotation) { throw "Resume: the rotation differs from the stored campaign rotation." }
        if ([string]$stored["interleave"] -ne $Interleave) { throw "Resume: the interleave differs from the stored campaign interleave." }
        $storedCore = $stored["coreParams"]
        if ([int](Get-Prop $storedCore "records") -ne $CoreRecords -or [int](Get-Prop $storedCore "chunkSize") -ne $CoreChunkSize -or [int](Get-Prop $storedCore "iterations") -ne $CoreIterations) {
            throw "Resume: the core parameters differ from the stored campaign."
        }
        if ($ClearExistingData) { throw "-ClearExistingData cannot be used when resuming a campaign (it would delete the campaign's results)." }
        $script:State.suiteState["path"] = $jsonPath
        Write-SuiteLog ("Resuming campaign {0} ({1} runs recorded)" -f $campaignGuid, $script:State.runs.Count) "Cyan"
        Add-SuiteEvent -Kind "Resume" -Instance $null -Detail ("resumed with blocks {0}" -f ($selectedBlocks -join ","))
    }
    else {
        $script:State = New-CampaignState -Id $campaignGuid -ProfileSettings $script:ProfileSettings -Orders $script:RotationOrders -CampaignFolder $campaignFolder
        $script:State.suiteState["path"] = $jsonPath
        Write-SuiteLog ("New campaign {0}" -f $campaignGuid) "Cyan"
    }
    $script:State.campaign["blocks"] = @(@(@($script:State.campaign["blocks"]) + $selectedBlocks) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique | Sort-Object)
    if ($BackupsVerified) { $script:State.campaign["backupsVerified"] = $true }
    if (-not [string]::IsNullOrWhiteSpace($CalibrationFile)) {
        if ($script:CalibrationWriteOnly) { $script:State.campaign["calibrationWrittenTo"] = $CalibrationFile }
        else { $script:State.campaign["calibrationFile"] = $CalibrationFile }
    }
    $script:State.suiteState["invocations"].Add([pscustomobject][ordered]@{
            startedAtUtc = [DateTime]::UtcNow.ToString("o")
            blocks = $selectedBlocks
            profile = $script:ProfileName
            includeTests = $IncludeTests
            excludeTests = $ExcludeTests
            includeOptional = [bool]$IncludeOptional
            noRerun = [bool]$NoRerun
            diagnostics = [bool]$script:DiagnosticsEnabled
            calibrationFile = $CalibrationFile
            operator = $env:USERNAME
            computer = $env:COMPUTERNAME
        })
    Save-CampaignState


    # Credentials (memory only) and one REST session per instance.
    $script:Credential = @{ User = (Resolve-Username -ProvidedUsername $Username); Password = (Get-PlainTextPassword -ProvidedPassword $Password) }
    $script:SuiteInstances = @(foreach ($definition in $instanceDefinitions) {
            [pscustomobject]@{
                Name = $definition.DisplayName; Definition = $definition; BaseUrl = $null; Session = $null; Identity = $null
                DbEngine = "Unknown"; LastAppStartUtc = $null; LastDllSha = $null; LastMethodology = $null
                StuckBlock = $null; NeedsRewarm = $false; RunningRequestId = $null; RunningRequestAppStart = $null
                ConsecutiveSuiteErrors = 0
            }
        })
    foreach ($inst in $script:SuiteInstances) { $script:InstancesByName[$inst.Name] = $inst }
    Initialize-HostCounters

    $catalogs = @{}
    foreach ($inst in $script:SuiteInstances) {
        Connect-SuiteInstance -Inst $inst
        $control = Get-BenchmarkControl -Inst $inst -WithCatalog
        $inst.Identity = Get-ControlIdentity -ControlRecord $control -ControlSetupID $SetupID
        $fields = Get-ControlFields $control
        Update-InstanceFromControl -Inst $inst -Fields $fields
        $engineText = "{0} {1} {2}" -f $fields.CurrentDatabase, $fields.CurrentInstance, $inst.Name
        $inst.DbEngine = if ($engineText -match '(?i)postgre|PgSql|Npgsql') { "PostgreSQL" } elseif ($engineText -match '(?i)mysql|maria') { "MySQL" } elseif ($engineText -match '(?i)sql') { "SQLServer" } else { "Unknown" }
        if ($inst.Name -match '(?i)PG$') { $inst.DbEngine = "PostgreSQL" }
        $saved = Get-InstanceStateEntry -Name $inst.Name
        $inst.LastAppStartUtc = $saved["lastAppStartUtc"]
        $inst.NeedsRewarm = [bool]$saved["needsRewarm"]
        $inst.StuckBlock = $saved["stuckBlock"]
        if (-not $isNewCampaign -and -not [string]::IsNullOrWhiteSpace($inst.LastAppStartUtc) -and $fields.AppStart -ne $inst.LastAppStartUtc) {
            Add-SuiteEvent -Kind "AppRestart" -Instance $inst.Name -Detail ("the application restarted since the last invocation ({0} -> {1})" -f $inst.LastAppStartUtc, $fields.AppStart)
            $inst.NeedsRewarm = $true
        }
        $inst.LastAppStartUtc = $fields.AppStart
        Save-InstanceState -Inst $inst
        $catalogs[$inst.Name] = Convert-BenchmarkCatalog -ControlRecord $control
        Write-SuiteLog ("{0,-10} {1}  engine {2}  DLL {3}  methodology {4}" -f $inst.Name, $inst.BaseUrl, $inst.DbEngine, $fields.DllSha, $fields.Methodology) "DarkGray"
    }

    # Catalog: TestCode and ScenarioVersion identical on all instances; same DLL and methodology (SPEC 5.4 item 3).
    $reference = $script:SuiteInstances[0]
    $refSignature = (@($catalogs[$reference.Name] | ForEach-Object { "{0}:{1}" -f $_.TestCode, $_.ScenarioVersion }) -join ",")
    foreach ($inst in $script:SuiteInstances) {
        $signature = (@($catalogs[$inst.Name] | ForEach-Object { "{0}:{1}" -f $_.TestCode, $_.ScenarioVersion }) -join ",")
        if ($signature -ne $refSignature) { throw ("The benchmark catalog (TestCode/ScenarioVersion) of {0} differs from {1}." -f $inst.Name, $reference.Name) }
        if ($inst.LastDllSha -ne $reference.LastDllSha -or [string]::IsNullOrWhiteSpace($inst.LastDllSha)) { throw ("ServerDllSha256 differs between {0} and {1} (or is empty): publish the same build to every instance." -f $inst.Name, $reference.Name) }
        if ($inst.LastMethodology -ne $reference.LastMethodology) { throw ("ServerMethodologyVersion differs between {0} and {1}." -f $inst.Name, $reference.Name) }
    }
    if ($reference.LastMethodology -ne $script:MethodologyVersion) {
        Write-SuiteLog ("Warning: the server methodology version is {0}; this suite was written for {1}." -f $reference.LastMethodology, $script:MethodologyVersion) "Yellow"
    }
    if ([string]::IsNullOrWhiteSpace($script:State.suiteState["serverDllSha256"])) {
        $script:State.suiteState["serverDllSha256"] = $reference.LastDllSha
        $script:State.suiteState["serverMethodologyVersion"] = $reference.LastMethodology
    }
    elseif ($script:State.suiteState["serverDllSha256"] -ne $reference.LastDllSha -or $script:State.suiteState["serverMethodologyVersion"] -ne $reference.LastMethodology) {
        throw (New-SuiteStop -Kind "campaign" -Message "Gate G4: the deployed DLL or methodology differs from the values this campaign started with (someone republished).")
    }
    $script:Catalog = $catalogs[$reference.Name]
    $script:EnvTest = Get-EnvCaptureTest -Catalog $script:Catalog
    $tests = Resolve-BenchmarkSelection -Catalog $script:Catalog -IncludedSelectors $IncludeTests -ExcludedSelectors $ExcludeTests
    if (@($tests).Count -eq 0) { throw "No benchmark matched the selection." }
    $script:State.instances = @($script:SuiteInstances | ForEach-Object { [pscustomobject][ordered]@{ name = $_.Name; baseUrl = $_.BaseUrl; dbEngine = $_.DbEngine } })
    $script:State.tests = @($script:Catalog)
    $plan = New-CampaignPlan -Tests $tests -SelectedBlocks $selectedBlocks -ProfileSettings $script:ProfileSettings -Orders $script:RotationOrders -InstanceNames $instanceNames
    [void](Write-PlanReport -Plan $plan -ProfileSettings $script:ProfileSettings -Orders $script:RotationOrders -InstanceNames $instanceNames -CatalogSource "server catalog")
    Save-CampaignState

    # Environment capture at the start (P4 start), once per campaign.
    $startFile = Join-Path $campaignFolder "environment-start.json"
    if (-not (Test-Path -LiteralPath $startFile) -and -not [string]::IsNullOrWhiteSpace($EnvironmentScript)) {
        Write-SuiteLog "Capturing environment-start.json" "DarkGray"
        [void](Invoke-EnvironmentScript -Mode "environment" -OutFile $startFile -InstanceNames $instanceNames)
    }
    if (Test-Path -LiteralPath $startFile) {
        $script:State.environment.start = [System.IO.File]::ReadAllText($startFile) | ConvertFrom-Json
        Test-StartEnvironment -StartEnv $script:State.environment.start
    }

    # Acumatica CPU per operation needs every site's w3wp mapped to its app pool (SPEC 5.4 item 15).
    $poolMap = Get-W3wpPoolMap
    $unmapped = @($script:SuiteInstances | Where-Object { @($poolMap.Values) -notcontains $_.Name } | ForEach-Object { $_.Name })
    if ($unmapped.Count -gt 0) {
        Add-SuiteEvent -Kind "GateWarning" -Instance $null -Detail ("no w3wp process could be mapped to the app pool of {0} (W3SVC_W3WP counters, appcmd and the process command line all failed); Acumatica CPU per operation will be missing for it" -f ($unmapped -join ", "))
    }

    if ($ClearExistingData) {
        foreach ($inst in $script:SuiteInstances) {
            Write-SuiteLog ("{0}: ClearTestData (results and test records)" -f $inst.Name) "Yellow"
            [void](Clear-BenchmarkData -Inst $inst)
        }
    }

    # Blocks.
    $firstBlock = $true
    $previousProblem = $null
    for ($i = 0; $i -lt $plan.Count; $i++) {
        $blockPlan = $plan[$i]
        if ($blockPlan.Block -eq "D" -and -not $firstBlock -and $null -ne $previousProblem) {
            Add-SuiteEvent -Kind "GateFailed" -Instance $null -Detail ("Block D not started automatically: " + $previousProblem)
            $script:BlockOutcome["D"] = "notStarted"
            break
        }
        $outcome = Invoke-Block -BlockPlan $blockPlan -IsFirstBlock $firstBlock
        $script:BlockOutcome[$blockPlan.Block] = $outcome
        if ($outcome -eq "aborted") { $previousProblem = "Block $($blockPlan.Block) was aborted by a gate" }
        if (@($script:SuiteInstances | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.StuckBlock) }).Count -gt 0) { $previousProblem = "an instance was Stuck in Block $($blockPlan.Block)" }
        $firstBlock = $false
        if ($blockPlan.Block -eq "A" -and $ApiReadCheck) {
            if ($script:ProfileName -eq "DryRun") { Invoke-ApiReadCheck }
            else { Write-SuiteLog "-ApiReadCheck only applies to the DryRun profile (SPEC 6.6 step 3l); skipped." "Yellow" }
        }
        if ($i -lt $plan.Count - 1) { Invoke-BetweenBlocks -NextBlock $plan[$i + 1].Block }
    }
}

$exitCode = 0
try {
    $script:RepetitionsExplicit = $PSBoundParameters.ContainsKey("Repetitions")
    $script:ProfileSettings = Get-ProfileSettings -Name $script:ProfileName
    $script:DiagnosticsEnabled = $false
    if ($Diagnostics) {
        if ($script:ProfileName -eq "DryRun") { $script:DiagnosticsEnabled = $true }
        else { Write-Warning "-Diagnostics only applies to the DryRun profile; engine counters are never read in other profiles (SPEC 5.4 item 18)." }
    }
    if ($WriteCalibration -and $script:ProfileName -ne "DryRun") {
        Write-Warning "-WriteCalibration only applies to the DryRun profile; ignored."
    }
    # With -WriteCalibration (DryRun) -CalibrationFile names the file to write: it is not read, so it may be a new
    # path, and the calibration dry run is not limited by older budgets (engine default 15 min).
    $script:CalibrationWriteOnly = ($WriteCalibration -and $script:ProfileName -eq "DryRun")
    $script:CalibrationBudgets = if ($script:CalibrationWriteOnly) { @{} } else { Read-CalibrationFile -Path $CalibrationFile }
    $maxWait = 900 + $WaitLimitExtraSec
    foreach ($v in $script:CalibrationBudgets.Values) { $maxWait = [Math]::Max($maxWait, [int]$v + $WaitLimitExtraSec) }
    if ($maxWait + $AbortWaitSec -ge $ActionTimeoutMinutes * 60) {
        throw ("ActionTimeoutMinutes ({0}) must exceed the largest wait limit (run budget + 5 min = {1} s) plus the 2-minute abort wait." -f $ActionTimeoutMinutes, $maxWait)
    }

    $selectedBlocks = @($Blocks | ForEach-Object { $_.ToUpperInvariant() } | Select-Object -Unique)
    $instanceDefinitions = @(foreach ($instance in $Instances) { Get-InstanceDefinition -Instance $instance -DefaultBaseHost $BaseHost })
    $instanceNames = [string[]]@($instanceDefinitions | ForEach-Object { $_.DisplayName })
    $script:RotationOrders = Get-RotationOrders -Names $instanceNames

    if ($ReportOnly) {
        if (@($InputJson).Count -eq 0) { throw "-ReportOnly needs -InputJson <campaign json path(s)>." }
        $outDir = Split-Path -Parent (Resolve-Path -LiteralPath $InputJson[0]).Path
        $code = Invoke-ReportScript -Inputs $InputJson -OutDir $outDir
        if ($null -ne $code) { $exitCode = [int]$code }
    }
    elseif ($PlanOnly) {
        $catalog = Get-DefaultBenchmarkCatalog
        $tests = Resolve-BenchmarkSelection -Catalog $catalog -IncludedSelectors $IncludeTests -ExcludedSelectors $ExcludeTests
        $plan = New-CampaignPlan -Tests $tests -SelectedBlocks $selectedBlocks -ProfileSettings $script:ProfileSettings -Orders $script:RotationOrders -InstanceNames $instanceNames
        [void](Write-PlanReport -Plan $plan -ProfileSettings $script:ProfileSettings -Orders $script:RotationOrders -InstanceNames $instanceNames -CatalogSource "offline copy of SPEC 1.1-1.2 (a live campaign uses GET BenchmarkControl?`$expand=BenchmarkCatalog)")
    }
    else {
        Invoke-Campaign -SelectedBlocks $selectedBlocks -InstanceDefinitions $instanceDefinitions -InstanceNames $instanceNames
    }
}
catch {
    $stop = $null
    if ($null -ne $_.Exception -and $_.Exception.Data.Contains("SuiteStop")) { $stop = [string]$_.Exception.Data["SuiteStop"] }
    if ($null -ne $script:State) {
        $kind = if ($stop -eq "campaign") { "GateFailed" } elseif ($stop -eq "preflight") { "Preflight" } else { "Abort" }
        Add-SuiteEvent -Kind $kind -Instance $null -Detail ("suite stopped: " + $_.Exception.Message)
    }
    Write-SuiteLog ("Suite stopped: " + $_.Exception.Message) "Red"
    if ($null -eq $stop) { Write-SuiteLog ([string]$_.ScriptStackTrace) "DarkGray" }
    $exitCode = switch ($stop) { "campaign" { 3 } "preflight" { 4 } default { 1 } }
}
finally {
    Write-Progress -Id 1 -Activity "PerfDB benchmark suite" -Completed
    if ($null -ne $script:State -and -not $PlanOnly -and -not $ReportOnly) {
        try {
            foreach ($b in $script:BlockOrder) { Update-AnalysisSet -Block $b }
            $outliers = Update-Outliers
            if ($outliers -gt 0) { Write-SuiteLog ("Outliers flagged (kept, never re-run): {0}" -f $outliers) "DarkYellow" }
            $folder = Split-Path -Parent $script:State.suiteState["path"]
            if ($WriteCalibration -and $script:ProfileName -eq "DryRun") {
                $calibrationPath = if (-not [string]::IsNullOrWhiteSpace($CalibrationFile)) { $CalibrationFile } else { Join-Path $folder "calibration.json" }
                Write-CalibrationFile -Path $calibrationPath
            }
            if (@($script:SuiteInstances).Count -gt 0 -and $null -ne $script:SuiteInstances[0].Session -and -not [string]::IsNullOrWhiteSpace($EnvironmentScript)) {
                $endFile = Join-Path $folder "environment-end.json"
                Write-SuiteLog "Capturing environment-end.json" "DarkGray"
                [void](Invoke-EnvironmentScript -Mode "environment" -OutFile $endFile -InstanceNames (Get-SiteNames))
                if (Test-Path -LiteralPath $endFile) { $script:State.environment.end = [System.IO.File]::ReadAllText($endFile) | ConvertFrom-Json }
            }
            Add-TableCountsToState -Folder $folder
            $allDone = ($exitCode -eq 0) -and (@($script:BlockOrder | Where-Object { $script:State.campaign["blocks"] -contains $_ -and [string](Get-Prop $script:State.suiteState["blockState"] $_) -ne "completed" }).Count -eq 0)
            if ($allDone) { $script:State.campaign["completedAtUtc"] = [DateTime]::UtcNow.ToString("o") }
            # The in-flight marker is NOT cleared here: Add-RunRecord clears it for every recorded run, so a marker that
            # is still set belongs to a run that was interrupted (Ctrl+C, a terminating error) after it may have
            # started. Import-CampaignState turns a Block D marker into pendingInFlight, and the resume adopts that
            # run from the server instead of running the (test, instance) a second time (SPEC 5.4 item 10).
            Save-CampaignState
            Write-SuiteLog ("Campaign JSON: {0}" -f $script:State.suiteState["path"]) "Green"
        }
        catch {
            Write-SuiteLog ("Finalizing the campaign JSON failed: " + $_.Exception.Message) "Red"
            if ($exitCode -eq 0) { $exitCode = 1 }
        }
    }
    foreach ($inst in @($script:SuiteInstances)) {
        if ($null -ne $inst.Session -and -not [string]::IsNullOrWhiteSpace([string]$inst.BaseUrl)) {
            Disconnect-AcumaticaInstance -BaseUrl $inst.BaseUrl -Session $inst.Session
        }
    }
    if ($AllowInsecureSsl) {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $legacyServerCertificateCallback
    }
    $script:Credential = $null
}

if (-not $PlanOnly -and -not $ReportOnly -and $null -ne $script:State -and $exitCode -eq 0) {
    $runsDone = @($script:State.runs | Where-Object { $_.testCode -ne $script:EnvCaptureCode }).Count
    if ($runsDone -gt 0) {
        try {
            $reportCode = Invoke-ReportScript -Inputs @($script:State.suiteState["path"]) -OutDir (Split-Path -Parent $script:State.suiteState["path"])
            if ($OpenReport) {
                $html = Join-Path (Split-Path -Parent $script:State.suiteState["path"]) ("PerfDBBenchmark-{0}.html" -f $script:State.campaign["id"])
                if (Test-Path -LiteralPath $html) { Start-Process -FilePath $html }
            }
            if ($null -ne $reportCode -and [int]$reportCode -ne 0) { Write-SuiteLog ("Report generator exit code: {0}" -f $reportCode) "Yellow" }
        }
        catch {
            Write-SuiteLog ("Report generation failed: " + $_.Exception.Message) "Yellow"
        }
    }
}

exit $exitCode

#endregion
