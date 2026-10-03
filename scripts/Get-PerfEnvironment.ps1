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
                       (SPEC section 5.4 item 19). With -BaselineFile, tables whose estimate changed are
                       counted exactly and the grown tables are listed.
      -EngineCounters  Cumulative engine counters for the suite's -Diagnostics (SPEC section 5.4 item 18).

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
    [string]$BaselineFile = "",
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

$script:ScriptVersion = 1
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
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        if ($null -ne $StdIn) {
            $process.StandardInput.Write($StdIn)
        }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutSec * 1000)) {
            try { $process.Kill() } catch { }
            throw ("{0} did not finish within {1} s" -f [IO.Path]::GetFileName($FilePath), $TimeoutSec)
        }
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $outTask.Result
            StdErr = $errTask.Result
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

function Invoke-MySqlJson {
    param([Parameter(Mandatory = $true)][string]$Sql)
    if ([string]::IsNullOrWhiteSpace($script:MySqlDefaults)) { throw "MySQL credentials file not available (pass -MySqlDefaultsFile)" }
    # --defaults-extra-file must be the first option. The password stays in that file.
    $arguments = "--defaults-extra-file=`"{0}`" --batch --raw --skip-column-names --default-character-set=utf8mb4 --connect-timeout=10" -f $script:MySqlDefaults
    $r = Invoke-NativeProcess -FilePath $MySqlExe -Arguments $arguments -StdIn ($Sql.Trim().TrimEnd(';') + ";`n") -TimeoutSec 300
    if ($r.ExitCode -ne 0) {
        throw ("mysql exit code {0}: {1}" -f $r.ExitCode, (Limit-Text $r.StdErr 300))
    }
    $parsed = ConvertFrom-JsonText -Text $r.StdOut
    Write-Output -NoEnumerate $parsed
}

