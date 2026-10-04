<#
.SYNOPSIS
    Captures the PerfDBBenchmark campaign environment as JSON (SPEC section 6.4).

.DESCRIPTION
    Modes (choose at most one switch):
      (none)           Full environment capture: host, background load, antivirus, repo and DLL hashes,
                       Acumatica sites (web.config flags, provider, app pool, driver versions), the three
                       database servers (versions, settings, sizes, statistics dates, instrumentation),
                       the client connection and the isolation level Acumatica actually uses, and the
                       highlight list that feeds the README disclosure tables (SPEC section 7.6).
      -Preflight       Checks that only the expected clients are connected to the database servers
                       (SPEC section 5.4 item 17). Exit code 2 when an unexpected client is connected.
      -TableCounts     Row counts of every table per engine plus the soft-deleted ARRegister and Batch rows
                       (SPEC section 5.4 item 19). The output's top-level "mode" names the variant:
                         -ExactCounts   ("exact") exact row count of EVERY base table on every engine, under
                                        engines.<engine>.exactCounts. SQL Server: sys.dm_db_partition_stats
                                        (index_id 0/1 summed; exact, no scan). MySQL: COUNT(*) per BASE TABLE.
                                        PostgreSQL: count(*) per plain table and per partitioned PARENT (partition
                                        children are skipped, so names line up with the other engines).
                         -MetadataOnly  ("metadata") no table is read on any engine: SQL Server
                                        sys.dm_db_partition_stats, MySQL mysql.innodb_table_stats.n_rows
                                        (summed over the '#p#' partition rows of a partitioned table),
                                        PostgreSQL pg_class.reltuples, under engines.<engine>.counts
                                        (countsExact says whether they are exact). Soft-deleted counts are skipped.
                         (neither)      ("legacy") the earlier behaviour: SQL Server counts, MySQL/PostgreSQL
                                        estimates plus exact counts for the key tables and the tables whose
                                        estimate changed against -BaselineFile.
                       With -BaselineFile, "changedTables" lists per engine the tables whose EXACT count differs
                       (an exact count is never compared with an estimate) and "comparison" says per engine
                       whether it was compared and, if not, why. An engine that fails gets "unavailable" and an
                       entry in the top-level "errors".
      -EngineCounters  Cumulative engine counters for the suite's -Diagnostics (SPEC section 5.4 item 18).

    The environment capture also records, per engine, databases.<engine>.collation (database default, locale
    provider, the collation of BAccount.AcctName, text columns per collation, PostgreSQL latin1_general* collations)
    and, per site, acumatica.instances.<site>.appSettings.sqlThrottling (the raw web.config appSettings value of
    'sqlThrottling:Enabled', or null when absent; E14), mirrored as acumatica.instances.<site>.webConfig['sqlThrottling:Enabled'].
    host.memory (Windows standby list = file cache) and highlights.cacheAfterServiceRestart record what a service
    restart leaves warm: PostgreSQL reads through the Windows file cache, MySQL may reload ib_buffer_pool at startup
    (databases.MySQL.status.Innodb_buffer_pool_load_status), SQL Server starts cold.

    Credentials:
      SQL Server uses Windows authentication (Integrated Security), read-only queries only.
      MySQL credentials are read by mysql.exe only, through --defaults-extra-file (-MySqlDefaultsFile).
      PostgreSQL credentials are read by psql.exe only, through PGPASSFILE (-PgPassFile).
      No password is ever passed on a command line, printed or written. Connection strings are read
      for their keys only; values of keys that may hold secrets are never read out.

    -SkipDatabases runs without elevation and without any database access.

.EXAMPLE
    .\scripts\Get-PerfEnvironment.ps1 -OutFile "$camp\environment-start.json" -CampaignDir $camp `
        -MySqlDefaultsFile "$repo\Exceptions\mysql-root.cnf" -PgPassFile "$repo\Exceptions\pgpass.conf"

.EXAMPLE
    .\scripts\Get-PerfEnvironment.ps1 -TableCounts -OutDir $camp -Label after-smoke -BaselineFile "$camp\table-counts-before-smoke.json"

.EXAMPLE
    .\scripts\Get-PerfEnvironment.ps1 -TableCounts -ExactCounts -OutDir $camp -Label campaign-end -BaselineFile "$camp\table-counts-campaign-baseline.json"

.EXAMPLE
    .\scripts\Get-PerfEnvironment.ps1 -TableCounts -MetadataOnly -OutDir $camp -Label campaign-start
#>
[CmdletBinding()]
param(
    [string]$OutFile = "",
    [string]$OutDir = "",
    [string]$Label = "",
    [string]$InstanceRoot = "D:\Instances\26.200.0334",
    [string[]]$Instances = @("PerfSQL", "PerfMySQL", "PerfPG"),
    [string]$MySqlDefaultsFile = "",
    [string]$PgPassFile = "",
    [switch]$SkipDatabases,
    [switch]$Preflight,
    [switch]$TableCounts,
    [switch]$EngineCounters,
    [switch]$ExactCounts,
    [switch]$MetadataOnly,
    [string]$BaselineFile = "",
    [int]$CountBatchSize = 100,
    [int]$CountTimeoutSec = 3600,
    [string]$CampaignDir = "",
    [string]$SqlServerInstance = "",
    [string]$MySqlExe = "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe",
    [string]$PsqlExe = "C:\Program Files\PostgreSQL\18\bin\psql.exe",
    [string]$PgHost = "localhost",
    [int]$PgPort = 5432,
    [string]$PgUser = "postgres",
    [int]$CompanyId = 2,
    [string[]]$PreflightAllow = @(),
    [string]$CpuCoreSplit = "",
    [string]$MsiMode = "",
    [string]$LicenceState = "unlicensed: 2 users / 2 API users",
    [int]$ScheduledTaskWindowHours = 36,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Windows PowerShell 5.1 serializes some arrays as {"value":[...],"Count":n}; removing the ETS type data fixes it.
Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue

# List parameters arrive as one comma-separated string when the script is started with "powershell -File".
$Instances = [string[]]@(foreach ($v in @($Instances)) { foreach ($part in ([string]$v -split ',')) { if ($part.Trim() -ne "") { $part.Trim() } } })
$PreflightAllow = [string[]]@(foreach ($v in @($PreflightAllow)) { if (-not [string]::IsNullOrWhiteSpace([string]$v)) { [string]$v } })
if ($Instances.Count -eq 0) { throw "-Instances is empty." }

$script:ScriptVersion = 2
$script:AppName = "Get-PerfEnvironment"
$script:CaptureErrors = New-Object System.Collections.Generic.List[string]
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:KeyTables = @(
    "GLTran", "GLHistory", "Batch", "ARTran", "ARRegister", "ARInvoice", "ARBalances", "SOOrder", "SOLine",
    "INSiteStatusByCostCenter", "InventoryItem", "INItemSite", "INSite", "BAccount", "Customer", "Location",
    "Account", "Sub", "Ledger", "Branch", "PerfTestRecord", "PerfTestResult"
)
$script:CampaignStoppedServices = @("MSSQLServerOLAPService", "SQLPBENGINE", "SQLPBDMS", "MSSQLLaunchpad", "SQLTELEMETRY")
$script:WatchedServices = @("MSSQLSERVER", "MySQL80", "postgresql-x64-18", "MSSQLServerOLAPService", "SQLPBENGINE", "SQLPBDMS", "MSSQLLaunchpad", "SQLTELEMETRY", "MSSQLFDLauncher", "SQLSERVERAGENT", "W3SVC", "WAS")
$script:AppCmd = Join-Path $env:windir "System32\inetsrv\appcmd.exe"

#region Generic helpers

function Write-Info {
    param([string]$Message, [string]$Color = "Gray")
    if (-not $Quiet) {
        Write-Host $Message -ForegroundColor $Color
    }
}

function Limit-Text {
    param([AllowNull()][string]$Text, [int]$Max = 300)
    if ($null -eq $Text) { return "" }
    $t = $Text.Trim()
    if ($t.Length -le $Max) { return $t }
    return $t.Substring(0, $Max) + "..."
}

function Add-CaptureError {
    param([string]$Section, [string]$Message)
    $script:CaptureErrors.Add(("{0}: {1}" -f $Section, (Limit-Text $Message 400)))
}

function Invoke-Section {
    param([string]$Section, [scriptblock]$Body)
    try {
        $value = & $Body
        # Keep arrays as arrays (PowerShell would otherwise unroll them on return).
        Write-Output -NoEnumerate $value
        return
    }
    catch {
        Add-CaptureError -Section $Section -Message $_.Exception.Message
        return [ordered]@{ unavailable = (Limit-Text $_.Exception.Message 300) }
    }
}

function Get-Prop {
    param([AllowNull()]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Test-IsElevated {
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function ConvertTo-IsoUtc {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime().ToString("o") }
    return [string]$Value
}

function Invoke-NativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string]$Arguments = "",
        [AllowNull()][string]$StdIn = $null,
        [hashtable]$Environment = @{},
        [int]$TimeoutSec = 120
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
    foreach ($key in $Environment.Keys) {
        $psi.EnvironmentVariables[[string]$key] = [string]$Environment[$key]
    }

    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        $tool = [IO.Path]::GetFileName($FilePath)
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        # stdin is written asynchronously and bounded by the same timeout: a script larger than the pipe buffer (the
        # exact-count batches are ~230 KB) blocks the writer while the client runs the early statements. If the client
        # stops early (psql ON_ERROR_STOP, mysql --batch abort) the pipe closes under the writer; that IOException is
        # kept aside so the client's own exit code and stderr are reported instead.
        # (Process.Dispose does not close the stdin writer, so a write still pending after Kill cannot throw from the
        # finally block below.)
        # ([string] parameters turn $null into "", so "no input" is the empty string.)
        $hasInput = -not [string]::IsNullOrEmpty($StdIn)
        $stdInError = $null
        $inputTimedOut = $false
        try {
            if ($hasInput) {
                $writeTask = $process.StandardInput.WriteAsync($StdIn)
                if (-not $writeTask.Wait([int][Math]::Max([double]0, [double]$TimeoutSec * 1000 - $watch.Elapsed.TotalMilliseconds))) {
                    $inputTimedOut = $true
                }
            }
            if (-not $inputTimedOut) { $process.StandardInput.Close() }
        }
        catch {
            # PowerShell wraps it (MethodInvocationException > AggregateException > IOException): keep the innermost message.
            $ex = $_.Exception
            while ($null -ne $ex.InnerException) { $ex = $ex.InnerException }
            if ($hasInput) { $stdInError = $ex.Message }
            # Close the write end; StreamWriter closes its stream even when the final flush fails.
            try { $process.StandardInput.Close() } catch { }
        }
        if ($inputTimedOut) {
            try { $process.Kill() } catch { }
            throw ("{0} did not finish within {1} s (it was still reading its input)" -f $tool, $TimeoutSec)
        }
        $remainingMs = [int][Math]::Max([double]0, [double]$TimeoutSec * 1000 - $watch.Elapsed.TotalMilliseconds)
        if (-not $process.WaitForExit($remainingMs)) {
            try { $process.Kill() } catch { }
            throw ("{0} did not finish within {1} s" -f $tool, $TimeoutSec)
        }
        $process.WaitForExit()
        $stdErr = $errTask.Result
        if ($null -ne $stdInError) {
            if ($process.ExitCode -eq 0) {
                throw ("{0} closed its input before reading all of it (exit code 0): {1}; stderr: {2}" -f $tool, $stdInError, (Limit-Text $stdErr 300))
            }
            $stdErr = ([string]$stdErr).TrimEnd() + (" [input not fully written: {0}]" -f $stdInError)
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $outTask.Result
            StdErr = $stdErr
        }
    }
    finally {
        $process.Dispose()
    }
}

function Write-JsonFileAtomic {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Object)
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json = $Object | ConvertTo-Json -Depth 30
    $tmp = $Path + ".tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

#endregion

#region Site (web.config) helpers

function Get-SafeConnectionStringInfo {
    param([AllowNull()][string]$ConnectionString)

    # Only these keys have their values read out. Everything else (passwords, user names, keys) is listed by name only.
    $safeKeys = @(
        "data source", "server", "host", "port", "initial catalog", "database", "integrated security", "encrypt",
        "trust server certificate", "trustservercertificate", "sslmode", "ssl mode", "use affected rows",
        "allow user variables", "pooling", "min pool size", "max pool size", "connect timeout", "connection timeout",
        "command timeout", "default command timeout", "timeout", "application name", "multipleactiveresultsets",
        "multisubnetfailover", "charset", "character set", "network library", "protocol"
    )

    $info = [ordered]@{ keyNames = @(); safeValues = [ordered]@{} }
    if ([string]::IsNullOrWhiteSpace($ConnectionString)) {
        return $info
    }

    # DbConnectionStringBuilder is an IDictionary: PowerShell dot syntax would read/write dictionary entries,
    # so the .NET members are called explicitly.
    $builder = New-Object System.Data.Common.DbConnectionStringBuilder
    try {
        $builder.set_ConnectionString($ConnectionString)
    }
    catch {
        $info["parseError"] = "connection string could not be parsed (content not shown)"
        return $info
    }

    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($key in @($builder.get_Keys())) {
        $name = [string]$key
        $keys.Add($name)
        $lower = $name.ToLowerInvariant()
        if (($safeKeys -contains $lower) -and ($lower -notmatch 'pass|pwd|secret|token|key|user|uid|cert')) {
            $info["safeValues"][$name] = [string]$builder.get_Item($name)
        }
    }
    $info["keyNames"] = $keys.ToArray()
    return $info
}

function Get-SafeValue {
    param($SafeValues, [string[]]$Names)
    foreach ($n in $Names) {
        foreach ($k in @($SafeValues.Keys)) {
            if ([string]$k -ieq $n) {
                return [string]$SafeValues[$k]
            }
        }
    }
    return $null
}

function Resolve-EngineFromText {
    param([AllowNull()][string]$Text, [bool]$IsProviderType)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "Unknown" }
    if ($Text -match 'PgSql|Npgsql|Postgre' -or ((-not $IsProviderType) -and $Text -match 'PG$')) { return "PostgreSQL" }
    if ($Text -match 'MySql|Maria') { return "MySQL" }
    if ($Text -match 'PXSqlDatabaseProvider|SqlServer|MsSql' -or ((-not $IsProviderType) -and $Text -match 'SQL')) { return "SQLServer" }
    return "Unknown"
}

function Get-AppSettingFacts {
    # appSettings entries that change Acumatica's runtime behaviour. E14: 'sqlThrottling:Enabled' (PX.Data binds the
    # 'sqlThrottling' section from IConfiguration, which reads appSettings). ConfigurationManager.AppSettings and
    # IConfiguration both match keys case-insensitively, so this does too; <remove> and <clear/> are honoured and the
    # last <add> wins. sqlThrottling is the raw value text, or null when the key is absent.
    param([System.Xml.XmlDocument]$Xml)
    $key = "sqlThrottling:Enabled"
    $value = $null
    $occurrences = 0
    $keysAsWritten = New-Object System.Collections.Generic.List[string]
    $otherKeys = New-Object System.Collections.Generic.List[object]
    $externalFile = $null
    $configSource = $null
    $section = $Xml.SelectSingleNode("/configuration/appSettings")
    if ($null -ne $section) {
        if ($section.HasAttribute("file")) { $externalFile = $section.GetAttribute("file") }
        if ($section.HasAttribute("configSource")) { $configSource = $section.GetAttribute("configSource") }
        foreach ($node in @($section.ChildNodes)) {
            if ($node.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
            $k = $node.GetAttribute("key")
            if ($node.LocalName -eq "clear") { $value = $null }
            elseif ($node.LocalName -eq "remove" -and $k -ieq $key) { $value = $null }
            elseif ($node.LocalName -eq "add" -and $k -ieq $key) {
                $occurrences++
                $keysAsWritten.Add($k)
                $value = $node.GetAttribute("value")
            }
            elseif ($node.LocalName -eq "add" -and $k -like "sqlThrottling:*") {
                $otherKeys.Add([ordered]@{ key = $k; value = $node.GetAttribute("value") })
            }
        }
    }
    return [ordered]@{
        sqlThrottling = $value
        sqlThrottlingKey = $key
        sqlThrottlingOccurrences = $occurrences
        sqlThrottlingKeysAsWritten = $keysAsWritten.ToArray()
        sqlThrottlingOtherKeys = $otherKeys.ToArray()
        externalFile = $externalFile
        configSource = $configSource
    }
}

function Get-SiteInfo {
    param([string]$InstanceName)

    $site = [ordered]@{
        name = $InstanceName
        path = (Join-Path $InstanceRoot $InstanceName)
        engine = (Resolve-EngineFromText -Text $InstanceName -IsProviderType $false)
        engineSource = "folder name"
        database = $null
        server = $null
        providerType = $null
        connectionString = $null
        webConfig = $null
        appSettings = $null
    }

    $webConfigPath = Join-Path $site.path "web.config"
    if (-not (Test-Path -LiteralPath $webConfigPath)) {
        $site.webConfig = [ordered]@{ unavailable = "web.config not found" }
        return $site
    }

    try {
        $xml = New-Object System.Xml.XmlDocument
        $xml.PreserveWhitespace = $false
        $xml.LoadXml([System.IO.File]::ReadAllText($webConfigPath))
    }
    catch {
        $site.webConfig = [ordered]@{ unavailable = ("web.config not readable: " + (Limit-Text $_.Exception.Message 200)) }
        Add-CaptureError -Section "site $InstanceName" -Message $_.Exception.Message
        return $site
    }

    $appKeys = @("DisableScheduleProcessor", "CompilePages", "ParallelProcessingDisabled", "ParallelProcessingMaxThreads",
        "ParallelProcessingBatchSize", "IsParallelProcessingSkipBatchExceptions", "EnableAutoNumberingInSeparateConnection", "QueryCacheLevel")
    $flags = [ordered]@{}
    foreach ($key in $appKeys) {
        $node = $xml.SelectSingleNode("/configuration/appSettings/add[@key='$key']")
        $flags[$key] = if ($null -ne $node) { $node.GetAttribute("value") } else { $null }
    }

    $compilation = $xml.SelectSingleNode("/configuration/system.web/compilation")
    $flags["compilationDebug"] = if ($null -ne $compilation) { $compilation.GetAttribute("debug") } else { $null }

    $threadPool = $xml.SelectSingleNode("/configuration/px.core/ThreadPoolSize")
    $flags["ThreadPoolSize"] = if ($null -ne $threadPool) { $threadPool.InnerText.Trim() } else { "15 (absent: default)" }

    $queryCacheNodes = $xml.SelectNodes("//*[@QueryCacheLevel] | //*[local-name()='QueryCacheLevel'] | /configuration/appSettings/add[@key='QueryCacheLevel']")
    if ($queryCacheNodes.Count -eq 0) {
        $flags["QueryCacheLevel"] = "(default graph)"
    }
    else {
        $first = $queryCacheNodes.Item(0)
        if ($first.LocalName -eq "add") { $flags["QueryCacheLevel"] = $first.GetAttribute("value") }
        elseif ($first.HasAttribute("QueryCacheLevel")) { $flags["QueryCacheLevel"] = $first.GetAttribute("QueryCacheLevel") }
        else { $flags["QueryCacheLevel"] = $first.InnerText.Trim() }
    }

    $sessionState = $xml.SelectSingleNode("/configuration/system.web/sessionState")
    if ($null -eq $sessionState) { $sessionState = $xml.SelectSingleNode("//system.web/sessionState") }
    $flags["sessionStateTimeoutMin"] = if ($null -ne $sessionState) { $sessionState.GetAttribute("timeout") } else { $null }

    $connectionStringName = "ProjectX"
    $pxDatabase = $xml.SelectSingleNode("/configuration/px.core/pxdatabase")
    if ($null -ne $pxDatabase) {
        $defaultProvider = $pxDatabase.GetAttribute("defaultProvider")
        $providerNode = $null
        if (-not [string]::IsNullOrWhiteSpace($defaultProvider)) {
            $providerNode = $pxDatabase.SelectSingleNode("providers/add[@name='$defaultProvider']")
        }
        if ($null -eq $providerNode) {
            $providerNode = $pxDatabase.SelectSingleNode("providers/add")
        }
        if ($null -ne $providerNode) {
            $site.providerType = $providerNode.GetAttribute("type")
            $csName = $providerNode.GetAttribute("connectionStringName")
            if (-not [string]::IsNullOrWhiteSpace($csName)) { $connectionStringName = $csName }
        }
    }

    $engineFromProvider = Resolve-EngineFromText -Text ([string]$site.providerType) -IsProviderType $true
    if ($engineFromProvider -ne "Unknown") {
        $site.engine = $engineFromProvider
        $site.engineSource = "provider type"
    }

    $csNode = $xml.SelectSingleNode("/configuration/connectionStrings/add[@name='$connectionStringName']")
    if ($null -eq $csNode) { $csNode = $xml.SelectSingleNode("/configuration/connectionStrings/add") }
    if ($null -ne $csNode) {
        $csInfo = Get-SafeConnectionStringInfo -ConnectionString $csNode.GetAttribute("connectionString")
        $site.connectionString = $csInfo
        $site.database = Get-SafeValue -SafeValues $csInfo["safeValues"] -Names @("Initial Catalog", "Database")
        $server = Get-SafeValue -SafeValues $csInfo["safeValues"] -Names @("Data Source", "Server", "Host")
        $port = Get-SafeValue -SafeValues $csInfo["safeValues"] -Names @("Port")
        $site.server = if ([string]::IsNullOrWhiteSpace($port)) { $server } else { "$server,$port" }
    }

    try {
        $site.appSettings = Get-AppSettingFacts -Xml $xml
        # E14: mirrored next to the other web.config flags, where the report's web.config fallback looks for it
        # (acumatica.instances.<site>.webConfig['sqlThrottling:Enabled']); the raw value text, or null when absent.
        $flags["sqlThrottling:Enabled"] = $site.appSettings["sqlThrottling"]
    }
    catch {
        $site.appSettings = [ordered]@{ unavailable = (Limit-Text $_.Exception.Message 200) }
        $flags["sqlThrottling:Enabled"] = $null
        Add-CaptureError -Section "site $InstanceName appSettings" -Message $_.Exception.Message
    }
    $site.webConfig = $flags
    return $site
}

function Get-FileHashOrNull {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
    catch { return ("unavailable: " + (Limit-Text $_.Exception.Message 120)) }
}

function Get-FileVersionOrNull {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Item -LiteralPath $Path).VersionInfo.FileVersion }
    catch { return $null }
}

function Get-AppPoolMap {
    # Returns @{ InstanceName = PoolName } using appcmd (needs elevation); falls back to the instance name.
    $map = @{}
    foreach ($i in $Instances) { $map[$i] = $i }
    if (-not (Test-Path -LiteralPath $script:AppCmd)) { return $map }
    foreach ($i in $Instances) {
        try {
            $r = Invoke-NativeProcess -FilePath $script:AppCmd -Arguments ("list app `"Default Web Site/{0}`" /text:applicationPool" -f $i) -TimeoutSec 30
            $pool = $r.StdOut.Trim()
            if ($r.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($pool)) { $map[$i] = $pool }
        }
        catch { }
    }
    return $map
}

function Get-AppPoolConfig {
    param([string]$PoolName)
    if (-not (Test-Path -LiteralPath $script:AppCmd)) {
        return [ordered]@{ unavailable = "appcmd.exe not found" }
    }
    $r = Invoke-NativeProcess -FilePath $script:AppCmd -Arguments ("list apppool `"{0}`" /text:*" -f $PoolName) -TimeoutSec 30
    if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($r.StdOut)) {
        return [ordered]@{ unavailable = ("appcmd failed (elevation needed?): " + (Limit-Text ($r.StdOut + " " + $r.StdErr) 200)) }
    }
    $text = $r.StdOut
    $config = [ordered]@{ pool = $PoolName }
    foreach ($key in @("state", "startMode", "autoStart", "managedRuntimeVersion", "managedPipelineMode", "identityType", "idleTimeout", "idleTimeoutAction", "maxProcesses", "time", "memory", "privateMemory", "requests", "limit", "action", "loadUserProfile", "disallowOverlappingRotation")) {
        $m = [regex]::Match($text, "(?m)^\s*" + [regex]::Escape($key) + ':"([^"]*)"')
        if ($m.Success) {
            $name = switch ($key) {
                "time" { "periodicRestart.time" }
                "memory" { "periodicRestart.memory" }
                "privateMemory" { "periodicRestart.privateMemory" }
                "requests" { "periodicRestart.requests" }
                "limit" { "cpu.limit" }
                "action" { "cpu.action" }
                default { $key }
            }
            $config[$name] = $m.Groups[1].Value
        }
    }
    $scheduleMatches = [regex]::Matches($text, '(?m)^\s*value:"([^"]*)"')
    $config["periodicRestart.schedule"] = @($scheduleMatches | ForEach-Object { $_.Groups[1].Value })
    return $config
}

#endregion

#region Database access

function Invoke-SqlServerRows {
    param([Parameter(Mandatory = $true)][string]$Sql, [string]$Database = "master")
    $cs = "Server={0};Database={1};Integrated Security=SSPI;Application Name={2};Encrypt=False;TrustServerCertificate=True;Connect Timeout=15" -f $script:SqlServerName, $Database, $script:AppName
    $connection = New-Object System.Data.SqlClient.SqlConnection($cs)
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Sql
        $command.CommandTimeout = 300
        $reader = $command.ExecuteReader()
        $rows = New-Object System.Collections.Generic.List[object]
        try {
            while ($reader.Read()) {
                $row = [ordered]@{}
                for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                    $value = $reader.GetValue($i)
                    if ($value -is [System.DBNull]) { $value = $null }
                    elseif ($value -is [DateTime]) { $value = $value.ToString("o") }
                    elseif ($value -is [DateTimeOffset]) { $value = $value.ToString("o") }
                    elseif ($value -is [byte[]]) { $value = [Convert]::ToBase64String($value) }
                    elseif ($value -is [Guid]) { $value = $value.ToString() }
                    $row[$reader.GetName($i)] = $value
                }
                $rows.Add([pscustomobject]$row)
            }
        }
        finally {
            $reader.Close()
        }
        return , $rows.ToArray()
    }
    finally {
        $connection.Dispose()
    }
}

function Invoke-SqlServerScalarRow {
    param([Parameter(Mandatory = $true)][string]$Sql, [string]$Database = "master")
    $rows = Invoke-SqlServerRows -Sql $Sql -Database $Database
    if (@($rows).Count -eq 0) { return $null }
    return $rows[0]
}

function ConvertFrom-JsonText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return $null }
    $t = $Text.Trim()
    if ($t.Length -eq 0 -or $t -eq "NULL") { return $null }
    $parsed = $t | ConvertFrom-Json
    Write-Output -NoEnumerate $parsed
}

function ConvertFrom-JsonLines {
    # One JSON value per non-empty output line (one line per statement of a multi-statement batch).
    param([AllowNull()][string]$Text, [int]$Expected, [string]$Tool)
    $lines = @(([string]$Text) -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -ne $Expected) {
        throw ("{0} returned {1} result line(s) instead of {2}" -f $Tool, $lines.Count, $Expected)
    }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($line in $lines) {
        $parsed = ConvertFrom-JsonText -Text $line
        $list.Add($parsed)
    }
    return , $list.ToArray()
}

function Invoke-MySqlText {
    param([Parameter(Mandatory = $true)][string]$Sql, [int]$TimeoutSec = 300)
    if ([string]::IsNullOrWhiteSpace($script:MySqlDefaults)) { throw "MySQL credentials file not available (pass -MySqlDefaultsFile)" }
    # --defaults-extra-file must be the first option. The password stays in that file.
    $arguments = "--defaults-extra-file=`"{0}`" --batch --raw --skip-column-names --default-character-set=utf8mb4 --connect-timeout=10" -f $script:MySqlDefaults
    $r = Invoke-NativeProcess -FilePath $MySqlExe -Arguments $arguments -StdIn ($Sql.Trim().TrimEnd(';') + ";`n") -TimeoutSec $TimeoutSec
    if ($r.ExitCode -ne 0) {
        throw ("mysql exit code {0}: {1}" -f $r.ExitCode, (Limit-Text $r.StdErr 300))
    }
    return [string]$r.StdOut
}

function Invoke-MySqlJson {
    param([Parameter(Mandatory = $true)][string]$Sql, [int]$TimeoutSec = 300)
    $parsed = ConvertFrom-JsonText -Text (Invoke-MySqlText -Sql $Sql -TimeoutSec $TimeoutSec)
    Write-Output -NoEnumerate $parsed
}

function Invoke-PgText {
    param([Parameter(Mandatory = $true)][string]$Sql, [Parameter(Mandatory = $true)][string]$Database, [int]$TimeoutSec = 300)
    if ([string]::IsNullOrWhiteSpace($script:PgPass)) { throw "PostgreSQL password file not available (pass -PgPassFile)" }
    # psql runs in autocommit: each statement of a multi-statement script is its own transaction.
    $arguments = "-X -A -t -q -w -v ON_ERROR_STOP=1 -h {0} -p {1} -U {2} -d `"{3}`"" -f $PgHost, $PgPort, $PgUser, $Database
    $environment = @{ PGPASSFILE = $script:PgPass; PGCONNECT_TIMEOUT = "10"; PGCLIENTENCODING = "UTF8" }
    $r = Invoke-NativeProcess -FilePath $PsqlExe -Arguments $arguments -StdIn ($Sql.Trim().TrimEnd(';') + ";`n") -Environment $environment -TimeoutSec $TimeoutSec
    if ($r.ExitCode -ne 0) {
        throw ("psql exit code {0}: {1}" -f $r.ExitCode, (Limit-Text $r.StdErr 300))
    }
    return [string]$r.StdOut
}

function Invoke-PgJson {
    param([Parameter(Mandatory = $true)][string]$Sql, [Parameter(Mandatory = $true)][string]$Database, [int]$TimeoutSec = 300)
    $parsed = ConvertFrom-JsonText -Text (Invoke-PgText -Sql $Sql -Database $Database -TimeoutSec $TimeoutSec)
    Write-Output -NoEnumerate $parsed
}

function ConvertTo-OrdinalDictionary {
    # Case-sensitive copy of a parsed JSON object or a dictionary. Windows PowerShell hashtables, [ordered] maps and
    # PSObject property lookups ignore case; table names (PostgreSQL has both distributedcache and "DistributedCache")
    # are compared exactly here.
    param($Source)
    if ($null -eq $Source) { return $null }
    $dict = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    if ($Source -is [System.Collections.IDictionary]) {
        foreach ($k in @($Source.Keys)) { $dict[[string]$k] = $Source[$k] }
    }
    else {
        foreach ($p in $Source.PSObject.Properties) { $dict[$p.Name] = $p.Value }
    }
    Write-Output -NoEnumerate $dict
}

function ConvertTo-UniqueKeyMap {
    # Ordered, case-sensitive map from (key, value) pairs. Every reader of these files parses them with Windows
    # PowerShell 5.1's ConvertFrom-Json, which rejects keys that differ only in case; such a key gets a stable '~2'
    # suffix (input order) and is listed in $Collisions. PostgreSQL keys are quote_ident() names, so
    # 'distributedcache' and '"DistributedCache"' are already distinct.
    param([System.Collections.IEnumerable]$Pairs, $Collisions)
    $map = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -ne $Pairs) {
        foreach ($pair in $Pairs) {
            $key = [string]$pair[0]
            $final = $key
            $n = 2
            while (-not $seen.Add($final)) {
                $final = $key + "~" + $n
                $n++
            }
            if ($final -cne $key -and $null -ne $Collisions) { $Collisions.Add(("{0} -> {1}" -f $key, $final)) }
            $map.Add($final, $pair[1])
        }
    }
    Write-Output -NoEnumerate $map
}

function Get-SortedByKey {
    # Sorts items by a string key, ordinal (deterministic, case-sensitive).
    param([object[]]$Items, [scriptblock]$Key)
    $arr = [object[]]@($Items)
    if ($arr.Count -lt 2) { return , $arr }
    $keys = [string[]]@(foreach ($item in $arr) { [string](& $Key $item) })
    # Explicit casts: Windows PowerShell otherwise binds an overload that sorts the keys but leaves the items unmoved.
    [Array]::Sort([Array]$keys, [Array]$arr, [System.Collections.IComparer][System.StringComparer]::Ordinal)
    return , $arr
}