function Invoke-PgJson {
    param([Parameter(Mandatory = $true)][string]$Sql, [Parameter(Mandatory = $true)][string]$Database)
    if ([string]::IsNullOrWhiteSpace($script:PgPass)) { throw "PostgreSQL password file not available (pass -PgPassFile)" }
    $arguments = "-X -A -t -q -w -v ON_ERROR_STOP=1 -h {0} -p {1} -U {2} -d `"{3}`"" -f $PgHost, $PgPort, $PgUser, $Database
    $environment = @{ PGPASSFILE = $script:PgPass; PGCONNECT_TIMEOUT = "10"; PGCLIENTENCODING = "UTF8" }
    $r = Invoke-NativeProcess -FilePath $PsqlExe -Arguments $arguments -StdIn ($Sql.Trim().TrimEnd(';') + ";`n") -Environment $environment -TimeoutSec 300
    if ($r.ExitCode -ne 0) {
        throw ("psql exit code {0}: {1}" -f $r.ExitCode, (Limit-Text $r.StdErr 300))
    }
    $parsed = ConvertFrom-JsonText -Text $r.StdOut
    Write-Output -NoEnumerate $parsed
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
    $cap.status = Invoke-Section "MySQL.status" { Invoke-MySqlJson "SELECT JSON_OBJECTAGG(VARIABLE_NAME, VARIABLE_VALUE) FROM performance_schema.global_status WHERE VARIABLE_NAME IN ('Uptime','Threads_connected','Ssl_accepts','Innodb_buffer_pool_pages_total','Innodb_buffer_pool_pages_data')" }
    $cap.schemaSize = Invoke-Section "MySQL.schemaSize" { Invoke-MySqlJson ("SET SESSION information_schema_stats_expiry = 0; SELECT JSON_OBJECT('dataBytes', SUM(data_length), 'indexBytes', SUM(index_length), 'tables', COUNT(*)) FROM information_schema.tables WHERE table_schema = {0}" -f $schemaLit) }
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
        Invoke-MySqlJson ("SELECT COALESCE(JSON_OBJECTAGG(table_name, DATE_FORMAT(last_update, '%Y-%m-%dT%H:%i:%s')), JSON_OBJECT()) FROM mysql.innodb_table_stats WHERE database_name = {0} AND LOWER(table_name) IN ({1})" -f $schemaLit, (Get-KeyTableListLiteral -Lower))
    }
    $cap.dataChecks = Invoke-Section "MySQL.dataChecks" {
        Invoke-MySqlJson ("SELECT JSON_OBJECT('soOrderArchived', (SELECT COUNT(*) FROM {0}.SOOrder WHERE CompanyID = {1} AND DatabaseRecordStatus <> 0), 'arRegisterSoftDeleted', (SELECT COUNT(*) FROM {0}.ARRegister WHERE CompanyID = {1} AND DeletedDatabaseRecord = 1), 'batchSoftDeleted', (SELECT COUNT(*) FROM {0}.Batch WHERE CompanyID = {1} AND DeletedDatabaseRecord = 1))" -f $schemaId, $CompanyId)
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
        Invoke-PgJson -Database $db -Sql ("SELECT COALESCE(json_object_agg(relname, json_build_object('lastAnalyze', last_analyze, 'lastAutoanalyze', last_autoanalyze, 'lastVacuum', last_vacuum, 'lastAutovacuum', last_autovacuum, 'nLiveTup', n_live_tup)), '{{}}'::json) FROM pg_stat_user_tables WHERE lower(relname) IN ({0})" -f (Get-KeyTableListLiteral -Lower))
    }
    $cap.dataChecks = Invoke-Section "PostgreSQL.dataChecks" {
        Invoke-PgJson -Database $db -Sql ("SELECT json_build_object('soOrderArchived', (SELECT count(*) FROM soorder WHERE companyid = {0} AND databaserecordstatus <> 0), 'arRegisterSoftDeleted', (SELECT count(*) FROM arregister WHERE companyid = {0} AND deleteddatabaserecord = true), 'batchSoftDeleted', (SELECT count(*) FROM batch WHERE companyid = {0} AND deleteddatabaserecord = true))" -f $CompanyId)
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
    $doc.volatileFields = @("capturedAtUtc", "host.uptimeSec", "background.topProcessesByWorkingSet", "background.scheduledTasksDue",
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

function Get-BaselineEstimates {
    param([string]$Engine)
    if ([string]::IsNullOrWhiteSpace($BaselineFile) -or -not (Test-Path -LiteralPath $BaselineFile)) { return $null }
    try {
        $baseline = [System.IO.File]::ReadAllText($BaselineFile) | ConvertFrom-Json
        return (Get-Prop (Get-Prop (Get-Prop $baseline "engines") $Engine) "estimates")
    }
    catch {
        Add-CaptureError -Section "tableCounts.baseline" -Message $_.Exception.Message
        return $null
    }
}

function Get-ChangedTables {
    param($Estimates, $Baseline)
    $changed = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Estimates.PSObject.Properties) {
        $before = if ($null -ne $Baseline) { Get-Prop $Baseline $p.Name } else { $null }
        if ($null -ne $Baseline -and ([string]$before -ne [string]$p.Value)) { $changed.Add($p.Name) }
    }
    return , $changed.ToArray()
}

function Invoke-TableCountsMode {
    param($Sites)
    $engines = [ordered]@{}
    foreach ($site in $Sites) {
        $engine = $site.engine
        if ($engines.Contains($engine)) { continue }
        $entry = [ordered]@{ instance = $site.name; database = $site.database }
        try {
            switch ($engine) {
                "SQLServer" {
                    $db = if ([string]::IsNullOrWhiteSpace([string]$site.database)) { $site.name } else { [string]$site.database }
                    $rows = Invoke-SqlServerRows -Database $db -Sql "SELECT s.name + N'.' + t.name AS tbl, SUM(p.row_count) AS cnt FROM sys.dm_db_partition_stats p JOIN sys.tables t ON t.object_id = p.object_id JOIN sys.schemas s ON s.schema_id = t.schema_id WHERE p.index_id IN (0, 1) AND t.is_ms_shipped = 0 GROUP BY s.name, t.name ORDER BY s.name, t.name"
                    $entry.method = "sys.dm_db_partition_stats (exact for committed rows)"
                    $entry.counts = ConvertTo-NameValueMap -Rows $rows -NameField "tbl" -ValueField "cnt"
                    $entry.softDeleted = Invoke-SqlServerScalarRow -Database $db -Sql ("SELECT (SELECT COUNT(*) FROM dbo.ARRegister WHERE CompanyID = {0} AND DeletedDatabaseRecord = 1) AS ARRegister, (SELECT COUNT(*) FROM dbo.Batch WHERE CompanyID = {0} AND DeletedDatabaseRecord = 1) AS Batch, (SELECT COUNT(*) FROM dbo.SOOrder WHERE CompanyID = {0} AND DatabaseRecordStatus <> 0) AS SOOrderArchived" -f $CompanyId)
                }
                "MySQL" {
                    if ([string]::IsNullOrWhiteSpace($script:MySqlDefaults)) { throw "MySQL credentials file not found (pass -MySqlDefaultsFile)" }
                    $schema = if ([string]::IsNullOrWhiteSpace([string]$site.database)) { $site.name.ToLowerInvariant() } else { [string]$site.database }
                    $schemaLit = Get-SqlLiteral $schema
                    $schemaId = Get-MySqlIdent $schema
                    $estimates = Invoke-MySqlJson ("SET SESSION information_schema_stats_expiry = 0; SELECT COALESCE(JSON_OBJECTAGG(table_name, table_rows), JSON_OBJECT()) FROM information_schema.tables WHERE table_schema = {0} AND table_type = 'BASE TABLE'" -f $schemaLit)
                    $entry.method = "information_schema.tables.table_rows (estimate); exact COUNT(*) for the key tables and for every table whose estimate changed against -BaselineFile"
                    $entry.estimates = $estimates
                    $baseline = Get-BaselineEstimates -Engine $engine
                    $changed = Get-ChangedTables -Estimates $estimates -Baseline $baseline
                    $keyLower = @($script:KeyTables | ForEach-Object { $_.ToLowerInvariant() })
                    $toCount = @(@($estimates.PSObject.Properties | ForEach-Object { $_.Name }) | Where-Object { ($keyLower -contains $_.ToLowerInvariant()) -or ($changed -contains $_) })
                    $exact = [ordered]@{}
                    for ($offset = 0; $offset -lt $toCount.Count; $offset += 40) {
                        $chunk = @($toCount | Select-Object -Skip $offset -First 40)
                        $parts = @($chunk | ForEach-Object { "{0}, (SELECT COUNT(*) FROM {1}.{2})" -f (Get-SqlLiteral $_), $schemaId, (Get-MySqlIdent $_) })
                        $result = Invoke-MySqlJson ("SELECT JSON_OBJECT(" + ($parts -join ", ") + ")")
                        foreach ($p in $result.PSObject.Properties) { $exact[$p.Name] = $p.Value }
                    }
                    $entry.exactCounts = $exact
                    $entry.changedVsBaseline = $changed
                    $entry.softDeleted = Invoke-MySqlJson ("SELECT JSON_OBJECT('ARRegister', (SELECT COUNT(*) FROM {0}.ARRegister WHERE CompanyID = {1} AND DeletedDatabaseRecord = 1), 'Batch', (SELECT COUNT(*) FROM {0}.Batch WHERE CompanyID = {1} AND DeletedDatabaseRecord = 1), 'SOOrderArchived', (SELECT COUNT(*) FROM {0}.SOOrder WHERE CompanyID = {1} AND DatabaseRecordStatus <> 0))" -f $schemaId, $CompanyId)
                }
                "PostgreSQL" {
                    if ([string]::IsNullOrWhiteSpace($script:PgPass)) { throw "PostgreSQL password file not found (pass -PgPassFile)" }
                    $db = if ([string]::IsNullOrWhiteSpace([string]$site.database)) { $site.name } else { [string]$site.database }
                    $estimates = Invoke-PgJson -Database $db -Sql "SELECT COALESCE(json_object_agg(CASE WHEN schemaname = 'public' THEN relname ELSE schemaname || '.' || relname END, n_live_tup), '{}'::json) FROM pg_stat_user_tables"
                    $entry.method = "pg_stat_user_tables.n_live_tup (estimate); exact count(*) for the key tables and for every table whose estimate changed against -BaselineFile"
                    $entry.estimates = $estimates
                    $baseline = Get-BaselineEstimates -Engine $engine
                    $changed = Get-ChangedTables -Estimates $estimates -Baseline $baseline
                    $keyLower = @($script:KeyTables | ForEach-Object { $_.ToLowerInvariant() })
                    $toCount = @(@($estimates.PSObject.Properties | ForEach-Object { $_.Name }) | Where-Object { ($keyLower -contains $_.ToLowerInvariant()) -or ($changed -contains $_) })
                    $exact = [ordered]@{}
                    for ($offset = 0; $offset -lt $toCount.Count; $offset += 40) {
                        $chunk = @($toCount | Select-Object -Skip $offset -First 40)
                        $parts = @($chunk | ForEach-Object {
                                $ident = if ($_.Contains(".")) { ($_.Split(".", 2) | ForEach-Object { Get-PgIdent $_ }) -join "." } else { Get-PgIdent $_ }
                                "{0}, (SELECT count(*) FROM {1})" -f (Get-SqlLiteral $_), $ident
                            })
                        $result = Invoke-PgJson -Database $db -Sql ("SELECT json_build_object(" + ($parts -join ", ") + ")")
                        foreach ($p in $result.PSObject.Properties) { $exact[$p.Name] = $p.Value }
                    }
                    $entry.exactCounts = $exact
                    $entry.changedVsBaseline = $changed
                    $entry.softDeleted = Invoke-PgJson -Database $db -Sql ("SELECT json_build_object('ARRegister', (SELECT count(*) FROM arregister WHERE companyid = {0} AND deleteddatabaserecord = true), 'Batch', (SELECT count(*) FROM batch WHERE companyid = {0} AND deleteddatabaserecord = true), 'SOOrderArchived', (SELECT count(*) FROM soorder WHERE companyid = {0} AND databaserecordstatus <> 0))" -f $CompanyId)
                }
            }
        }
        catch {
            $entry.unavailable = Limit-Text $_.Exception.Message 300
            Add-CaptureError -Section "tableCounts.$engine" -Message $_.Exception.Message
        }
        $engines[$engine] = $entry
    }

    $grown = [ordered]@{}
    if (-not [string]::IsNullOrWhiteSpace($BaselineFile) -and (Test-Path -LiteralPath $BaselineFile)) {
        try {
            $baseline = [System.IO.File]::ReadAllText($BaselineFile) | ConvertFrom-Json
            foreach ($engine in @($engines.Keys)) {
                $now = $engines[$engine]
                $nowCounts = if ($now.Contains("counts")) { $now.counts } elseif ($now.Contains("exactCounts")) { $now.exactCounts } else { $null }
                $old = Get-Prop (Get-Prop $baseline "engines") $engine
                $oldCounts = Get-Prop $old "counts"
                if ($null -eq $oldCounts) { $oldCounts = Get-Prop $old "exactCounts" }
                if ($null -eq $nowCounts -or $null -eq $oldCounts) { continue }
                $list = New-Object System.Collections.Generic.List[object]
                foreach ($key in @($nowCounts.Keys)) {
                    $before = Get-Prop $oldCounts $key
                    $after = $nowCounts[$key]
                    if ($null -ne $before -and $null -ne $after -and [long]$after -ne [long]$before) {
                        $list.Add([ordered]@{ table = $key; before = [long]$before; after = [long]$after; delta = ([long]$after - [long]$before) })
                    }
                }
                $grown[$engine] = $list.ToArray()
            }
        }
        catch {
            Add-CaptureError -Section "tableCounts.compare" -Message $_.Exception.Message
        }
    }

    return [ordered]@{ label = $Label; companyId = $CompanyId; baselineFile = $BaselineFile; engines = $engines; changedTables = $grown }
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