function Get-SqlLiteral {
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-MySqlIdent {
    param([string]$Value)
    return '`' + $Value.Replace('`', '``') + '`'
}

function Get-PgIdent {
    param([string]$Value)
    return '"' + $Value.Replace('"', '""') + '"'
}

function Get-KeyTableListLiteral {
    param([switch]$Lower)
    $names = foreach ($t in $script:KeyTables) { if ($Lower) { $t.ToLowerInvariant() } else { $t } }
    return (($names | ForEach-Object { Get-SqlLiteral $_ }) -join ",")
}

function ConvertTo-NameValueMap {
    param($Rows, [string]$NameField = "name", [string]$ValueField = "value")
    $map = [ordered]@{}
    foreach ($row in @($Rows)) {
        $map[[string](Get-Prop $row $NameField)] = Get-Prop $row $ValueField
    }
    return $map
}

#endregion

#region Engine captures

function ConvertTo-NullableString {
    param($Value)
    if ($null -eq $Value) { return $null }
    return [string]$Value
}

function New-CollationInfo {
    # databases.<engine>.collation (contract C3). ColumnRows are {name, n} rows: text columns of base tables per collation.
    param($DatabaseDefault, $LocaleProvider, $ProbeColumnCollation, $ColumnRows, $IcuCollations, [string]$Source)
    $pairs = New-Object System.Collections.Generic.List[object]
    foreach ($row in @($ColumnRows)) {
        if ($null -eq $row) { continue }
        $name = ConvertTo-NullableString (Get-Prop $row "name")
        if ([string]::IsNullOrEmpty($name)) { $name = "(none)" }
        $pairs.Add(@($name, [long](Get-Prop $row "n")))
    }
    $collisions = New-Object System.Collections.Generic.List[string]
    $columns = ConvertTo-UniqueKeyMap -Pairs $pairs -Collisions $collisions
    $info = [ordered]@{
        databaseDefault = (ConvertTo-NullableString $DatabaseDefault)
        localeProvider = (ConvertTo-NullableString $LocaleProvider)
        probeColumn = "BAccount.AcctName"
        probeColumnCollation = (ConvertTo-NullableString $ProbeColumnCollation)
        columnCollations = $columns
        icuCollations = $IcuCollations
        source = $Source
    }
    if ($collisions.Count -gt 0) { $info["keyCollisions"] = $collisions.ToArray() }
    return $info
}

function Get-SqlServerCapture {
    param($Site)
    $db = [string]$Site.database
    if ([string]::IsNullOrWhiteSpace($db)) { $db = $Site.name }
    $dbLit = Get-SqlLiteral $db
    $cap = [ordered]@{ engine = "SQLServer"; instance = $Site.name; server = $script:SqlServerName; database = $db }

    $cap.version = Invoke-Section "SQLServer.version" {
        Invoke-SqlServerScalarRow -Sql "SELECT @@VERSION AS version, CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion')) AS productVersion, CONVERT(nvarchar(128), SERVERPROPERTY('ProductLevel')) AS productLevel, CONVERT(nvarchar(128), SERVERPROPERTY('ProductUpdateLevel')) AS productUpdateLevel, CONVERT(nvarchar(128), SERVERPROPERTY('Edition')) AS edition, CONVERT(nvarchar(128), SERVERPROPERTY('EngineEdition')) AS engineEdition, CONVERT(nvarchar(128), SERVERPROPERTY('Collation')) AS serverCollation, CONVERT(nvarchar(128), SERVERPROPERTY('MachineName')) AS machineName"
    }
    $cap.configurations = Invoke-Section "SQLServer.configurations" {
        ConvertTo-NameValueMap -Rows (Invoke-SqlServerRows -Sql "SELECT name, CONVERT(nvarchar(64), value_in_use) AS value FROM sys.configurations ORDER BY name")
    }
    $cap.database = Invoke-Section "SQLServer.database" {
        Invoke-SqlServerScalarRow -Sql ("SELECT name, recovery_model_desc, is_read_committed_snapshot_on, snapshot_isolation_state_desc, compatibility_level, collation_name, is_auto_create_stats_on, is_auto_update_stats_on, is_auto_update_stats_async_on, delayed_durability_desc, is_query_store_on, log_reuse_wait_desc, page_verify_option_desc, target_recovery_time_in_seconds FROM sys.databases WHERE name = {0}" -f $dbLit)
    }
    $cap.files = Invoke-Section "SQLServer.files" {
        $files = Invoke-SqlServerRows -Sql ("SELECT type_desc AS type, name, physical_name AS physicalName, CAST(size AS bigint) * 8 / 1024 AS sizeMB, growth, is_percent_growth AS isPercentGrowth, max_size AS maxSize FROM sys.master_files WHERE database_id = DB_ID({0})" -f $dbLit)
        [ordered]@{ files = $files; totalMB = (@($files) | Measure-Object -Property sizeMB -Sum).Sum }
    }
    $cap.sysInfo = Invoke-Section "SQLServer.sysInfo" {
        Invoke-SqlServerScalarRow -Sql "SELECT cpu_count, hyperthread_ratio, scheduler_count, physical_memory_kb / 1024 AS physicalMemoryMB, committed_kb / 1024 AS committedMB, committed_target_kb / 1024 AS committedTargetMB, max_workers_count, CONVERT(varchar(33), sqlserver_start_time, 126) AS sqlserverStartTime, numa_node_count, softnuma_configuration_desc FROM sys.dm_os_sys_info"
    }
    $cap.services = Invoke-Section "SQLServer.services" {
        , (Invoke-SqlServerRows -Sql "SELECT servicename, startup_type_desc, status_desc, service_account, instant_file_initialization_enabled, CONVERT(varchar(33), last_startup_time, 126) AS lastStartupTime FROM sys.dm_server_services")
    }
    $cap.queryStore = Invoke-Section "SQLServer.queryStore" {
        Invoke-SqlServerScalarRow -Database $db -Sql "SELECT actual_state_desc, desired_state_desc, query_capture_mode_desc, size_based_cleanup_mode_desc, current_storage_size_mb, max_storage_size_mb FROM sys.database_query_store_options"
    }
    $cap.clientConnections = Invoke-Section "SQLServer.clientConnections" {
        , (Invoke-SqlServerRows -Sql "SELECT c.net_transport AS netTransport, c.protocol_type AS protocolType, c.encrypt_option AS encryptOption, c.auth_scheme AS authScheme, s.login_name AS loginName, s.program_name AS programName, s.client_interface_name AS clientInterface, DB_NAME(s.database_id) AS db, COUNT(*) AS sessions FROM sys.dm_exec_connections c JOIN sys.dm_exec_sessions s ON s.session_id = c.session_id WHERE s.is_user_process = 1 AND c.session_id <> @@SPID GROUP BY c.net_transport, c.protocol_type, c.encrypt_option, c.auth_scheme, s.login_name, s.program_name, s.client_interface_name, DB_NAME(s.database_id) ORDER BY s.login_name")
    }
    $cap.isolation = Invoke-Section "SQLServer.isolation" {
        $rows = Invoke-SqlServerRows -Sql "SELECT s.login_name AS loginName, s.transaction_isolation_level AS level, CASE s.transaction_isolation_level WHEN 0 THEN 'Unspecified' WHEN 1 THEN 'ReadUncommitted' WHEN 2 THEN 'ReadCommitted' WHEN 3 THEN 'RepeatableRead' WHEN 4 THEN 'Serializable' WHEN 5 THEN 'Snapshot' END AS levelName, COUNT(*) AS sessions FROM sys.dm_exec_sessions s WHERE s.is_user_process = 1 AND s.session_id <> @@SPID GROUP BY s.login_name, s.transaction_isolation_level ORDER BY s.login_name"
        [ordered]@{ sessions = $rows; readCommittedSnapshot = (Get-Prop $cap.database "is_read_committed_snapshot_on") }
    }
    $cap.statisticsDates = Invoke-Section "SQLServer.statisticsDates" {
        $rows = Invoke-SqlServerRows -Database $db -Sql ("SELECT t.name AS tableName, CONVERT(varchar(33), MAX(STATS_DATE(s.object_id, s.stats_id)), 126) AS lastUpdated, COUNT(*) AS statsCount FROM sys.stats s JOIN sys.tables t ON t.object_id = s.object_id WHERE t.name IN ({0}) GROUP BY t.name" -f (Get-KeyTableListLiteral))
        ConvertTo-NameValueMap -Rows $rows -NameField "tableName" -ValueField "lastUpdated"
    }
    $cap.dataChecks = Invoke-Section "SQLServer.dataChecks" {
        Invoke-SqlServerScalarRow -Database $db -Sql ("SELECT (SELECT COUNT(*) FROM dbo.SOOrder WHERE CompanyID = {0} AND DatabaseRecordStatus <> 0) AS soOrderArchived, (SELECT COUNT(*) FROM dbo.ARRegister WHERE CompanyID = {0} AND DeletedDatabaseRecord = 1) AS arRegisterSoftDeleted, (SELECT COUNT(*) FROM dbo.Batch WHERE CompanyID = {0} AND DeletedDatabaseRecord = 1) AS batchSoftDeleted" -f $CompanyId)
    }
    $cap.collation = Invoke-Section "SQLServer.collation" {
        $head = Invoke-SqlServerScalarRow -Database $db -Sql "SELECT CONVERT(nvarchar(128), DATABASEPROPERTYEX(DB_NAME(), 'Collation')) AS databaseDefault, (SELECT TOP (1) c.collation_name FROM sys.columns c JOIN sys.tables t ON t.object_id = c.object_id JOIN sys.schemas s ON s.schema_id = t.schema_id WHERE s.name = N'dbo' AND t.name = N'BAccount' AND c.name = N'AcctName') AS probeColumnCollation"
        $rows = Invoke-SqlServerRows -Database $db -Sql "SELECT c.collation_name AS name, COUNT(*) AS n FROM sys.columns c JOIN sys.tables t ON t.object_id = c.object_id WHERE t.is_ms_shipped = 0 AND c.collation_name IS NOT NULL GROUP BY c.collation_name ORDER BY c.collation_name"
        New-CollationInfo -DatabaseDefault (Get-Prop $head "databaseDefault") -LocaleProvider $null -ProbeColumnCollation (Get-Prop $head "probeColumnCollation") -ColumnRows $rows -IcuCollations $null -Source "DATABASEPROPERTYEX(DB_NAME(), 'Collation'); sys.columns.collation_name of the user tables (sys.tables)"
    }
    return $cap
}

function Get-MySqlCapture {
    param($Site)
    $schema = [string]$Site.database
    if ([string]::IsNullOrWhiteSpace($schema)) { $schema = $Site.name.ToLowerInvariant() }
    $schemaLit = Get-SqlLiteral $schema
    $schemaId = Get-MySqlIdent $schema
    $cap = [ordered]@{ engine = "MySQL"; instance = $Site.name; schema = $schema }

    $cap.version = Invoke-Section "MySQL.version" { Invoke-MySqlJson "SELECT JSON_OBJECT('version', VERSION(), 'versionComment', @@version_comment, 'hostname', @@hostname)" }
    $cap.globalVariables = Invoke-Section "MySQL.globalVariables" { Invoke-MySqlJson "SELECT JSON_OBJECTAGG(VARIABLE_NAME, VARIABLE_VALUE) FROM performance_schema.global_variables" }
    $cap.persistedVariables = Invoke-Section "MySQL.persistedVariables" { Invoke-MySqlJson "SELECT COALESCE(JSON_OBJECTAGG(VARIABLE_NAME, VARIABLE_VALUE), JSON_OBJECT()) FROM performance_schema.persisted_variables" }
    # Innodb_buffer_pool_load_status shows whether MySQL reloaded the pages listed in ib_buffer_pool at startup
    # (innodb_buffer_pool_load_at_startup, in globalVariables): a warm start that SQL Server does not get after a restart.
    $cap.status = Invoke-Section "MySQL.status" { Invoke-MySqlJson "SELECT JSON_OBJECTAGG(VARIABLE_NAME, VARIABLE_VALUE) FROM performance_schema.global_status WHERE VARIABLE_NAME IN ('Uptime','Threads_connected','Ssl_accepts','Innodb_buffer_pool_pages_total','Innodb_buffer_pool_pages_data','Innodb_buffer_pool_bytes_data','Innodb_buffer_pool_load_status','Innodb_buffer_pool_dump_status')" }
    $cap.schemaSize = Invoke-Section "MySQL.schemaSize" {
        # From the persistent InnoDB statistics (mysql.innodb_index_stats, stat 'size' = pages allocated to each index,
        # times innodb_page_size), not information_schema.TABLES.DATA_LENGTH: with information_schema_stats_expiry = 0
        # (or an empty statistics cache) that opens every one of the ~2.3k tables and reads its tablespace header, a
        # MySQL-only warm-up right before part 1 and Block D (SQL Server and PostgreSQL report sizes from file metadata).
        # dataBytes = clustered index (PRIMARY or GEN_CLUST_INDEX), indexBytes = all other indexes; partitions are
        # included, InnoDB's internal full-text tables (fts_<16 hex digits>_...) are not. As of the last statistics update.
        $s = Invoke-MySqlJson ("SELECT JSON_OBJECT('dataBytes', CAST(COALESCE(SUM(CASE WHEN index_name IN ('PRIMARY', 'GEN_CLUST_INDEX') THEN stat_value ELSE 0 END), 0) * @@innodb_page_size AS UNSIGNED), 'indexBytes', CAST(COALESCE(SUM(CASE WHEN index_name IN ('PRIMARY', 'GEN_CLUST_INDEX') THEN 0 ELSE stat_value END), 0) * @@innodb_page_size AS UNSIGNED), 'statisticsLastUpdate', DATE_FORMAT(MAX(last_update), '%Y-%m-%dT%H:%i:%s'), 'tables', (SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = {0})) FROM mysql.innodb_index_stats WHERE LOWER(database_name) = LOWER({0}) AND stat_name = 'size' AND LOWER(table_name) NOT LIKE 'fts\_________________\_%'" -f $schemaLit)
        $info = [ordered]@{}
        foreach ($k in @("dataBytes", "indexBytes", "tables", "statisticsLastUpdate")) { $info[$k] = Get-Prop $s $k }
        $info["source"] = "mysql.innodb_index_stats stat_name 'size' x innodb_page_size (persistent InnoDB statistics, as of statisticsLastUpdate); no user table is opened"
        $info
    }
    $cap.clientConnections = Invoke-Section "MySQL.clientConnections" {
        $types = Invoke-MySqlJson "SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('user', u, 'connectionType', ct, 'threads', n)), JSON_ARRAY()) FROM (SELECT PROCESSLIST_USER AS u, CONNECTION_TYPE AS ct, COUNT(*) AS n FROM performance_schema.threads WHERE PROCESSLIST_USER IS NOT NULL AND PROCESSLIST_ID <> CONNECTION_ID() GROUP BY PROCESSLIST_USER, CONNECTION_TYPE) x"
        $tls = Invoke-MySqlJson "SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('user', u, 'sslVersion', v, 'sslCipher', c, 'threads', n)), JSON_ARRAY()) FROM (SELECT t.PROCESSLIST_USER AS u, MAX(CASE WHEN s.VARIABLE_NAME = 'Ssl_version' THEN s.VARIABLE_VALUE END) AS v, MAX(CASE WHEN s.VARIABLE_NAME = 'Ssl_cipher' THEN s.VARIABLE_VALUE END) AS c, 1 AS n FROM performance_schema.threads t JOIN performance_schema.status_by_thread s ON s.THREAD_ID = t.THREAD_ID WHERE t.PROCESSLIST_USER IS NOT NULL AND t.PROCESSLIST_ID <> CONNECTION_ID() AND s.VARIABLE_NAME IN ('Ssl_version','Ssl_cipher') GROUP BY t.THREAD_ID, t.PROCESSLIST_USER) x"
        [ordered]@{ connectionTypes = $types; tlsByThread = $tls }
    }
    $cap.isolation = Invoke-Section "MySQL.isolation" {
        Invoke-MySqlJson "SELECT JSON_OBJECT('global', @@GLOBAL.transaction_isolation, 'byThread', (SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('user', u, 'value', val, 'threads', n)), JSON_ARRAY()) FROM (SELECT t.PROCESSLIST_USER AS u, v.VARIABLE_VALUE AS val, COUNT(*) AS n FROM performance_schema.variables_by_thread v JOIN performance_schema.threads t ON t.THREAD_ID = v.THREAD_ID WHERE t.PROCESSLIST_USER IS NOT NULL AND t.PROCESSLIST_ID <> CONNECTION_ID() AND v.VARIABLE_NAME = 'transaction_isolation' GROUP BY t.PROCESSLIST_USER, v.VARIABLE_VALUE) x))"
    }
    $cap.instrumentation = Invoke-Section "MySQL.instrumentation" {
        Invoke-MySqlJson ("SELECT JSON_OBJECT('eventScheduler', @@event_scheduler, 'performanceSchema', @@performance_schema, 'schemaEvents', (SELECT COUNT(*) FROM information_schema.events WHERE event_schema = {0}), 'allEvents', (SELECT COUNT(*) FROM information_schema.events))" -f $schemaLit)
    }
    $cap.statisticsDates = Invoke-Section "MySQL.statisticsDates" {
        # mysql.innodb_table_stats.database_name is utf8mb3_bin (case-sensitive) and holds the schema name as stored
        # ('perfmysql' with lower_case_table_names=1), while web.config says 'PerfMySQL': compare both lower-cased.
        # A partitioned table (Acumatica's DatabaseRecordStatus partitions of SOOrder, SOLine, ...) has one row per
        # partition ('soorder#p#databaserecordstatuspartition0') and none under its own name: group by the base name and
        # keep the latest partition date, so it is listed under its own name as on SQL Server and PostgreSQL.
        Invoke-MySqlJson ("SELECT COALESCE(JSON_OBJECTAGG(x.b, x.d), JSON_OBJECT()) FROM (SELECT SUBSTRING_INDEX(LOWER(table_name), '#p#', 1) AS b, DATE_FORMAT(MAX(last_update), '%Y-%m-%dT%H:%i:%s') AS d FROM mysql.innodb_table_stats WHERE LOWER(database_name) = LOWER({0}) AND SUBSTRING_INDEX(LOWER(table_name), '#p#', 1) IN ({1}) GROUP BY SUBSTRING_INDEX(LOWER(table_name), '#p#', 1)) x" -f $schemaLit, (Get-KeyTableListLiteral -Lower))
    }
    $cap.dataChecks = Invoke-Section "MySQL.dataChecks" {
        Invoke-MySqlJson ("SELECT JSON_OBJECT('soOrderArchived', (SELECT COUNT(*) FROM {0}.SOOrder WHERE CompanyID = {1} AND DatabaseRecordStatus <> 0), 'arRegisterSoftDeleted', (SELECT COUNT(*) FROM {0}.ARRegister WHERE CompanyID = {1} AND DeletedDatabaseRecord = 1), 'batchSoftDeleted', (SELECT COUNT(*) FROM {0}.Batch WHERE CompanyID = {1} AND DeletedDatabaseRecord = 1))" -f $schemaId, $CompanyId)
    }
    $cap.collation = Invoke-Section "MySQL.collation" {
        $c = Invoke-MySqlJson ("SELECT JSON_OBJECT('databaseDefault', (SELECT DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = {0}), 'databaseCharacterSet', (SELECT DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = {0}), 'probeColumnCollation', (SELECT COLLATION_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = {0} AND LOWER(TABLE_NAME) = 'baccount' AND LOWER(COLUMN_NAME) = 'acctname' LIMIT 1), 'columns', (SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('name', x.coll, 'n', x.n)), JSON_ARRAY()) FROM (SELECT c.COLLATION_NAME AS coll, COUNT(*) AS n FROM information_schema.COLUMNS c JOIN information_schema.TABLES t ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME WHERE c.TABLE_SCHEMA = {0} AND t.TABLE_TYPE = 'BASE TABLE' AND c.COLLATION_NAME IS NOT NULL GROUP BY c.COLLATION_NAME) x))" -f $schemaLit)
        $info = New-CollationInfo -DatabaseDefault (Get-Prop $c "databaseDefault") -LocaleProvider $null -ProbeColumnCollation (Get-Prop $c "probeColumnCollation") -ColumnRows (Get-Prop $c "columns") -IcuCollations $null -Source "information_schema.SCHEMATA.DEFAULT_COLLATION_NAME; information_schema.COLUMNS.COLLATION_NAME of the schema's BASE TABLEs"
        $info["databaseCharacterSet"] = ConvertTo-NullableString (Get-Prop $c "databaseCharacterSet")
        $info
    }
    return $cap
}

function Get-PgSettingsMap {
    param($Settings)
    $map = @{}
    foreach ($s in @($Settings)) {
        $map[[string](Get-Prop $s "name")] = $s
    }
    return $map
}

function Get-PostgreSqlCapture {
    param($Site)
    $db = [string]$Site.database
    if ([string]::IsNullOrWhiteSpace($db)) { $db = $Site.name }
    $cap = [ordered]@{ engine = "PostgreSQL"; instance = $Site.name; database = $db }

    $cap.version = Invoke-Section "PostgreSQL.version" {
        Invoke-PgJson -Database $db -Sql "SELECT json_build_object('version', version(), 'serverVersion', current_setting('server_version'), 'postmasterStartTime', pg_postmaster_start_time(), 'database', current_database(), 'dbSizeBytes', pg_database_size(current_database()), 'owner', (SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = current_database()))"
    }
    $cap.databaseRow = Invoke-Section "PostgreSQL.databaseRow" {
        Invoke-PgJson -Database $db -Sql "SELECT to_jsonb(d) - 'datacl' FROM pg_database d WHERE datname = current_database()"
    }
    $cap.settings = Invoke-Section "PostgreSQL.settings" {
        # Invoke-PgJson already returns the parsed array as one object; do not wrap it in @() (that would nest it).
        Invoke-PgJson -Database $db -Sql "SELECT json_agg(json_build_object('name', name, 'setting', setting, 'unit', unit, 'source', source) ORDER BY name) FROM pg_settings"
    }
    $cap.nonDefaultSettings = Invoke-Section "PostgreSQL.nonDefaultSettings" {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($s in @($cap.settings)) {
            $src = [string](Get-Prop $s "source")
            if (-not [string]::IsNullOrWhiteSpace($src) -and $src -ne "default" -and $src -ne "override") { $list.Add($s) }
        }
        , $list.ToArray()
    }
    $cap.roleSettings = Invoke-Section "PostgreSQL.roleSettings" {
        Invoke-PgJson -Database $db -Sql "SELECT COALESCE(json_agg(json_build_object('database', d.datname, 'role', r.rolname, 'settings', s.setconfig)), '[]'::json) FROM pg_db_role_setting s LEFT JOIN pg_database d ON d.oid = s.setdatabase LEFT JOIN pg_roles r ON r.oid = s.setrole"
    }
    $cap.walSize = Invoke-Section "PostgreSQL.walSize" {
        Invoke-PgJson -Database $db -Sql "SELECT json_build_object('walFiles', count(*), 'walBytes', COALESCE(sum(size), 0)) FROM pg_ls_waldir()"
    }
    $cap.clientConnections = Invoke-Section "PostgreSQL.clientConnections" {
        Invoke-PgJson -Database $db -Sql "SELECT COALESCE(json_agg(x), '[]'::json) FROM (SELECT a.usename AS user, a.datname AS db, a.application_name AS application, host(a.client_addr) AS client_addr, s.ssl, s.version AS ssl_version, s.cipher AS ssl_cipher, count(*) AS backends FROM pg_stat_activity a LEFT JOIN pg_stat_ssl s ON s.pid = a.pid WHERE a.backend_type = 'client backend' AND a.pid <> pg_backend_pid() GROUP BY 1, 2, 3, 4, 5, 6, 7) x"
    }
    $cap.isolation = Invoke-Section "PostgreSQL.isolation" {
        Invoke-PgJson -Database $db -Sql "SELECT json_build_object('defaultTransactionIsolation', current_setting('default_transaction_isolation'), 'byBackend', (SELECT COALESCE(json_agg(json_build_object('user', usename, 'backends', n)), '[]'::json) FROM (SELECT usename, count(*) AS n FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid() GROUP BY usename) x))"
    }
    $cap.instrumentation = Invoke-Section "PostgreSQL.instrumentation" {
        Invoke-PgJson -Database $db -Sql "SELECT json_build_object('sharedPreloadLibraries', current_setting('shared_preload_libraries'), 'extensions', (SELECT COALESCE(json_agg(extname ORDER BY extname), '[]'::json) FROM pg_extension), 'trackActivities', current_setting('track_activities'), 'trackCounts', current_setting('track_counts'))"
    }
    $cap.statisticsDates = Invoke-Section "PostgreSQL.statisticsDates" {
        # Keys are quote_ident() names so that a quoted mixed-case twin can never collide with the lower-case table under
        # Windows PowerShell's case-insensitive ConvertFrom-Json. relkind 'p' marks a partitioned parent (its own
        # n_live_tup is always 0); reltuples is the planner estimate (summed over the leaf partitions for a parent).
        # After a restore from the template database, the cumulative pg_stat counters (n_live_tup, last_*) restart
        # empty while pg_class.reltuples is copied, so nLiveTup = 0 then does not mean an empty table.
        Invoke-PgJson -Database $db -Sql ("SELECT COALESCE(json_object_agg(quote_ident(s.relname), json_build_object('lastAnalyze', s.last_analyze, 'lastAutoanalyze', s.last_autoanalyze, 'lastVacuum', s.last_vacuum, 'lastAutovacuum', s.last_autovacuum, 'nLiveTup', s.n_live_tup, 'relkind', c.relkind, 'reltuples', CASE WHEN c.relkind = 'p' THEN (SELECT sum(GREATEST(l.reltuples, 0))::bigint FROM pg_partition_tree(c.oid::regclass) pt JOIN pg_class l ON l.oid = pt.relid::oid WHERE pt.isleaf) WHEN c.reltuples < 0 THEN NULL ELSE c.reltuples::bigint END)), '{{}}'::json) FROM pg_stat_user_tables s JOIN pg_class c ON c.oid = s.relid WHERE s.schemaname = 'public' AND lower(s.relname) IN ({0})" -f (Get-KeyTableListLiteral -Lower))
    }
    $cap.dataChecks = Invoke-Section "PostgreSQL.dataChecks" {
        Invoke-PgJson -Database $db -Sql ("SELECT json_build_object('soOrderArchived', (SELECT count(*) FROM soorder WHERE companyid = {0} AND databaserecordstatus <> 0), 'arRegisterSoftDeleted', (SELECT count(*) FROM arregister WHERE companyid = {0} AND deleteddatabaserecord = true), 'batchSoftDeleted', (SELECT count(*) FROM batch WHERE companyid = {0} AND deleteddatabaserecord = true))" -f $CompanyId)
    }
    $cap.collation = Invoke-Section "PostgreSQL.collation" {
        # Text columns per collation from pg_attribute (the data behind information_schema.columns.collation_name, which
        # shows NULL for the database default; here that is counted as 'default'). Base tables of schema public only:
        # plain tables and partitioned parents, partition children skipped (they repeat the parent's columns).
        $c = Invoke-PgJson -Database $db -Sql "SELECT json_build_object('datcollate', d.datcollate, 'datctype', d.datctype, 'datlocale', d.datlocale, 'localeProvider', CASE d.datlocprovider WHEN 'c' THEN 'libc' WHEN 'i' THEN 'icu' WHEN 'b' THEN 'builtin' ELSE d.datlocprovider::text END, 'probeColumnCollation', (SELECT co.collname FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace LEFT JOIN pg_collation co ON co.oid = a.attcollation WHERE n.nspname = 'public' AND c.relname = 'baccount' AND a.attname = 'acctname' AND a.attnum > 0 AND NOT a.attisdropped LIMIT 1), 'columns', (SELECT COALESCE(json_agg(json_build_object('name', x.collname, 'n', x.n) ORDER BY x.collname), '[]'::json) FROM (SELECT co.collname, count(*) AS n FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace JOIN pg_collation co ON co.oid = a.attcollation WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND NOT c.relispartition AND a.attnum > 0 AND NOT a.attisdropped GROUP BY co.collname) x), 'icu', (SELECT COALESCE(json_agg(json_build_object('name', co.collname, 'schema', cn.nspname, 'provider', CASE co.collprovider WHEN 'c' THEN 'libc' WHEN 'i' THEN 'icu' WHEN 'b' THEN 'builtin' WHEN 'd' THEN 'default' ELSE co.collprovider::text END, 'locale', COALESCE(co.colllocale, co.collcollate), 'deterministic', co.collisdeterministic) ORDER BY co.collname, cn.nspname), '[]'::json) FROM pg_collation co JOIN pg_namespace cn ON cn.oid = co.collnamespace WHERE co.collname LIKE 'latin1\_general%')) FROM pg_database d WHERE d.datname = current_database()"
        $provider = ConvertTo-NullableString (Get-Prop $c "localeProvider")
        $default = if ($provider -eq "libc" -or $null -eq (Get-Prop $c "datlocale")) { Get-Prop $c "datcollate" } else { Get-Prop $c "datlocale" }
        $icu = @(foreach ($row in @(Get-Prop $c "icu")) {
                if ($null -eq $row) { continue }
                [ordered]@{ name = (Get-Prop $row "name"); schema = (Get-Prop $row "schema"); provider = (Get-Prop $row "provider"); locale = (Get-Prop $row "locale"); deterministic = (Get-Prop $row "deterministic") }
            })
        $info = New-CollationInfo -DatabaseDefault $default -LocaleProvider $provider -ProbeColumnCollation (Get-Prop $c "probeColumnCollation") -ColumnRows (Get-Prop $c "columns") -IcuCollations $icu -Source "pg_database (datlocprovider, datcollate, datlocale); pg_attribute.attcollation of the text columns of schema public (plain tables and partitioned parents); pg_collation rows LIKE 'latin1_general%'"
        $info["datcollate"] = ConvertTo-NullableString (Get-Prop $c "datcollate")
        $info["datctype"] = ConvertTo-NullableString (Get-Prop $c "datctype")
        $info["datlocale"] = ConvertTo-NullableString (Get-Prop $c "datlocale")
        $info
    }
    return $cap
}

#endregion

#region Environment sections

function Get-CpuCoreSplit {
    param([string]$CpuName)
    if (-not [string]::IsNullOrWhiteSpace($CpuCoreSplit)) {
        return [ordered]@{ value = $CpuCoreSplit; source = "manual (-CpuCoreSplit)" }
    }
    $known = @{
        "Core\(TM\) Ultra 9 285HX" = "8P+16E"
        "Core\(TM\) Ultra 9 275HX" = "8P+16E"
        "Core\(TM\) i9-14900HX" = "8P+16E"
        "Core\(TM\) i9-13980HX" = "8P+16E"
    }
    foreach ($pattern in $known.Keys) {
        if ($CpuName -match $pattern) {
            return [ordered]@{ value = $known[$pattern]; source = "manual table for this CPU model (no Windows API reports the split)" }
        }
    }
    return [ordered]@{ value = $null; source = "not recorded: pass -CpuCoreSplit" }
}

function Get-HostSection {
    $section = [ordered]@{}
    $section.computer = Invoke-Section "host.computer" {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem
        [ordered]@{
            manufacturer = $cs.Manufacturer
            model = $cs.Model
            systemFamily = (Get-Prop $cs "SystemFamily")
            totalPhysicalMemoryGB = [Math]::Round([double]$cs.TotalPhysicalMemory / 1GB, 1)
            processorsSockets = $cs.NumberOfProcessors
            logicalProcessors = $cs.NumberOfLogicalProcessors
        }
    }
    $section.cpu = Invoke-Section "host.cpu" {
        $cpus = @(Get-CimInstance -ClassName Win32_Processor)
        $first = $cpus[0]
        $cores = ($cpus | Measure-Object -Property NumberOfCores -Sum).Sum
        $logical = ($cpus | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        [ordered]@{
            name = ([string]$first.Name).Trim()
            cores = $cores
            logicalProcessors = $logical
            hyperThreading = ($logical -gt $cores)
            maxClockMHz = $first.MaxClockSpeed
            performanceEfficiencySplit = (Get-CpuCoreSplit -CpuName ([string]$first.Name))
        }
    }
    $section.os = Invoke-Section "host.os" {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        [ordered]@{
            caption = $os.Caption
            version = $os.Version
            build = $os.BuildNumber
            ubr = (Invoke-Section "host.os.ubr" { (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name UBR).UBR })
            lastBootUtc = (ConvertTo-IsoUtc $os.LastBootUpTime)
        }
    }
    $section.memory = Invoke-Section "host.memory" {
        # Windows memory lists. The standby list is the file cache: PostgreSQL reads its data files through it, and a
        # service restart does not empty it (SQL Server and InnoDB data files use unbuffered I/O and do not rely on it).
        # Recorded so the cache state at the start of a measured block can be disclosed; no file names are available.
        $m = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory
        $standby = [double]$m.StandbyCacheCoreBytes + [double]$m.StandbyCacheNormalPriorityBytes + [double]$m.StandbyCacheReserveBytes
        [ordered]@{
            availableMB = [Math]::Round([double]$m.AvailableBytes / 1MB, 0)
            standbyListMB = [Math]::Round($standby / 1MB, 0)
            standbyCoreMB = [Math]::Round([double]$m.StandbyCacheCoreBytes / 1MB, 0)
            standbyNormalPriorityMB = [Math]::Round([double]$m.StandbyCacheNormalPriorityBytes / 1MB, 0)
            standbyReserveMB = [Math]::Round([double]$m.StandbyCacheReserveBytes / 1MB, 0)
            modifiedListMB = [Math]::Round([double]$m.ModifiedPageListBytes / 1MB, 0)
            freeAndZeroMB = [Math]::Round([double]$m.FreeAndZeroPageListBytes / 1MB, 0)
            systemCacheWorkingSetMB = [Math]::Round([double]$m.CacheBytes / 1MB, 0)
            source = "Win32_PerfFormattedData_PerfOS_Memory (standby list = Standby Cache Core + Normal Priority + Reserve)"
        }
    }
    $section.uptimeSec = Invoke-Section "host.uptime" {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        [Math]::Round(((Get-Date) - $os.LastBootUpTime).TotalSeconds, 0)
    }
    $section.disks = Invoke-Section "host.disks" {
        $disks = @(Get-PhysicalDisk | Sort-Object DeviceId | ForEach-Object {
                [ordered]@{ friendlyName = $_.FriendlyName; mediaType = [string]$_.MediaType; busType = [string]$_.BusType; sizeGB = [Math]::Round([double]$_.Size / 1GB, 0) }
            })
        , $disks
    }
    $section.power = Invoke-Section "host.power" {
        $r = Invoke-NativeProcess -FilePath (Join-Path $env:windir "System32\powercfg.exe") -Arguments "/getactivescheme" -TimeoutSec 30
        $line = $r.StdOut.Trim()
        $guid = $null; $name = $null
        $m = [regex]::Match($line, '([0-9a-fA-F]{8}-[0-9a-fA-F-]{27})\s+\((.*)\)')
        if ($m.Success) { $guid = $m.Groups[1].Value; $name = $m.Groups[2].Value }
        $acLine = $null
        try {
            Add-Type -AssemblyName System.Windows.Forms
            $acLine = [string][System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus
        }
        catch { }
        $batteries = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
        [ordered]@{
            activeSchemeGuid = $guid
            activeSchemeName = $name
            raw = $line
            powerLine = $acLine
            battery = if ($batteries.Count -gt 0) { [ordered]@{ present = $true; chargePct = $batteries[0].EstimatedChargeRemaining; status = $batteries[0].BatteryStatus } } else { [ordered]@{ present = $false } }
            msiMode = if ([string]::IsNullOrWhiteSpace($MsiMode)) { "not recorded (manual: pass -MsiMode)" } else { $MsiMode }
        }
    }
    return $section
}

function Get-BackgroundSection {
    param($AppPoolMap)
    $section = [ordered]@{}
    $section.runningServices = Invoke-Section "background.runningServices" {
        , @(Get-Service | Where-Object { $_.Status -eq "Running" } | Sort-Object Name | ForEach-Object { $_.Name })
    }
    $section.watchedServices = Invoke-Section "background.watchedServices" {
        $list = foreach ($name in $script:WatchedServices) {
            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($null -eq $svc) {
                [ordered]@{ name = $name; status = "NotInstalled"; startType = $null; stoppedForCampaign = ($script:CampaignStoppedServices -contains $name) }
            }
            else {
                [ordered]@{ name = $name; status = [string]$svc.Status; startType = [string]$svc.StartType; stoppedForCampaign = ($script:CampaignStoppedServices -contains $name) }
            }
        }
        , @($list)
    }
    $section.appPools = Invoke-Section "background.appPools" {
        if (-not (Test-Path -LiteralPath $script:AppCmd)) { throw "appcmd.exe not found" }
        $r = Invoke-NativeProcess -FilePath $script:AppCmd -Arguments "list apppool" -TimeoutSec 30
        if ($r.ExitCode -ne 0) { throw ("appcmd list apppool failed (elevation needed?): " + (Limit-Text ($r.StdOut + " " + $r.StdErr) 200)) }
        $pools = foreach ($line in ($r.StdOut -split "`r?`n")) {
            $m = [regex]::Match($line, '^APPPOOL "([^"]+)" \((.*)\)')
            if ($m.Success) {
                $state = [regex]::Match($m.Groups[2].Value, 'state:([^,\)]+)').Groups[1].Value
                [ordered]@{ name = $m.Groups[1].Value; state = $state; benchmarkPool = (@($AppPoolMap.Values) -contains $m.Groups[1].Value) }
            }
        }
        $all = @($pools)
        [ordered]@{ pools = $all; otherStartedPools = @($all | Where-Object { -not $_.benchmarkPool -and $_.state -eq "Started" } | ForEach-Object { $_.name }) }
    }
    $section.topProcessesByWorkingSet = Invoke-Section "background.topProcesses" {
        , @(Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 10 | ForEach-Object {
                [ordered]@{ name = $_.ProcessName; id = $_.Id; workingSetMB = [Math]::Round($_.WorkingSet64 / 1MB, 0) }
            })
    }
    $section.scheduledTasksDue = Invoke-Section "background.scheduledTasks" {
        $limit = (Get-Date).AddHours($ScheduledTaskWindowHours)
        $due = New-Object System.Collections.Generic.List[object]
        foreach ($task in @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.State -ne "Disabled" })) {
            try {
                $info = $task | Get-ScheduledTaskInfo -ErrorAction Stop
                $next = $info.NextRunTime
                if ($null -ne $next -and $next -gt (Get-Date) -and $next -le $limit) {
                    $due.Add([ordered]@{ path = $task.TaskPath; name = $task.TaskName; nextRunLocal = $next.ToString("s") })
                }
            }
            catch { }
        }
        [ordered]@{ windowHours = $ScheduledTaskWindowHours; tasks = $due.ToArray() }
    }
    return $section
}

function Get-ManualFile {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($script:CampaignFolder)) { return "not recorded (no -CampaignDir)" }
    $path = Join-Path $script:CampaignFolder $Name
    if (-not (Test-Path -LiteralPath $path)) { return "not recorded ($Name missing)" }
    return ([System.IO.File]::ReadAllText($path)).Trim()
}

function Get-AntivirusSection {
    $section = [ordered]@{}
    $section.bitdefenderExclusionsManual = Get-ManualFile -Name "av-exclusions.txt"
    $section.defender = Invoke-Section "antivirus.defender" {
        $s = Get-MpComputerStatus
        [ordered]@{ amRunningMode = (Get-Prop $s "AMRunningMode"); realTimeProtectionEnabled = (Get-Prop $s "RealTimeProtectionEnabled"); antivirusEnabled = (Get-Prop $s "AntivirusEnabled") }
    }
    return $section
}

function Get-RepoSection {
    $section = [ordered]@{ repoRoot = $script:RepoRoot }
    $section.git = Invoke-Section "repo.git" {
        $git = Get-Command git -ErrorAction Stop
        $head = Invoke-NativeProcess -FilePath $git.Source -Arguments ("-C `"{0}`" rev-parse HEAD" -f $script:RepoRoot) -TimeoutSec 30
        $branch = Invoke-NativeProcess -FilePath $git.Source -Arguments ("-C `"{0}`" rev-parse --abbrev-ref HEAD" -f $script:RepoRoot) -TimeoutSec 30
        $status = Invoke-NativeProcess -FilePath $git.Source -Arguments ("-C `"{0}`" status --porcelain" -f $script:RepoRoot) -TimeoutSec 60
        $dirty = @($status.StdOut -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        [ordered]@{ head = $head.StdOut.Trim(); branch = $branch.StdOut.Trim(); porcelainLines = $dirty.Count; clean = ($dirty.Count -eq 0); porcelainSample = @($dirty | Select-Object -First 20) }
    }
    $section.dll = Invoke-Section "repo.dll" {
        $built = Join-Path $script:RepoRoot "src\PerfDBBenchmark.Core\bin\Release\net48\PerfDBBenchmark.Core.dll"
        $hashes = [ordered]@{ built = (Get-FileHashOrNull $built) }
        foreach ($i in $Instances) {
            $hashes[$i] = Get-FileHashOrNull (Join-Path (Join-Path $InstanceRoot $i) "Bin\PerfDBBenchmark.Core.dll")
        }
        $values = @($hashes.Values | Where-Object { $null -ne $_ })
        $distinct = @($values | Select-Object -Unique)
        [ordered]@{ sha256 = $hashes; allPresent = ($values.Count -eq $hashes.Count); allEqual = (($values.Count -eq $hashes.Count) -and $distinct.Count -eq 1) }
    }
    return $section
}

function Get-AcumaticaSection {
    param($Sites, $AppPoolMap)
    $section = [ordered]@{ licenceState = $LicenceState; requestProfilerManual = (Get-ManualFile -Name "request-profiler.txt"); instances = [ordered]@{} }
    foreach ($site in $Sites) {
        $i = $site.name
        $entry = [ordered]@{
            path = $site.path
            engine = $site.engine
            engineSource = $site.engineSource
            providerType = $site.providerType
            database = $site.database
            pxDataFileVersion = (Get-FileVersionOrNull (Join-Path $site.path "Bin\PX.Data.dll"))
            webConfig = $site.webConfig
            appSettings = $site.appSettings
            connectionStringKeys = if ($null -ne $site.connectionString) { $site.connectionString["keyNames"] } else { @() }
            connectionStringSafeValues = if ($null -ne $site.connectionString) { $site.connectionString["safeValues"] } else { [ordered]@{} }
            appPool = $AppPoolMap[$i]
        }
        $entry.appPoolConfig = Invoke-Section "acumatica.$i.appPool" { Get-AppPoolConfig -PoolName $AppPoolMap[$i] }
        $drivers = [ordered]@{}
        foreach ($dll in @("MySqlConnector.dll", "Npgsql.dll", "Microsoft.Data.SqlClient.dll", "System.Data.SqlClient.dll")) {
            $v = Get-FileVersionOrNull (Join-Path $site.path ("Bin\" + $dll))
            if ($null -eq $v) { $v = Get-FileVersionOrNull (Join-Path $InstanceRoot ("Files\Bin\" + $dll)) }
            $drivers[$dll] = $v
        }
        $entry.driverVersions = $drivers
        $section.instances[$i] = $entry
    }
    $section.pxDataFileVersionInstaller = Get-FileVersionOrNull (Join-Path $InstanceRoot "Files\Bin\PX.Data.dll")
    return $section
}

function Get-SettingValue {
    param($Map, [string]$Name)
    if ($null -eq $Map) { return $null }
    $v = Get-Prop $Map $Name
    return $v
}

function Get-PgSetting {
    param($PgCapture, [string]$Name)
    if ($null -eq $PgCapture) { return $null }
    foreach ($s in @(Get-Prop $PgCapture "settings")) {
        if ([string](Get-Prop $s "name") -eq $Name) {
            $unit = [string](Get-Prop $s "unit")
            $setting = [string](Get-Prop $s "setting")
            if ([string]::IsNullOrWhiteSpace($unit)) { return $setting }
            return ("{0} {1}" -f $setting, $unit)
        }
    }
    return $null
}

function Get-ClientConnectionSummary {
    param($Sites, $Databases, $AppPoolMap)
    $summary = [ordered]@{}
    foreach ($site in $Sites) {
        $engine = $site.engine
        $cap = Get-Prop $Databases $engine
        $entry = [ordered]@{ engine = $engine; transport = $null; encryption = $null; login = $null; isolation = $null; detail = $null }
        if ($null -eq $cap -or $null -ne (Get-Prop $cap "skipped") -or $null -ne (Get-Prop $cap "unavailable")) {
            $entry.detail = "database not captured"
            $summary[$site.name] = $entry
            continue
        }
        switch ($engine) {
            "SQLServer" {
                $login = "IIS APPPOOL\" + $AppPoolMap[$site.name]
                $rows = @(Get-Prop $cap "clientConnections" | Where-Object { $null -ne $_ -and ([string](Get-Prop $_ "loginName")) -ieq $login })
                $entry.login = $login
                $entry.transport = (@($rows | ForEach-Object { [string](Get-Prop $_ "netTransport") } | Select-Object -Unique) -join ", ")
                $entry.encryption = (@($rows | ForEach-Object { [string](Get-Prop $_ "encryptOption") } | Select-Object -Unique) -join ", ")
                $iso = Get-Prop $cap "isolation"
                $isoRows = @(Get-Prop $iso "sessions" | Where-Object { $null -ne $_ -and ([string](Get-Prop $_ "loginName")) -ieq $login })
                $entry.isolation = (@($isoRows | ForEach-Object { [string](Get-Prop $_ "levelName") } | Select-Object -Unique) -join ", ")
                $entry.detail = "sessions: " + (($rows | Measure-Object -Property sessions -Sum).Sum)
            }
            "MySQL" {
                $cc = Get-Prop $cap "clientConnections"
                $types = @(Get-Prop $cc "connectionTypes" | Where-Object { $null -ne $_ -and ([string](Get-Prop $_ "user")) -eq "acumatica" })
                $tls = @(Get-Prop $cc "tlsByThread" | Where-Object { $null -ne $_ -and ([string](Get-Prop $_ "user")) -eq "acumatica" })
                $entry.login = "acumatica"
                $entry.transport = (@($types | ForEach-Object { [string](Get-Prop $_ "connectionType") } | Select-Object -Unique) -join ", ")
                $ciphers = @($tls | ForEach-Object { $c = [string](Get-Prop $_ "sslCipher"); if ([string]::IsNullOrWhiteSpace($c)) { "none" } else { $c } } | Select-Object -Unique)
                $entry.encryption = if ($ciphers.Count -eq 0) { $null } else { "TLS cipher: " + ($ciphers -join ", ") }
                $iso = Get-Prop $cap "isolation"
                $byThread = @(Get-Prop $iso "byThread" | Where-Object { $null -ne $_ -and ([string](Get-Prop $_ "user")) -eq "acumatica" })
                $entry.isolation = (@($byThread | ForEach-Object { [string](Get-Prop $_ "value") } | Select-Object -Unique) -join ", ")
                if ([string]::IsNullOrWhiteSpace($entry.isolation)) { $entry.isolation = "global " + [string](Get-Prop $iso "global") }
            }
            "PostgreSQL" {
                $rows = @(Get-Prop $cap "clientConnections" | Where-Object { $null -ne $_ -and ([string](Get-Prop $_ "user")) -eq "acumatica" })
                $entry.login = "acumatica"
                $entry.transport = (@($rows | ForEach-Object { $a = [string](Get-Prop $_ "client_addr"); if ([string]::IsNullOrWhiteSpace($a)) { "unix/local" } else { "TCP " + $a } } | Select-Object -Unique) -join ", ")
                $entry.encryption = (@($rows | ForEach-Object { "ssl " + [string](Get-Prop $_ "ssl") } | Select-Object -Unique) -join ", ")
                $entry.isolation = [string](Get-Prop (Get-Prop $cap "isolation") "defaultTransactionIsolation")
            }
        }
        $summary[$site.name] = $entry
    }
    return $summary
}

function Get-HighlightList {
    param($Databases, $ClientConnection)
    $sql = Get-Prop $Databases "SQLServer"
    $my = Get-Prop $Databases "MySQL"
    $pg = Get-Prop $Databases "PostgreSQL"
    $sqlCfg = Get-Prop $sql "configurations"
    $sqlDb = Get-Prop $sql "database"
    $myVars = Get-Prop $my "globalVariables"

    $h = [ordered]@{}
    $h.memory = [ordered]@{
        SQLServer = [ordered]@{ maxServerMemoryMB = (Get-SettingValue $sqlCfg "max server memory (MB)"); minServerMemoryMB = (Get-SettingValue $sqlCfg "min server memory (MB)"); covers = "buffer pool, plan cache and query memory" }
        MySQL = [ordered]@{ innodbBufferPoolSize = (Get-SettingValue $myVars "innodb_buffer_pool_size"); covers = "data and index cache only" }
        PostgreSQL = [ordered]@{ sharedBuffers = (Get-PgSetting $pg "shared_buffers"); effectiveCacheSize = (Get-PgSetting $pg "effective_cache_size"); covers = "shared_buffers is the database's own cache; the Windows file cache adds to it; effective_cache_size is a planner hint" }
    }
    $h.commitDurability = [ordered]@{
        SQLServer = [ordered]@{ recoveryModel = (Get-Prop $sqlDb "recovery_model_desc"); delayedDurability = (Get-Prop $sqlDb "delayed_durability_desc") }
        MySQL = [ordered]@{ innodbFlushLogAtTrxCommit = (Get-SettingValue $myVars "innodb_flush_log_at_trx_commit"); logBin = (Get-SettingValue $myVars "log_bin"); syncBinlog = (Get-SettingValue $myVars "sync_binlog") }
        PostgreSQL = [ordered]@{ synchronousCommit = (Get-PgSetting $pg "synchronous_commit"); walLevel = (Get-PgSetting $pg "wal_level") }
    }
    $h.clientConnection = $ClientConnection
    $h.isolationInUse = [ordered]@{}
    foreach ($k in @($ClientConnection.Keys)) { $h.isolationInUse[$k] = $ClientConnection[$k].isolation }
    $h.queryParallelism = [ordered]@{
        SQLServer = [ordered]@{ maxDegreeOfParallelism = (Get-SettingValue $sqlCfg "max degree of parallelism"); costThresholdForParallelism = (Get-SettingValue $sqlCfg "cost threshold for parallelism") }
        MySQL = [ordered]@{ note = "no intra-query parallelism for ordinary queries"; innodbParallelReadThreads = (Get-SettingValue $myVars "innodb_parallel_read_threads") }
        PostgreSQL = [ordered]@{ maxParallelWorkersPerGather = (Get-PgSetting $pg "max_parallel_workers_per_gather"); maxParallelWorkers = (Get-PgSetting $pg "max_parallel_workers") }
    }
    $h.sortMemory = [ordered]@{
        SQLServer = "dynamic memory grant"
        MySQL = [ordered]@{ sortBufferSize = (Get-SettingValue $myVars "sort_buffer_size"); joinBufferSize = (Get-SettingValue $myVars "join_buffer_size"); tmpTableSize = (Get-SettingValue $myVars "tmp_table_size") }
        PostgreSQL = [ordered]@{ workMem = (Get-PgSetting $pg "work_mem"); hashMemMultiplier = (Get-PgSetting $pg "hash_mem_multiplier") }
    }
    $h.jit = [ordered]@{ PostgreSQL = (Get-PgSetting $pg "jit") }
    $h.randomPageCost = [ordered]@{ PostgreSQL = (Get-PgSetting $pg "random_page_cost") }
    $h.walOrRedo = [ordered]@{ MySQL = [ordered]@{ innodbRedoLogCapacity = (Get-SettingValue $myVars "innodb_redo_log_capacity") }; PostgreSQL = [ordered]@{ maxWalSize = (Get-PgSetting $pg "max_wal_size") } }
    # What a service restart leaves warm (SPEC 3q "equal restart"): SQL Server keeps nothing (own buffer pool, unbuffered
    # I/O); MySQL reloads the pages listed in ib_buffer_pool when load_at_startup is ON; PostgreSQL reads through the
    # Windows file cache (standby list, host.memory), which a service restart does not empty.
    $myStatus = Get-Prop $my "status"
    $h.cacheAfterServiceRestart = [ordered]@{
        SQLServer = "buffer pool only (data files opened unbuffered): empty after a service restart"
        MySQL = [ordered]@{ innodbBufferPoolDumpAtShutdown = (Get-SettingValue $myVars "innodb_buffer_pool_dump_at_shutdown"); innodbBufferPoolLoadAtStartup = (Get-SettingValue $myVars "innodb_buffer_pool_load_at_startup"); innodbBufferPoolDumpPct = (Get-SettingValue $myVars "innodb_buffer_pool_dump_pct"); innodbFlushMethod = (Get-SettingValue $myVars "innodb_flush_method"); bufferPoolLoadStatus = (Get-SettingValue $myStatus "Innodb_buffer_pool_load_status") }
        PostgreSQL = [ordered]@{ debugIoDirect = (Get-PgSetting $pg "debug_io_direct"); ioMethod = (Get-PgSetting $pg "io_method"); note = "data files are read through the Windows file cache unless debug_io_direct includes 'data'; a service restart empties shared_buffers only" }
    }
    $pgDbRow = Get-Prop $pg "databaseRow"
    $h.collation = [ordered]@{
        SQLServer = [ordered]@{ server = (Get-Prop (Get-Prop $sql "version") "serverCollation"); database = (Get-Prop $sqlDb "collation_name") }
        MySQL = [ordered]@{ collationServer = (Get-SettingValue $myVars "collation_server"); characterSetServer = (Get-SettingValue $myVars "character_set_server") }
        PostgreSQL = [ordered]@{ datcollate = (Get-Prop $pgDbRow "datcollate"); datctype = (Get-Prop $pgDbRow "datctype"); localeProvider = (Get-Prop $pgDbRow "datlocprovider") }
    }
    $h.queryStore = [ordered]@{ SQLServer = (Get-Prop (Get-Prop $sql "queryStore") "actual_state_desc") }
    $h.sqlServerEdition = (Get-Prop (Get-Prop $sql "version") "edition")
    $h.versions = [ordered]@{
        SQLServer = (Get-Prop (Get-Prop $sql "version") "productVersion")
        MySQL = (Get-Prop (Get-Prop $my "version") "version")
        PostgreSQL = (Get-Prop (Get-Prop $pg "version") "serverVersion")
    }
    return $h
}

#endregion

#region Modes

function Get-DatabaseCaptures {
    param($Sites)
    $databases = [ordered]@{}
    foreach ($site in $Sites) {
        $engine = $site.engine
        if ($databases.Contains($engine)) { continue }
        if ($SkipDatabases) {
            $databases[$engine] = [ordered]@{ skipped = $true; reason = "-SkipDatabases" }
            continue
        }
        switch ($engine) {
            "SQLServer" { $databases[$engine] = Invoke-Section "SQLServer" { Get-SqlServerCapture -Site $site } }
            "MySQL" {
                if ([string]::IsNullOrWhiteSpace($script:MySqlDefaults)) { $databases[$engine] = [ordered]@{ unavailable = "MySQL credentials file not found (pass -MySqlDefaultsFile)" } }
                elseif (-not (Test-Path -LiteralPath $MySqlExe)) { $databases[$engine] = [ordered]@{ unavailable = "mysql.exe not found (pass -MySqlExe)" } }
                else { $databases[$engine] = Invoke-Section "MySQL" { Get-MySqlCapture -Site $site } }
            }
            "PostgreSQL" {
                if ([string]::IsNullOrWhiteSpace($script:PgPass)) { $databases[$engine] = [ordered]@{ unavailable = "PostgreSQL password file not found (pass -PgPassFile)" } }
                elseif (-not (Test-Path -LiteralPath $PsqlExe)) { $databases[$engine] = [ordered]@{ unavailable = "psql.exe not found (pass -PsqlExe)" } }
                else { $databases[$engine] = Invoke-Section "PostgreSQL" { Get-PostgreSqlCapture -Site $site } }
            }
            default { $databases[$engine] = [ordered]@{ unavailable = "unknown engine for instance $($site.name)" } }
        }
    }
    return $databases
}

function Invoke-EnvironmentMode {
    param($Sites, $AppPoolMap)
    Write-Info "Capturing host, background, antivirus, repo and Acumatica facts..."
    $doc = [ordered]@{}
    $doc.host = Get-HostSection
    $doc.background = Get-BackgroundSection -AppPoolMap $AppPoolMap
    $doc.antivirus = Get-AntivirusSection
    $doc.repo = Get-RepoSection
    $doc.acumatica = Get-AcumaticaSection -Sites $Sites -AppPoolMap $AppPoolMap
    Write-Info "Capturing database servers..."
    $doc.databases = Get-DatabaseCaptures -Sites $Sites
    $doc.clientConnection = Get-ClientConnectionSummary -Sites $Sites -Databases $doc.databases -AppPoolMap $AppPoolMap
    $doc.sizes = [ordered]@{
        SQLServer = (Get-Prop (Get-Prop (Get-Prop $doc.databases "SQLServer") "files") "totalMB")
        MySQL = (Get-Prop (Get-Prop $doc.databases "MySQL") "schemaSize")
        PostgreSQL = [ordered]@{ dbSizeBytes = (Get-Prop (Get-Prop (Get-Prop $doc.databases "PostgreSQL") "version") "dbSizeBytes"); wal = (Get-Prop (Get-Prop $doc.databases "PostgreSQL") "walSize") }
    }
    $doc.highlights = Get-HighlightList -Databases $doc.databases -ClientConnection $doc.clientConnection
    $doc.volatileFields = @("capturedAtUtc", "host.uptimeSec", "host.memory", "background.topProcessesByWorkingSet", "background.scheduledTasksDue",
        "databases.SQLServer.sysInfo.committedMB", "databases.SQLServer.sysInfo.committedTargetMB", "databases.SQLServer.clientConnections",
        "databases.SQLServer.isolation.sessions", "databases.SQLServer.queryStore.current_storage_size_mb", "databases.MySQL.status",
        "databases.MySQL.clientConnections", "databases.MySQL.isolation.byThread", "databases.PostgreSQL.clientConnections",
        "databases.PostgreSQL.isolation.byBackend", "databases.PostgreSQL.walSize", "sizes")
    return $doc
}

function Test-Allowed {
    param([string]$Text)
    foreach ($pattern in $PreflightAllow) {
        if (-not [string]::IsNullOrWhiteSpace($pattern) -and $Text -match $pattern) { return $true }
    }
    return $false
}

function Invoke-PreflightMode {
    param($Sites, $AppPoolMap)
    $checks = [ordered]@{}
    $ok = $true
    $engines = @($Sites | ForEach-Object { $_.engine } | Select-Object -Unique)
    foreach ($engine in $engines) {
        $site = @($Sites | Where-Object { $_.engine -eq $engine })[0]
        $check = [ordered]@{ checked = $false; ok = $true; offenders = @(); expected = $null; note = $null }
        try {
            switch ($engine) {
                "SQLServer" {
                    $expectedLogins = @($Sites | Where-Object { $_.engine -eq "SQLServer" } | ForEach-Object { "IIS APPPOOL\" + $AppPoolMap[$_.name] })
                    $check.expected = "user sessions only from " + ($expectedLogins -join ", ") + " and this script"
                    $rows = Invoke-SqlServerRows -Sql "SELECT s.session_id AS sessionId, s.login_name AS loginName, s.program_name AS programName, s.host_name AS hostName, DB_NAME(s.database_id) AS db, s.status FROM sys.dm_exec_sessions s WHERE s.is_user_process = 1 AND s.session_id <> @@SPID"
                    $offenders = @($rows | Where-Object {
                            $login = [string](Get-Prop $_ "loginName")
                            $program = [string](Get-Prop $_ "programName")
                            -not (($expectedLogins -contains $login) -or ($program -eq $script:AppName) -or (Test-Allowed ("{0}|{1}" -f $login, $program)))
                        })
                    $check.checked = $true
                    $check.offenders = @($offenders | Group-Object -Property loginName, programName | ForEach-Object { [ordered]@{ client = $_.Name; sessions = $_.Count } })
                }
                "MySQL" {
                    if ([string]::IsNullOrWhiteSpace($script:MySqlDefaults)) { $check.note = "not checked: MySQL credentials file not found"; break }
                    $check.expected = "connections only from user acumatica, this script and system threads"
                    $rows = Invoke-MySqlJson "SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('id', ID, 'user', USER, 'host', HOST, 'db', DB, 'command', COMMAND)), JSON_ARRAY()) FROM information_schema.PROCESSLIST WHERE ID <> CONNECTION_ID()"
                    $offenders = @(@($rows) | Where-Object {
                            $user = [string](Get-Prop $_ "user")
                            $command = [string](Get-Prop $_ "command")
                            -not (($user -eq "acumatica") -or ($user -eq "event_scheduler") -or ($user -eq "system user") -or ($command -eq "Daemon") -or (Test-Allowed ("{0}|{1}" -f $user, [string](Get-Prop $_ "host"))))
                        })
                    $check.checked = $true
                    $check.offenders = @($offenders | Group-Object -Property user | ForEach-Object { [ordered]@{ client = $_.Name; sessions = $_.Count } })
                }
                "PostgreSQL" {
                    if ([string]::IsNullOrWhiteSpace($script:PgPass)) { $check.note = "not checked: PostgreSQL password file not found"; break }
                    $check.expected = "client backends only from user acumatica and this script"
                    $db = if ([string]::IsNullOrWhiteSpace([string]$site.database)) { "postgres" } else { [string]$site.database }
                    $rows = Invoke-PgJson -Database $db -Sql "SELECT COALESCE(json_agg(json_build_object('pid', pid, 'user', usename, 'application', application_name, 'db', datname, 'clientAddr', host(client_addr))), '[]'::json) FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()"
                    $offenders = @(@($rows) | Where-Object {
                            $user = [string](Get-Prop $_ "user")
                            -not (($user -eq "acumatica") -or (Test-Allowed ("{0}|{1}" -f $user, [string](Get-Prop $_ "application"))))
                        })
                    $check.checked = $true
                    $check.offenders = @($offenders | Group-Object -Property user, application | ForEach-Object { [ordered]@{ client = $_.Name; sessions = $_.Count } })
                }
            }
        }
        catch {
            $check.note = "not checked: " + (Limit-Text $_.Exception.Message 200)
            Add-CaptureError -Section "preflight.$engine" -Message $_.Exception.Message
        }
        $check.ok = (@($check.offenders).Count -eq 0)
        if (-not $check.ok) { $ok = $false }
        $checks[$engine] = $check
    }
    return [ordered]@{ ok = $ok; checks = $checks; allowPatterns = $PreflightAllow }
}

# ---- Table counts (SPEC 5.4 item 19; contract C2) ----

# Modes: "exact" (-ExactCounts), "metadata" (-MetadataOnly), "legacy" (neither). Set in Main.
$script:CountMode = "legacy"
$script:BaselineDoc = $null
$script:BaselineLoaded = $false

function Get-BaselineDocument {
    # The -BaselineFile document, parsed once. A named baseline that is missing or unreadable is an error: the residue
    # comparison it was given for cannot be made.
    if ($script:BaselineLoaded) { return $script:BaselineDoc }
    $script:BaselineLoaded = $true
    if ([string]::IsNullOrWhiteSpace($BaselineFile)) { return $null }
    if (-not (Test-Path -LiteralPath $BaselineFile)) {
        Add-CaptureError -Section "tableCounts.baseline" -Message ("baseline file not found: {0}" -f $BaselineFile)
        return $null
    }
    try {
        $script:BaselineDoc = [System.IO.File]::ReadAllText($BaselineFile) | ConvertFrom-Json
    }
    catch {
        Add-CaptureError -Section "tableCounts.baseline" -Message $_.Exception.Message
        $script:BaselineDoc = $null
    }
    return $script:BaselineDoc
}

function Get-BaselineEstimates {
    # Legacy mode only: the baseline's estimates for one engine, as a case-sensitive dictionary (or $null).
    param([string]$Engine)
    $baseline = Get-BaselineDocument
    if ($null -eq $baseline) { return $null }
    $estimates = Get-Prop (Get-Prop (Get-Prop $baseline "engines") $Engine) "estimates"
    if ($null -eq $estimates) { return $null }
    $dict = ConvertTo-OrdinalDictionary $estimates
    Write-Output -NoEnumerate $dict
}

function Get-ChangedTables {
    # Legacy mode only: tables whose estimate differs from the baseline estimate (they are then counted exactly).
    param($Estimates, $Baseline)
    $changed = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Baseline) { return , $changed.ToArray() }
    foreach ($k in @($Estimates.Keys)) {
        $key = [string]$k
        $before = $null
        if ($Baseline.ContainsKey($key)) { $before = $Baseline[$key] }
        if ([string]$before -ne [string]$Estimates[$key]) { $changed.Add($key) }
    }
    return , $changed.ToArray()
}

function Set-SoftDeletedSkipped {
    param($Entry)
    $Entry["softDeleted"] = $null
    $Entry["softDeletedNote"] = "not captured: -MetadataOnly reads no table data on any engine"
}

function Add-KeyCollisions {
    param($Entry, $Collisions)
    if ($null -ne $Collisions -and $Collisions.Count -gt 0) { $Entry["keyCollisions"] = $Collisions.ToArray() }
}

function Add-SqlServerTableCounts {
    # Every user table from sys.dm_db_partition_stats (index_id 0 = heap, 1 = clustered index, summed over partitions):
    # an exact committed row count kept as metadata, so no table is read in any mode.
    param($Site, $Entry, [string]$Mode)
    $db = if ([string]::IsNullOrWhiteSpace([string]$Site.database)) { [string]$Site.name } else { [string]$Site.database }
    $rows = Invoke-SqlServerRows -Database $db -Sql "SELECT s.name + N'.' + t.name AS tbl, SUM(p.row_count) AS cnt FROM sys.dm_db_partition_stats p JOIN sys.tables t ON t.object_id = p.object_id JOIN sys.schemas s ON s.schema_id = t.schema_id WHERE p.index_id IN (0, 1) AND t.is_ms_shipped = 0 GROUP BY s.name, t.name ORDER BY s.name, t.name"
    $pairs = New-Object System.Collections.Generic.List[object]
    foreach ($row in @($rows)) {
        if ($null -eq $row) { continue }
        $pairs.Add(@([string](Get-Prop $row "tbl"), [long](Get-Prop $row "cnt")))
    }
    if ($pairs.Count -eq 0) { throw ("no user table found in database {0}" -f $db) }
    $collisions = New-Object System.Collections.Generic.List[string]
    $map = ConvertTo-UniqueKeyMap -Pairs $pairs -Collisions $collisions
    $Entry["method"] = "sys.dm_db_partition_stats: row_count of index_id 0/1 summed over the partitions of every user table (exact committed row count kept as metadata; no table is read)"
    $Entry["tableCount"] = $map.Count
    if ($Mode -eq "exact") {
        $Entry["exactCounts"] = $map
    }
    else {
        $Entry["counts"] = $map
        $Entry["countsExact"] = $true
    }
    Add-KeyCollisions -Entry $Entry -Collisions $collisions
    if ($Mode -eq "metadata") {
        Set-SoftDeletedSkipped -Entry $Entry
    }
    else {
        $Entry["softDeleted"] = Invoke-SqlServerScalarRow -Database $db -Sql ("SELECT (SELECT COUNT(*) FROM dbo.ARRegister WHERE CompanyID = {0} AND DeletedDatabaseRecord = 1) AS ARRegister, (SELECT COUNT(*) FROM dbo.Batch WHERE CompanyID = {0} AND DeletedDatabaseRecord = 1) AS Batch, (SELECT COUNT(*) FROM dbo.SOOrder WHERE CompanyID = {0} AND DatabaseRecordStatus <> 0) AS SOOrderArchived" -f $CompanyId)
    }
}

function Get-MySqlBaseTables {
    # Every BASE TABLE of the schema, sorted ordinally. Reads the data dictionary only (no table is opened).
    param([string]$Schema)
    $names = Invoke-MySqlJson ("SELECT COALESCE(JSON_ARRAYAGG(TABLE_NAME), JSON_ARRAY()) FROM information_schema.TABLES WHERE TABLE_SCHEMA = {0} AND TABLE_TYPE = 'BASE TABLE'" -f (Get-SqlLiteral $Schema))
    $list = [string[]]@(foreach ($n in @($names)) { if ($null -ne $n) { [string]$n } })
    [Array]::Sort([Array]$list, [System.Collections.IComparer][System.StringComparer]::Ordinal)
    return , $list
}

function Invoke-MySqlExactCounts {
    # Exact COUNT(*) per table: CountBatchSize tables per statement (UNION ALL), every statement in one mysql.exe session
    # (autocommit, so each statement is its own consistent read). One JSON line per statement.
    param([string]$Schema, [string[]]$Tables)
    $dict = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $total = @($Tables).Count
    if ($total -eq 0) {
        Write-Output -NoEnumerate $dict
        return
    }
    $size = [Math]::Max(1, $CountBatchSize)
    $schemaId = Get-MySqlIdent $Schema
    $statements = New-Object System.Collections.Generic.List[string]
    for ($offset = 0; $offset -lt $total; $offset += $size) {
        $last = [Math]::Min($offset + $size, $total) - 1
        $parts = @(foreach ($i in $offset..$last) {
                "SELECT {0} AS k, COUNT(*) AS n FROM {1}.{2}" -f (Get-SqlLiteral $Tables[$i]), $schemaId, (Get-MySqlIdent $Tables[$i])
            })
        $statements.Add("SELECT JSON_ARRAYAGG(JSON_OBJECT('k', x.k, 'n', x.n)) FROM (" + ($parts -join " UNION ALL ") + ") x")
    }
    $text = Invoke-MySqlText -Sql ($statements.ToArray() -join ";`n") -TimeoutSec $CountTimeoutSec
    $results = ConvertFrom-JsonLines -Text $text -Expected $statements.Count -Tool "mysql"
    foreach ($result in $results) {
        foreach ($row in @($result)) {
            if ($null -eq $row) { continue }
            $dict[[string](Get-Prop $row "k")] = [long](Get-Prop $row "n")
        }
    }
    foreach ($t in $Tables) {
        if (-not $dict.ContainsKey($t)) { throw ("mysql returned no count for table {0}" -f $t) }
    }
    Write-Output -NoEnumerate $dict
}

function Add-MySqlTableCounts {
    param($Site, $Entry, [string]$Mode)
    if ([string]::IsNullOrWhiteSpace($script:MySqlDefaults)) { throw "MySQL credentials file not found (pass -MySqlDefaultsFile)" }
    if (-not (Test-Path -LiteralPath $MySqlExe)) { throw "mysql.exe not found (pass -MySqlExe)" }
    $schema = if ([string]::IsNullOrWhiteSpace([string]$Site.database)) { ([string]$Site.name).ToLowerInvariant() } else { [string]$Site.database }
    $schemaLit = Get-SqlLiteral $schema
    $schemaId = Get-MySqlIdent $schema
    $collisions = New-Object System.Collections.Generic.List[string]

    if ($Mode -eq "exact") {
        $tables = Get-MySqlBaseTables -Schema $schema
        if ($tables.Count -eq 0) { throw ("no BASE TABLE found in schema {0}" -f $schema) }
        $exact = Invoke-MySqlExactCounts -Schema $schema -Tables $tables
        $pairs = New-Object System.Collections.Generic.List[object]
        foreach ($t in $tables) { $pairs.Add(@($t, $exact[$t])) }
        $map = ConvertTo-UniqueKeyMap -Pairs $pairs -Collisions $collisions
        $Entry["method"] = ("COUNT(*) of every BASE TABLE of the schema (exact; reads every table), {0} tables per statement" -f [Math]::Max(1, $CountBatchSize))
        $Entry["tableCount"] = $map.Count
        $Entry["exactCounts"] = $map
    }
    elseif ($Mode -eq "metadata") {
        # Data dictionary for the table list and mysql.innodb_table_stats for the persistent statistics: no user table is
        # opened (information_schema.TABLES.TABLE_ROWS is not used, because with information_schema_stats_expiry = 0 it
        # opens every table). database_name there is case-sensitive (utf8mb3_bin) and lower-case: compare lower-cased.
        # A partitioned table has one statistics row per partition ('soorder#p#databaserecordstatuspartition0') and none
        # under its own name: rows are grouped by the lower-cased base name and n_rows summed over the partitions
        # ('p' = number of partition rows), so SOOrder, SOLine, ... get an estimate like on the other engines.
        $doc = Invoke-MySqlJson ("SELECT JSON_OBJECT('tables', (SELECT COALESCE(JSON_ARRAYAGG(TABLE_NAME), JSON_ARRAY()) FROM information_schema.TABLES WHERE TABLE_SCHEMA = {0} AND TABLE_TYPE = 'BASE TABLE'), 'stats', (SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('t', x.b, 'n', x.n, 'p', x.p)), JSON_ARRAY()) FROM (SELECT SUBSTRING_INDEX(LOWER(table_name), '#p#', 1) AS b, CAST(SUM(n_rows) AS UNSIGNED) AS n, CAST(SUM(LOCATE('#p#', LOWER(table_name)) > 0) AS UNSIGNED) AS p FROM mysql.innodb_table_stats WHERE LOWER(database_name) = LOWER({0}) GROUP BY SUBSTRING_INDEX(LOWER(table_name), '#p#', 1)) x))" -f $schemaLit)
        $stats = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        $partitionRows = [System.Collections.Generic.Dictionary[string, long]]::new([System.StringComparer]::Ordinal)
        foreach ($row in @(Get-Prop $doc "stats")) {
            if ($null -eq $row) { continue }
            $b = [string](Get-Prop $row "t")
            $stats[$b] = Get-Prop $row "n"
            $p = Get-Prop $row "p"
            if ($null -ne $p -and [long]$p -gt 0) { $partitionRows[$b] = [long]$p }
        }
        $tables = [string[]]@(foreach ($n in @(Get-Prop $doc "tables")) { if ($null -ne $n) { [string]$n } })
        [Array]::Sort([Array]$tables, [System.Collections.IComparer][System.StringComparer]::Ordinal)
        if ($tables.Count -eq 0) { throw ("no BASE TABLE found in schema {0}" -f $schema) }
        $pairs = New-Object System.Collections.Generic.List[object]
        $partitioned = New-Object System.Collections.Generic.List[string]
        $missing = 0
        foreach ($t in $tables) {
            $n = $null
            $lower = $t.ToLowerInvariant()
            if ($stats.ContainsKey($lower)) { $n = $stats[$lower] }
            if ($null -eq $n) { $missing++ } else { $n = [long]$n }
            if ($partitionRows.ContainsKey($lower)) { $partitioned.Add($t) }
            $pairs.Add(@($t, $n))
        }
        $map = ConvertTo-UniqueKeyMap -Pairs $pairs -Collisions $collisions
        $Entry["method"] = "mysql.innodb_table_stats.n_rows (persistent InnoDB statistics: an estimate; summed over the partitions of a partitioned table; no user table is opened or read)"
        $Entry["tableCount"] = $map.Count
        $Entry["counts"] = $map
        $Entry["countsExact"] = $false
        $Entry["tablesWithoutStatistics"] = $missing
        $Entry["partitionedTables"] = $partitioned.ToArray()
    }
    else {
        $est = Invoke-MySqlJson ("SET SESSION information_schema_stats_expiry = 0; SELECT COALESCE(JSON_ARRAYAGG(JSON_OBJECT('t', table_name, 'n', table_rows)), JSON_ARRAY()) FROM information_schema.tables WHERE table_schema = {0} AND table_type = 'BASE TABLE'" -f $schemaLit)
        $rows = Get-SortedByKey -Items @(@($est) | Where-Object { $null -ne $_ }) -Key { param($r) Get-Prop $r "t" }
        $pairs = New-Object System.Collections.Generic.List[object]
        foreach ($row in $rows) { $pairs.Add(@([string](Get-Prop $row "t"), (Get-Prop $row "n"))) }
        $estimates = ConvertTo-UniqueKeyMap -Pairs $pairs -Collisions $collisions
        $baseline = Get-BaselineEstimates -Engine "MySQL"
        $changed = Get-ChangedTables -Estimates $estimates -Baseline $baseline
        $keyLower = @($script:KeyTables | ForEach-Object { $_.ToLowerInvariant() })
        $toCount = [string[]]@(foreach ($row in $rows) {
                $t = [string](Get-Prop $row "t")
                if (($keyLower -contains $t.ToLowerInvariant()) -or ($changed -ccontains $t)) { $t }
            })
        $exact = Invoke-MySqlExactCounts -Schema $schema -Tables $toCount
        $exactPairs = New-Object System.Collections.Generic.List[object]
        foreach ($t in $toCount) { $exactPairs.Add(@($t, $exact[$t])) }
        $Entry["method"] = "information_schema.tables.table_rows (estimate); exact COUNT(*) for the key tables and for every table whose estimate changed against -BaselineFile"
        $Entry["estimates"] = $estimates
        $Entry["exactCounts"] = (ConvertTo-UniqueKeyMap -Pairs $exactPairs -Collisions $null)
        $Entry["exactCountsScope"] = "key tables and tables whose estimate changed against the baseline (not every table)"
        $Entry["changedVsBaseline"] = $changed
    }
    Add-KeyCollisions -Entry $Entry -Collisions $collisions
    if ($Mode -eq "metadata") {
        Set-SoftDeletedSkipped -Entry $Entry
    }
    else {
        $Entry["softDeleted"] = Invoke-MySqlJson ("SELECT JSON_OBJECT('ARRegister', (SELECT COUNT(*) FROM {0}.ARRegister WHERE CompanyID = {1} AND DeletedDatabaseRecord = 1), 'Batch', (SELECT COUNT(*) FROM {0}.Batch WHERE CompanyID = {1} AND DeletedDatabaseRecord = 1), 'SOOrderArchived', (SELECT COUNT(*) FROM {0}.SOOrder WHERE CompanyID = {1} AND DatabaseRecordStatus <> 0))" -f $schemaId, $CompanyId)
    }
}

function Get-PgCountableTables {
    # Plain tables and partitioned parents of every user schema (relkind r/p that are not partitions). Partition
    # children are skipped, so a partitioned table (Acumatica's DatabaseRecordStatus partitions of SOOrder, SOLine, ...)
    # is counted once under its own name, as on SQL Server and MySQL. Keys are quote_ident() names (schema-qualified
    # outside public), so 'distributedcache' and '"DistributedCache"' stay distinct. The result is parsed as an array of
    # fixed-key objects, never as an object keyed by table name (Windows PowerShell's ConvertFrom-Json rejects keys
    # that differ only in case). Catalog reads only. Estimate: none | reltuples | nlivetup (summed over the leaf
    # partitions for a partitioned parent).
    param([string]$Database, [string]$Estimate = "none")
    $leafSum = "(SELECT sum({0})::bigint FROM pg_partition_tree(c.oid::regclass) pt JOIN pg_class l ON l.oid = pt.relid::oid WHERE pt.isleaf)"
    $estimateSql = switch ($Estimate) {
        "reltuples" { "CASE WHEN c.relkind = 'p' THEN " + ($leafSum -f "GREATEST(l.reltuples, 0)") + " WHEN c.reltuples < 0 THEN NULL ELSE c.reltuples::bigint END" }
        "nlivetup" { "CASE WHEN c.relkind = 'p' THEN " + ($leafSum -f "COALESCE(pg_stat_get_live_tuples(l.oid), 0)") + " ELSE pg_stat_get_live_tuples(c.oid) END" }
        default { "NULL::bigint" }
    }
    $userSchema = "n.nspname <> 'information_schema' AND n.nspname NOT LIKE 'pg\_%'"
    $sql = "SELECT json_build_object('partitionChildren', (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relispartition AND c.relkind IN ('r', 'p') AND " + $userSchema + "), " +
        "'tables', (SELECT COALESCE(json_agg(json_build_object('k', CASE WHEN n.nspname = 'public' THEN quote_ident(c.relname) ELSE quote_ident(n.nspname) || '.' || quote_ident(c.relname) END, 's', n.nspname, 't', c.relname, 'p', (c.relkind = 'p'), 'e', " + $estimateSql + ")), '[]'::json) " +
        "FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition AND " + $userSchema + "))"
    $doc = Invoke-PgJson -Database $Database -Sql $sql
    $tables = Get-SortedByKey -Items @(@(Get-Prop $doc "tables") | Where-Object { $null -ne $_ }) -Key { param($r) Get-Prop $r "k" }
    return [pscustomobject]@{ Tables = $tables; PartitionChildren = [long](Get-Prop $doc "partitionChildren") }
}

function Invoke-PgExactCounts {
    # Exact count(*) per table: CountBatchSize tables per statement (UNION ALL), every statement in one psql session in
    # autocommit, so each batch is its own transaction and releases its locks (one statement over ~2.3k tables plus the
    # indexes the planner opens could exhaust the shared lock table: max_locks_per_transaction 64). Plain tables are read
    # with ONLY (no inheritance children); a partitioned parent counts all of its partitions. jsonb text is one line.
    param([string]$Database, [object[]]$Tables)
    $dict = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $total = @($Tables).Count
    if ($total -eq 0) {
        Write-Output -NoEnumerate $dict
        return
    }
    $size = [Math]::Max(1, $CountBatchSize)
    $statements = New-Object System.Collections.Generic.List[string]
    for ($offset = 0; $offset -lt $total; $offset += $size) {
        $last = [Math]::Min($offset + $size, $total) - 1
        $parts = @(foreach ($i in $offset..$last) {
                $t = $Tables[$i]
                $only = if ([bool](Get-Prop $t "p")) { "" } else { "ONLY " }
                "SELECT {0}::text AS k, count(*) AS n FROM {1}{2}.{3}" -f (Get-SqlLiteral ([string](Get-Prop $t "k"))), $only, (Get-PgIdent ([string](Get-Prop $t "s"))), (Get-PgIdent ([string](Get-Prop $t "t")))
            })
        $statements.Add("SELECT COALESCE(jsonb_agg(jsonb_build_object('k', x.k, 'n', x.n)), '[]'::jsonb) FROM (" + ($parts -join " UNION ALL ") + ") x")
    }
    $text = Invoke-PgText -Database $Database -Sql ($statements.ToArray() -join ";`n") -TimeoutSec $CountTimeoutSec
    $results = ConvertFrom-JsonLines -Text $text -Expected $statements.Count -Tool "psql"
    foreach ($result in $results) {
        foreach ($row in @($result)) {
            if ($null -eq $row) { continue }
            $dict[[string](Get-Prop $row "k")] = [long](Get-Prop $row "n")
        }
    }
    foreach ($t in $Tables) {
        $k = [string](Get-Prop $t "k")
        if (-not $dict.ContainsKey($k)) { throw ("psql returned no count for table {0}" -f $k) }
    }
    Write-Output -NoEnumerate $dict
}

function Add-PgTableCounts {
    param($Site, $Entry, [string]$Mode)
    if ([string]::IsNullOrWhiteSpace($script:PgPass)) { throw "PostgreSQL password file not found (pass -PgPassFile)" }
    if (-not (Test-Path -LiteralPath $PsqlExe)) { throw "psql.exe not found (pass -PsqlExe)" }
    $db = if ([string]::IsNullOrWhiteSpace([string]$Site.database)) { [string]$Site.name } else { [string]$Site.database }
    $estimateKind = if ($Mode -eq "exact") { "none" } elseif ($Mode -eq "metadata") { "reltuples" } else { "nlivetup" }
    $list = Get-PgCountableTables -Database $db -Estimate $estimateKind
    $tables = @($list.Tables)
    if ($tables.Count -eq 0) { throw ("no user table found in database {0}" -f $db) }
    $collisions = New-Object System.Collections.Generic.List[string]

    if ($Mode -eq "exact") {
        $exact = Invoke-PgExactCounts -Database $db -Tables $tables
        $pairs = New-Object System.Collections.Generic.List[object]
        foreach ($t in $tables) {
            $k = [string](Get-Prop $t "k")
            $pairs.Add(@($k, $exact[$k]))
        }
        $map = ConvertTo-UniqueKeyMap -Pairs $pairs -Collisions $collisions
        $Entry["method"] = ("count(*) of every plain table and partitioned parent (exact; reads every table; partition children are not listed, their rows are counted under the parent), {0} tables per statement" -f [Math]::Max(1, $CountBatchSize))
        $Entry["tableCount"] = $map.Count
        $Entry["exactCounts"] = $map
    }
    elseif ($Mode -eq "metadata") {
        $pairs = New-Object System.Collections.Generic.List[object]
        $missing = 0
        foreach ($t in $tables) {
            $e = Get-Prop $t "e"
            if ($null -eq $e) { $missing++ } else { $e = [long]$e }
            $pairs.Add(@([string](Get-Prop $t "k"), $e))
        }
        $map = ConvertTo-UniqueKeyMap -Pairs $pairs -Collisions $collisions
        $Entry["method"] = "pg_class.reltuples (planner estimate from VACUUM/ANALYZE, copied with the template database; summed over the leaf partitions for a partitioned parent; no table is read). pg_stat n_live_tup is not used: it restarts at 0 after a restore."
        $Entry["tableCount"] = $map.Count
        $Entry["counts"] = $map
        $Entry["countsExact"] = $false
        $Entry["tablesWithoutStatistics"] = $missing
    }
    else {
        $pairs = New-Object System.Collections.Generic.List[object]
        foreach ($t in $tables) { $pairs.Add(@([string](Get-Prop $t "k"), (Get-Prop $t "e"))) }
        $estimates = ConvertTo-UniqueKeyMap -Pairs $pairs -Collisions $collisions
        $baseline = Get-BaselineEstimates -Engine "PostgreSQL"
        $changed = Get-ChangedTables -Estimates $estimates -Baseline $baseline
        $keyLower = @($script:KeyTables | ForEach-Object { $_.ToLowerInvariant() })
        $toCount = @(foreach ($t in $tables) {
                $k = [string](Get-Prop $t "k")
                if (($keyLower -contains $k.ToLowerInvariant()) -or ($changed -ccontains $k)) { $t }
            })
        $exact = Invoke-PgExactCounts -Database $db -Tables $toCount
        $exactPairs = New-Object System.Collections.Generic.List[object]
        foreach ($t in $toCount) {
            $k = [string](Get-Prop $t "k")
            $exactPairs.Add(@($k, $exact[$k]))
        }
        $Entry["method"] = "pg_stat n_live_tup (estimate; summed over the leaf partitions for a partitioned parent; restarts at 0 after a restore); exact count(*) for the key tables and for every table whose estimate changed against -BaselineFile"
        $Entry["estimates"] = $estimates
        $Entry["exactCounts"] = (ConvertTo-UniqueKeyMap -Pairs $exactPairs -Collisions $null)
        $Entry["exactCountsScope"] = "key tables and tables whose estimate changed against the baseline (not every table)"
        $Entry["changedVsBaseline"] = $changed
    }
    $Entry["partitionedParents"] = [string[]]@(foreach ($t in $tables) { if ([bool](Get-Prop $t "p")) { [string](Get-Prop $t "k") } })
    $Entry["partitionChildrenSkipped"] = $list.PartitionChildren
    Add-KeyCollisions -Entry $Entry -Collisions $collisions
    if ($Mode -eq "metadata") {
        Set-SoftDeletedSkipped -Entry $Entry
    }
    else {
        $Entry["softDeleted"] = Invoke-PgJson -Database $db -Sql ("SELECT json_build_object('ARRegister', (SELECT count(*) FROM arregister WHERE companyid = {0} AND deleteddatabaserecord = true), 'Batch', (SELECT count(*) FROM batch WHERE companyid = {0} AND deleteddatabaserecord = true), 'SOOrderArchived', (SELECT count(*) FROM soorder WHERE companyid = {0} AND databaserecordstatus <> 0))" -f $CompanyId)
    }
}

function Get-ExactCountSource {
    # The exact counts of one engine entry: 'exactCounts', or 'counts' flagged exact (SQL Server's
    # sys.dm_db_partition_stats; older files without the flag are recognised by their method text). Estimates are never
    # returned, so an exact count is never compared with an estimate. Complete = the map covers every table (an exact-mode
    # file, or SQL Server counts); a legacy file's MySQL/PostgreSQL exactCounts cover some tables only.
    param($Entry, [string]$DocMode)
    if ($null -eq $Entry -or $null -ne (Get-Prop $Entry "unavailable")) { return $null }
    $exact = Get-Prop $Entry "exactCounts"
    if ($null -ne $exact) {
        return [pscustomobject]@{ Map = (ConvertTo-OrdinalDictionary $exact); Complete = ($DocMode -eq "exact") }
    }
    $counts = Get-Prop $Entry "counts"
    if ($null -eq $counts) { return $null }
    $flag = Get-Prop $Entry "countsExact"
    $isExact = if ($null -ne $flag) { [bool]$flag } else { ([string](Get-Prop $Entry "method")) -like "sys.dm_db_partition_stats*" }
    if (-not $isExact) { return $null }
    return [pscustomobject]@{ Map = (ConvertTo-OrdinalDictionary $counts); Complete = $true }
}

function Compare-TableCountsWithBaseline {
    # changedTables.<engine>: the tables whose EXACT count differs between this file and -BaselineFile (exact vs exact
    # only). comparison.<engine>: whether the engine was compared and, if not, why (engine not captured on either side,
    # unavailable, or estimates only), plus the tables present on one side only when both sides list every table.
    param($Engines, [string]$Mode)
    $out = [ordered]@{ baselineMode = $null; baselineCapturedAtUtc = $null; changedTables = [ordered]@{}; comparison = [ordered]@{} }
    if ([string]::IsNullOrWhiteSpace($BaselineFile)) { return $out }
    $baseline = Get-BaselineDocument
    $baseEngines = $null
    if ($null -ne $baseline) {
        $bm = [string](Get-Prop $baseline "mode")
        $out.baselineMode = if ([string]::IsNullOrWhiteSpace($bm)) { "legacy" } else { $bm }
        $out.baselineCapturedAtUtc = Get-Prop $baseline "capturedAtUtc"
        $baseEngines = Get-Prop $baseline "engines"
    }
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($k in @($Engines.Keys)) { $names.Add([string]$k) }
    if ($null -ne $baseEngines) {
        foreach ($p in $baseEngines.PSObject.Properties) { if (-not $names.Contains($p.Name)) { $names.Add($p.Name) } }
    }
    foreach ($engine in $names) {
        $info = [ordered]@{ compared = $false; reason = $null; scope = $null; tablesCompared = 0; tablesChanged = 0; tablesOnlyNow = @(); tablesOnlyInBaseline = @() }
        try {
            $nowEntry = if ($Engines.Contains($engine)) { $Engines[$engine] } else { $null }
            $oldEntry = if ($null -ne $baseEngines) { Get-Prop $baseEngines $engine } else { $null }
            $now = Get-ExactCountSource -Entry $nowEntry -DocMode $Mode
            $old = Get-ExactCountSource -Entry $oldEntry -DocMode ([string]$out.baselineMode)
            if ($null -eq $baseline) { $info.reason = "baseline file missing or unreadable (see errors)" }
            elseif ($null -eq $nowEntry) { $info.reason = "engine not captured in this file" }
            elseif ($null -ne (Get-Prop $nowEntry "unavailable")) { $info.reason = "engine unavailable in this file: " + [string](Get-Prop $nowEntry "unavailable") }
            elseif ($null -eq $now) { $info.reason = "this file holds estimates only for this engine; an estimate is never compared with an exact count" }
            elseif ($null -eq $oldEntry) { $info.reason = "engine not captured in the baseline" }
            elseif ($null -ne (Get-Prop $oldEntry "unavailable")) { $info.reason = "engine unavailable in the baseline: " + [string](Get-Prop $oldEntry "unavailable") }
            elseif ($null -eq $old) { $info.reason = "the baseline holds estimates only for this engine; an estimate is never compared with an exact count" }
            else {
                $both = ($now.Complete -and $old.Complete)
                $rows = New-Object System.Collections.Generic.List[object]
                $onlyNow = New-Object System.Collections.Generic.List[string]
                $onlyOld = New-Object System.Collections.Generic.List[string]
                $compared = 0
                foreach ($key in @($now.Map.Keys)) {
                    $after = $now.Map[$key]
                    if ($old.Map.ContainsKey($key)) {
                        $before = $old.Map[$key]
                        if ($null -eq $before -or $null -eq $after) { continue }
                        $compared++
                        if ([long]$after -ne [long]$before) {
                            $rows.Add([ordered]@{ table = $key; before = [long]$before; after = [long]$after; delta = ([long]$after - [long]$before) })
                        }
                    }
                    elseif ($both) { $onlyNow.Add($key) }
                }
                if ($both) {
                    foreach ($key in @($old.Map.Keys)) { if (-not $now.Map.ContainsKey($key)) { $onlyOld.Add($key) } }
                }
                $info.compared = $true
                $info.scope = if ($both) { "every table on both sides (exact vs exact)" } else { "only the tables counted exactly on both sides (a legacy capture counted some tables only)" }
                $info.tablesCompared = $compared
                $info.tablesChanged = $rows.Count
                $info.tablesOnlyNow = $onlyNow.ToArray()
                $info.tablesOnlyInBaseline = $onlyOld.ToArray()
                $out.changedTables[$engine] = $rows.ToArray()
            }
        }
        catch {
            $info.compared = $false
            $info.reason = "comparison failed: " + (Limit-Text $_.Exception.Message 200)
            Add-CaptureError -Section ("tableCounts.compare.{0}" -f $engine) -Message $_.Exception.Message
        }
        $out.comparison[$engine] = $info
    }
    return $out
}

function Invoke-TableCountsMode {
    param($Sites)
    $countMode = $script:CountMode
    $engines = [ordered]@{}
    foreach ($site in $Sites) {
        $engine = $site.engine
        if ($engines.Contains($engine)) { continue }
        $entry = [ordered]@{ instance = $site.name; database = $site.database }
        $work = [ordered]@{}
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            switch ($engine) {
                "SQLServer" { Add-SqlServerTableCounts -Site $site -Entry $work -Mode $countMode }
                "MySQL" { Add-MySqlTableCounts -Site $site -Entry $work -Mode $countMode }
                "PostgreSQL" { Add-PgTableCounts -Site $site -Entry $work -Mode $countMode }
                default { throw ("unknown engine for instance {0}" -f $site.name) }
            }
            # Only a complete result is kept: an engine is either counted or 'unavailable', never half-filled.
            foreach ($k in @($work.Keys)) { $entry[$k] = $work[$k] }
        }
        catch {
            $entry.unavailable = Limit-Text $_.Exception.Message 300
            Add-CaptureError -Section "tableCounts.$engine" -Message $_.Exception.Message
        }
        $entry.elapsedSec = [Math]::Round($watch.Elapsed.TotalSeconds, 1)
        $engines[$engine] = $entry
        $state = if ($entry.Contains("unavailable")) { "unavailable" } else { "{0} tables" -f $entry["tableCount"] }
        Write-Info ("Table counts ({0}) {1,-10} {2} in {3} s" -f $countMode, $engine, $state, $entry.elapsedSec)
    }

    $cmp = Compare-TableCountsWithBaseline -Engines $engines -Mode $countMode
    $note = switch ($countMode) {
        "exact" { "Exact row count of every base table on every engine (engines.<engine>.exactCounts). SQL Server reads sys.dm_db_partition_stats metadata; MySQL and PostgreSQL run COUNT(*) on every table, which reads the data: take this capture only where cache state does not matter. A service restart does not fully undo it: PostgreSQL's data stay in the Windows file cache (standby list), and MySQL reloads the buffer-pool pages listed in ib_buffer_pool when innodb_buffer_pool_load_at_startup is ON; only SQL Server starts cold." }
        "metadata" { "Metadata only: no table data is read on any engine (engines.<engine>.counts; countsExact says whether they are exact). Soft-deleted counts are skipped." }
        default { "Legacy capture: SQL Server exact counts; MySQL and PostgreSQL estimates plus exact counts for the key tables and the tables whose estimate changed against the baseline." }
    }
    return [ordered]@{
        mode = $countMode
        modeNote = $note
        label = $Label
        companyId = $CompanyId
        baselineFile = $BaselineFile
        baselineMode = $cmp.baselineMode
        baselineCapturedAtUtc = $cmp.baselineCapturedAtUtc
        engines = $engines
        changedTables = $cmp.changedTables
        comparison = $cmp.comparison
    }
}

function Invoke-EngineCountersMode {
    param($Sites)
    $engines = [ordered]@{}
    foreach ($site in $Sites) {
        $engine = $site.engine
        if ($engines.Contains($engine)) { continue }
        $engines[$engine] = Invoke-Section "engineCounters.$engine" {
            switch ($engine) {
                "SQLServer" {
                    Invoke-SqlServerScalarRow -Sql "SELECT (SELECT TOP 1 cntr_value FROM sys.dm_os_performance_counters WHERE counter_name = 'Batch Requests/sec' AND object_name LIKE '%SQL Statistics%') AS batchRequests, (SELECT TOP 1 cntr_value FROM sys.dm_os_performance_counters WHERE counter_name = 'SQL Compilations/sec' AND object_name LIKE '%SQL Statistics%') AS sqlCompilations, (SELECT SUM(total_spills) FROM sys.dm_exec_query_stats) AS totalSpills"
                }
                "MySQL" {
                    Invoke-MySqlJson "SELECT JSON_OBJECTAGG(VARIABLE_NAME, VARIABLE_VALUE) FROM performance_schema.global_status WHERE VARIABLE_NAME IN ('Questions','Com_select','Com_insert','Com_update','Com_delete','Sort_merge_passes','Created_tmp_disk_tables','Created_tmp_tables')"
                }
                "PostgreSQL" {
                    $db = if ([string]::IsNullOrWhiteSpace([string]$site.database)) { $site.name } else { [string]$site.database }
                    $stats = Invoke-PgJson -Database $db -Sql "SELECT json_build_object('tempFiles', temp_files, 'tempBytes', temp_bytes, 'xactCommit', xact_commit, 'xactRollback', xact_rollback) FROM pg_stat_database WHERE datname = current_database()"
                    $pgss = $null
                    try {
                        $pgss = Invoke-PgJson -Database $db -Sql "SELECT json_build_object('pgssCalls', sum(calls), 'jitFunctions', sum(jit_functions), 'jitGenerationTimeMs', sum(jit_generation_time)) FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())"
                    }
                    catch {
                        $pgss = [ordered]@{ pgssCalls = $null; note = "pg_stat_statements not loaded (E12)" }
                    }
                    $merged = [ordered]@{}
                    foreach ($p in $stats.PSObject.Properties) { $merged[$p.Name] = $p.Value }
                    if ($pgss -is [System.Collections.IDictionary]) { foreach ($k in $pgss.Keys) { $merged[$k] = $pgss[$k] } }
                    else { foreach ($p in $pgss.PSObject.Properties) { $merged[$p.Name] = $p.Value } }
                    $merged
                }
                default { throw "unknown engine" }
            }
        }
    }
    return [ordered]@{ engines = $engines }
}

#endregion

#region Main

$modeCount = @($Preflight, $TableCounts, $EngineCounters | Where-Object { $_ }).Count
if ($modeCount -gt 1) {
    throw "Use at most one of -Preflight, -TableCounts and -EngineCounters."
}
$mode = if ($Preflight) { "preflight" } elseif ($TableCounts) { "tableCounts" } elseif ($EngineCounters) { "engineCounters" } else { "environment" }
if ($SkipDatabases -and $mode -ne "environment") {
    throw "-SkipDatabases only applies to the environment capture."
}
if (($ExactCounts -or $MetadataOnly) -and -not $TableCounts) {
    throw "-ExactCounts and -MetadataOnly only apply to -TableCounts."
}
if ($ExactCounts -and $MetadataOnly) {
    throw "Use at most one of -ExactCounts and -MetadataOnly."
}
$script:CountMode = if ($ExactCounts) { "exact" } elseif ($MetadataOnly) { "metadata" } else { "legacy" }

$stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$script:CampaignFolder = $CampaignDir
if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $dir = if (-not [string]::IsNullOrWhiteSpace($OutDir)) { $OutDir } elseif (-not [string]::IsNullOrWhiteSpace($CampaignDir)) { $CampaignDir } else { Join-Path $script:RepoRoot "artifacts\benchmark-reports\environment" }
    $suffix = if ([string]::IsNullOrWhiteSpace($Label)) { $stamp } else { $Label }
    $fileName = switch ($mode) {
        "preflight" { "preflight-$suffix.json" }
        "tableCounts" { "table-counts-$suffix.json" }
        "engineCounters" { "engine-counters-$suffix.json" }
        default { "environment-$suffix.json" }
    }
    $OutFile = Join-Path $dir $fileName
}
if ([string]::IsNullOrWhiteSpace($script:CampaignFolder)) {
    $script:CampaignFolder = Split-Path -Parent $OutFile
}

# Credential files: only their presence is recorded; their content is never read by this script.
$script:MySqlDefaults = $null
$mysqlCandidate = if (-not [string]::IsNullOrWhiteSpace($MySqlDefaultsFile)) { $MySqlDefaultsFile } else { Join-Path $script:RepoRoot "Exceptions\mysql-root.cnf" }
if (Test-Path -LiteralPath $mysqlCandidate) { $script:MySqlDefaults = (Resolve-Path -LiteralPath $mysqlCandidate).Path }
$script:PgPass = $null
$pgCandidate = if (-not [string]::IsNullOrWhiteSpace($PgPassFile)) { $PgPassFile } else { Join-Path $script:RepoRoot "Exceptions\pgpass.conf" }
if (Test-Path -LiteralPath $pgCandidate) { $script:PgPass = (Resolve-Path -LiteralPath $pgCandidate).Path }

$sites = @(foreach ($instance in $Instances) { Get-SiteInfo -InstanceName $instance })
$sqlSite = @($sites | Where-Object { $_.engine -eq "SQLServer" }) | Select-Object -First 1
$script:SqlServerName = if (-not [string]::IsNullOrWhiteSpace($SqlServerInstance)) { $SqlServerInstance } elseif ($null -ne $sqlSite -and -not [string]::IsNullOrWhiteSpace([string]$sqlSite.server)) { [string]$sqlSite.server } else { "localhost" }
$appPoolMap = Get-AppPoolMap

$document = [ordered]@{
    schemaVersion = 1
    kind = $mode
    scriptVersion = $script:ScriptVersion
    capturedAtUtc = [DateTime]::UtcNow.ToString("o")
    computer = $env:COMPUTERNAME
    elevated = (Test-IsElevated)
    options = [ordered]@{
        instances = $Instances
        instanceRoot = $InstanceRoot
        skipDatabases = [bool]$SkipDatabases
        companyId = $CompanyId
        sqlServer = $script:SqlServerName
        mysqlCredentials = if ($null -ne $script:MySqlDefaults) { "defaults-extra-file present" } else { "not available" }
        postgresCredentials = if ($null -ne $script:PgPass) { "PGPASSFILE present" } else { "not available" }
    }
    sites = [ordered]@{}
}
foreach ($site in $sites) {
    $document.sites[$site.name] = [ordered]@{ engine = $site.engine; engineSource = $site.engineSource; database = $site.database; server = $site.server; appPool = $appPoolMap[$site.name] }
}

$exitCode = 0
switch ($mode) {
    "environment" {
        $body = Invoke-EnvironmentMode -Sites $sites -AppPoolMap $appPoolMap
        foreach ($k in $body.Keys) { $document[$k] = $body[$k] }
    }
    "preflight" {
        $body = Invoke-PreflightMode -Sites $sites -AppPoolMap $appPoolMap
        foreach ($k in $body.Keys) { $document[$k] = $body[$k] }
        if (-not $body.ok) { $exitCode = 2 }
    }
    "tableCounts" {
        $body = Invoke-TableCountsMode -Sites $sites
        foreach ($k in $body.Keys) { $document[$k] = $body[$k] }
    }
    "engineCounters" {
        $body = Invoke-EngineCountersMode -Sites $sites
        foreach ($k in $body.Keys) { $document[$k] = $body[$k] }
    }
}

$document.errors = $script:CaptureErrors.ToArray()
Write-JsonFileAtomic -Path $OutFile -Object $document

Write-Info ("{0} written: {1}" -f $mode, $OutFile) "Green"
if ($script:CaptureErrors.Count -gt 0) {
    Write-Info ("{0} section(s) unavailable; see 'errors' in the file." -f $script:CaptureErrors.Count) "Yellow"
}
if ($mode -eq "preflight") {
    foreach ($engine in $document.checks.Keys) {
        $c = $document.checks[$engine]
        $text = if (-not $c.checked) { "not checked (" + [string]$c.note + ")" } elseif ($c.ok) { "OK" } else { "UNEXPECTED CLIENTS: " + ((@($c.offenders) | ForEach-Object { "{0} x{1}" -f $_.client, $_.sessions }) -join "; ") }
        Write-Info ("Pre-flight {0,-10} {1}" -f $engine, $text) $(if ($c.ok) { "Green" } else { "Red" })
    }
}

exit $exitCode

#endregion
