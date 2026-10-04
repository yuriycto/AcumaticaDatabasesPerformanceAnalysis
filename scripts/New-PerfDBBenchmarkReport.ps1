<#
.SYNOPSIS
    Builds the PerfDBBenchmark 2026 R2 report from one or more campaign JSON v2 files.

.DESCRIPTION
    Reads the campaign JSON written by scripts\Run-PerfDBBenchmarkEndpointSuite.ps1 (schema v2, SPEC section 3.9),
    builds the analysis set (6 slots per test and engine, SPEC 7.2.0), applies the comparability gate (SPEC 3.10
    layer 4), the parity rules, the winner/tie rule with practical floors (SPEC 7.2.1) and writes:

        <OutDir>\analysis.json                       cells, verdicts, families, derived values, diagnostics
        <OutDir>\PerfDBBenchmark-<CampaignId>.html   self-contained report (inline CSS and SVG, no script)
        <OutDir>\README-results.md                   the README fragments of SPEC section 7
        <OutDir>\charts\*.svg                        at-a-glance, one chart per family, scaling, speed-up

    Every threshold of the tie rule is in the $TieRule hashtable at the top of this script and is mirrored into
    analysis.json (tieRule). The statistics live only here; the in-app comparison on AC301000 is indicative only.

    Works in Windows PowerShell 5.1 and in PowerShell 7. The script itself is ASCII-only on purpose.

.PARAMETER InputJson
    One or more campaign JSON files. They are merged by CampaignId (for example Block D from a second night).
    Side files next to an input (environment-start.json, environment-end.json, decisions.json, calibration.json)
    are used when the campaign JSON does not embed them.

.PARAMETER OutDir
    Output folder. Default: the folder of the first input file.

.PARAMETER Publish
    Publication mode: exit code 2 when any test is not comparable (unless -AllowPartial), and exit code 3 when the
    campaign profile is not Full (Quick, DryRun and Smoke results are preliminary and never published).
    The outputs are always written first.

.PARAMETER AllowPartial
    With -Publish: publish even when some tests are not comparable. They are shown as n/a and listed.

.PARAMETER SelfTest
    Runs the tie-rule vectors V1-V12 of SPEC 7.2.4 (plus a few helper checks) and exits non-zero on any mismatch.
    With -InputJson as well, the report is built after the self-test passes.

.PARAMETER ChartUrlPrefix
    Prefix for chart links in README-results.md (default 'charts/'; WP9 uses 'docs/images/2026r2/').

.EXAMPLE
    .\scripts\New-PerfDBBenchmarkReport.ps1 -InputJson scripts\samples\campaign-v2-sample.json -OutDir $env:TEMP\perf-report

.EXAMPLE
    .\scripts\New-PerfDBBenchmarkReport.ps1 -SelfTest

.NOTES
    Created by AcuPower LTD (acupowererp.com) for the PerfDBBenchmark project.
    Exit codes: 0 ok; 1 self-test failure or error; 2 -Publish with a not-comparable test; 3 -Publish with a non-Full profile.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string[]]$InputJson,
    [string]$OutDir,
    [switch]$Publish,
    [switch]$AllowPartial,
    [switch]$SelfTest,
    [string]$ChartUrlPrefix = 'charts/'
)

# The suite (Run-PerfDBBenchmarkEndpointSuite.ps1 -ReportOnly, and its end-of-campaign report) runs this script in its
# own session, which uses Set-StrictMode -Version Latest. This script is written for non-strict semantics (for example
# @(...)[0] on an empty result is $null), so strict mode is switched off for this script's scope.
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

#region ---------------------------------------------------------------- tie rule (single source of every threshold)

# SPEC 7.2.1 / 3.9 analysis.json.tieRule. Change a value here and it changes everywhere (verdicts, labels, text, JSON).
$TieRule = [ordered]@{
    minGapPct              = 5       # T = max(minGapPct, cvMultiplier * max(CV_A, CV_B))
    cvMultiplier           = 2
    maxUShare              = 0.14    # tie when U > floor(maxUShare * nA * nB): 5 for 6v6, 4 for 5v6, 3 for 5v5
    slightlyFasterBelowPct = 20      # non-tie below this gap = "slightly faster"
    muchFasterRatio        = 1.5     # m_B / m_A >= this = "much faster"
    minValidSlots          = 5       # comparability gate and the n < 5 rule
    noisyCvPct             = 15      # robust CV above this marks the cell "noisy"
    gapRoundDecimals       = 6       # the gap is rounded before any threshold comparison
    cappedCellShare        = 0.5     # a cell with at least this share of +inf (Capped) values is a Capped cell
    floors                 = [ordered]@{
        'Screens'            = [ordered]@{ absMs = 100 }
        'Reports'            = [ordered]@{ absMs = 1000; relPct = 10 }
        'OrderEntry'         = [ordered]@{ absMs = 100 }
        'InvoiceRelease.U01' = [ordered]@{ absMs = 100 }
        'InvoiceRelease.U04' = [ordered]@{ relPct = 10 }
        'ManyUsers'          = [ordered]@{ relPct = 10 }
        'Core'               = [ordered]@{ relPct = 10 }
    }
    # report-level rules (they never change a pairwise verdict)
    leadTier1SharePct      = 60      # an engine leads a family when in Tier 1 on >= 60% of its comparable tests ...
    madScale               = 1.4826  # robust CV = 100 * madScale * MAD / median
    outlierLow             = 0.67    # outlier when value / cell median is outside [outlierLow, outlierHigh]
    outlierHigh            = 1.5
    positionEffectNotePct  = 3       # a sentence is added when |position effect| exceeds this
    cpuAttributionBelowPct = 30      # database share of CPU below this adds the attribution sentence
    settleTimeoutWarnPct   = 20      # settle time-outs above this share of a block are reported
}

#endregion

#region ---------------------------------------------------------------- constants

$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:PosInf = [double]::PositiveInfinity

# Non-ASCII symbols (the script stays ASCII-only so Windows PowerShell 5.1 parses it without a BOM).
$script:TIMES = [string][char]0x00D7   # multiplication sign
$script:APPROX = [string][char]0x2248  # almost equal
$script:GE = [string][char]0x2265      # greater or equal
$script:NDASH = [string][char]0x2013
$script:MDASH = [string][char]0x2014
$script:MIDDOT = [string][char]0x00B7
$script:INF = [string][char]0x221E
$script:ARROW = [string][char]0x2192

$script:EngineOrder = @('SQLServer', 'MySQL', 'PostgreSQL')
$script:EngineInfo = [ordered]@{
    'SQLServer'  = [ordered]@{ name = 'SQL Server'; color = '#0072B2'; process = 'sqlservr' }
    'MySQL'      = [ordered]@{ name = 'MySQL'; color = '#E69F00'; process = 'mysqld' }
    'PostgreSQL' = [ordered]@{ name = 'PostgreSQL'; color = '#CC79A7'; process = 'postgres' }
}

# Dry run 3f(b): the per-run engine counter divided by the run's operations. The three counters count different
# things (and include driver and session statements), so the label names no cause and compares tests within one engine.
$script:StatementCounterHead = 'Engine statement counter per operation'
$script:StatementCounterTail = '(whole run incl. warm-up, Prepare, Verify, polling): SQL Server Batch Requests, MySQL Questions, PostgreSQL pg_stat_statements calls; the counters count different things, so compare tests within one engine, not engines.'

# Family order, reader names and texts (SPEC 5.5, 7.1, 7.3). Family introductions are verbatim from SPEC 7.3.
$script:FamilyOrder = @('Screens', 'Reports', 'OrderEntry', 'ManyUsers', 'InvoiceRelease', 'Core')
$script:FamilyInfo = [ordered]@{
    'Screens'        = [ordered]@{ display = 'Everyday screens'; label = ''; chart = 'family-screens.svg'
        what = "Opening documents, looking up a customer's orders, finding who bought an item, searching customers: one person, no other load."
        why = 'This is the delay people feel all day. Small costs per request add up across every screen and every user. These numbers are the database-dependent part of opening a screen; the browser and the network add the same time on every database (dry-run step 3l shows the full API read for comparison).' }
    'Reports'        = [ordered]@{ display = 'Reports & month-end'; label = ''; chart = 'family-reports.svg'
        what = 'Sales analysis, trial balance, account drill-down on the 302,000-line ledger, and paging through or counting very large lists.'
        why = 'Month-end and management reports ask the database for the most work per click.' }
    'OrderEntry'     = [ordered]@{ display = 'Order entry (1 clerk)'; label = '(1 test)'; chart = 'family-order-entry.svg'
        what = 'Saving real 3-line sales orders through Acumatica''s full business logic.'
        why = 'The everyday write path of order desks and integrations.' }
    'ManyUsers'      = [ordered]@{ display = 'Many simultaneous users'; label = ''; chart = 'family-many-users.svg'
        what = '4, 8 and 16 clerks entering orders non-stop, with no pause between orders, spread over different products or all selling the same best-seller.'
        why = 'Shows how far each database scales on this machine and how it behaves at hot spots. Because nobody pauses, 16 clerks here load the system like a much larger real team.' }
    'InvoiceRelease' = [ordered]@{ display = 'Invoice release to GL'; label = ''; chart = 'family-invoice.svg'
        what = 'Creating, releasing and posting AR invoices, by 1 and 4 people.'
        why = 'The heaviest routine accounting write; it decides how long month-end close takes.' }
    'Core'           = [ordered]@{ display = 'Platform basics: bulk record work'; label = ''; chart = 'family-core.svg'
        what = 'Loading, saving, changing and deleting 10,000 plain records, and a multi-table list, by 1 worker and by one job shared among 8 workers.'
        why = 'The platform''s basic costs. They help explain the differences in the other families.' }
}

$script:FontStack = "system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"

#endregion

#region ---------------------------------------------------------------- generic helpers

function Get-Field {
    # Single key lookup on a dictionary or object; keys may contain dots ("probe.accent.quebec", "w3wp:PerfSQL").
    param($Obj, [string]$Key)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) {
        # Dictionary<string,object> (JavaScriptSerializer) only exposes ContainsKey; OrderedDictionary only Contains.
        # Arrays are returned unrolled (PowerShell pipeline semantics): callers wrap list values in @(...).
        $has = if ($Obj -is [System.Collections.Specialized.OrderedDictionary]) { $Obj.Contains($Key) } else { $Obj.ContainsKey($Key) }
        if ($has) { return $Obj[$Key] }
        foreach ($k in @($Obj.Keys)) { if ([string]::Equals([string]$k, $Key, [StringComparison]::OrdinalIgnoreCase)) { return $Obj[$k] } }
        return $null
    }
    if ($Obj -is [string] -or $Obj -is [ValueType]) { return $null }
    $p = $Obj.PSObject.Properties[$Key]
    if ($p) { return $p.Value }
    return $null
}

function Get-RawMember {
    # Like Get-Field but for one known key of a map; used where the exact value (arrays kept as arrays) is needed.
    param($Obj, [string]$Key)
    if ($Obj -is [System.Collections.IDictionary]) { return , $Obj[$Key] }
    return , $Obj.PSObject.Properties[$Key].Value
}

function Get-PathValue {
    # Dotted path lookup ("result.params.opsPerPass").
    param($Obj, [string]$Path)
    $cur = $Obj
    foreach ($seg in $Path.Split('.')) {
        if ($null -eq $cur) { return $null }
        $cur = Get-Field $cur $seg
    }
    return $cur
}

function Get-Keys {
    param($Obj)
    if ($null -eq $Obj) { return @() }
    if ($Obj -is [System.Collections.IDictionary]) { return @($Obj.Keys | ForEach-Object { [string]$_ }) }
    if ($Obj -is [string] -or $Obj -is [ValueType] -or $Obj -is [System.Collections.IEnumerable]) { return @() }
    return @($Obj.PSObject.Properties | ForEach-Object { $_.Name })
}

function Test-IsMap { param($Obj) return ($Obj -is [System.Collections.IDictionary]) -or ($null -ne $Obj -and $Obj -is [System.Management.Automation.PSCustomObject]) }

function Test-IsList { param($Obj) return ($null -ne $Obj) -and ($Obj -is [System.Collections.IEnumerable]) -and -not ($Obj -is [string]) -and -not (Test-IsMap $Obj) }

function ConvertTo-Num {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $null }
    if ($Value -is [string]) {
        $s = $Value.Trim()
        if ($s -match '^(?i:inf|infinity|\+inf)$') { return $script:PosInf }
        $d = 0.0
        if ([double]::TryParse($s, [Globalization.NumberStyles]::Float, $script:Inv, [ref]$d)) { return $d }
        return $null
    }
    try { return [double]$Value } catch { return $null }
}

function ConvertTo-Flag {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    if (Test-IsMap $Value) {
        foreach ($k in @('approved', 'accepted', 'value', 'enabled', 'decision')) { $v = Get-Field $Value $k; if ($null -ne $v) { return (ConvertTo-Flag $v) } }
        return $false
    }
    return ([string]$Value) -match '^(?i:true|yes|y|1|on|approved|accepted|applied)$'
}

function Test-Inf { param($Value) return ($null -ne $Value) -and [double]::IsPositiveInfinity([double]$Value) }

function Get-Round {
    param([double]$Value, [int]$Decimals)
    if ([double]::IsInfinity($Value) -or [double]::IsNaN($Value)) { return $Value }
    return [Math]::Round($Value, $Decimals, [MidpointRounding]::AwayFromZero)
}

function Read-PerfJson {
    param([string]$Path)
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $text = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8)
    return , (ConvertFrom-PerfJsonText $text)
}

function ConvertFrom-PerfJsonText {
    # Case-sensitive JSON reader (keys that differ only in case are kept apart).
    param([string]$Text)
    if ($PSVersionTable.PSVersion.Major -ge 6) { return , ($Text | ConvertFrom-Json -AsHashtable -Depth 200) }
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue
    $ser.RecursionLimit = 1000
    return , $ser.DeserializeObject($Text)
}

function ConvertTo-JsonText {
    # Deterministic JSON writer (no ConvertTo-Json depth or escaping surprises). +inf is written as "inf".
    param($Value, [int]$Depth = 0, [int]$PrettyDepth = 3)
    $nl = "`n"; $ind = '  ' * ($Depth + 1); $ind0 = '  ' * $Depth
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [string] -or $Value -is [char] -or $Value -is [guid]) { return (ConvertTo-JsonString ([string]$Value)) }
    if ($Value -is [datetime]) { return (ConvertTo-JsonString ($Value.ToUniversalTime().ToString('o'))) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [uint32] -or $Value -is [uint64]) { return ([string]$Value) }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        $d = [double]$Value
        if ([double]::IsPositiveInfinity($d)) { return '"inf"' }
        if ([double]::IsNegativeInfinity($d)) { return '"-inf"' }
        if ([double]::IsNaN($d)) { return 'null' }
        return (Get-Round $d 6).ToString('0.######', $script:Inv)
    }
    if (Test-IsMap $Value) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($k in (Get-Keys $Value)) {
            $sep = if ($Depth -lt $PrettyDepth) { ': ' } else { ':' }
            if ($Value -is [System.Collections.IDictionary]) { $item = $Value[$k] } else { $item = $Value.PSObject.Properties[$k].Value }
            $parts.Add((ConvertTo-JsonString $k) + $sep + (ConvertTo-JsonText $item ($Depth + 1) $PrettyDepth))
        }
        if ($parts.Count -eq 0) { return '{}' }
        if ($Depth -lt $PrettyDepth) { return '{' + $nl + $ind + ($parts -join (',' + $nl + $ind)) + $nl + $ind0 + '}' }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($x in $Value) { $parts.Add((ConvertTo-JsonText $x ($Depth + 1) $PrettyDepth)) }
        if ($parts.Count -eq 0) { return '[]' }
        if ($Depth -lt $PrettyDepth) { return '[' + $nl + $ind + ($parts -join (',' + $nl + $ind)) + $nl + $ind0 + ']' }
        return '[' + ($parts -join ',') + ']'
    }
    return (ConvertTo-JsonString ([string]$Value))
}

function ConvertTo-JsonString {
    param([string]$Text)
    $sb = New-Object System.Text.StringBuilder ($Text.Length + 2)
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        switch ($c) {
            34 { [void]$sb.Append('\"'); continue }
            92 { [void]$sb.Append('\\'); continue }
            10 { [void]$sb.Append('\n'); continue }
            13 { [void]$sb.Append('\r'); continue }
            9 { [void]$sb.Append('\t'); continue }
            default { if ($c -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $c)) } else { [void]$sb.Append($ch) } }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Write-Utf8File {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function ConvertTo-XmlText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&#39;')
}

function Get-EngineName { param([string]$Engine) $i = $script:EngineInfo[$Engine]; if ($i) { return $i.name }; return $Engine }

function Get-EngineColor { param([string]$Engine) $i = $script:EngineInfo[$Engine]; if ($i) { return $i.color }; return '#6B7280' }

function Resolve-Engine {
    param([string]$DbEngine, [string]$Instance)
    foreach ($s in @($DbEngine, $Instance)) {
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        $n = $s.ToLowerInvariant().Replace(' ', '')
        if ($n -match 'postgre|pgsql|npgsql' -or $n.EndsWith('pg')) { return 'PostgreSQL' }
        if ($n -match 'mysql|maria') { return 'MySQL' }
        if ($n -match 'sqlserver|mssql' -or $n -eq 'perfsql' -or $n.EndsWith('sql')) { return 'SQLServer' }
    }
    if ($DbEngine) { return $DbEngine }
    return 'Unknown'
}

function Join-EngineNames {
    param([string[]]$Engines)
    $names = @($Engines | ForEach-Object { Get-EngineName $_ })
    if ($names.Count -eq 0) { return '' }
    if ($names.Count -eq 1) { return $names[0] }
    if ($names.Count -eq 2) { return $names[0] + ' and ' + $names[1] }
    return (($names[0..($names.Count - 2)]) -join ', ') + ' and ' + $names[-1]
}

#endregion

#region ---------------------------------------------------------------- statistics

function Get-Median {
    param([double[]]$Values)
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    $s = [double[]]@($Values | Sort-Object)
    $n = $s.Count
    if ($n % 2 -eq 1) { return $s[[int](($n - 1) / 2)] }
    return ($s[[int]($n / 2) - 1] + $s[[int]($n / 2)]) / 2.0
}

function Get-FiniteValues {
    param([double[]]$Values)
    if ($null -eq $Values) { return , ([double[]]@()) }
    return , ([double[]]@($Values | Where-Object { -not [double]::IsInfinity($_) -and -not [double]::IsNaN($_) }))
}

function Get-RobustCvPct {
    # 100 * 1.4826 * MAD / median over the finite values (SPEC 7.2.1).
    param([double[]]$Values)
    $f = Get-FiniteValues $Values
    if ($f.Count -lt 2) { return 0.0 }
    $m = Get-Median $f
    if ($null -eq $m -or $m -eq 0) { return 0.0 }
    $dev = [double[]]@($f | ForEach-Object { [Math]::Abs($_ - $m) })
    $mad = Get-Median $dev
    return 100.0 * $TieRule.madScale * $mad / $m
}

function Get-UStatistic {
    # U = pairs (a, b) with a > b, plus 0.5 for each a = b (two +inf values count 0.5). a from the faster side.
    param([double[]]$Fast, [double[]]$Slow)
    $u = 0.0
    foreach ($a in $Fast) { foreach ($b in $Slow) { if ($a -gt $b) { $u += 1.0 } elseif ($a -eq $b) { $u += 0.5 } } }
    return $u
}

function Get-Binomial {
    param([int]$N, [int]$K)
    $r = 1.0
    for ($i = 1; $i -le $K; $i++) { $r = $r * ($N - $K + $i) / $i }
    return $r
}

function Get-SignTest {
    # Paired sign test per repetition (information only, SPEC 7.2.1). Pairs with equal values are dropped.
    param([object[]]$FastByRep, [object[]]$SlowByRep)
    $wins = 0; $losses = 0
    $n = [Math]::Min(@($FastByRep).Count, @($SlowByRep).Count)
    for ($i = 0; $i -lt $n; $i++) {
        $a = $FastByRep[$i]; $b = $SlowByRep[$i]
        if ($null -eq $a -or $null -eq $b) { continue }
        if ([double]$a -lt [double]$b) { $wins++ } elseif ([double]$a -gt [double]$b) { $losses++ }
    }
    $m = $wins + $losses
    $p = 1.0
    if ($m -gt 0) {
        $k = [Math]::Min($wins, $losses)
        $tail = 0.0
        for ($i = 0; $i -le $k; $i++) { $tail += (Get-Binomial $m $i) }
        $p = [Math]::Min(1.0, 2.0 * $tail / [Math]::Pow(2, $m))
    }
    return [ordered]@{ wins = $wins; of = $m; pTwoSided = (Get-Round $p 4) }
}

function Get-TimePerUnit {
    # Time per unit of work (lower is better). OpsPerMin is inverted; a Capped run is +inf (SPEC 7.2.1).
    param($HeadlineValue, [bool]$HigherIsBetter, [bool]$Capped)
    if ($Capped) { return $script:PosInf }
    $v = ConvertTo-Num $HeadlineValue
    if ($null -eq $v) { return $null }
    if ($HigherIsBetter) { if ($v -le 0) { return $script:PosInf }; return 60000.0 / $v }
    return [double]$v
}

function Get-FloorSpec {
    param([string]$Family, [int]$Users)
    switch ($Family) {
        'InvoiceRelease' { if ($Users -gt 1) { return $TieRule.floors['InvoiceRelease.U04'] } else { return $TieRule.floors['InvoiceRelease.U01'] } }
        default { if ($TieRule.floors.Contains($Family)) { return $TieRule.floors[$Family] } }
    }
    return $null
}

function Compare-PerfPair {
    <#
      Pairwise verdict between two engines (SPEC 7.2.1). A and B are time-per-unit values (finite or +inf) of the
      analysis set. Returns the faster side, the rounded gap, the threshold T, U and its maximum, the statistical
      label, the practical floor ("noticeable") and the practical label used by tiers.
    #>
    param(
        [double[]]$A, [double[]]$B,
        $Floor = $null,
        [bool]$CappedCellA = $false, [bool]$CappedCellB = $false,
        [string]$NameA = 'A', [string]$NameB = 'B'
    )
    $mA = Get-Median $A; $mB = Get-Median $B
    $swap = $false
    if ($CappedCellA -and -not $CappedCellB) { $swap = $true }
    elseif (-not ($CappedCellB -and -not $CappedCellA)) { if ($mB -lt $mA) { $swap = $true } }
    if ($swap) { $fast = $B; $slow = $A; $fName = $NameB; $sName = $NameA; $mF = $mB; $mS = $mA; $capF = $CappedCellB; $capS = $CappedCellA }
    else { $fast = $A; $slow = $B; $fName = $NameA; $sName = $NameB; $mF = $mA; $mS = $mB; $capF = $CappedCellA; $capS = $CappedCellB }

    $nF = @($fast).Count; $nS = @($slow).Count
    $cvF = Get-RobustCvPct $fast; $cvS = Get-RobustCvPct $slow
    $t = [Math]::Max($TieRule.minGapPct / 100.0, $TieRule.cvMultiplier * [Math]::Max($cvF, $cvS) / 100.0)

    if ((Test-Inf $mF) -and (Test-Inf $mS)) { $gap = 0.0 }
    elseif (Test-Inf $mS) { $gap = $script:PosInf }
    elseif ($mF -le 0) { $gap = $(if ($mS -gt 0) { $script:PosInf } else { 0.0 }) }
    else { $gap = Get-Round ($mS / $mF - 1.0) $TieRule.gapRoundDecimals }

    $u = Get-UStatistic $fast $slow
    $uMax = [Math]::Floor($TieRule.maxUShare * $nF * $nS)
    $strictWins = 0
    foreach ($xf in $fast) { foreach ($xs in $slow) { if ($xf -lt $xs) { $strictWins++ } } }

    if ($capF -and $capS) { $stat = 'tie' }
    elseif ($capS) { $stat = 'much faster' }
    elseif ($nF -lt $TieRule.minValidSlots -or $nS -lt $TieRule.minValidSlots) {
        if (((1.0 + $gap) -ge $TieRule.muchFasterRatio) -and $u -eq 0) { $stat = 'much faster' } else { $stat = 'inconclusive' }
    }
    elseif ($gap -lt $t -or $u -gt $uMax) { $stat = 'tie' }
    elseif ($gap -lt ($TieRule.slightlyFasterBelowPct / 100.0)) { $stat = 'slightly faster' }
    elseif ((1.0 + $gap) -lt $TieRule.muchFasterRatio) { $stat = 'faster' }
    else { $stat = 'much faster' }

    $absDiff = $null
    if (-not (Test-Inf $mS) -and $null -ne $mS -and $null -ne $mF) { $absDiff = $mS - $mF }
    $noticeable = $false
    if ($stat -eq 'slightly faster' -or $stat -eq 'faster' -or $stat -eq 'much faster') {
        $noticeable = $true
        if ($null -ne $Floor -and -not $capS) {
            $absMs = ConvertTo-Num (Get-Field $Floor 'absMs')
            $relPct = ConvertTo-Num (Get-Field $Floor 'relPct')
            if ($null -ne $absMs -and $null -ne $absDiff -and $absDiff -lt $absMs) { $noticeable = $false }
            if ($null -ne $relPct -and $gap -lt ($relPct / 100.0)) { $noticeable = $false }
        }
    }
    $practical = if ($stat -eq 'tie' -or $stat -eq 'inconclusive' -or -not $noticeable) { 'tie' } else { $stat }
    $label = if ($stat -ne 'tie' -and $stat -ne 'inconclusive' -and -not $noticeable) { $stat + ', not noticeable' } else { $stat }

    return [ordered]@{
        faster = $fName; slower = $sName; mFast = $mF; mSlow = $mS; nFast = $nF; nSlow = $nS
        gap = $gap; gapPct = $(if (Test-Inf $gap) { $script:PosInf } else { Get-Round (100.0 * $gap) 4 })
        thresholdPct = Get-Round (100.0 * $t) 4; cvFastPct = Get-Round $cvF 4; cvSlowPct = Get-Round $cvS 4
        u = $u; uMax = $uMax; strictWins = $strictWins; pairings = ($nF * $nS)
        statLabel = $stat; label = $label; noticeable = $noticeable; practical = $practical
        absDiffMsPerUnit = $absDiff; cappedFast = $capF; cappedSlow = $capS
    }
}

function Get-Tiers {
    <#
      Tiers from the practical verdicts (SPEC 7.2.1): Tier 1 = the fastest engine plus every engine that ties with
      it; then the fastest remaining engine plus its ties, and so on. Capped cells always form the last tier.
      $Pairs is a hashtable "E1|E2" -> pair result. Returns @{ tiers = @(@(..),..); notes = @(..) }.
    #>
    param([object[]]$Cells, [hashtable]$Pairs)
    $live = @($Cells | Where-Object { -not $_.cappedCell } | Sort-Object { $_.median })
    $capped = @($Cells | Where-Object { $_.cappedCell })
    $tiers = New-Object System.Collections.ArrayList
    $remaining = New-Object System.Collections.ArrayList
    foreach ($c in $live) { [void]$remaining.Add($c) }
    while ($remaining.Count -gt 0) {
        $leader = $remaining[0]
        $tier = @($leader.engine)
        foreach ($c in @($remaining | Select-Object -Skip 1)) {
            $p = $Pairs[$leader.engine + '|' + $c.engine]
            if ($p -and $p.practical -eq 'tie') { $tier += $c.engine }
        }
        [void]$tiers.Add($tier)
        foreach ($e in $tier) { $x = @($remaining | Where-Object { $_.engine -eq $e })[0]; [void]$remaining.Remove($x) }
    }
    if ($capped.Count -gt 0) { [void]$tiers.Add(@($capped | ForEach-Object { $_.engine })) }

    # Non-transitive verdicts (SPEC 7.2.1): an engine slower than some, but not all, engines of a higher tier, or
    # slower than another engine of its own tier (both tie with the tier's leader). Never invent a single winner.
    $notes = @()
    for ($ti = 0; $ti -lt $tiers.Count; $ti++) {
        foreach ($e in @($tiers[$ti])) {
            $above = @(); for ($tj = 0; $tj -lt $ti; $tj++) { $above += @($tiers[$tj]) }
            $same = @(@($tiers[$ti]) | Where-Object { $_ -ne $e })
            $fasterAbove = @($above | Where-Object { $p = $Pairs[$_ + '|' + $e]; $p -and $p.practical -ne 'tie' -and $p.faster -eq $_ })
            $fasterSame = @($same | Where-Object { $p = $Pairs[$_ + '|' + $e]; $p -and $p.practical -ne 'tie' -and $p.faster -eq $_ })
            if ($fasterSame.Count -gt 0 -or ($fasterAbove.Count -gt 0 -and $fasterAbove.Count -lt $above.Count)) {
                $notes += ((Get-EngineName $e) + ' is slower than ' + (Join-EngineNames @($fasterAbove + $fasterSame)) + ' only.')
            }
        }
    }
    return @{ tiers = @($tiers); notes = $notes }
}

#endregion

#region ---------------------------------------------------------------- formatting

function Format-Sig3 {
    # 3 significant digits, thousands separators, trailing zeros dropped (SPEC 7.2.3 number format).
    param($Value)
    if ($null -eq $Value) { return 'n/a' }
    $v = [double]$Value
    if ([double]::IsPositiveInfinity($v)) { return $script:INF }
    if ([double]::IsNaN($v)) { return 'n/a' }
    if ($v -eq 0) { return '0' }
    $mag = [Math]::Floor([Math]::Log10([Math]::Abs($v)))
    if ($mag -ge 2) {
        $f = [Math]::Pow(10, $mag - 2)
        $r = [Math]::Round($v / $f, 0, [MidpointRounding]::AwayFromZero) * $f
        return $r.ToString('#,0', $script:Inv)
    }
    $dec = [int](2 - $mag)
    if ($dec -gt 6) { $dec = 6 }
    $r = [Math]::Round($v, $dec, [MidpointRounding]::AwayFromZero)
    return $r.ToString('#,0.' + ('#' * $dec), $script:Inv)
}

function Format-Ratio {
    param($Ratio)
    if ($null -eq $Ratio) { return 'n/a' }
    if (Test-Inf $Ratio) { return $script:GE + ' limit' }
    return ([double]$Ratio).ToString('0.00', $script:Inv) + $script:TIMES
}

function Format-Pct {
    param($Pct)
    if ($null -eq $Pct) { return 'n/a' }
    $p = [double]$Pct
    if ([double]::IsInfinity($p)) { return $script:INF + '%' }
    if ([Math]::Abs($p) -ge 10) { return ([Math]::Round($p, 0, [MidpointRounding]::AwayFromZero)).ToString('0', $script:Inv) + '%' }
    return ([Math]::Round($p, 1, [MidpointRounding]::AwayFromZero)).ToString('0.#', $script:Inv) + '%'
}

function Get-DisplaySpec {
    <#
      How a test's values are shown to readers (SPEC 1.2 display conversion, 7.1 units):
        rate  - OpsPerMin tests: orders or invoices per minute (median of the per-run throughput)
        time  - ms or s per unit; pages are divided by params.opsPerPass; "s per ..." units and reports whose
                fastest median is >= 1 s are shown in seconds.
    #>
    param($Test, $CellList)
    $unit = [string]$Test.readerUnit
    $per = $unit -replace '^(ms|s)\s+', ''
    if ($Test.higherIsBetter) {
        $what = ($unit -replace '\s+per minute$', '')
        if (-not $what) { $what = [string]$Test.opsUnit }
        return [ordered]@{ kind = 'rate'; divisor = 1.0; unit = 'per min'; per = $unit; long = $unit; what = $what }
    }
    $divisor = 1.0
    if ([string]$Test.opsUnit -eq 'pages') {
        $ops = $null
        foreach ($c in @($CellList)) { if ($c.opsPerPass) { $ops = [double]$c.opsPerPass; break } }
        if (-not $ops) { $ops = ConvertTo-Num $Test.defaultOpsPerPass }
        if (-not $ops -or $ops -le 0) { $ops = 80.0 }
        $divisor = $ops
        if ($unit -notmatch 'page') { $per = 'per list page' }
    }
    $seconds = $unit -match '^s\s'
    if (-not $seconds -and $divisor -eq 1.0) {
        $fin = @($CellList | Where-Object { $null -ne $_.median -and -not (Test-Inf $_.median) } | ForEach-Object { [double]$_.median })
        if ($fin.Count -gt 0 -and ([double]($fin | Measure-Object -Minimum).Minimum) -ge 1000) { $seconds = $true }
    }
    if ($seconds) { return [ordered]@{ kind = 'time'; divisor = $divisor * 1000.0; unit = 's'; per = $per; long = 's ' + $per; what = '' } }
    return [ordered]@{ kind = 'time'; divisor = $divisor; unit = 'ms'; per = $per; long = 'ms ' + $per; what = '' }
}

function Format-TimeValue {
    # A time-per-unit value (ms) in the display unit, for example "41.2 ms" or "1.9 s".
    param($Ms, $Spec, [switch]$NoUnit)
    if ($null -eq $Ms) { return 'n/a' }
    if (Test-Inf $Ms) { return 'over the time limit' }
    $v = [double]$Ms / [double]$Spec.divisor
    if ($NoUnit) { return (Format-Sig3 $v) }
    return (Format-Sig3 $v) + ' ' + $Spec.unit
}

function Format-CellMedian {
    # The cell's median in reader units (rate tests show the median throughput).
    param($Cell, $Spec, [switch]$NoUnit)
    if ($null -eq $Cell) { return 'n/a' }
    if ($Cell.cappedCell) { return 'over the time limit' }
    if ($Spec.kind -eq 'rate') {
        if ($null -eq $Cell.medianHeadline) { return 'n/a' }
        if ($NoUnit) { return (Format-Sig3 $Cell.medianHeadline) }
        return (Format-Sig3 $Cell.medianHeadline) + ' ' + $Spec.what + '/min'
    }
    return (Format-TimeValue $Cell.median $Spec -NoUnit:$NoUnit)
}

function Format-CellRange {
    param($Cell, $Spec)
    if ($null -eq $Cell -or $Cell.nValid -eq 0) { return 'n/a' }
    $med = Format-CellMedian $Cell $Spec -NoUnit
    if ($Spec.kind -eq 'rate') {
        $lo = Format-Sig3 $Cell.minHeadline; $hi = Format-Sig3 $Cell.maxHeadline
        $s = $med + ' (' + $lo + $script:NDASH + $hi + ')'
    }
    elseif ($Cell.cappedCell) {
        $s = $Cell.cappedText
    }
    else {
        $lo = Format-TimeValue $Cell.min $Spec -NoUnit; $hi = Format-TimeValue $Cell.max $Spec -NoUnit
        $s = $med + ' (' + $lo + $script:NDASH + $hi + ')'
    }
    if ($Cell.cappedRuns -gt 0 -and -not $Cell.cappedCell) { $s += '; ' + $Cell.cappedRuns + ' run(s) over the time limit' }
    if ($Cell.nValid -lt $Cell.nSlots) { $s += ', n = ' + $Cell.nValid }
    if ($Cell.noisy) { $s += ', noisy' }
    return $s
}

#endregion

#region ---------------------------------------------------------------- input loading and merging

function Get-SideFile {
    param([string[]]$Dirs, [string]$Name)
    foreach ($d in $Dirs) {
        $p = Join-Path $d $Name
        if (Test-Path -LiteralPath $p) { try { return , (Read-PerfJson $p) } catch { Write-Warning ("Could not read {0}: {1}" -f $p, $_.Exception.Message) } }
    }
    return $null
}

function Add-EnvShapeAliases {
    # WP7 integration: the real producers name things differently from the sample fixture this report was written
    # against. Get-PerfEnvironment.ps1 (WP5) writes databases.<Engine>, host.cpu/os/power, antivirus.bitdefender* and
    # acumatica.instances.<i>.driverVersions; ENV_CAPTURE (WP1) writes dataFingerprint.values["count.<Table>"].
    # Add the keys this report reads, only when they are missing, so fixture-shaped input is unchanged.
    param($Doc, [switch]$EnvCapture)
    if (-not ($Doc -is [System.Collections.IDictionary])) { return }
    if ($EnvCapture) {
        $fp = Get-Field $Doc 'dataFingerprint'
        $values = Get-Field $fp 'values'
        if ($fp -is [System.Collections.IDictionary] -and (Test-IsMap $values) -and $null -eq (Get-Field $fp 'counts')) {
            $counts = [ordered]@{}
            foreach ($k in (Get-Keys $values)) { if ($k -like 'count.*') { $counts[$k.Substring(6)] = Get-Field $values $k } }
            if ($counts.Count) { $fp['counts'] = $counts }
        }
        return
    }
    $dbs = Get-Field $Doc 'databases'
    if ($dbs -is [System.Collections.IDictionary]) {
        foreach ($pair in @(@('SQLServer', 'sqlServer'), @('MySQL', 'mySql'), @('PostgreSQL', 'postgreSql'))) {
            $cap = Get-Field $dbs $pair[0]
            if (-not ($cap -is [System.Collections.IDictionary])) { continue }
            $mb = $null
            switch ($pair[0]) {
                'SQLServer' {
                    $mb = ConvertTo-Num (Get-PathValue $cap 'files.totalMB')
                    $qs = Get-PathValue $cap 'queryStore.actual_state_desc'
                    if ($qs -and $null -eq (Get-Field $cap 'query_store')) { $cap['query_store'] = $qs }
                }
                'MySQL' {
                    $a = ConvertTo-Num (Get-PathValue $cap 'schemaSize.dataBytes'); $b = ConvertTo-Num (Get-PathValue $cap 'schemaSize.indexBytes')
                    if ($null -ne $a -and $null -ne $b) { $mb = ($a + $b) / 1MB }
                }
                'PostgreSQL' { $a = ConvertTo-Num (Get-PathValue $cap 'version.dbSizeBytes'); if ($null -ne $a) { $mb = $a / 1MB } }
            }
            if ($null -ne $mb -and $null -eq (Get-Field $cap 'databaseSizeMb')) { $cap['databaseSizeMb'] = [Math]::Round($mb, 0) }
            if ($null -eq (Get-Field $Doc $pair[1])) { $Doc[$pair[1]] = $cap }
        }
    }
    if ($null -eq (Get-Field $Doc 'drivers')) {
        $insts = Get-PathValue $Doc 'acumatica.instances'
        $dv = $null
        foreach ($k in (Get-Keys $insts)) { $dv = Get-Field (Get-Field $insts $k) 'driverVersions'; if (Test-IsMap $dv) { break } }
        if (Test-IsMap $dv) {
            $drv = [ordered]@{}
            $v = Get-Field $dv 'Microsoft.Data.SqlClient.dll'; if ($v) { $drv['sqlServer'] = 'Microsoft.Data.SqlClient ' + $v }
            $v = Get-Field $dv 'MySqlConnector.dll'; if ($v) { $drv['mySql'] = 'MySqlConnector ' + $v }
            $v = Get-Field $dv 'Npgsql.dll'; if ($v) { $drv['postgreSql'] = 'Npgsql ' + $v }
            if ($drv.Count) { $Doc['drivers'] = $drv }
        }
    }
    $h = Get-Field $Doc 'host'
    if ($h -is [System.Collections.IDictionary]) {
        if ($null -eq (Get-Field $h 'cpuName')) { $v = Get-PathValue $h 'cpu.name'; if ($v) { $h['cpuName'] = $v } }
        if ($null -eq (Get-Field $h 'logicalCpus')) { $v = Get-PathValue $h 'cpu.logicalProcessors'; if ($null -ne $v) { $h['logicalCpus'] = $v } }
        if ($null -eq (Get-Field $h 'powerScheme')) { $v = Get-PathValue $h 'power.activeSchemeName'; if ($v) { $h['powerScheme'] = $v } }
        if ($null -eq (Get-Field $h 'osCaption')) { $v = Get-PathValue $h 'os.caption'; if ($v) { $h['osCaption'] = ([string]$v + ' ' + [string](Get-PathValue $h 'os.version')).Trim() } }
    }
    $av = Get-Field $Doc 'antivirus'
    if ($av -is [System.Collections.IDictionary] -and $null -eq (Get-Field $av 'exclusions')) {
        $v = Get-Field $av 'bitdefenderExclusionsManual'; if ($v) { $av['exclusions'] = $v }
    }
}

function Import-Campaign {
    param([string[]]$Paths)
    $docs = @()
    foreach ($p in $Paths) {
        if (-not (Test-Path -LiteralPath $p)) { throw "Input file not found: $p" }
        $d = Read-PerfJson $p
        $sv = ConvertTo-Num (Get-Field $d 'schemaVersion')
        if ($sv -ne 2) { Write-Warning ("{0}: schemaVersion is {1}, expected 2." -f $p, $sv) }
        $docs += , $d
    }
    $dirs = @($Paths | ForEach-Object { Split-Path -Parent ((Resolve-Path -LiteralPath $_).ProviderPath) } | Select-Object -Unique)

    $warnings = New-Object System.Collections.ArrayList
    $campaigns = @(); $runs = New-Object System.Collections.ArrayList; $events = New-Object System.Collections.ArrayList
    $tests = [ordered]@{}; $instances = [ordered]@{}; $envCaptures = New-Object System.Collections.ArrayList
    $starts = @(); $ends = @(); $diag = [ordered]@{}; $seen = @{}; $tableCounts = New-Object System.Collections.ArrayList; $tcSeen = @{}; $dryRun = $null
    foreach ($d in $docs) {
        $c = Get-Field $d 'campaign'
        if ($c) { $campaigns += , $c }
        foreach ($r in @(Get-Field $d 'runs')) {
            if ($null -eq $r) { continue }
            $rid = [string](Get-Field $r 'requestId')
            $key = if ($rid) { $rid + '|' + (Get-Field $r 'instance') + '|' + (Get-Field $r 'testCode') } else { [guid]::NewGuid().ToString() }
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            [void]$runs.Add($r)
        }
        foreach ($e in @(Get-Field $d 'events')) {
            if (-not $e) { continue }
            $ek = 'event|' + (Get-Field $e 'atUtc') + '|' + (Get-Field $e 'kind') + '|' + (Get-Field $e 'instance') + '|' + (Get-Field $e 'detail')
            if ($seen.ContainsKey($ek)) { continue }   # the same event can appear in two files of one campaign
            $seen[$ek] = $true
            [void]$events.Add($e)
        }
        foreach ($t in @(Get-Field $d 'tests')) {
            if ($null -eq $t) { continue }
            $code = [string](Get-Field $t 'TestCode')
            if (-not $code) { continue }
            if ($tests.Contains($code)) {
                $v1 = Get-Field $tests[$code] 'ScenarioVersion'; $v2 = Get-Field $t 'ScenarioVersion'
                if ($null -ne $v1 -and $null -ne $v2 -and [string]$v1 -ne [string]$v2) { [void]$warnings.Add("Catalog rows for $code differ in ScenarioVersion ($v1 vs $v2); the first is used.") }
                continue
            }
            $tests[$code] = $t
        }
        foreach ($i in @(Get-Field $d 'instances')) { if ($i) { $n = [string](Get-Field $i 'name'); if ($n -and -not $instances.Contains($n)) { $instances[$n] = $i } } }
        $env = Get-Field $d 'environment'
        if ($env) {
            $s = Get-Field $env 'start'; if ($s) { $starts += , $s }
            $en = Get-Field $env 'end'; if ($en) { $ends += , $en }
            foreach ($ec in @(Get-Field $env 'envCaptures')) { if ($ec) { [void]$envCaptures.Add($ec) } }
            # table counts embedded by the suite (environment.tableCounts: file name -> compact capture)
            $tcs = Get-Field $env 'tableCounts'
            foreach ($name in (Get-Keys $tcs)) {
                if ($tcSeen.ContainsKey($name)) { continue }
                $tcSeen[$name] = $true
                $entry = Get-Field $tcs $name
                if (Test-IsMap $entry) { $entry['source'] = $name; [void]$tableCounts.Add($entry) }
            }
        }
        $dg = Get-Field $d 'diagnostics'
        if ($dg) { foreach ($k in (Get-Keys $dg)) { $diag[$k] = Get-Field $dg $k } }
        if ($c) { $cd = Get-Field $c 'diagnostics'; if ($cd) { foreach ($k in (Get-Keys $cd)) { $diag[$k] = Get-Field $cd $k } } }
        # dryrun-diagnostics.json names the dry run (dryRun.folder, dryRun.dryCampaignId): where the API-read probe is
        $dr = Get-Field $d 'dryRun'
        if ($null -eq $dryRun -and (Test-IsMap $dr)) { $dryRun = $dr }
    }
    if ($campaigns.Count -eq 0) { throw 'No campaign object found in the input JSON.' }
    if ($starts.Count -eq 0) { $s = Get-SideFile $dirs 'environment-start.json'; if ($s) { $starts += , $s } }
    if ($ends.Count -eq 0) { $s = Get-SideFile $dirs 'environment-end.json'; if ($s) { $ends += , $s } }
    foreach ($s in @($starts) + @($ends)) { Add-EnvShapeAliases $s }
    foreach ($ec in $envCaptures) { Add-EnvShapeAliases (Get-Field $ec 'env') -EnvCapture }
    $decisions = Get-SideFile $dirs 'decisions.json'
    $calibration = Get-SideFile $dirs 'calibration.json'
    # Run-Campaign's state (sqlLogChain: the SQL Server log chain checked live before the campaign; throttleReadings: a
    # summary of the E14 licence-telemetry gates) and the full records of those gates (throttle-readings.json)
    $runCampaignState = Get-SideFile $dirs 'run-campaign-state.json'
    $throttleReadings = Get-SideFile $dirs 'throttle-readings.json'
    # Contract C4: diagnostics.apiReadProbe (never published). Run-Campaign passes only the campaign JSON and
    # dryrun-diagnostics.json, and the dry run keeps the probe out of dryrun-diagnostics.json (3l writes it to
    # dryrun\3l-api-read-probe.json), so it is loaded here at run time. Get-Diagnostics never copies this key.
    if (-not $diag.Contains('apiReadProbe')) {
        $arm = $(if ($diag.Contains('apiReadMs')) { $diag['apiReadMs'] } else { $null })
        $probe = Find-ApiReadProbe -Dirs $dirs -DryRun $dryRun -ApiReadMs $arm
        if ($null -ne $probe) { $diag['apiReadProbe'] = $probe }
    }
    # table-counts-<label>.json written by Get-PerfEnvironment -TableCounts next to an input (SPEC 5.4 item 19, 6.6 3n).
    # The full file replaces the suite's compact embedded copy of the same name: the campaign residue (contract C2)
    # needs its per-engine exact counts.
    foreach ($dir in $dirs) {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'table-counts-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $at = -1
            if ($tcSeen.ContainsKey($f.Name)) {
                for ($j = 0; $j -lt $tableCounts.Count; $j++) { if ([string](Get-Field $tableCounts[$j] 'source') -eq $f.Name -and -not (Test-IsMap (Get-Field $tableCounts[$j] 'engines'))) { $at = $j; break } }
                if ($at -lt 0) { continue }
            }
            $tcSeen[$f.Name] = $true
            try {
                $doc = Read-PerfJson $f.FullName
                if (Test-IsMap $doc) { $doc['source'] = $f.Name; if ($at -ge 0) { $tableCounts[$at] = $doc } else { [void]$tableCounts.Add($doc) } }
            }
            catch { Write-Warning ("Could not read {0}: {1}" -f $f.FullName, $_.Exception.Message) }
        }
    }

    $ids = @($campaigns | ForEach-Object { [string](Get-Field $_ 'id') } | Where-Object { $_ } | Select-Object -Unique)
    $meta = $campaigns[0]
    return [ordered]@{
        meta = $meta; campaignIds = $ids; runs = $runs; events = $events; tests = $tests; instances = $instances
        start = $(if ($starts.Count) { $starts[0] } else { $null }); end = $(if ($ends.Count) { $ends[-1] } else { $null })
        envCaptures = $envCaptures; diagnosticsIn = $diag; decisions = $decisions; calibration = $calibration
        tableCounts = $tableCounts; warnings = $warnings; inputDirs = $dirs; runCampaignState = $runCampaignState
        throttleReadings = $throttleReadings
    }
}

function Find-ApiReadProbe {
    # Contract C4: the API-read probe of the dry run's 3d campaign (diagnostics.apiReadProbe), runtime only: the report
    # uses its endpoint versions, engines and exception types, never its messages, and never writes it out. Looked up
    # in the dry-run folder named by dryrun-diagnostics.json (dryRun.folder), then in <input folder>\dryrun:
    #  - 3l-api-read-probe.json (Invoke-PerfDryRun 3l: chosenEndpoint and tried[]);
    #  - the 3d campaign JSON <folder>\<id>\PerfDBBenchmark-<id>.json, whose probe also has measureErrors, notes,
    #    warmUp, count and failure. It is read only when the 3l file is missing or when an engine has no timed call
    #    or failed calls (diagnostics.apiReadMs), because only then are those fields needed.
    # A probe of another dry-run campaign, or one whose chosen endpoint is not the measured one, is not used.
    param([string[]]$Dirs, $DryRun, $ApiReadMs)
    $folders = @()
    $f = [string](Get-Field $DryRun 'folder')
    if ($f -and (Test-Path -LiteralPath $f -PathType Container)) { $folders += (Resolve-Path -LiteralPath $f).ProviderPath }
    foreach ($d in @($Dirs)) {
        $p = Join-Path $d 'dryrun'
        if ((Test-Path -LiteralPath $p -PathType Container) -and $folders -notcontains $p) { $folders += $p }
    }
    $wantId = [string](Get-Field $DryRun 'dryCampaignId')
    $measured = @()
    $needFull = $true
    if (Test-IsMap $ApiReadMs) {
        $vals = @((Get-Keys $ApiReadMs) | ForEach-Object { Get-Field $ApiReadMs $_ } | Where-Object { Test-IsMap $_ })
        $measured = @($vals | ForEach-Object { [string](Get-Field $_ 'endpoint') } | Where-Object { $_ } | Select-Object -Unique)
        $needFull = @($vals | Where-Object { (0 + (ConvertTo-Num (Get-Field $_ 'n'))) -lt 1 -or (0 + (ConvertTo-Num (Get-Field $_ 'errors'))) -gt 0 }).Count -gt 0
    }
    foreach ($folder in $folders) {
        $probe = $null
        $p3l = Join-Path $folder '3l-api-read-probe.json'
        if (Test-Path -LiteralPath $p3l) {
            try { $probe = Read-PerfJson $p3l } catch { Write-Warning ("Could not read {0}: {1}" -f $p3l, $_.Exception.Message) }
            $fileId = [string](Get-Field $probe 'dryCampaignId')
            if ($wantId -and $fileId -and $fileId -ne $wantId) { Write-Warning ("{0} belongs to dry-run campaign {1}, not {2}: not used." -f $p3l, $fileId, $wantId); $probe = $null }
        }
        $id = $wantId
        if (-not $id) { $id = [string](Get-Field $probe 'dryCampaignId') }
        if (($needFull -or -not (Test-IsMap $probe)) -and $id) {
            $full = Join-Path (Join-Path $folder $id) ('PerfDBBenchmark-' + $id + '.json')
            if (Test-Path -LiteralPath $full) {
                try { $doc = Read-PerfJson $full; $fp = Get-PathValue $doc 'diagnostics.apiReadProbe'; if (Test-IsMap $fp) { $probe = $fp } }
                catch { Write-Warning ("Could not read the API-read probe from {0}: {1}" -f $full, $_.Exception.Message) }
                $doc = $null
            }
        }
        if (-not (Test-IsMap $probe)) { continue }
        $chosen = [string](Get-Field $probe 'chosenEndpoint')
        if ($chosen -and $measured.Count -and ($measured.Count -gt 1 -or $measured[0] -ne $chosen)) {
            Write-Warning ("The API-read probe in {0} chose {1}, but diagnostics.apiReadMs was measured on {2}: the probe is not used." -f $folder, $chosen, ($measured -join ', '))
            continue
        }
        return , $probe
    }
    return $null
}

function New-TestModel {
    param($Row, [string]$Code)
    $users = [int](ConvertTo-Num (Get-Field $Row 'UserCount')); if ($users -lt 1) { $users = 1 }
    $family = [string](Get-Field $Row 'Family')
    $kind = [string](Get-Field $Row 'HeadlineKind')
    $hib = Get-Field $Row 'HigherIsBetter'
    $higher = if ($null -ne $hib) { ConvertTo-Flag $hib } else { $kind -eq 'OpsPerMin' }
    # ErrorsInvalidate is not a catalog field: false for the multi-user ORD and INV codes, true for every other code (SPEC 0.3 #18).
    $ei = Get-Field $Row 'ErrorsInvalidate'
    $errorsInvalidate = if ($null -ne $ei) { ConvertTo-Flag $ei } else { -not ($users -gt 1 -and ($family -eq 'ManyUsers' -or $family -eq 'InvoiceRelease')) }
    $pe = Get-Field $Row 'ParityExpected'
    return [pscustomobject]@{
        code = $Code; displayName = [string](Get-Field $Row 'DisplayName'); family = $family; block = [string](Get-Field $Row 'RunBlock')
        sortOrder = [int](ConvertTo-Num (Get-Field $Row 'SortOrder')); shortLabel = [string](Get-Field $Row 'ShortLabel'); category = [string](Get-Field $Row 'Category')
        users = $users; headlineKind = $kind; higherIsBetter = [bool]$higher; readerUnit = [string](Get-Field $Row 'ReaderUnit'); opsUnit = [string](Get-Field $Row 'OpsUnit')
        parityExpected = $(if ($null -ne $pe) { ConvertTo-Flag $pe } else { $true }); errorsInvalidate = [bool]$errorsInvalidate
        excludeFromComparison = (ConvertTo-Flag (Get-Field $Row 'ExcludeFromComparison')) -or $family -eq 'Environment' -or $kind -eq 'None'
        isDestructive = ConvertTo-Flag (Get-Field $Row 'IsDestructive'); isOptional = ConvertTo-Flag (Get-Field $Row 'IsOptional')
        question = [string](Get-Field $Row 'Question'); what = [string](Get-Field $Row 'WhatItSimulates'); why = [string](Get-Field $Row 'WhyItMatters')
        defaultOpsPerPass = ConvertTo-Num (Get-Field $Row 'DefaultOpsPerPass'); defaultPasses = ConvertTo-Num (Get-Field $Row 'DefaultPasses')
        defaultWarmUpPasses = ConvertTo-Num (Get-Field $Row 'DefaultWarmUpPasses'); scenarioVersion = Get-Field $Row 'ScenarioVersion'
        legacy = Get-Field $Row 'LegacyTestCode'
    }
}

function New-RunModel {
    param($Raw, [hashtable]$InstanceEngines)
    $instance = [string](Get-Field $Raw 'instance')
    $engine = Resolve-Engine ([string](Get-Field $Raw 'dbEngine')) $instance
    if ($InstanceEngines.ContainsKey($instance)) { $engine = $InstanceEngines[$instance] }
    $slot = Get-Field $Raw 'slot'
    $role = [string](Get-Field $slot 'role')
    $isRerun = ConvertTo-Flag (Get-Field $Raw 'isRerun')
    if (-not $role) { $role = if ($isRerun) { 'rerun' } else { 'original' } }
    $result = Get-Field $Raw 'result'
    if ($null -eq $result) {
        # The suite keeps the raw ResultJson when Windows PowerShell 5.1 could not parse it (resultJsonRaw).
        $rawText = Get-Field $Raw 'resultJsonRaw'
        if ($rawText -is [string] -and $rawText.Trim().StartsWith('{')) { try { $result = ConvertFrom-PerfJsonText $rawText } catch { $result = $null } }
    }
    $params = Get-Field $result 'params'
    $settle = Get-Field $Raw 'settle'
    $capped = Get-Field $result 'capped'
    $status = [string](Get-Field $Raw 'status')
    $rep = ConvertTo-Num (Get-Field $Raw 'repetitionNo'); if ($null -eq $rep) { $rep = ConvertTo-Num (Get-Field $slot 'repetitionNo') }
    return [pscustomobject]@{
        raw = $Raw; campaignId = [string](Get-Field $Raw 'campaignId'); block = [string](Get-Field $Raw 'block')
        rep = $(if ($null -ne $rep) { [int]$rep } else { -1 }); isWarmup = ConvertTo-Flag (Get-Field $Raw 'isWarmup')
        pos = ConvertTo-Num (Get-Field $Raw 'orderPosition'); instance = $instance; engine = $engine
        testCode = [string](Get-Field $Raw 'testCode'); family = [string](Get-Field $Raw 'family')
        status = $status; invalidReason = [string](Get-Field $Raw 'invalidReason'); requestId = [string](Get-Field $Raw 'requestId')
        startedAtUtc = [string](Get-Field $Raw 'startedAtUtc')
        valid = ($status -eq 'Completed' -or $status -eq 'Capped'); capped = ($status -eq 'Capped')
        headlineValue = ConvertTo-Num (Get-Field $Raw 'headlineValue')
        p95Ms = ConvertTo-Num (Get-Field $Raw 'p95Ms'); opsCount = ConvertTo-Num (Get-Field $Raw 'opsCount')
        errors = [int](ConvertTo-Num (Get-Field $Raw 'errorCount')); deadlocks = [int](ConvertTo-Num (Get-Field $Raw 'deadlockCount'))
        retries = [int](ConvertTo-Num (Get-Field $Raw 'retryCount')); lockViolations = [int](ConvertTo-Num (Get-Field $Raw 'lockViolationCount'))
        timeouts = [int](ConvertTo-Num (Get-Field $Raw 'timeoutCount'))
        rows = ConvertTo-Num (Get-Field $Raw 'rowsReturned'); checksum = [string](Get-Field $Raw 'checksum')
        paramsHash = [string](Get-Field $Raw 'paramsHash'); methodology = [string](Get-Field $Raw 'methodologyVersion'); dll = [string](Get-Field $Raw 'dllSha256')
        role = $role; rerunRound = [int](ConvertTo-Num (Get-Field $slot 'rerunRound')); isRerun = $isRerun -or $role -eq 'rerun'
        suiteUsed = Get-Field $slot 'usedInAnalysis'
        superseded = [bool](Get-Field $Raw 'supersededBy') -or [bool](Get-Field $Raw 'supersedeReason')
        stuck = ConvertTo-Flag (Get-Field $Raw 'stuck')
        settleTimedOut = ConvertTo-Flag (Get-Field $settle 'timedOut'); perfAvgPct = ConvertTo-Num (Get-Field $settle 'perfAvgPct'); tempC = ConvertTo-Num (Get-Field $settle 'tempC')
        procCounters = Get-Field $Raw 'procCounters'; diagnostics = Get-Field $Raw 'diagnostics'
        result = $result; params = $params; opsPerPass = ConvertTo-Num (Get-Field $params 'opsPerPass')
        capKind = [string](Get-Field $capped 'kind'); capLimitMs = ConvertTo-Num (Get-Field $capped 'limitMs')
        operationCapMs = ConvertTo-Num (Get-Field $params 'operationCapMs')
    }
}

#endregion

#region ---------------------------------------------------------------- analysis set, cells, verdicts

function Select-SlotRun {
    # SPEC 7.2.0: the original run if valid; otherwise the first valid run from the slot's triple re-runs.
    param([object[]]$Candidates)
    $cands = @($Candidates | Where-Object { -not $_.superseded -and -not $_.isWarmup })
    if ($cands.Count -eq 0) { return $null }
    $orig = @($cands | Where-Object { -not $_.isRerun -and $_.role -ne 'rewarm' } | Sort-Object startedAtUtc)
    $o = $(if ($orig.Count) { $orig[-1] } else { $null })
    if ($o -and $o.valid) { return [pscustomobject]@{ run = $o; source = 'original' } }
    $reruns = @($cands | Where-Object { $_.isRerun } | Sort-Object rerunRound, startedAtUtc)
    foreach ($r in $reruns) { if ($r.valid) { return [pscustomobject]@{ run = $r; source = 'rerun' } } }
    return $null
}

function Test-ProcCountersUsable {
    # The suite marks procCounters.available = false when a process snapshot failed (WMI error); such a run has no
    # usable CPU figures (a missing flag, as in older files, counts as available).
    param($Pc)
    if (-not $Pc) { return $false }
    $av = Get-Field $Pc 'available'
    if ($null -ne $av -and -not (ConvertTo-Flag $av)) { return $false }
    return $true
}

function Get-ProcGroupCpuMs {
    # CPU ms of one process group during a run. Prefers the suite's per-process 'delta' (correct when processes
    # start or exit during the run, e.g. PostgreSQL backends); falls back to end - start of the group sums.
    param($Pc, [string]$Group)
    $d = ConvertTo-Num (Get-Field (Get-Field (Get-Field $Pc 'delta') $Group) 'cpuMs')
    if ($null -ne $d) { return $d }
    $a = ConvertTo-Num (Get-Field (Get-Field (Get-Field $Pc 'start') $Group) 'cpuMs')
    $b = ConvertTo-Num (Get-Field (Get-Field (Get-Field $Pc 'end') $Group) 'cpuMs')
    if ($null -ne $a -and $null -ne $b) { return ($b - $a) }
    return $null
}

function Get-RunCpu {
    # Database and Acumatica CPU of one run from the cumulative per-process counters (SPEC 5.4 item 15).
    param($Run)
    $pc = $Run.procCounters
    if (-not (Test-ProcCountersUsable $pc)) { return $null }
    $s = Get-Field $pc 'start'; $e = Get-Field $pc 'end'
    if (-not $s -or -not $e) { return $null }
    $proc = $script:EngineInfo[$Run.engine].process
    $db = Get-ProcGroupCpuMs $pc $proc
    $app = Get-ProcGroupCpuMs $pc ('w3wp:' + $Run.instance)
    $ops = 0.0
    foreach ($p in @(Get-Field $Run.result 'passes')) { $o = ConvertTo-Num (Get-Field $p 'ops'); if ($o) { $ops += $o } }
    foreach ($p in @(Get-Field $Run.result 'warmupPasses')) { $o = ConvertTo-Num (Get-Field $p 'ops'); if ($o) { $ops += $o } }
    $wops = ConvertTo-Num (Get-Field $Run.params 'warmUpOpsPerWorker'); $users = ConvertTo-Num (Get-Field $Run.params 'users')
    if ($wops -and $users) { $ops += $wops * $users }
    if ($ops -le 0 -and $Run.opsCount) { $ops = [double]$Run.opsCount }
    return [ordered]@{ dbCpuMs = $db; appCpuMs = $app; ops = $ops }
}

function Get-OthersCpu {
    # CPU used by the database processes of the engines that were NOT running during this run.
    param($Run)
    $pc = $Run.procCounters
    $out = @{}
    if (-not (Test-ProcCountersUsable $pc)) { return $out }
    foreach ($eng in $script:EngineOrder) {
        if ($eng -eq $Run.engine) { continue }
        $v = Get-ProcGroupCpuMs $pc $script:EngineInfo[$eng].process
        if ($null -ne $v) { $out[$eng] = $v }
    }
    return $out
}

function Get-U01WallThroughput {
    # Orders per minute of a 1-clerk run on the wall-clock basis including untimed resets (SPEC 1.3.1, review m7).
    param($Run)
    $vals = @()
    foreach ($p in @(Get-Field $Run.result 'passes')) {
        $ok = ConvertTo-Num (Get-Field $p 'okOps'); $w = ConvertTo-Num (Get-Field $p 'wallInclResetsMs')
        if ($null -eq $w) { $w = ConvertTo-Num (Get-Field $p 'wallMs') }
        if ($ok -and $w -and $w -gt 0) { $vals += ($ok / ($w / 60000.0)) }
    }
    if ($vals.Count -gt 0) { return (Get-Median ([double[]]$vals)) }
    if ($Run.headlineValue -and $Run.headlineValue -gt 0) { return 60000.0 / $Run.headlineValue }
    return $null
}

function Get-SteadyOpsPerMin {
    param($Run)
    $vals = @(@(Get-Field $Run.result 'passes') | ForEach-Object { ConvertTo-Num (Get-Field $_ 'steadyOpsPerMin') } | Where-Object { $null -ne $_ })
    if ($vals.Count -eq 0) { return $null }
    return (Get-Median ([double[]]$vals))
}

function Get-CappedText {
    param($Test, [object[]]$Runs)
    $capRun = @($Runs | Where-Object { $_.capped }) | Select-Object -First 1
    $limit = $null; $kind = $null
    if ($capRun) { $kind = $capRun.capKind; $limit = $capRun.capLimitMs; if (-not $limit -and $kind -eq 'operationCap') { $limit = $capRun.operationCapMs } }
    $per = ([string]$Test.readerUnit) -replace '^(ms|s)\s+', ''
    if ($kind -eq 'operationCap' -and $limit) { return ('over ' + (Format-Sig3 ($limit / 1000.0)) + ' s ' + $per) }
    if ($kind -eq 'runBudget' -and $limit) { return ('over the time limit (run budget ' + (Format-Sig3 ($limit / 1000.0)) + ' s)') }
    return 'over the time limit'
}

function New-Cell {
    param($Test, [string]$Engine, [object[]]$EngineRuns, [int]$NSlots)
    $slots = @(); $values = @(); $tpu = @(); $selected = @()
    for ($rep = 1; $rep -le $NSlots; $rep++) {
        $sel = Select-SlotRun @($EngineRuns | Where-Object { $_.rep -eq $rep })
        if ($sel) {
            $r = $sel.run
            $t = Get-TimePerUnit $r.headlineValue $Test.higherIsBetter $r.capped
            if ($null -eq $t) { $values += $null; $tpu += $null; $slots += [ordered]@{ rep = $rep; requestId = $r.requestId; source = $sel.source; note = 'no headline value' }; continue }
            $values += $(if ($r.capped) { 'inf' } else { $r.headlineValue })
            $tpu += $t
            $selected += $r
            $slots += [ordered]@{ rep = $rep; requestId = $r.requestId; source = $sel.source; status = $r.status; suiteUsedInAnalysis = $r.suiteUsed }
        }
        else { $values += $null; $tpu += $null; $slots += [ordered]@{ rep = $rep; requestId = $null; source = 'empty' } }
    }
    $valid = [double[]]@($tpu | Where-Object { $null -ne $_ })
    $finite = Get-FiniteValues $valid
    $n = $valid.Count
    # Capped runs are counted by status: a throughput of 0 (every save failed) is +inf time per order as well, but it
    # did not hit the time limit and must not be labelled so.
    $cappedRuns = @($selected | Where-Object { $_.capped }).Count
    $median = Get-Median $valid
    $cv = Get-RobustCvPct $valid
    $cappedCell = ($n -gt 0) -and ($cappedRuns -ge $TieRule.cappedCellShare * $n)

    $headlines = [double[]]@($selected | Where-Object { -not $_.capped -and $null -ne $_.headlineValue } | ForEach-Object { [double]$_.headlineValue })
    $p95 = [double[]]@($selected | Where-Object { $null -ne $_.p95Ms } | ForEach-Object { [double]$_.p95Ms })

    # CPU attribution per run (database vs Acumatica)
    $dbPerOp = @(); $appPerOp = @(); $share = @()
    foreach ($r in $selected) {
        $c = Get-RunCpu $r
        if (-not $c -or -not $c.ops) { continue }
        if ($null -ne $c.dbCpuMs) { $dbPerOp += ($c.dbCpuMs / $c.ops) }
        if ($null -ne $c.appCpuMs) { $appPerOp += ($c.appCpuMs / $c.ops) }
        if ($null -ne $c.dbCpuMs -and $null -ne $c.appCpuMs -and ($c.dbCpuMs + $c.appCpuMs) -gt 0) { $share += ($c.dbCpuMs / ($c.dbCpuMs + $c.appCpuMs)) }
    }

    # parity signature (non-capped runs only; an interrupted run has a partial checksum)
    $sigs = @{}
    foreach ($r in @($selected | Where-Object { -not $_.capped })) { $k = [string]$r.checksum + '|' + [string]$r.rows; if ($sigs.ContainsKey($k)) { $sigs[$k]++ } else { $sigs[$k] = 1 } }
    $modal = $null; $modalCount = 0
    foreach ($k in $sigs.Keys) { if ($sigs[$k] -gt $modalCount) { $modal = $k; $modalCount = $sigs[$k] } }

    # probes (keys "probe.*" of ResultJson.parity) by modal value
    $probes = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)   # probe keys differ only by case and accents
    foreach ($r in $selected) {
        $par = Get-Field $r.result 'parity'
        foreach ($k in (Get-Keys $par)) { if ($k -like 'probe.*' -and -not $probes.Contains($k)) { $probes[$k] = [string](Get-Field $par $k) } }
    }

    # outliers: finite values outside [0.67, 1.5] x the cell median (flagged and counted, never dropped)
    $outliers = @()
    if ($null -ne $median -and -not (Test-Inf $median) -and $median -gt 0) {
        for ($i = 0; $i -lt $tpu.Count; $i++) {
            $t = $tpu[$i]
            if ($null -eq $t -or (Test-Inf $t)) { continue }
            $ratio = $t / $median
            if ($ratio -lt $TieRule.outlierLow -or $ratio -gt $TieRule.outlierHigh) { $outliers += [ordered]@{ repetitionNo = ($i + 1); ratio = (Get-Round $ratio 3) } }
        }
    }

    $opsPerPass = $null
    foreach ($r in $selected) { if ($r.opsPerPass) { $opsPerPass = $r.opsPerPass; break } }
    return [pscustomobject]@{
        testCode = $Test.code; engine = $Engine; instance = $(if ($selected.Count) { $selected[0].instance } else { (@($EngineRuns | Select-Object -First 1).instance) })
        nValid = $n; nSlots = $NSlots; cappedRuns = $cappedRuns; cappedCell = $cappedCell
        values = $values; timePerUnitMs = $tpu; slots = $slots; selectedRuns = $selected
        median = $median; min = $(if ($finite.Count) { [double]($finite | Measure-Object -Minimum).Minimum } else { $null }); max = $(if ($finite.Count) { [double]($finite | Measure-Object -Maximum).Maximum } else { $null })
        medianHeadline = Get-Median $headlines; minHeadline = $(if ($headlines.Count) { [double]($headlines | Measure-Object -Minimum).Minimum } else { $null }); maxHeadline = $(if ($headlines.Count) { [double]($headlines | Measure-Object -Maximum).Maximum } else { $null })
        robustCvPct = $cv; noisy = ($cv -gt $TieRule.noisyCvPct); relToFastest = $null
        medianP95Ms = Get-Median $p95
        errors = [int](($selected | Measure-Object -Property errors -Sum).Sum); deadlocks = [int](($selected | Measure-Object -Property deadlocks -Sum).Sum)
        retries = [int](($selected | Measure-Object -Property retries -Sum).Sum); lockViolations = [int](($selected | Measure-Object -Property lockViolations -Sum).Sum)
        timeouts = [int](($selected | Measure-Object -Property timeouts -Sum).Sum)
        rowsReturned = $(if ($modal) { ConvertTo-Num ($modal.Split('|')[1]) } else { $null }); checksum = $(if ($modal) { $modal.Split('|')[0] } else { $null })
        paritySignature = $modal; paritySignatures = $sigs.Count; probes = $probes
        outliers = $outliers; settleTimeouts = @($selected | Where-Object { $_.settleTimedOut }).Count
        dbCpuMsPerOp = $(if ($dbPerOp.Count) { Get-Median ([double[]]$dbPerOp) } else { $null })
        appCpuMsPerOp = $(if ($appPerOp.Count) { Get-Median ([double[]]$appPerOp) } else { $null })
        dbCpuShare = $(if ($share.Count) { Get-Median ([double[]]$share) } else { $null })
        cappedText = Get-CappedText $Test $selected
        opsPerPass = $opsPerPass
        paramsHashes = @($selected | ForEach-Object { $_.paramsHash } | Where-Object { $_ } | Select-Object -Unique)
        methodologies = @($selected | ForEach-Object { $_.methodology } | Where-Object { $_ } | Select-Object -Unique)
        dlls = @($selected | ForEach-Object { $_.dll } | Where-Object { $_ } | Select-Object -Unique)
        steadyOpsPerMin = $(
            $st = [double[]]@($selected | ForEach-Object { Get-SteadyOpsPerMin $_ } | Where-Object { $null -ne $_ })
            if ($st.Count) { Get-Median $st } else { $null })
        wallOpsPerMin = $(
            if ($Test.users -eq 1 -and $Test.family -eq 'OrderEntry') {
                $wt = [double[]]@($selected | ForEach-Object { Get-U01WallThroughput $_ } | Where-Object { $null -ne $_ })
                if ($wt.Count) { [ordered]@{ median = Get-Median $wt; min = [double]($wt | Measure-Object -Minimum).Minimum; max = [double]($wt | Measure-Object -Maximum).Maximum; n = $wt.Count } } else { $null }
            } else { $null })
    }
}

function Get-TestVerdict {
    param($Test, [object[]]$Cells, [string[]]$Engines, [string[]]$GlobalGateReasons)
    $byEngine = @{}; foreach ($c in $Cells) { $byEngine[$c.engine] = $c }
    $v = [ordered]@{
        testCode = $Test.code; comparable = $true; reason = $null; parity = 'n/a'; parityNote = $null
        excludedEngines = @(); pairs = @(); tiers = @(); tierNotes = @(); headline = $null; sentenceMd = $null
        rankedEngines = @(); cappedEngines = @(); resultsDiffer = $false; probes = $null
    }

    # ---- comparability gate (SPEC 3.10 layer 4) ----
    $reasons = @()
    foreach ($e in $Engines) {
        $c = $byEngine[$e]
        $n = if ($c) { $c.nValid } else { 0 }
        if ($n -lt $TieRule.minValidSlots) { $reasons += ('fewer than {0} valid runs on {1} (n = {2})' -f $TieRule.minValidSlots, (Get-EngineName $e), $n) }
    }
    $ph = @($Cells | ForEach-Object { $_.paramsHashes } | Where-Object { $_ } | Select-Object -Unique)
    if ($ph.Count -gt 1) { $reasons += ('parameters differ ({0} ParamsHash values)' -f $ph.Count) }
    $mv = @($Cells | ForEach-Object { $_.methodologies } | Where-Object { $_ } | Select-Object -Unique)
    if ($mv.Count -gt 1) { $reasons += ('methodology versions differ (' + ($mv -join ', ') + ')') }
    $dl = @($Cells | ForEach-Object { $_.dlls } | Where-Object { $_ } | Select-Object -Unique)
    if ($dl.Count -gt 1) { $reasons += ('customization DLL differs ({0} SHA-256 values)' -f $dl.Count) }
    $reasons += @($GlobalGateReasons)
    if ($reasons.Count -gt 0) {
        $v.comparable = $false; $v.reason = ($reasons -join '; ')
        $v.headline = 'n/a: not comparable (' + $v.reason + ')'
        $v.sentenceMd = $v.headline
        return $v
    }

    # ---- failed saves (ErrorsInvalidate = false tests): excluded from the "faster" verdict ----
    $excluded = @{}
    $anyErrors = $false
    if (-not $Test.errorsInvalidate) {
        foreach ($e in $Engines) {
            $c = $byEngine[$e]
            if ($c.errors -gt 0) { $anyErrors = $true; $excluded[$e] = ('{0} failed {1}' -f $c.errors, $(if ($c.errors -eq 1) { 'save' } else { 'saves' })); $v.excludedEngines += [ordered]@{ engine = $e; why = 'errors'; detail = $excluded[$e] } }
        }
    }

    # ---- parity (correctness first) ----
    if ($Test.parityExpected -and -not ($anyErrors)) {
        $groups = [ordered]@{}
        foreach ($e in $Engines) {
            $c = $byEngine[$e]
            if (-not $c.paritySignature) { continue }
            if (-not $groups.Contains($c.paritySignature)) { $groups[$c.paritySignature] = @() }
            $groups[$c.paritySignature] += $e
        }
        if ($groups.Count -le 1) { $v.parity = 'same' }
        else {
            $v.parity = 'differs'
            $major = $null
            foreach ($k in $groups.Keys) { if (@($groups[$k]).Count -ge 2) { $major = $k } }
            if ($major) {
                foreach ($k in $groups.Keys) {
                    if ($k -eq $major) { continue }
                    foreach ($e in $groups[$k]) {
                        $c = $byEngine[$e]; $ref = $byEngine[@($groups[$major])[0]]
                        $excluded[$e] = 'returned a different answer'
                        $v.excludedEngines += [ordered]@{ engine = $e; why = 'different answer'; detail = ('rows {0} vs {1}; checksum {2} vs {3}' -f (Format-Sig3 $c.rowsReturned), (Format-Sig3 $ref.rowsReturned), $c.checksum, $ref.checksum) }
                    }
                }
                $v.parityNote = (Join-EngineNames @($groups[$major])) + ' returned the same answer; ' + (Join-EngineNames @($v.excludedEngines | Where-Object { $_.why -eq 'different answer' } | ForEach-Object { $_.engine })) + ' returned a different answer and is not ranked on this test.'
            }
            else {
                $v.resultsDiffer = $true
                # Engines without a signature (every analysis-set run was capped, so no complete answer) are unknown,
                # not "different": say "every database" only when all of them answered.
                $answered = @($Engines | Where-Object { $byEngine[$_] -and $byEngine[$_].paritySignature })
                $unknown = @($Engines | Where-Object { $answered -notcontains $_ })
                if ($unknown.Count -gt 0) {
                    $v.parityNote = (Join-EngineNames $answered) + ' returned different answers; ' + (Join-EngineNames $unknown) + "'s answer is unknown (no complete run to compare); no speed verdict."
                }
                else { $v.parityNote = 'Every database returned a different answer; no speed verdict.' }
            }
        }
        foreach ($e in $Engines) { $c = $byEngine[$e]; if ($c -and $c.paritySignatures -gt 1) { $v.parityNote = (([string]$v.parityNote + ' ' + (Get-EngineName $e) + ' did not return the same answer in every run.').Trim()) } }
    }
    elseif ($Test.parityExpected -and $anyErrors) {
        $v.parity = 'n/a'
        $v.parityNote = 'Answers are compared only when every database saved every document (failed saves on ' + (Join-EngineNames @($excluded.Keys | Sort-Object { [array]::IndexOf($script:EngineOrder, $_) })) + ').'
    }

    # probes: "Same answer?" rows (never block ranking)
    $probeKeys = @($Cells | ForEach-Object { $_.probes.Keys } | Select-Object -Unique)   # Select-Object -Unique compares strings case-sensitively
    if ($probeKeys.Count -gt 0) {
        $pr = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
        foreach ($k in $probeKeys) { $row = [ordered]@{}; foreach ($e in $Engines) { $row[$e] = $byEngine[$e].probes[$k] }; $pr[$k] = $row }
        $v.probes = $pr
    }

    if ($v.resultsDiffer) {
        if ($v.parityNote -like 'Every database*') {
            $v.headline = 'Results differ on every database; no speed verdict.'
            $v.sentenceMd = '**Results differ:** every database returned a different answer, so there is no speed verdict.'
        }
        else {
            $v.headline = 'Results differ; no speed verdict.'
            $v.sentenceMd = '**Results differ:** ' + $v.parityNote
        }
        return $v
    }

    # ---- pairwise verdicts among the ranked engines ----
    $ranked = @($Engines | Where-Object { -not $excluded.ContainsKey($_) -and $byEngine[$_].nValid -gt 0 })
    $v.rankedEngines = $ranked
    $v.cappedEngines = @($ranked | Where-Object { $byEngine[$_].cappedCell })
    $floor = Get-FloorSpec $Test.family $Test.users
    $pairs = @{}
    for ($i = 0; $i -lt $ranked.Count; $i++) {
        for ($j = $i + 1; $j -lt $ranked.Count; $j++) {
            $ca = $byEngine[$ranked[$i]]; $cb = $byEngine[$ranked[$j]]
            $a = [double[]]@($ca.timePerUnitMs | Where-Object { $null -ne $_ })
            $b = [double[]]@($cb.timePerUnitMs | Where-Object { $null -ne $_ })
            $p = Compare-PerfPair -A $a -B $b -Floor $floor -CappedCellA $ca.cappedCell -CappedCellB $cb.cappedCell -NameA $ranked[$i] -NameB $ranked[$j]
            $fastCell = $byEngine[$p.faster]; $slowCell = $byEngine[$p.slower]
            $p['signTest'] = Get-SignTest $fastCell.timePerUnitMs $slowCell.timePerUnitMs
            $pairs[$p.faster + '|' + $p.slower] = $p
            $pairs[$p.slower + '|' + $p.faster] = $p
            $v.pairs += $p
        }
    }
    $tierInfo = Get-Tiers @($ranked | ForEach-Object { $byEngine[$_] }) $pairs
    $v.tiers = @($tierInfo.tiers)
    $v.tierNotes = @($tierInfo.notes)
    $v['pairLookup'] = $pairs
    return $v
}

#endregion

#region ---------------------------------------------------------------- verdict text (SPEC 7.2.3 phrasing templates)

function Get-Bold { param([string]$Text, [bool]$Md) if ($Md) { return '**' + $Text + '**' } return $Text }

function Get-PairValueText {
    # "1.9 s vs 2.4 s per report" or "610 vs 480 orders per minute"
    param($Pair, $Spec, $CellFast, $CellSlow)
    if ($Spec.kind -eq 'rate') {
        return (Format-Sig3 $CellFast.medianHeadline) + ' vs ' + (Format-Sig3 $CellSlow.medianHeadline) + ' ' + $Spec.per
    }
    return (Format-TimeValue $Pair.mFast $Spec) + ' vs ' + (Format-TimeValue $Pair.mSlow $Spec) + ' ' + $Spec.per
}

function Get-PairSentence {
    # SPEC 7.2.3 templates. With three ranked databases the slower one is named ("... faster than MySQL").
    param($Test, $Pair, $Spec, [hashtable]$ByEngine, [bool]$Md, [bool]$NameSlower = $false)
    $F = Get-EngineName $Pair.faster; $S = Get-EngineName $Pair.slower
    $than = if ($NameSlower) { " than $S" } else { '' }
    $cf = $ByEngine[$Pair.faster]; $cs = $ByEngine[$Pair.slower]
    $vals = Get-PairValueText $Pair $Spec $cf $cs
    $ratio = 1.0 + [double]$Pair.gap
    if ($Spec.kind -eq 'rate') { $diff = (Format-Pct (100.0 * $Pair.gap)) + ' more ' + $Spec.what + ' per minute' }
    else { $diff = (Format-Pct (100.0 * (1.0 - $Pair.mFast / $Pair.mSlow))) + ' lower median time' }
    switch ($Pair.statLabel) {
        'slightly faster' {
            if (-not $Pair.noticeable) { return (Get-Bold 'Not noticeable:' $Md) + " $F was slightly faster$than ($vals), a difference nobody will notice." }
            return (Get-Bold "$F was slightly faster${than}:" $Md) + " $diff ($F won $($Pair.strictWins) of $($Pair.pairings) run pairings)."
        }
        'faster' {
            if (-not $Pair.noticeable) { return (Get-Bold 'Not noticeable:' $Md) + " $F was faster$than ($vals), a difference nobody will notice." }
            return (Get-Bold "$F was faster${than}:" $Md) + " $diff ($vals)."
        }
        'much faster' {
            if ($Pair.cappedSlow) { return (Get-Bold "$F was much faster${than}:" $Md) + " $S did not finish within the time limit." }
            if (-not $Pair.noticeable) { return (Get-Bold 'Not noticeable:' $Md) + " $F was much faster$than in relative terms ($vals), but nobody will notice the difference." }
            return (Get-Bold "$F was much faster${than}:" $Md) + ' ' + (Format-Ratio $ratio) + " (median $vals)."
        }
    }
    return ''
}

function Get-TieSentence {
    param($Pair, [bool]$Md)
    if ($Pair.statLabel -eq 'inconclusive') {
        return (Get-Bold 'Inconclusive:' $Md) + (' too few valid runs to separate them (n = {0} and {1}); counted as a tie.' -f $Pair.nFast, $Pair.nSlow)
    }
    if ($Pair.gapPct -lt $Pair.thresholdPct) {
        return (Get-Bold 'Tie:' $Md) + ' within ' + (Format-Pct $Pair.gapPct) + ' (below the ' + (Format-Pct $Pair.thresholdPct) + ' threshold).'
    }
    return (Get-Bold 'Tie:' $Md) + ' ' + (Format-Pct $Pair.gapPct) + ' apart, but the runs overlapped too much to call it (' + (Get-EngineName $Pair.faster) + ' won ' + $Pair.strictWins + ' of ' + $Pair.pairings + ' run pairings).'
}

function Get-VerdictText {
    param($Test, $Verdict, [hashtable]$ByEngine, $Spec, [bool]$Md)
    if (-not $Verdict.comparable) { return 'n/a: not comparable (' + $Verdict.reason + ').' }
    if ($Verdict.resultsDiffer) {
        if ([string]$Verdict.parityNote -like 'Every database*') { return (Get-Bold 'Results differ:' $Md) + ' every database returned a different answer, so there is no speed verdict.' }
        return (Get-Bold 'Results differ:' $Md) + ' ' + [string]$Verdict.parityNote
    }
    $parts = @()
    foreach ($x in @($Verdict.excludedEngines)) {
        if ($x.why -eq 'different answer') { $parts += ((Get-Bold ((Get-EngineName $x.engine) + ' returned a different answer') $Md) + ' and is not ranked on this test.') }
        elseif ($x.why -eq 'errors') { $parts += ((Get-EngineName $x.engine) + ': ' + (Get-Bold $x.detail $Md) + '; not ranked on this test.') }
    }
    $pairs = $Verdict.pairLookup
    $ranked = @($Verdict.rankedEngines)
    $capped = @($Verdict.cappedEngines)
    $live = @($ranked | Where-Object { $capped -notcontains $_ } | Sort-Object { $ByEngine[$_].median })

    foreach ($e in $capped) {
        $others = @($live | ForEach-Object { (Get-EngineName $_) + ' ' + (Format-CellMedian $ByEngine[$_] $Spec) })
        $parts += ((Get-Bold ((Get-EngineName $e) + ' did not finish within the time limit') $Md) + ' (' + $ByEngine[$e].cappedText + ')' + $(if ($others.Count) { '; ' + ($others -join ', ') } else { '' }) + '.')
    }

    $nameSlower = ($live.Count -ge 3)
    if ($live.Count -ge 2) {
        $liveTiers = @($Verdict.tiers | ForEach-Object { , @($_ | Where-Object { $capped -notcontains $_ }) } | Where-Object { @($_).Count -gt 0 })
        $livePairs = @(); for ($i = 0; $i -lt $live.Count; $i++) { for ($j = $i + 1; $j -lt $live.Count; $j++) { $livePairs += $pairs[$live[$i] + '|' + $live[$j]] } }
        $inTier = @($livePairs | Where-Object { $_.practical -ne 'tie' })
        if ($liveTiers.Count -eq 1 -and $inTier.Count -gt 0) {
            # Non-transitive inside one tier: X faster than Y, but both tie with the leader. Report it; never invent a winner.
            foreach ($p in $inTier) { $parts += (Get-PairSentence $Test $p $Spec $ByEngine $Md $true) }
            $tiedWithBoth = @($live | Where-Object { $e = $_; @($inTier | Where-Object { $_.faster -eq $e -or $_.slower -eq $e }).Count -eq 0 })
            if ($tiedWithBoth.Count) { $parts += ((Join-EngineNames $tiedWithBoth) + ' tied with both, so all ' + $live.Count + ' stay in the fastest group.') }
            $parts += @($Verdict.tierNotes)
        }
        elseif ($liveTiers.Count -eq 1) {
            $nn = @($livePairs | Where-Object { $_.statLabel -ne 'tie' -and $_.statLabel -ne 'inconclusive' -and -not $_.noticeable } | Sort-Object { $_.gap } -Descending)
            if ($nn.Count -gt 0) {
                $parts += (Get-PairSentence $Test $nn[0] $Spec $ByEngine $Md $nameSlower)
                $lo = $ByEngine[$live[0]]; $hi = $ByEngine[$live[-1]]
                if ($Spec.kind -eq 'rate') { $range = (Format-Sig3 $hi.medianHeadline) + $script:NDASH + (Format-Sig3 $lo.medianHeadline) + ' ' + $Spec.per }
                else { $range = (Format-TimeValue $lo.median $Spec -NoUnit) + $script:NDASH + (Format-TimeValue $hi.median $Spec) + ' ' + $Spec.per }
                $parts += ($Test.displayName + ': ' + $range + ' on ' + $(if ($live.Count -eq 3) { 'all three' } else { Join-EngineNames $live }) + '; not noticeable.')
            }
            else {
                $worst = @($livePairs | Sort-Object { $_.gap } -Descending)[0]
                if ($live.Count -eq 3 -and $worst.statLabel -ne 'inconclusive') {
                    $parts += ((Get-Bold 'Tie:' $Md) + ' all three within ' + (Format-Pct $worst.gapPct) + $(if ($worst.gapPct -lt $worst.thresholdPct) { ' (below the ' + (Format-Pct $worst.thresholdPct) + ' threshold).' } else { '; the runs overlapped too much to call a difference.' }))
                }
                else { $parts += (Get-TieSentence $worst $Md) }
            }
        }
        else {
            $t1 = @($liveTiers[0]); $fastest = $live[0]
            if ($t1.Count -eq 1) {
                $next = @($liveTiers[1])[0]
                $parts += (Get-PairSentence $Test $pairs[$fastest + '|' + $next] $Spec $ByEngine $Md $nameSlower)
                $restTiers = @($liveTiers | Select-Object -Skip 1)
                foreach ($tier in $restTiers) {
                    foreach ($e in @($tier)) {
                        if ($e -eq $next) { continue }
                        $ratio = $ByEngine[$e].median / $ByEngine[$fastest].median
                        $p = $pairs[$next + '|' + $e]
                        $tieNote = if ($p -and $p.practical -eq 'tie' -and @($tier) -contains $next) { ' (tied with ' + (Get-EngineName $next) + ')' } else { '' }
                        $parts += ((Get-EngineName $e) + ' was ' + (Format-Ratio $ratio) + ' slower than ' + (Get-EngineName $fastest) + $tieNote + '.')
                    }
                }
            }
            else {
                $slow = @(); foreach ($tier in @($liveTiers | Select-Object -Skip 1)) { $slow += @($tier) }
                $txt = (Join-EngineNames $t1) + ' tied'
                $slowTxt = @($slow | ForEach-Object { (Get-EngineName $_) + ' was ' + (Format-Ratio ($ByEngine[$_].median / $ByEngine[$fastest].median)) + ' slower' })
                $parts += ((Get-Bold $txt $Md) + '; ' + ($slowTxt -join '; ') + '.')
            }
            $parts += @($Verdict.tierNotes)
        }
    }
    elseif ($live.Count -eq 1 -and $capped.Count -eq 0 -and $ranked.Count -eq 1) {
        $parts += ('Only ' + (Get-EngineName $live[0]) + ' could be ranked on this test.')
    }
    return ($parts -join ' ').Trim()
}

function Get-ConcurrencySentence {
    # "With 16 clerks working non-stop, X processed N orders/min (95% of orders saved within T ms); failed saves: 0; automatic retries: R."
    param($Test, $Cell, $Spec)
    if (-not $Cell -or $Cell.nValid -eq 0) { return $null }
    $who = if ($Test.displayName -match 'clerk') { 'clerks' } elseif ($Test.displayName -match 'people|person') { 'people' } else { 'workers' }
    $what = $Spec.what; if (-not $what) { $what = 'operations' }
    $verb = if ($what -match 'invoice') { 'released' } else { 'saved' }
    $tp = if ($Cell.medianHeadline) { Format-Sig3 $Cell.medianHeadline } else { 'n/a' }
    $p95 = if ($Cell.medianP95Ms) { Format-Sig3 $Cell.medianP95Ms } else { 'n/a' }
    $s = "With $($Test.users) $who working non-stop, $(Get-EngineName $Cell.engine) processed $tp $what/min (95% of $what $verb within $p95 ms); failed saves: $($Cell.errors); automatic retries: $($Cell.retries); deadlocks: $($Cell.deadlocks)"
    if ($Cell.steadyOpsPerMin) { $s += '; steady-state ' + (Format-Sig3 $Cell.steadyOpsPerMin) + " $what/min" }
    return $s + '.'
}

#endregion

#region ---------------------------------------------------------------- environment helpers

function Get-LeafMap {
    # Flattens a JSON object into path -> scalar text (lists of {name, value} rows keep the name in the path).
    param($Obj, [string]$Prefix, [System.Collections.IDictionary]$Into)
    if ($null -eq $Obj) { return }
    if (Test-IsMap $Obj) {
        foreach ($k in (Get-Keys $Obj)) {
            if ($Obj -is [System.Collections.IDictionary]) { $item = $Obj[$k] } else { $item = $Obj.PSObject.Properties[$k].Value }
            Get-LeafMap $item $(if ($Prefix) { $Prefix + '.' + $k } else { $k }) $Into
        }
        return
    }
    if (Test-IsList $Obj) {
        $i = 0
        foreach ($x in $Obj) {
            $name = $null
            if (Test-IsMap $x) { foreach ($nk in @('name', 'Name', 'Variable_name', 'key')) { $nv = Get-Field $x $nk; if ($nv) { $name = [string]$nv; break } } }
            Get-LeafMap $x ($Prefix + '[' + $(if ($name) { $name } else { $i }) + ']') $Into
            $i++
        }
        return
    }
    $Into[$Prefix] = [string]$Obj
}

function Find-Setting {
    # First value of a setting anywhere in the given objects: a key with that name, or a {name, value} row.
    param([object[]]$Sources, [string[]]$Names)
    foreach ($src in $Sources) {
        if ($null -eq $src) { continue }
        $map = [ordered]@{}; Get-LeafMap $src '' $map
        foreach ($n in $Names) {
            $pat = [regex]::Escape($n)
            foreach ($k in $map.Keys) {
                if ($k -match ('(^|\.)' + $pat + '$')) { return $map[$k] }
                if ($k -match ('\[' + $pat + '\]\.(value_in_use|value|setting|Value|VARIABLE_VALUE)$')) {
                    $v = $map[$k]
                    $unitKey = $k -replace '\.(value_in_use|value|setting|Value|VARIABLE_VALUE)$', '.unit'
                    if ($map.Contains($unitKey) -and $map[$unitKey]) { $v = $v + ' x ' + $map[$unitKey] }
                    return $v
                }
            }
        }
    }
    return $null
}

function Get-EngineEnvSources {
    param($Data, [string]$Engine)
    $out = @()
    foreach ($ec in @($Data.envCaptures)) {
        $inst = [string](Get-Field $ec 'instance')
        if ((Resolve-Engine '' $inst) -eq $Engine -or ($Data.instanceEngines.ContainsKey($inst) -and $Data.instanceEngines[$inst] -eq $Engine)) { $out += , (Get-PathValue $ec 'env.db'); break }
    }
    if ($Data.start) {
        foreach ($k in (Get-Keys $Data.start)) {
            $n = $k.ToLowerInvariant()
            $hit = switch ($Engine) { 'SQLServer' { $n -match 'sqlserver|mssql' } 'MySQL' { $n -match 'mysql' } 'PostgreSQL' { $n -match 'postgre|pgsql|^pg$' } default { $false } }
            if ($hit) { $out += , (Get-Field $Data.start $k) }
        }
    }
    return , $out
}

function Get-EnvGateReasons {
    # Global part of the comparability gate: start/end captures agree on DLL, Acumatica build and engine versions;
    # ENV_CAPTURE master-data hash equal across instances (SPEC 3.10 layer 4).
    param($Data, [System.Collections.ArrayList]$Notes)
    $reasons = @()
    if ($Data.start -and $Data.end) {
        $a = [ordered]@{}; Get-LeafMap $Data.start '' $a
        $b = [ordered]@{}; Get-LeafMap $Data.end '' $b
        $diff = @()
        # Leaves the environment script marks as volatile, and sizes (e.g. databases.PostgreSQL.version.dbSizeBytes),
        # change during any campaign and say nothing about the software versions this check is about.
        $volatile = @(@(Get-Field $Data.start 'volatileFields') | Where-Object { $_ } | ForEach-Object { [string]$_ })
        # Add-EnvShapeAliases copies databases.<Engine> to top-level sqlServer/mySql/postgreSql; compare the original only.
        if (Test-IsMap (Get-Field $Data.start 'databases')) { $volatile += @('sqlServer', 'mySql', 'postgreSql') }
        foreach ($k in $a.Keys) {
            if ($k -notmatch '(?i)(sha256|dll|build|pxdata|version|edition)') { continue }
            if ($k -match '(?i)(uptime|captured|time|label|date|size|bytes)') { continue }
            if (@($volatile | Where-Object { $k -eq $_ -or $k.StartsWith($_ + '.') -or $k.StartsWith($_ + '[') }).Count -gt 0) { continue }
            if ($b.Contains($k) -and [string]$b[$k] -ne [string]$a[$k]) { $diff += $k }
        }
        if ($diff.Count -gt 0) { $reasons += ('environment changed between start and end (' + ($diff -join ', ') + ')') }
    }
    else { [void]$Notes.Add('Environment start/end captures were not both available; the start/end part of the comparability gate was not checked.') }
    $hashes = @{}
    foreach ($ec in @($Data.envCaptures)) {
        $map = [ordered]@{}; Get-LeafMap (Get-Field $ec 'env') '' $map
        foreach ($k in $map.Keys) { if ($k -match '(?i)(^|\.)masterDataHash$') { $hashes[[string]$map[$k]] = $true } }
    }
    if ($hashes.Count -gt 1) { $reasons += 'master data differ between instances (ENV_CAPTURE masterDataHash)' }
    if ($hashes.Count -eq 0) { [void]$Notes.Add('No ENV_CAPTURE masterDataHash was found; the master-data part of the comparability gate was not checked.') }
    return , $reasons
}

function Get-IsolationByEngine {
    param($Data)
    $out = [ordered]@{}
    foreach ($e in $script:EngineOrder) {
        $src = Get-EngineEnvSources $Data $e
        $v = Find-Setting $src @('isolation', 'transaction_isolation', 'default_transaction_isolation', 'transaction_isolation_level')
        $out[$e] = $v
    }
    return $out
}

function Test-MySqlRepeatableRead {
    param($Data)
    $iso = Get-IsolationByEngine $Data
    return ([string]$iso['MySQL']) -match '(?i)repeatable'
}

#endregion

#region ---------------------------------------------------------------- SVG charts

function Get-NiceRelMax {
    param([double]$MaxRel)
    foreach ($s in @(1.25, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10, 15, 20, 30, 50, 100)) { if ($MaxRel * 1.05 -le $s) { return [double]$s } }
    return [Math]::Ceiling($MaxRel * 1.1)
}

function Get-RelTicks {
    param([double]$Base, [double]$AxisMax)
    $step = 0.25
    foreach ($s in @(0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 20)) { if (($AxisMax - $Base) / $s -le 8) { $step = $s; break } }
    $t = @(); $x = $Base
    while ($x -le $AxisMax + 1e-9) { $t += $x; $x += $step }
    return $t
}

function New-SvgDocument {
    param([int]$Width, [int]$Height, [string]$Title, [string]$Body)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine(('<svg xmlns="http://www.w3.org/2000/svg" width="{0}" height="{1}" viewBox="0 0 {0} {1}" role="img" aria-label="{2}">' -f $Width, $Height, (ConvertTo-XmlText $Title)))
    [void]$sb.AppendLine(('<title>{0}</title>' -f (ConvertTo-XmlText $Title)))
    [void]$sb.AppendLine('<defs><pattern id="capHatch" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="6" height="6" fill="#ffffff"/><line x1="0" y1="0" x2="0" y2="6" stroke="#4B5563" stroke-width="2"/></pattern></defs>')
    [void]$sb.AppendLine(('<rect x="0" y="0" width="{0}" height="{1}" fill="#ffffff"/>' -f $Width, $Height))
    [void]$sb.AppendLine(('<g font-family="{0}" fill="#1F2937">' -f $script:FontStack))
    [void]$sb.Append($Body)
    [void]$sb.AppendLine('</g>')
    [void]$sb.AppendLine('</svg>')
    return $sb.ToString()
}

function Get-SvgText {
    param([double]$X, [double]$Y, [string]$Text, [int]$Size = 12, [string]$Anchor = 'start', [string]$Weight = 'normal', [string]$Fill = '#1F2937')
    return ('<text x="{0}" y="{1}" font-size="{2}" text-anchor="{3}" font-weight="{4}" fill="{5}">{6}</text>' -f (Get-Round $X 1), (Get-Round $Y 1), $Size, $Anchor, $Weight, $Fill, (ConvertTo-XmlText $Text)) + "`n"
}

function Get-SvgLegend {
    param([double]$X, [double]$Y)
    $sb = ''
    $x = $X
    foreach ($e in $script:EngineOrder) {
        $sb += ('<rect x="{0}" y="{1}" width="12" height="12" fill="{2}"/>' -f $x, ($Y - 10), (Get-EngineColor $e)) + "`n"
        $sb += Get-SvgText ($x + 17) $Y (Get-EngineName $e) 12
        $x += 30 + 7.2 * (Get-EngineName $e).Length
    }
    return $sb
}

function New-RelativeBarChart {
    <#
      Horizontal bars relative to the fastest engine of each test (1.00x at the left baseline), min-max whiskers,
      end labels "1.18x - 47 ms", "~" for ties and ">=" for time-limit cells (SPEC 7.4). Sections are stacked;
      each section has its own relative axis.
    #>
    param([string]$Title, [string]$Subtitle, [object[]]$Sections, [int]$Width = 960, [switch]$Compact)
    $barH = if ($Compact) { 11 } else { 16 }
    $barGap = if ($Compact) { 3 } else { 4 }
    $engineW = 92; $left = 16; $endW = 210
    $x0 = $left + $engineW; $x1 = $Width - 16 - $endW
    $plotW = $x1 - $x0
    $body = ''
    $y = 30
    $body += Get-SvgText $left $y $Title 18 'start' '600'
    $y += 20
    if ($Subtitle) { $body += Get-SvgText $left $y $Subtitle 12 'start' 'normal' '#4B5563'; $y += 18 }
    $body += Get-SvgLegend $left ($y + 4)
    $y += 22
    foreach ($sec in $Sections) {
        $groups = @($sec.groups)
        if ($groups.Count -eq 0) { continue }
        $maxRel = 1.0
        foreach ($g in $groups) { foreach ($b in @($g.bars)) { if (-not $b.capped -and $null -ne $b.rel -and -not (Test-Inf $b.rel)) { $maxRel = [Math]::Max($maxRel, [double]$b.rel) } } }
        $axisMax = Get-NiceRelMax ([Math]::Max(1.2, $maxRel))
        # At a glance: 1.00x at the left baseline (SPEC 7.4); family charts: bars from 0 so length is proportional to time.
        $base = if ($Compact) { 1.0 } else { 0.0 }
        $span = $axisMax - $base
        $sx = { param($r) $x0 + (([Math]::Min([Math]::Max([double]$r, $base), $axisMax) - $base) / $span) * $plotW }
        if ($sec.title -and @($Sections).Count -gt 1) { $y += 8; $body += Get-SvgText $left ($y + 12) $sec.title 14 'start' '600'; $y += 22 }
        $ticks = Get-RelTicks $base $axisMax
        $top = $y
        $y += 14
        $rows = ''
        $spans = @()
        foreach ($g in $groups) {
            $rows += Get-SvgText $left ($y + 11) $g.label $(if ($Compact) { 11 } else { 12 }) 'start' '600'
            if ($g.note) { $rows += Get-SvgText $x1 ($y + 11) $g.note 11 'end' 'normal' '#4B5563' }
            $y += $(if ($Compact) { 15 } else { 18 })
            $spanTop = $y - 2
            if (@($g.bars).Count -eq 0 -and $g.na) {
                $rows += Get-SvgText $x0 ($y + 10) $g.na 11 'start' 'normal' '#6B7280'
                $y += 16
            }
            foreach ($b in @($g.bars)) {
                $rows += Get-SvgText ($x0 - 6) ($y + $barH - 2) (Get-EngineName $b.engine) $(if ($Compact) { 10 } else { 11 }) 'end'
                $opacity = if ($b.excluded) { '0.45' } else { '1' }
                if ($b.capped) {
                    $rows += ('<rect x="{0}" y="{1}" width="{2}" height="{3}" fill="url(#capHatch)" stroke="{4}" stroke-width="1.5"><title>{5}</title></rect>' -f $x0, $y, (Get-Round $plotW 1), $barH, (Get-EngineColor $b.engine), (ConvertTo-XmlText $b.tooltip)) + "`n"
                    $rows += Get-SvgText ($x1 + 6) ($y + $barH - 2) $b.endLabel $(if ($Compact) { 10 } else { 11 })
                }
                elseif ($null -ne $b.rel) {
                    $bx = & $sx $b.rel
                    $rows += ('<rect x="{0}" y="{1}" width="{2}" height="{3}" fill="{4}" fill-opacity="{5}"><title>{6}</title></rect>' -f $x0, $y, (Get-Round ([Math]::Max(2, $bx - $x0)) 1), $barH, (Get-EngineColor $b.engine), $opacity, (ConvertTo-XmlText $b.tooltip)) + "`n"
                    if ($null -ne $b.relMin -and $null -ne $b.relMax -and $b.relMax -gt $b.relMin) {
                        $wx0 = & $sx $b.relMin; $wx1 = & $sx $b.relMax; $cy = $y + $barH / 2
                        $rows += ('<line x1="{0}" y1="{2}" x2="{1}" y2="{2}" stroke="#111827" stroke-width="1"/>' -f (Get-Round $wx0 1), (Get-Round $wx1 1), (Get-Round $cy 1)) + "`n"
                        $rows += ('<line x1="{0}" y1="{1}" x2="{0}" y2="{2}" stroke="#111827" stroke-width="1"/>' -f (Get-Round $wx0 1), (Get-Round ($cy - 3) 1), (Get-Round ($cy + 3) 1)) + "`n"
                        $rows += ('<line x1="{0}" y1="{1}" x2="{0}" y2="{2}" stroke="#111827" stroke-width="1"/>' -f (Get-Round $wx1 1), (Get-Round ($cy - 3) 1), (Get-Round ($cy + 3) 1)) + "`n"
                    }
                    $lx = [Math]::Max($bx, $(if ($null -ne $b.relMax) { & $sx $b.relMax } else { $bx })) + 6
                    $rows += Get-SvgText $lx ($y + $barH - 2) $b.endLabel $(if ($Compact) { 10 } else { 11 })
                }
                $y += $barH + $barGap
            }
            if (@($g.bars).Count -gt 0) { $spans += , @($spanTop, ($y - $barGap + 2)) }
            $y += $(if ($Compact) { 6 } else { 10 })
        }
        # grid and axis for this section: tick labels on top, grid lines only behind the bars (never through test names)
        $grid = ''
        foreach ($t in $ticks) {
            $tx = & $sx $t
            $stroke = if ([Math]::Abs($t - 1.0) -lt 1e-9) { '#374151' } else { '#E5E7EB' }
            $dash = if ([Math]::Abs($t - 1.0) -lt 1e-9) { ' stroke-dasharray="4 3"' } else { '' }
            foreach ($sp in $spans) {
                $grid += ('<line x1="{0}" y1="{1}" x2="{0}" y2="{2}" stroke="{3}" stroke-width="1"{4}/>' -f (Get-Round $tx 1), (Get-Round $sp[0] 1), (Get-Round $sp[1] 1), $stroke, $dash) + "`n"
            }
            $grid += Get-SvgText $tx ($top + 0) ($t.ToString('0.##', $script:Inv) + $script:TIMES) 10 'middle' 'normal' '#4B5563'
        }
        $body += $grid + $rows
    }
    $y += 6
    $body += Get-SvgText $left ($y + 4) ("Time relative to the fastest engine on each test (1.00$($script:TIMES) = fastest; lower is better). Whiskers: min" + $script:NDASH + "max of the runs. " + $script:APPROX + ' = tied with the fastest; ' + $script:GE + ' = over the time limit.') 11 'start' 'normal' '#4B5563'
    $y += 20
    return (New-SvgDocument $Width ([int]$y) $Title $body)
}

function New-ScalingChart {
    # Orders per minute against clerks working non-stop (1, 4, 8, 16 on an ordinal axis), spread solid, hot item dashed.
    param($Scaling, [int]$Width = 960)
    $left = 70; $plotW = 500; $top = 112; $plotH = 300
    $xs = @(1, 4, 8, 16)
    $maxY = 1.0
    foreach ($series in @($Scaling)) { foreach ($pt in @($series.points)) { if ($pt.max) { $maxY = [Math]::Max($maxY, [double]$pt.max) } elseif ($pt.median) { $maxY = [Math]::Max($maxY, [double]$pt.median) } } }
    $mag = [Math]::Pow(10, [Math]::Floor([Math]::Log10($maxY)))
    $nice = $mag; foreach ($f in @(1, 2, 2.5, 5, 10)) { if ($f * $mag -ge $maxY * 1.08) { $nice = $f * $mag; break } }
    $sx = { param($u) $i = [array]::IndexOf($xs, [int]$u); $left + 40 + $i * (($plotW - 80) / 3.0) }
    $sy = { param($v) $top + $plotH - ([double]$v / $nice) * $plotH }
    $body = ''
    $body += Get-SvgText 16 30 'Orders per minute with more clerks working non-stop' 18 'start' '600'
    $body += Get-SvgText 16 50 ('Solid lines: different products (spread). Dashed lines and squares: everyone sells the best-seller (hot item).') 12 'start' 'normal' '#4B5563'
    $body += Get-SvgText 16 66 ('Whiskers: min' + $script:NDASH + 'max of the runs. Higher is better. The 1-clerk point uses the same wall-clock basis as the others.') 12 'start' 'normal' '#4B5563'
    $body += Get-SvgLegend 16 92
    for ($k = 0; $k -le 5; $k++) {
        $v = $nice * $k / 5; $yy = & $sy $v
        $body += ('<line x1="{0}" y1="{1}" x2="{2}" y2="{1}" stroke="#E5E7EB" stroke-width="1"/>' -f $left, (Get-Round $yy 1), ($left + $plotW)) + "`n"
        $body += Get-SvgText ($left - 6) ($yy + 4) (Format-Sig3 $v) 10 'end' 'normal' '#4B5563'
    }
    foreach ($u in $xs) { $xx = & $sx $u; $body += Get-SvgText $xx ($top + $plotH + 18) ([string]$u) 11 'middle'; }
    $body += Get-SvgText ($left + $plotW / 2) ($top + $plotH + 36) 'clerks working non-stop' 11 'middle' 'normal' '#4B5563'
    $body += ('<line x1="{0}" y1="{1}" x2="{0}" y2="{2}" stroke="#9CA3AF"/>' -f $left, $top, ($top + $plotH)) + "`n"
    $body += ('<line x1="{0}" y1="{1}" x2="{2}" y2="{1}" stroke="#9CA3AF"/>' -f $left, ($top + $plotH), ($left + $plotW)) + "`n"
    $endLabels = @()
    foreach ($series in @($Scaling)) {
        $pts = @($series.points | Where-Object { $null -ne $_.median } | Sort-Object { [int]$_.users })
        if ($pts.Count -eq 0) { continue }
        $color = Get-EngineColor $series.engine
        $dash = if ($series.variant -eq 'hot') { ' stroke-dasharray="6 4"' } else { '' }
        $d = ($pts | ForEach-Object { '{0},{1}' -f (Get-Round (& $sx $_.users) 1), (Get-Round (& $sy $_.median) 1) }) -join ' '
        if ($pts.Count -gt 1) { $body += ('<polyline points="{0}" fill="none" stroke="{1}" stroke-width="2.5"{2}/>' -f $d, $color, $dash) + "`n" }
        foreach ($pt in $pts) {
            $cx = & $sx $pt.users; $cy = & $sy $pt.median
            if ($null -ne $pt.min -and $null -ne $pt.max) {
                $body += ('<line x1="{0}" y1="{1}" x2="{0}" y2="{2}" stroke="{3}" stroke-width="1.5"/>' -f (Get-Round $cx 1), (Get-Round (& $sy $pt.min) 1), (Get-Round (& $sy $pt.max) 1), $color) + "`n"
            }
            $tip = ConvertTo-XmlText ('{0}, {1} clerks, {2}: {3} orders/min (min {4}, max {5})' -f (Get-EngineName $series.engine), $pt.users, $series.variant, (Format-Sig3 $pt.median), (Format-Sig3 $pt.min), (Format-Sig3 $pt.max))
            if ($series.variant -eq 'hot') {
                $shape = '<rect x="{0}" y="{1}" width="8" height="8" fill="#ffffff" stroke="{2}" stroke-width="2"><title>{3}</title></rect>' -f (Get-Round ($cx - 4) 1), (Get-Round ($cy - 4) 1), $color, $tip
            }
            else {
                $shape = '<circle cx="{0}" cy="{1}" r="4.5" fill="{2}"><title>{3}</title></circle>' -f (Get-Round $cx 1), (Get-Round $cy 1), $color, $tip
            }
            $body += $shape + "`n"
        }
        $last = $pts[-1]
        $endLabels += [pscustomobject]@{ x = ((& $sx $last.users) + 8); y = ((& $sy $last.median) + 4); text = ((Get-EngineName $series.engine) + $(if ($series.variant -eq 'hot') { ' (hot item)' } else { '' })); color = $color }
    }
    # end labels: keep at least 12 px apart so engine names never overlap
    foreach ($grp in @($endLabels | Group-Object { [int]$_.x })) {
        $prevY = -1000.0
        foreach ($lab in @($grp.Group | Sort-Object y)) {
            if ($lab.y - $prevY -lt 12) { $lab.y = $prevY + 12 }
            $prevY = $lab.y
            $body += Get-SvgText $lab.x $lab.y $lab.text 10 'start' 'normal' $lab.color
        }
    }
    # p95 table
    $tx = $left + $plotW + 60; $ty = $top + 4
    $body += Get-SvgText $tx $ty 'p95 ms per order' 12 'start' '600'
    $ty += 15
    $body += Get-SvgText $tx $ty '(95% of saves were at least this fast)' 11 'start' 'normal' '#4B5563'
    $ty += 20
    $body += Get-SvgText $tx $ty 'clerks' 11 'start' '600'
    $cx = $tx + 70
    foreach ($e in $script:EngineOrder) { $body += Get-SvgText $cx $ty (Get-EngineName $e) 11 'start' '600' (Get-EngineColor $e); $cx += 72 }
    foreach ($variant in @('spread', 'hot')) {
        foreach ($u in $xs) {
            $vals = @()
            foreach ($e in $script:EngineOrder) {
                $s = @($Scaling | Where-Object { $_.engine -eq $e -and $_.variant -eq $variant })[0]
                $pt = if ($s) { @($s.points | Where-Object { [int]$_.users -eq $u })[0] } else { $null }
                $vals += $(if ($pt -and $pt.p95Ms) { Format-Sig3 $pt.p95Ms } else { $null })
            }
            if (@($vals | Where-Object { $null -ne $_ }).Count -eq 0) { continue }
            $ty += 18
            $body += Get-SvgText $tx $ty ([string]$u + $(if ($variant -eq 'hot') { ' (hot item)' } else { '' })) 11
            $cx = $tx + 70
            foreach ($val in $vals) { $body += Get-SvgText $cx $ty $(if ($null -ne $val) { $val } else { $script:NDASH }) 11; $cx += 72 }
        }
    }
    $height = [Math]::Max($top + $plotH + 56, $ty + 30)
    return (New-SvgDocument $Width ([int]$height) 'Orders per minute with more clerks working non-stop' $body)
}

function New-SpeedupChart {
    # 1-worker -> 8-worker speed-up per platform-basics operation and engine (m(1U) / m(8U)).
    param($Speedups, [int]$Width = 960)
    $ops = @($Speedups | ForEach-Object { $_.operation } | Select-Object -Unique)
    $maxS = 8.0
    foreach ($s in @($Speedups)) { if ($s.speedup -and -not (Test-Inf $s.speedup)) { $maxS = [Math]::Max($maxS, [double]$s.speedup) } }
    $axisMax = [Math]::Ceiling($maxS)
    $left = 16; $labelW = 200; $engineW = 92; $x0 = $left + $labelW + $engineW; $x1 = $Width - 100; $plotW = $x1 - $x0
    $sx = { param($v) $x0 + ([Math]::Min([double]$v, $axisMax) / $axisMax) * $plotW }
    $body = ''
    $body += Get-SvgText 16 30 ('Speed-up from 1 worker to 8 parallel workers (same 10,000-record job or 80-page list)') 18 'start' '600'
    $body += Get-SvgText 16 50 ('Speed-up = median time with 1 worker / median time with 8 workers. 1' + $script:TIMES + ' = no gain; 8' + $script:TIMES + ' = perfect scaling. Higher is better.') 12 'start' 'normal' '#4B5563'
    $body += Get-SvgLegend 16 74
    $y = 96
    $top = $y
    $rows = ''
    foreach ($op in $ops) {
        $rows += Get-SvgText $left ($y + 12) $op 12 'start' '600'
        foreach ($e in $script:EngineOrder) {
            $s = @($Speedups | Where-Object { $_.operation -eq $op -and $_.engine -eq $e })[0]
            $rows += Get-SvgText ($x0 - 6) ($y + 12) (Get-EngineName $e) 11 'end'
            if ($s -and $null -ne $s.speedup -and -not (Test-Inf $s.speedup)) {
                $bx = & $sx $s.speedup
                $rows += ('<rect x="{0}" y="{1}" width="{2}" height="14" fill="{3}"><title>{4}</title></rect>' -f $x0, $y, (Get-Round ([Math]::Max(1, $bx - $x0)) 1), (Get-EngineColor $e), (ConvertTo-XmlText ('{0} {1}: {2}' -f (Get-EngineName $e), $op, (Format-Ratio $s.speedup)))) + "`n"
                $rows += Get-SvgText ($bx + 6) ($y + 12) (Format-Ratio $s.speedup) 11
            }
            else { $rows += Get-SvgText ($x0 + 4) ($y + 12) 'n/a' 11 'start' 'normal' '#6B7280' }
            $y += 18
        }
        $y += 10
    }
    $grid = ''
    for ($t = 0; $t -le $axisMax; $t++) {
        $tx = & $sx $t
        $stroke = if ($t -eq 1 -or $t -eq 8) { '#374151' } else { '#E5E7EB' }
        $dash = if ($t -eq 1 -or $t -eq 8) { ' stroke-dasharray="4 3"' } else { '' }
        $grid += ('<line x1="{0}" y1="{1}" x2="{0}" y2="{2}" stroke="{3}"{4}/>' -f (Get-Round $tx 1), ($top - 4), ($y - 6), $stroke, $dash) + "`n"
        $grid += Get-SvgText $tx ($top - 8) ([string]$t + $script:TIMES) 10 'middle' 'normal' '#4B5563'
    }
    $body += $grid + $rows
    return (New-SvgDocument $Width ([int]($y + 10)) 'Speed-up from 1 worker to 8 parallel workers' $body)
}

#endregion

#region ---------------------------------------------------------------- Markdown to HTML (for the self-contained report)

function Convert-InlineMd {
    param([string]$Text)
    $t = ConvertTo-XmlText $Text
    $t = [regex]::Replace($t, '\*\*(.+?)\*\*', '<b>$1</b>')
    $t = [regex]::Replace($t, '`([^`]+)`', '<code>$1</code>')
    $t = [regex]::Replace($t, '\[([^\]]+)\]\(([^)]+)\)', '<a href="$2">$1</a>')
    $t = [regex]::Replace($t, '(?<![\w*])\*([^*\s][^*]*?)\*(?![\w*])', '<i>$1</i>')
    $t = $t.Replace('&lt;br&gt;', '<br>')
    return $t
}

function Convert-MarkdownToHtml {
    # Converts the Markdown this script generates (headings, paragraphs, lists, tables, quotes, images).
    param([string]$Markdown, [hashtable]$InlineSvg)
    $out = New-Object System.Text.StringBuilder
    $lines = $Markdown -split "`n"
    $i = 0
    $para = New-Object System.Collections.ArrayList
    $flush = {
        if ($para.Count -gt 0) { [void]$out.AppendLine('<p>' + (Convert-InlineMd (($para -join ' ').Trim())) + '</p>'); $para.Clear() }
    }
    while ($i -lt $lines.Count) {
        $line = $lines[$i].TrimEnd("`r")
        if ($line -match '^\s*$') { & $flush; $i++; continue }
        if ($line -match '^<!--') { & $flush; while ($i -lt $lines.Count -and $lines[$i] -notmatch '-->') { $i++ }; $i++; continue }
        if ($line -match '^(#{1,6})\s+(.*)$') {
            & $flush
            $lvl = $Matches[1].Length; $txt = $Matches[2]
            $id = ($txt.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
            [void]$out.AppendLine(('<h{0} id="{1}">{2}</h{0}>' -f $lvl, $id, (Convert-InlineMd $txt)))
            $i++; continue
        }
        if ($line -match '^!\[([^\]]*)\]\(([^)]+)\)\s*$') {
            & $flush
            $alt = $Matches[1]; $src = $Matches[2]
            $file = [IO.Path]::GetFileName($src)
            if ($InlineSvg -and $InlineSvg.ContainsKey($file)) { [void]$out.AppendLine('<figure class="chart">' + $InlineSvg[$file] + '</figure>') }
            else { [void]$out.AppendLine(('<p><img src="{0}" alt="{1}"></p>' -f (ConvertTo-XmlText $src), (ConvertTo-XmlText $alt))) }
            $i++; continue
        }
        if ($line -match '^>\s?(.*)$') {
            & $flush
            $q = @()
            while ($i -lt $lines.Count -and $lines[$i].TrimEnd("`r") -match '^>\s?(.*)$') { $q += $Matches[1]; $i++ }
            [void]$out.AppendLine('<blockquote><p>' + (Convert-InlineMd (($q -join ' ').Trim())) + '</p></blockquote>')
            continue
        }
        if ($line -match '^\s*[-*]\s+(.*)$') {
            & $flush
            [void]$out.AppendLine('<ul>')
            while ($i -lt $lines.Count -and $lines[$i].TrimEnd("`r") -match '^\s*[-*]\s+(.*)$') { [void]$out.AppendLine('<li>' + (Convert-InlineMd $Matches[1]) + '</li>'); $i++ }
            [void]$out.AppendLine('</ul>')
            continue
        }
        if ($line -match '^\|') {
            & $flush
            $rows = @()
            while ($i -lt $lines.Count -and $lines[$i].TrimEnd("`r") -match '^\|') { $rows += $lines[$i].TrimEnd("`r"); $i++ }
            [void]$out.AppendLine('<table>')
            $r = 0
            foreach ($row in $rows) {
                $cells = @(($row.Trim().Trim('|')) -split '(?<!\\)\|' | ForEach-Object { $_.Trim().Replace('\|', '|') })
                if ($r -eq 1 -and $row -match '^\|[\s:|-]+\|?$') { $r++; continue }
                $tag = if ($r -eq 0) { 'th' } else { 'td' }
                [void]$out.AppendLine('<tr>' + (($cells | ForEach-Object { "<$tag>" + (Convert-InlineMd $_) + "</$tag>" }) -join '') + '</tr>')
                $r++
            }
            [void]$out.AppendLine('</table>')
            continue
        }
        [void]$para.Add($line)
        $i++
    }
    & $flush
    return $out.ToString()
}

function Get-MdCell {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.Replace('|', '\|').Replace("`n", ' ')
}

#endregion

#region ---------------------------------------------------------------- self-test (SPEC 7.2.4)

function Invoke-SelfTest {
    $fails = 0
    $rows = @()
    $check = {
        param([string]$Id, [string]$What, [bool]$Ok, [string]$Detail)
        $script:selfRows += [pscustomobject]@{ Id = $Id; Ok = $(if ($Ok) { 'PASS' } else { 'FAIL' }); Check = $What; Detail = $Detail }
        if (-not $Ok) { $script:selfFails++ }
    }
    $script:selfRows = @(); $script:selfFails = 0
    $inf = $script:PosInf
    $base = [double[]]@(100, 101, 99, 100, 102, 98)
    $ops = { param([double[]]$v) [double[]]@($v | ForEach-Object { Get-TimePerUnit $_ $true $false }) }

    $p = Compare-PerfPair -A $base -B ([double[]]@(120, 118, 122, 119, 121, 120))
    & $check 'V1' 'A faster (gap 20.0% after rounding, U = 0)' ($p.faster -eq 'A' -and $p.statLabel -eq 'faster' -and $p.gap -eq 0.2 -and $p.u -eq 0) ("label={0} gap={1} U={2}" -f $p.statLabel, $p.gap, $p.u)

    $p = Compare-PerfPair -A $base -B ([double[]]@(103, 99, 104, 101, 102, 100))
    & $check 'V2' 'tie (gap 1.5% < 5%)' ($p.statLabel -eq 'tie' -and [Math]::Abs($p.gapPct - 1.5) -lt 1e-9) ("label={0} gapPct={1}" -f $p.statLabel, $p.gapPct)

    $p = Compare-PerfPair -A $base -B ([double[]]@(160, 158, 162, 159, 161, 160))
    & $check 'V3' 'A much faster (1.6x)' ($p.faster -eq 'A' -and $p.statLabel -eq 'much faster' -and $p.gap -eq 0.6) ("label={0} ratio={1}" -f $p.statLabel, (1 + $p.gap))

    $p = Compare-PerfPair -A ([double[]]@(100, 130, 80, 110, 95, 120)) -B ([double[]]@(112, 140, 90, 125, 100, 135))
    & $check 'V4' 'tie (gap 12.9% < T = 2 x max(CV_A 17.6%, CV_B 21.9%) = 43.8%)' ($p.statLabel -eq 'tie' -and [Math]::Abs($p.gapPct - 12.8571) -lt 0.001 -and [Math]::Abs($p.cvFastPct - 17.65) -lt 0.05 -and [Math]::Abs($p.cvSlowPct - 21.89) -lt 0.05 -and [Math]::Abs($p.thresholdPct - 43.79) -lt 0.05) ("label={0} gapPct={1} CV_A={2} CV_B={3} T={4}" -f $p.statLabel, $p.gapPct, $p.cvFastPct, $p.cvSlowPct, $p.thresholdPct)

    $p = Compare-PerfPair -A ([double[]]@(100, 100, 100, 100, 100, 130)) -B ([double[]]@(108, 108, 108, 108, 108, 90))
    & $check 'V5' 'tie (gap 8% >= 5%, but U = 11 > 5)' ($p.statLabel -eq 'tie' -and $p.u -eq 11 -and $p.uMax -eq 5 -and $p.gap -eq 0.08) ("label={0} gap={1} U={2} Umax={3}" -f $p.statLabel, $p.gap, $p.u, $p.uMax)

    $p = Compare-PerfPair -A (& $ops ([double[]]@(600, 600, 600, 600, 600, 600))) -B (& $ops ([double[]]@(500, 500, 500, 500, 500, 500)))
    & $check 'V6' 'OpsPerMin 600 vs 500: A faster (100 vs 120 ms; gap 20.0%)' ($p.faster -eq 'A' -and $p.statLabel -eq 'faster' -and $p.gap -eq 0.2 -and [Math]::Abs($p.mFast - 100) -lt 1e-9 -and [Math]::Abs($p.mSlow - 120) -lt 1e-9) ("label={0} mA={1} mB={2} gap={3}" -f $p.statLabel, $p.mFast, $p.mSlow, $p.gap)

    $p = Compare-PerfPair -A ([double[]]@(100, 100, 100, 100)) -B ([double[]]@(160, 160, 160, 160, 160, 160))
    & $check 'V7' 'A (n = 4) much faster (ratio >= 1.5, U = 0)' ($p.faster -eq 'A' -and $p.statLabel -eq 'much faster' -and $p.u -eq 0) ("label={0} nA={1}" -f $p.statLabel, $p.nFast)

    $p = Compare-PerfPair -A ([double[]]@(100, 100, 100, 100)) -B ([double[]]@(120, 120, 120, 120, 120, 120))
    & $check 'V8' 'A (n = 4) vs 120 x6: inconclusive' ($p.statLabel -eq 'inconclusive' -and $p.practical -eq 'tie') ("label={0}" -f $p.statLabel)

    $p = Compare-PerfPair -A $base -B ([double[]]@(110, 109, 111, 110, 112, 108))
    & $check 'V9' 'A slightly faster (gap 10%, T = 5%, U = 0)' ($p.faster -eq 'A' -and $p.statLabel -eq 'slightly faster' -and $p.gap -eq 0.1 -and $p.thresholdPct -eq 5 -and $p.u -eq 0) ("label={0} gap={1} T={2} U={3}" -f $p.statLabel, $p.gap, $p.thresholdPct, $p.u)

    $p = Compare-PerfPair -A ([double[]]@(40, 40.5, 39.5, 40, 41, 39)) -B ([double[]]@(46, 46.5, 45.5, 46, 47, 45)) -Floor (Get-FloorSpec 'Screens' 1)
    & $check 'V10' 'Screens: A slightly faster, not noticeable (6 ms < 100 ms); a tie in tiers' ($p.statLabel -eq 'slightly faster' -and -not $p.noticeable -and $p.practical -eq 'tie' -and [Math]::Abs($p.absDiffMsPerUnit - 6) -lt 1e-9) ("label={0} noticeable={1} practical={2} diff={3}" -f $p.label, $p.noticeable, $p.practical, $p.absDiffMsPerUnit)

    $b11 = [double[]]@(150, 150, 150, 150, $inf, $inf)
    $cap11 = (@($b11 | Where-Object { Test-Inf $_ }).Count -ge $TieRule.cappedCellShare * $b11.Count)
    $p = Compare-PerfPair -A ([double[]]@(100, 100, 100, 100, 100, 100)) -B $b11 -CappedCellB $cap11
    & $check 'V11' 'A much faster (B median 150, ratio 1.5, U = 0); B is not a Capped cell' ($p.faster -eq 'A' -and $p.statLabel -eq 'much faster' -and $p.mSlow -eq 150 -and $p.u -eq 0 -and -not $cap11) ("label={0} mB={1} U={2} cappedCell={3}" -f $p.statLabel, $p.mSlow, $p.u, $cap11)

    $b12 = [double[]]@(150, 150, 150, $inf, $inf, $inf)
    $cap12 = (@($b12 | Where-Object { Test-Inf $_ }).Count -ge $TieRule.cappedCellShare * $b12.Count)
    $a12 = [double[]]@(100, 100, 100, 100, 100, 100)
    $p = Compare-PerfPair -A $a12 -B $b12 -CappedCellB $cap12
    $cells = @([pscustomobject]@{ engine = 'A'; median = (Get-Median $a12); cappedCell = $false }, [pscustomobject]@{ engine = 'B'; median = (Get-Median $b12); cappedCell = $cap12 })
    $tiers = Get-Tiers $cells @{ 'A|B' = $p; 'B|A' = $p }
    $lastTier = @($tiers.tiers[-1])
    & $check 'V12' 'B is a Capped cell (over the time limit, last tier); A much faster' ($cap12 -and $p.faster -eq 'A' -and $p.statLabel -eq 'much faster' -and (Test-Inf $p.mSlow) -and $lastTier.Count -eq 1 -and $lastTier[0] -eq 'B' -and $tiers.tiers.Count -eq 2) ("label={0} cappedCell={1} tiers={2}" -f $p.statLabel, $cap12, (($tiers.tiers | ForEach-Object { '[' + (@($_) -join ',') + ']' }) -join ' '))

    # helper checks
    $st = Get-SignTest @(1, 1, 1, 1, 1, 1) @(2, 2, 2, 2, 2, 2)
    & $check 'H1' 'sign test: 6 of 6 gives two-sided p = 0.031' ($st.wins -eq 6 -and [Math]::Abs($st.pTwoSided - 0.0313) -lt 0.0001) ("p={0}" -f $st.pTwoSided)
    $um = @([Math]::Floor($TieRule.maxUShare * 36), [Math]::Floor($TieRule.maxUShare * 30), [Math]::Floor($TieRule.maxUShare * 25))
    & $check 'H2' 'U thresholds: 5 (6v6), 4 (5v6), 3 (5v5)' ($um[0] -eq 5 -and $um[1] -eq 4 -and $um[2] -eq 3) ($um -join ',')
    $fm = @((Format-Sig3 41.234), (Format-Sig3 1234), (Format-Sig3 0.81234), (Format-Sig3 46), (Format-Ratio 1.18))
    & $check 'H3' 'number format: 3 significant digits; ratios as 1.18x' ($fm[0] -eq '41.2' -and $fm[1] -eq '1,230' -and $fm[2] -eq '0.812' -and $fm[3] -eq '46' -and $fm[4] -eq ('1.18' + $script:TIMES)) ($fm -join ' | ')
    $tri = @{}
    $pa = Compare-PerfPair -A ([double[]]@(100, 101, 99, 100, 102, 98)) -B ([double[]]@(103, 104, 102, 103, 105, 101)) -NameA 'A' -NameB 'B'
    $pb = Compare-PerfPair -A ([double[]]@(103, 104, 102, 103, 105, 101)) -B ([double[]]@(107, 108, 106, 107, 109, 105)) -NameA 'B' -NameB 'C'
    $pc = Compare-PerfPair -A ([double[]]@(100, 101, 99, 100, 102, 98)) -B ([double[]]@(107, 108, 106, 107, 109, 105)) -NameA 'A' -NameB 'C'
    foreach ($q in @($pa, $pb, $pc)) { $tri[$q.faster + '|' + $q.slower] = $q; $tri[$q.slower + '|' + $q.faster] = $q }
    $cells = @([pscustomobject]@{ engine = 'A'; median = 100.0; cappedCell = $false }, [pscustomobject]@{ engine = 'B'; median = 103.0; cappedCell = $false }, [pscustomobject]@{ engine = 'C'; median = 107.0; cappedCell = $false })
    $tt = Get-Tiers $cells $tri
    & $check 'H4' 'non-transitive verdicts are reported (A~B, B~C, A faster than C)' ($tt.tiers.Count -eq 2 -and @($tt.tiers[0]).Count -eq 2 -and @($tt.notes).Count -eq 1) ((($tt.tiers | ForEach-Object { '[' + (@($_) -join ',') + ']' }) -join ' ') + ' ' + (@($tt.notes) -join ' '))

    $script:selfRows | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
    if ($script:selfFails -gt 0) { Write-Host ("SELF-TEST FAILED: {0} check(s) failed." -f $script:selfFails) -ForegroundColor Red; return $false }
    Write-Host ("SELF-TEST PASSED: {0} checks (V1-V12 of SPEC 7.2.4 plus helpers)." -f $script:selfRows.Count) -ForegroundColor Green
    return $true
}

#endregion

#region ---------------------------------------------------------------- analysis

function Invoke-Analysis {
    param($Data)
    $notes = New-Object System.Collections.ArrayList
    foreach ($w in $Data.warnings) { [void]$notes.Add($w) }

    # engines and instances
    $instanceEngines = @{}
    foreach ($k in $Data.instances.Keys) { $instanceEngines[$k] = Resolve-Engine ([string](Get-Field $Data.instances[$k] 'dbEngine')) $k }
    $Data['instanceEngines'] = $instanceEngines
    $runs = @($Data.runs | ForEach-Object { New-RunModel $_ $instanceEngines })
    $engines = @($script:EngineOrder | Where-Object { $e = $_; ($instanceEngines.Values -contains $e) -or (@($runs | Where-Object { $_.engine -eq $e }).Count -gt 0) })
    $nSlots = [int](ConvertTo-Num (Get-Field $Data.meta 'repetitions')); if ($nSlots -lt 1) { $nSlots = 6 }

    # test catalog (+ codes that appear only in runs)
    $tests = [ordered]@{}
    foreach ($code in $Data.tests.Keys) { $tests[$code] = New-TestModel $Data.tests[$code] $code }
    foreach ($r in $runs) {
        if ($r.testCode -and -not $tests.Contains($r.testCode)) {
            [void]$notes.Add("Test $($r.testCode) is not in the catalog of the campaign JSON; a minimal descriptor was built from its runs.")
            $tests[$r.testCode] = New-TestModel ([ordered]@{ TestCode = $r.testCode; DisplayName = $r.testCode; Family = $r.family; UserCount = (Get-Field $r.raw 'userCount'); HigherIsBetter = (Get-Field $r.raw 'higherIsBetter'); HeadlineKind = $(if (ConvertTo-Flag (Get-Field $r.raw 'higherIsBetter')) { 'OpsPerMin' } else { 'MedianOpMs' }); SortOrder = 999 }) $r.testCode
        }
    }
    $compTests = @($tests.Values | Where-Object { -not $_.excludeFromComparison } | Where-Object { $code = $_.code; @($runs | Where-Object { $_.testCode -eq $code }).Count -gt 0 } | Sort-Object sortOrder, code)

    # several campaigns: each test must come from one campaign (Block D may come from another night)
    if (@($Data.campaignIds).Count -gt 1) {
        foreach ($t in $compTests) {
            $code = $t.code
            $byCamp = @($runs | Where-Object { $_.testCode -eq $code } | Group-Object campaignId)
            if ($byCamp.Count -gt 1) {
                $keep = ($byCamp | Sort-Object { @($_.Group | Where-Object { $_.valid }).Count } -Descending | Select-Object -First 1).Name
                [void]$notes.Add("Test $code has runs in several campaigns; campaign $keep is used.")
                $runs = @($runs | Where-Object { $_.testCode -ne $code -or $_.campaignId -eq $keep })
            }
        }
    }

    $gateReasons = Get-EnvGateReasons $Data $notes

    # cells and verdicts
    $cellsByTest = [ordered]@{}; $verdicts = [ordered]@{}; $specs = @{}
    foreach ($t in $compTests) {
        $code = $t.code
        $tRuns = @($runs | Where-Object { $_.testCode -eq $code -and -not $_.isWarmup -and $_.rep -ge 1 })
        $cells = @()
        foreach ($e in $engines) { $cells += (New-Cell $t $e @($tRuns | Where-Object { $_.engine -eq $e }) $nSlots) }
        $finiteMedians = @($cells | Where-Object { $null -ne $_.median -and -not (Test-Inf $_.median) } | ForEach-Object { [double]$_.median })
        $fastest = if ($finiteMedians.Count) { [double]($finiteMedians | Measure-Object -Minimum).Minimum } else { $null }
        foreach ($c in $cells) { if ($fastest -and $null -ne $c.median) { $c.relToFastest = $c.median / $fastest } }
        $cellsByTest[$code] = $cells
        $verdicts[$code] = Get-TestVerdict $t $cells $engines $gateReasons
        $specs[$code] = Get-DisplaySpec $t $cells
    }

    # headline sentences
    foreach ($t in $compTests) {
        $by = @{}; foreach ($c in $cellsByTest[$t.code]) { $by[$c.engine] = $c }
        $v = $verdicts[$t.code]
        $v.sentenceMd = Get-VerdictText $t $v $by $specs[$t.code] $true
        $v.headline = Get-VerdictText $t $v $by $specs[$t.code] $false
    }

    # families
    $families = [ordered]@{}
    foreach ($f in @($script:FamilyOrder + @($compTests | ForEach-Object { $_.family } | Where-Object { $script:FamilyOrder -notcontains $_ } | Select-Object -Unique))) {
        $ft = @($compTests | Where-Object { $_.family -eq $f })
        if ($ft.Count -eq 0) { continue }
        $info = $script:FamilyInfo[$f]
        $fam = [ordered]@{ family = $f; displayName = $(if ($info) { $info.display } else { $f }); label = $(if ($info) { $info.label } else { '' })
            index = [ordered]@{}; indexTests = @(); excludedTests = @(); leader = 'none'; cell = [ordered]@{}; tier1Share = [ordered]@{}; dbCpuShare = [ordered]@{}; muchSlower = [ordered]@{}; comparableTests = @() }
        $comparable = @($ft | Where-Object { $verdicts[$_.code].comparable -and -not $verdicts[$_.code].resultsDiffer })
        $fam.comparableTests = @($comparable | ForEach-Object { $_.code })
        foreach ($t in $ft) {
            $v = $verdicts[$t.code]
            $why = $null
            if (-not $v.comparable) { $why = 'not comparable' }
            elseif ($v.resultsDiffer) { $why = 'results differ' }
            elseif (@($v.excludedEngines).Count -gt 0) { $why = (@($v.excludedEngines | ForEach-Object { $(if ($_.why -eq 'errors') { 'failed saves' } else { $_.why }) + ' (' + (Get-EngineName $_.engine) + ')' }) -join '; ') }
            elseif (@($v.cappedEngines).Count -gt 0) { $why = 'capped on ' + (Join-EngineNames @($v.cappedEngines)) }
            if ($why) { $fam.excludedTests += [ordered]@{ testCode = $t.code; displayName = $t.displayName; why = $why } } else { $fam.indexTests += $t.code }
        }
        foreach ($e in $engines) {
            $ratios = @()
            foreach ($code in $fam.indexTests) {
                $c = @($cellsByTest[$code] | Where-Object { $_.engine -eq $e })[0]
                if ($c -and $c.relToFastest) { $ratios += [double]$c.relToFastest }
            }
            $fam.index[$e] = $(if ($ratios.Count) { [Math]::Exp((($ratios | ForEach-Object { [Math]::Log($_) }) | Measure-Object -Sum).Sum / $ratios.Count) } else { $null })
            $inT1 = 0; $muchSlower = $false
            foreach ($t in $comparable) {
                $v = $verdicts[$t.code]
                if (@($v.tiers).Count -gt 0 -and (@($v.tiers[0]) -contains $e)) { $inT1++ }
                foreach ($p in @($v.pairs)) { if ($p.slower -eq $e -and $p.practical -eq 'much faster') { $muchSlower = $true } }
            }
            $share = if ($comparable.Count) { $inT1 / $comparable.Count } else { $null }
            $fam.tier1Share[$e] = $share
            $fam.muchSlower[$e] = $muchSlower
            # database share of CPU over the family's analysis-set runs
            $db = 0.0; $app = 0.0
            foreach ($t in $ft) { foreach ($c in @($cellsByTest[$t.code] | Where-Object { $_.engine -eq $e })) { foreach ($r in $c.selectedRuns) { $cpu = Get-RunCpu $r; if ($cpu -and $null -ne $cpu.dbCpuMs -and $null -ne $cpu.appCpuMs) { $db += $cpu.dbCpuMs; $app += $cpu.appCpuMs } } } }
            $fam.dbCpuShare[$e] = $(if (($db + $app) -gt 0) { $db / ($db + $app) } else { $null })
        }
        $leaders = @($engines | Where-Object { $null -ne $fam.tier1Share[$_] -and (100.0 * $fam.tier1Share[$_]) -ge $TieRule.leadTier1SharePct -and -not $fam.muchSlower[$_] })
        if ($leaders.Count -eq 1) { $fam.leader = $leaders[0] }
        foreach ($e in $engines) {
            if ($fam.leader -eq $e) { $fam.cell[$e] = 'Leads' }
            elseif ($null -ne $fam.tier1Share[$e] -and (100.0 * $fam.tier1Share[$e]) -ge $TieRule.leadTier1SharePct) { $fam.cell[$e] = 'Tied' }
            elseif ($null -ne $fam.index[$e]) { $fam.cell[$e] = (Format-Ratio $fam.index[$e]) + ' slower (typical)' }
            else {
                # No family index (every test was left out): say why instead of printing a number.
                $cappedOn = @($ft | Where-Object { @($verdicts[$_.code].cappedEngines) -contains $e })
                $exOn = @($ft | Where-Object { @($verdicts[$_.code].excludedEngines | Where-Object { $_.engine -eq $e }).Count -gt 0 })
                if ($cappedOn.Count) { $fam.cell[$e] = 'over the time limit on ' + $cappedOn.Count + ' of ' + $ft.Count + ' test(s)' }
                elseif ($exOn.Count) { $fam.cell[$e] = 'not ranked on ' + $exOn.Count + ' of ' + $ft.Count + ' test(s)' }
                else { $fam.cell[$e] = 'n/a' }
            }
        }
        $families[$f] = $fam
    }

    # derived values
    $derived = Get-Derived $compTests $cellsByTest $verdicts $engines
    $diagnostics = Get-Diagnostics $Data $runs $compTests $cellsByTest $engines $nSlots
    return [ordered]@{
        engines = $engines; nSlots = $nSlots; tests = $compTests; allTests = $tests; runs = $runs; cells = $cellsByTest; verdicts = $verdicts; specs = $specs
        families = $families; derived = $derived; diagnostics = $diagnostics; gateReasons = $gateReasons; notes = $notes
    }
}

function Get-Derived {
    param([object[]]$Tests, $Cells, $Verdicts, [string[]]$Engines)
    $byCode = @{}; foreach ($t in $Tests) { $byCode[$t.code] = $t }
    $cell = { param($code, $e) if ($Cells.Contains($code)) { @($Cells[$code] | Where-Object { $_.engine -eq $e })[0] } else { $null } }

    # scaling (orders per minute; the 1-clerk point on the wall-clock basis including untimed resets)
    $scaling = @()
    $p95 = @()
    foreach ($variant in @('spread', 'hot')) {
        foreach ($e in $Engines) {
            $pts = @()
            foreach ($t in @($Tests | Where-Object { $_.code -like ($(if ($variant -eq 'spread') { 'ORD_SO_ENTRY_U*' } else { 'ORD_SO_HOTITEM_U*' })) } | Sort-Object users)) {
                $c = & $cell $t.code $e
                if (-not $c -or $c.nValid -eq 0) { continue }
                if ($t.users -eq 1) {
                    if ($c.wallOpsPerMin) { $pts += [ordered]@{ users = 1; testCode = $t.code; median = $c.wallOpsPerMin.median; min = $c.wallOpsPerMin.min; max = $c.wallOpsPerMin.max; n = $c.wallOpsPerMin.n; p95Ms = $c.medianP95Ms; basis = 'wallInclResetsMs' } }
                }
                else { $pts += [ordered]@{ users = $t.users; testCode = $t.code; median = $c.medianHeadline; min = $c.minHeadline; max = $c.maxHeadline; n = $c.nValid; p95Ms = $c.medianP95Ms; errors = $c.errors; steadyOpsPerMin = $c.steadyOpsPerMin } }
            }
            if ($pts.Count -eq 0) { continue }
            $one = @($pts | Where-Object { $_.users -eq 1 })[0]
            if (-not $one -and $variant -eq 'hot') { $one = @($scaling | Where-Object { $_.engine -eq $e -and $_.variant -eq 'spread' } | ForEach-Object { @($_.points | Where-Object { $_.users -eq 1 }) } | Select-Object -First 1)[0] }
            foreach ($pt in $pts) { $pt['scaling'] = $(if ($one -and $one.median -and $pt.median) { $pt.median / $one.median } else { $null }) }
            $scaling += [ordered]@{ engine = $e; variant = $variant; points = $pts }
        }
    }
    $hot = @()
    foreach ($t in @($Tests | Where-Object { $_.code -like 'ORD_SO_HOTITEM_U*' })) {
        $spreadCode = $t.code.Replace('HOTITEM', 'ENTRY')
        foreach ($e in $Engines) {
            $h = & $cell $t.code $e; $s = & $cell $spreadCode $e
            if ($h -and $s -and $h.medianHeadline -and $s.medianHeadline) { $hot += [ordered]@{ users = $t.users; engine = $e; spreadOpsPerMin = $s.medianHeadline; hotOpsPerMin = $h.medianHeadline; penalty = $s.medianHeadline / $h.medianHeadline; hotErrors = $h.errors; hotRetries = $h.retries } }
        }
    }
    $speed = @()
    $opNames = [ordered]@{ 'CORE_READ' = 'Load 10,000 records'; 'CORE_INSERT' = 'Save 10,000 new records'; 'CORE_UPDATE' = 'Change 10,000 records'; 'CORE_DELETE' = 'Delete 10,000 records'; 'CORE_JOIN_FULL' = 'Availability list, all columns'; 'CORE_JOIN_SLIM' = 'Availability list, needed columns' }
    foreach ($k in $opNames.Keys) {
        foreach ($e in $Engines) {
            $a = & $cell ($k + '_1U') $e; $b = & $cell ($k + '_8U') $e
            if ($a -and $b -and $a.median -and $b.median -and -not (Test-Inf $a.median) -and -not (Test-Inf $b.median)) { $speed += [ordered]@{ operation = $opNames[$k]; prefix = $k; engine = $e; median1U = $a.median; median8U = $b.median; speedup = $a.median / $b.median } }
        }
    }
    $steady = @()
    foreach ($t in @($Tests | Where-Object { $_.users -gt 1 -and $_.higherIsBetter })) {
        foreach ($e in $Engines) { $c = & $cell $t.code $e; if ($c -and $c.steadyOpsPerMin) { $steady += [ordered]@{ testCode = $t.code; engine = $e; steadyOpsPerMin = $c.steadyOpsPerMin; headlineOpsPerMin = $c.medianHeadline } } }
    }
    return [ordered]@{ scaling = $scaling; hotItemPenalty = $hot; speedup1Uto8U = $speed; steadyState = $steady }
}

function Get-TableCountsGap {
    # Why one engine has no row counts in one table-count capture (contract C2), or $null when it has them.
    param($Tc, [string]$Engine)
    $short = { param($s) $t = [string]$s; if ($t.Length -gt 160) { $t = $t.Substring(0, 157) + '...' }; return $t }
    $engs = Get-Field $Tc 'engines'
    if (-not (Test-IsMap $engs)) {
        # the suite's compact copy (campaign JSON environment.tableCounts): unavailable engines are listed under
        # "unavailable"; an engine with changed tables or soft-deleted counts was captured
        $un = Get-Field (Get-Field $Tc 'unavailable') $Engine
        if ($un) { return ('unavailable: ' + (& $short $un)) }
        if ((Test-MapHasKey (Get-Field $Tc 'changedTables') $Engine) -or $null -ne (Get-Field (Get-Field $Tc 'softDeleted') $Engine)) { return $null }
        return 'not in this capture'
    }
    $en = Get-Field $engs $Engine
    if (-not (Test-IsMap $en)) { return 'not in this capture' }
    $un = Get-Field $en 'unavailable'
    if ($un) { return ('unavailable: ' + (& $short $un)) }
    if (-not (Test-IsMap (Get-Field $en 'exactCounts')) -and -not (Test-IsMap (Get-Field $en 'counts'))) { return 'no row counts' }
    return $null
}

function Get-ResidueTables {
    # Residue tables (SPEC 5.4 item 19, 6.6 3n): per table-count capture, the tables whose row count changed against
    # its baseline (Get-PerfEnvironment -TableCounts -BaselineFile), the soft-deleted ARRegister/Batch rows, and the
    # engines without row counts in that capture (contract C2: engines.<e>.unavailable; they are named, never skipped).
    param($Data, [string[]]$Engines)
    $out = @()
    foreach ($tc in @($Data.tableCounts)) {
        if (-not $tc) { continue }
        $changed = Get-Field $tc 'changedTables'
        $soft = Get-Field $tc 'softDeleted'
        if (-not (Test-IsMap $soft)) {
            $soft = [ordered]@{}
            $engs = Get-Field $tc 'engines'
            foreach ($e in (Get-Keys $engs)) { $sd = Get-Field (Get-Field $engs $e) 'softDeleted'; if ($sd) { $soft[$e] = $sd } }
        }
        $byEngine = [ordered]@{}
        foreach ($e in (Get-Keys $changed)) {
            $rows = @(@(Get-Field $changed $e) | Where-Object { Test-IsMap $_ } | ForEach-Object {
                    [ordered]@{ table = [string](Get-Field $_ 'table'); before = ConvertTo-Num (Get-Field $_ 'before'); after = ConvertTo-Num (Get-Field $_ 'after'); delta = ConvertTo-Num (Get-Field $_ 'delta') }
                } | Sort-Object { - [Math]::Abs([double](0 + $_.delta)) })
            $byEngine[$e] = $rows
        }
        $notCaptured = [ordered]@{}
        foreach ($e in @($Engines)) { $gap = Get-TableCountsGap $tc $e; if ($gap) { $notCaptured[$e] = $gap } }
        $out += [ordered]@{
            source = [string](Get-Field $tc 'source'); label = [string](Get-Field $tc 'label'); capturedAtUtc = [string](Get-Field $tc 'capturedAtUtc')
            mode = [string](Get-Field $tc 'mode'); baselineFile = [string](Get-Field $tc 'baselineFile'); changedTables = $byEngine; softDeleted = $soft
            notCaptured = $notCaptured
        }
    }
    return , $out
}

function Test-MapHasKey {
    # Exact (case-sensitive where the map is) key test: PostgreSQL can hold two tables whose names differ only in case.
    param($Map, [string]$Key)
    if ($null -eq $Map) { return $false }
    if ($Map -is [System.Collections.Specialized.OrderedDictionary]) { return $Map.Contains($Key) }
    if ($Map -is [System.Collections.IDictionary]) { return $Map.ContainsKey($Key) }
    return $null -ne $Map.PSObject.Properties[$Key]
}

function Get-MapValue {
    param($Map, [string]$Key)
    if ($Map -is [System.Collections.IDictionary]) { return $Map[$Key] }
    $p = $Map.PSObject.Properties[$Key]
    if ($p) { return $p.Value }
    return $null
}

function Get-ExactCountMap {
    # Exact row counts of one engine in one table-count capture (contract C2): engines.<e>.exactCounts (mode "exact":
    # every base table; older "legacy" files: the key and changed tables only), or SQL Server's counts in an older file
    # (sys.dm_db_partition_stats, exact). A metadata-only capture has estimates and is never compared.
    param($Tc, [string]$Engine)
    $gap = Get-TableCountsGap $Tc $Engine
    if ($gap) { return [ordered]@{ counts = $null; reason = $gap; full = $false } }
    if (-not (Test-IsMap (Get-Field $Tc 'engines'))) { return [ordered]@{ counts = $null; reason = 'only the compact copy in the campaign JSON was found (the full file was not next to the input)'; full = $false } }
    $mode = [string](Get-Field $Tc 'mode')
    if ($mode -eq 'metadata') { return [ordered]@{ counts = $null; reason = 'metadata-only capture (no exact counts)'; full = $false } }
    $en = Get-Field (Get-Field $Tc 'engines') $Engine
    $ex = Get-Field $en 'exactCounts'
    if (Test-IsMap $ex) { return [ordered]@{ counts = $ex; reason = $null; full = ($mode -eq 'exact') } }
    $cn = Get-Field $en 'counts'
    if ($Engine -eq 'SQLServer' -and (Test-IsMap $cn)) { return [ordered]@{ counts = $cn; reason = $null; full = $true } }
    return [ordered]@{ counts = $null; reason = 'no exact row counts'; full = $false }
}

function Get-TableDisplayName { param([string]$Name) return (($Name -replace '^(?i)(dbo|public)\.', '').Replace('"', '')) }

function Get-CaptureErrorTexts {
    param($Tc)
    $out = @()
    if (-not $Tc) { return , $out }
    foreach ($er in @(Get-Field $Tc 'errors')) {
        if (-not $er) { continue }
        $t = if (Test-IsMap $er) { ([string](Get-Field $er 'section') + ': ' + [string](Get-Field $er 'message')).Trim(': ') } else { [string]$er }
        if ($t.Length -gt 200) { $t = $t.Substring(0, 197) + '...' }
        $out += ([string](Get-Field $Tc 'source') + ': ' + $t)
    }
    return , $out
}

function Get-CampaignResidue {
    # Contract C2: the campaign's residue = exact row counts at the campaign end (table-counts-campaign-end.json) against
    # the campaign baseline (table-counts-campaign-baseline.json: dry-run step 3p, after the clear and before the equal
    # restart), engine by engine, exact against exact. An engine without exact counts in either file is listed as not
    # captured (its residue is unknown); it is never compared with estimates. $null when neither file exists.
    param($Data, [string[]]$Engines)
    $pick = {
        param([string]$Label)
        $hit = $null
        foreach ($tc in @($Data.tableCounts)) {
            if (-not $tc) { continue }
            if ([string](Get-Field $tc 'source') -ieq ('table-counts-' + $Label + '.json') -or [string](Get-Field $tc 'label') -ieq $Label) { $hit = $tc }
        }
        return , $hit
    }
    $base = & $pick 'campaign-baseline'
    $end = & $pick 'campaign-end'
    if ($null -eq $base -and $null -eq $end) { return $null }
    $res = [ordered]@{
        baseline = $(if ($base) { [string](Get-Field $base 'source') } else { $null }); baselineMode = $(if ($base) { [string](Get-Field $base 'mode') } else { $null })
        baselineCapturedAtUtc = $(if ($base) { [string](Get-Field $base 'capturedAtUtc') } else { $null })
        end = $(if ($end) { [string](Get-Field $end 'source') } else { $null }); endMode = $(if ($end) { [string](Get-Field $end 'mode') } else { $null })
        endCapturedAtUtc = $(if ($end) { [string](Get-Field $end 'capturedAtUtc') } else { $null })
        engines = [ordered]@{}; errors = @((Get-CaptureErrorTexts $base) + (Get-CaptureErrorTexts $end))
    }
    foreach ($e in @($Engines)) {
        $b = if ($base) { Get-ExactCountMap $base $e } else { [ordered]@{ counts = $null; reason = 'no table-counts-campaign-baseline.json'; full = $false } }
        $x = if ($end) { Get-ExactCountMap $end $e } else { [ordered]@{ counts = $null; reason = 'no table-counts-campaign-end.json'; full = $false } }
        if ($null -eq $b.counts -or $null -eq $x.counts) {
            $why = @()
            if ($null -eq $b.counts) { $why += ('baseline ' + $b.reason) }
            if ($null -eq $x.counts) { $why += ('end ' + $x.reason) }
            $res.engines[$e] = [ordered]@{ captured = $false; reason = ($why -join '; ') }
            continue
        }
        $rows = New-Object System.Collections.ArrayList
        $compared = 0; $onlyEnd = 0; $onlyBase = 0
        foreach ($k in (Get-Keys $x.counts)) {
            if (-not (Test-MapHasKey $b.counts $k)) { $onlyEnd++; continue }
            $before = ConvertTo-Num (Get-MapValue $b.counts $k); $after = ConvertTo-Num (Get-MapValue $x.counts $k)
            $compared++
            if ($null -ne $before -and $null -ne $after -and $before -ne $after) { [void]$rows.Add([ordered]@{ table = (Get-TableDisplayName $k); before = $before; after = $after; delta = ($after - $before) }) }
        }
        foreach ($k in (Get-Keys $b.counts)) { if (-not (Test-MapHasKey $x.counts $k)) { $onlyBase++ } }
        $sorted = @($rows | Sort-Object @{ Expression = { [Math]::Abs([double]$_.delta) }; Descending = $true }, @{ Expression = { $_.table } })
        $sb = Get-Field (Get-Field (Get-Field $base 'engines') $e) 'softDeleted'
        $sx = Get-Field (Get-Field (Get-Field $end 'engines') $e) 'softDeleted'
        $soft = [ordered]@{}
        foreach ($k in @(@(Get-Keys $sb) + @(Get-Keys $sx) | Select-Object -Unique)) { $soft[$k] = [ordered]@{ before = ConvertTo-Num (Get-Field $sb $k); after = ConvertTo-Num (Get-Field $sx $k) } }
        $res.engines[$e] = [ordered]@{ captured = $true; everyTable = ($b.full -and $x.full); tablesCompared = $compared; onlyInBaseline = $onlyBase; onlyAtEnd = $onlyEnd; changed = $sorted; softDeleted = $soft }
    }
    return $res
}

function Format-ResidueRow {
    param($Row)
    $dlt = 0 + $Row.delta
    return ($Row.table + ' ' + ('{0:N0}' -f (0 + $Row.before)) + ' ' + $script:ARROW + ' ' + ('{0:N0}' -f (0 + $Row.after)) + ' (' + $(if ($dlt -ge 0) { '+' } else { '' }) + ('{0:N0}' -f $dlt) + ')')
}

function Get-CampaignResidueText {
    # Appendix text of Get-CampaignResidue: per engine the changed tables (largest change first), or "not captured".
    param($R)
    $parts = @()
    foreach ($e in @($R.engines.Keys)) {
        $x = $R.engines[$e]
        if (-not $x.captured) { $parts += ((Get-EngineName $e) + ': not captured (' + $x.reason + '), so its residue is not known'); continue }
        $rows = @($x.changed)
        $shown = @($rows | Select-Object -First 15 | ForEach-Object { Format-ResidueRow $_ })
        $more = if ($rows.Count -gt 15) { ' and ' + ($rows.Count - 15) + ' more' } else { '' }
        $txt = (Get-EngineName $e) + ': ' + $(if ($rows.Count) { ($shown -join ', ') + $more } else { 'no table changed' })
        $txt += ' (' + ('{0:N0}' -f $x.tablesCompared) + ' tables compared' + $(if (-not $x.everyTable) { '; not every table was counted exactly in both files' } else { '' }) + $(if ($x.onlyAtEnd -or $x.onlyInBaseline) { '; ' + $x.onlyAtEnd + ' only at the end, ' + $x.onlyInBaseline + ' only in the baseline' } else { '' }) + ')'
        $parts += $txt
    }
    $soft = @(foreach ($e in @($R.engines.Keys)) {
            $x = $R.engines[$e]
            if (-not $x.captured -or -not $x.softDeleted -or $x.softDeleted.Count -eq 0) { continue }
            (Get-EngineName $e) + ' ' + ((@($x.softDeleted.Keys) | ForEach-Object { $_ + ' ' + (Format-EnvValue $x.softDeleted[$_].before) + ' ' + $script:ARROW + ' ' + (Format-EnvValue $x.softDeleted[$_].after) }) -join ', ')
        })
    if ($soft.Count) { $parts += ('soft-deleted / archived rows (baseline ' + $script:ARROW + ' end): ' + ($soft -join '; ')) }
    if (@($R.errors).Count) { $parts += ('capture errors: ' + (@($R.errors) -join ' | ')) }
    return ($parts -join '. ')
}

# ---- dry-run 3l / 3f texts, collation, SQL throttle, CPU affinity and SQL log chain disclosures

function Get-InstanceEngine {
    param($Data, [string]$Instance)
    if ($Data.instanceEngines -and $Data.instanceEngines.ContainsKey($Instance)) { return $Data.instanceEngines[$Instance] }
    return (Resolve-Engine '' $Instance)
}

function Get-ApiReadPublished {
    # Contract C4: diagnostics.apiReadMs.<instance> = { endpoint, n, p50Ms, p95Ms, meanMs, minMs, maxMs, errors } and
    # nothing else is published (older files also carried warmUp, orderNbrs and a note with the raw error text; the
    # probe with exception messages, diagnostics.apiReadProbe, is never published). A plain number (hand-entered,
    # older sample files) is read as p50Ms with n unknown. Entries that are not measurements are dropped.
    param($Raw)
    if ($null -eq $Raw -or $Raw -is [string]) { return $Raw }
    if (-not (Test-IsMap $Raw)) { return 'not provided' }
    $out = [ordered]@{}
    foreach ($inst in (Get-Keys $Raw)) {
        $v = Get-Field $Raw $inst
        if (Test-IsMap $v) {
            if (-not (Test-MapHasKey $v 'n') -and -not (Test-MapHasKey $v 'p50Ms')) { continue }
            $ep = Get-Field $v 'endpoint'
            $out[$inst] = [ordered]@{
                endpoint = $(if ($null -ne $ep -and [string]$ep -ne '') { [string]$ep } else { $null })
                n = ConvertTo-Num (Get-Field $v 'n'); p50Ms = ConvertTo-Num (Get-Field $v 'p50Ms'); p95Ms = ConvertTo-Num (Get-Field $v 'p95Ms')
                meanMs = ConvertTo-Num (Get-Field $v 'meanMs'); minMs = ConvertTo-Num (Get-Field $v 'minMs'); maxMs = ConvertTo-Num (Get-Field $v 'maxMs')
                errors = ConvertTo-Num (Get-Field $v 'errors')
            }
        }
        elseif ($null -ne (ConvertTo-Num $v)) {
            $out[$inst] = [ordered]@{ endpoint = $null; n = $null; p50Ms = (ConvertTo-Num $v); p95Ms = $null; meanMs = $null; minMs = $null; maxMs = $null; errors = $null }
        }
    }
    return $out
}

function Get-OpenSalesOrderP50 {
    # "Open a sales order" per-operation p50 of one engine: the cell median of the analysis set (each run's headline is
    # its median ms per order opened); without a cell, the median of the engine's valid measured runs.
    param([string]$Engine, $Cells, [object[]]$Runs)
    $c = $null
    if ($Cells -and $Cells.Contains('SCR_OPEN_SALES_ORDER')) { $c = @($Cells['SCR_OPEN_SALES_ORDER'] | Where-Object { $_.engine -eq $Engine })[0] }
    if ($c -and $null -ne $c.median -and -not (Test-Inf $c.median)) { return [double]$c.median }
    $v = @($Runs | Where-Object { $_.testCode -eq 'SCR_OPEN_SALES_ORDER' -and $_.engine -eq $Engine -and $_.valid -and -not $_.capped -and -not $_.isWarmup -and $null -ne $_.headlineValue } | ForEach-Object { [double]$_.headlineValue })
    if ($v.Count) { return (Get-Median ([double[]]$v)) }
    return $null
}

function Get-ApiFailLabel {
    param($Entry)
    $t = [string](Get-Field $Entry 'exceptionType')
    if ($t) { return $t }
    $st = ConvertTo-Num (Get-Field $Entry 'status')
    if ($st -and $st -gt 0) { return ('HTTP ' + [int]$st + ', exception type not recorded') }
    return 'no response'
}

function Format-ApiFailedVersion {
    # One endpoint version of the API-read probe that did not answer on every engine:
    # "<endpoint>: <exception type> on <engines>[; <other type> on <engines>][ (answered on <engines>)]".
    # Only the exception type (or the HTTP status) is used, never the exception message.
    param($Data, [string]$Endpoint, [object[]]$Rows)
    $groups = [ordered]@{}; $okEngines = @()
    foreach ($t in @($Rows)) {
        $eng = Get-InstanceEngine $Data ([string](Get-Field $t 'instance'))
        if ((ConvertTo-Num (Get-Field $t 'status')) -eq 200) { if ($okEngines -notcontains $eng) { $okEngines += $eng }; continue }
        $label = Get-ApiFailLabel $t
        if (-not $groups.Contains($label)) { $groups[$label] = @() }
        if ($groups[$label] -notcontains $eng) { $groups[$label] = @($groups[$label]) + $eng }
    }
    if ($groups.Count -eq 0) { return $null }
    $order = { param([string[]]$E) @($E | Sort-Object { $i = [array]::IndexOf([string[]]$script:EngineOrder, $_); if ($i -lt 0) { 99 } else { $i } }) }
    $txt = $Endpoint + ': ' + ((@($groups.Keys) | ForEach-Object { $_ + ' on ' + (Join-EngineNames (& $order $groups[$_])) }) -join '; ')
    if ($okEngines.Count) { $txt += ' (answered on ' + (Join-EngineNames (& $order $okEngines)) + ')' }
    return $txt
}

function Get-ApiReadSummary {
    # SPEC FR-M11 / 6.6 3l: per engine the end-to-end API read (median of the timed GETs) next to the database-dependent
    # part measured by "Open a sales order" (SCR_OPEN_SALES_ORDER per-operation p50). Available only when every engine
    # has n > 0; failed calls of an engine are stated next to its figures. The endpoint versions that did not answer on
    # every engine, and the reason when the read is not available, come from diagnostics.apiReadProbe (loaded by
    # Import-Campaign from the dry-run folder; never published): only endpoint versions, engines and exception types
    # are used, never an exception message or the probe's failure text.
    param($Data, $Published, $Cells, [object[]]$Runs, [string[]]$Engines)
    $s = [ordered]@{ available = $false; endpoint = $null; n = $null; warmUp = $null; callsPerEngine = $null; perEngine = [ordered]@{}; endpointsThatFailed = @(); reason = $null }
    if (-not (Test-IsMap $Published)) { $s.reason = 'not provided: the dry-run diagnostics were not passed to the report'; return $s }
    $probe = $null
    if ($Data.diagnosticsIn -and $Data.diagnosticsIn.Contains('apiReadProbe')) { $probe = $Data.diagnosticsIn['apiReadProbe'] }
    if (-not (Test-IsMap $probe)) { $probe = $null }
    $wu = ConvertTo-Num (Get-Field $probe 'warmUp'); $cnt = ConvertTo-Num (Get-Field $probe 'count')
    if ($null -ne $wu) { $s.warmUp = [int]$wu }
    if ($null -ne $wu -and $null -ne $cnt) { $s.callsPerEngine = [int]($wu + $cnt) }
    $byEngine = @{}
    foreach ($inst in (Get-Keys $Published)) { $byEngine[(Get-InstanceEngine $Data $inst)] = $inst }
    $missing = @()
    foreach ($e in @($Engines)) {
        $y = Get-OpenSalesOrderP50 $e $Cells $Runs
        $inst = $byEngine[$e]
        if (-not $inst) { $missing += $e; $s.perEngine[$e] = [ordered]@{ instance = $null; endpoint = $null; n = $null; errors = $null; apiReadP50Ms = $null; apiReadP95Ms = $null; openSalesOrderP50Ms = $y }; continue }
        $m = $Published[$inst]
        $ok = ($null -ne $m.p50Ms) -and ($null -eq $m.n -or $m.n -gt 0)
        if (-not $ok) { $missing += $e }
        $s.perEngine[$e] = [ordered]@{ instance = $inst; endpoint = $m.endpoint; n = $m.n; errors = $m.errors; apiReadP50Ms = $m.p50Ms; apiReadP95Ms = $m.p95Ms; openSalesOrderP50Ms = $y }
    }
    $eps = @($s.perEngine.Values | ForEach-Object { $_.endpoint } | Where-Object { $_ } | Select-Object -Unique)
    if ($eps.Count) { $s.endpoint = ($eps -join ', ') }
    $ns = @($s.perEngine.Values | ForEach-Object { $_.n } | Where-Object { $null -ne $_ } | Select-Object -Unique)
    if ($ns.Count -eq 1) { $s.n = $ns[0] }
    # the probe: the endpoint versions that did not answer on every engine, with the engines and exception types
    $chosen = [string](Get-Field $probe 'chosenEndpoint')
    $epOrder = @(); $rowsByEp = @{}
    foreach ($t in @(@(Get-Field $probe 'tried') | Where-Object { Test-IsMap $_ })) {
        $ep = [string](Get-Field $t 'endpoint')
        if (-not $ep) { continue }
        if ($epOrder -notcontains $ep) { $epOrder += $ep; $rowsByEp[$ep] = @() }
        $rowsByEp[$ep] = @($rowsByEp[$ep]) + @(, $t)
    }
    $failedEps = @($epOrder | Where-Object { $ep = $_; @($rowsByEp[$ep] | Where-Object { (ConvertTo-Num (Get-Field $_ 'status')) -ne 200 }).Count -gt 0 })
    $s.endpointsThatFailed = @(foreach ($ep in $failedEps) { if ($ep -eq $chosen) { continue }; $x = Format-ApiFailedVersion $Data $ep $rowsByEp[$ep]; if ($x) { $x } })
    $s.available = ($missing.Count -eq 0 -and @($Engines).Count -gt 0)
    if ($s.available) { return $s }

    # not available: why, from the probe
    $why = @()
    $noteEngines = @((Get-Keys (Get-Field $probe 'notes')) | ForEach-Object { Get-InstanceEngine $Data $_ })
    if ($noteEngines.Count) { $why += ('no sample order numbers on ' + (Join-EngineNames $noteEngines) + ', so no endpoint version was probed or measured') }
    $failure = [string](Get-Field $probe 'failure')
    if ($chosen) {
        $me = @(@(Get-Field $probe 'measureErrors') | Where-Object { Test-IsMap $_ })
        foreach ($e in $missing) {
            $p = $s.perEngine[$e]
            $row = @($me | Where-Object { (Get-InstanceEngine $Data ([string](Get-Field $_ 'instance'))) -eq $e })[0]
            $er = $p.errors
            if ($null -eq $er -and $row) { $er = ConvertTo-Num (Get-Field $row 'errors') }
            $stopped = $row -and (ConvertTo-Flag (Get-Field $row 'stoppedAfterWarmUp'))
            # calls made: warm-up + timed, or only the warm-up calls when they all failed (the timed calls were skipped)
            $made = $(if ($stopped) { $s.warmUp } else { $s.callsPerEngine })
            $detail = @()
            if ($null -ne $er -and $er -gt 0) { $detail += ([string][int]$er + $(if ($made) { ' of ' + $made } else { '' }) + ' calls failed') }
            if ($row) {
                $detail += (Get-ApiFailLabel $row)
                if ($stopped) { $detail += 'every warm-up call failed, so the timed calls were skipped' }
            }
            elseif (-not $p.instance) { $detail += 'no result for this engine' }
            elseif ($null -ne $er -and $er -gt 0) { $detail += 'exception type not recorded' }
            else { $detail += 'not measured' }
            $why += ((Get-EngineName $e) + ': no successful timed call on ' + $chosen + ' (' + ($detail -join '; ') + ')')
        }
        if ($s.endpointsThatFailed.Count) { $why += ('not used: ' + ($s.endpointsThatFailed -join '; ')) }
    }
    elseif ($epOrder.Count) {
        if ($failedEps.Count -eq $epOrder.Count -and -not $failure) { $why += ('no Default endpoint version answered on every engine: ' + ($s.endpointsThatFailed -join '; ')) }
        else { $why += ('the endpoint probe did not finish' + $(if ($s.endpointsThatFailed.Count) { ' (' + ($s.endpointsThatFailed -join '; ') + ')' } else { '' })) }
    }
    elseif ($probe -and $noteEngines.Count -eq 0 -and -not $failure) {
        # the dry run's 3l file without the 3d campaign JSON: notes and failure are not in it
        $why += 'no endpoint version was probed (no sample order numbers, or an early error; details in the unpublished probe)'
    }
    # the failure text is a raw exception message: never published (contract C4)
    if ($failure) { $why += 'the API read stopped with an unexpected error (details in the unpublished probe)' }
    if ($why.Count) { $s.reason = ($why -join '; '); return $s }

    # no probe at all (an older campaign, or the dry-run folder is not next to the inputs): the published fields only
    $none = @($missing | Where-Object { $p = $s.perEngine[$_]; $p.instance -and -not $p.endpoint -and (0 + $p.n) -eq 0 -and (0 + $p.errors) -eq 0 })
    if ($none.Count -eq $missing.Count) {
        $s.reason = 'no Default endpoint version answered on every engine, or none could be probed (exception type not recorded: the probe was not found)'
        return $s
    }
    $bad = @($missing | ForEach-Object {
            $p = $s.perEngine[$_]
            (Get-EngineName $_) + $(if (-not $p.instance) { ': no result' } elseif ($null -ne $p.errors -and $p.errors -gt 0) { ': ' + [int]$p.errors + ' failed calls' + $(if ($p.endpoint) { ' on ' + $p.endpoint } else { '' }) } else { ': not measured' })
        })
    $s.reason = 'no successful timed call on every engine (' + ($bad -join '; ') + '; exception type not recorded: the probe was not found)'
    return $s
}

function Get-ApiReadText {
    # The published 3l sentence (SPEC FR-M11, 6.6 3l), or the not-available line. Failed calls of an engine are named
    # next to its figures (its median then comes from fewer timed calls).
    param($S)
    if (-not $S) { return 'End-to-end API read: not available (not provided)' }
    if (-not $S.available) { return ('End-to-end API read: not available (' + $S.reason + ')') }
    $parts = @(foreach ($e in @($S.perEngine.Keys)) {
            $p = $S.perEngine[$e]
            $extra = @()
            if ($null -eq $S.n -and $null -ne $p.n) { $extra += ('median of ' + [int]$p.n + ' timed calls') }
            if ($null -ne $p.errors -and $p.errors -gt 0) { $extra += ([string][int]$p.errors + $(if ($S.callsPerEngine) { ' of ' + $S.callsPerEngine } else { '' }) + ' calls failed') }
            (Get-EngineName $e) + ': end-to-end API read ' + $script:APPROX + ' ' + (Format-Sig3 $p.apiReadP50Ms) + ' ms' + $(if ($extra.Count) { ' (' + ($extra -join '; ') + ')' } else { '' }) + '; the database-dependent part measured by Open a sales order ' + $script:APPROX + ' ' + $(if ($null -ne $p.openSalesOrderP50Ms) { (Format-Sig3 $p.openSalesOrderP50Ms) + ' ms' } else { '(not measured)' })
        })
    $wuTxt = $(if ($null -ne $S.warmUp) { [string][int]$S.warmUp } else { '5' })
    $how = 'median of ' + $(if ($null -ne $S.n) { [string][int]$S.n + ' timed' } else { 'the timed' }) + ' GET SalesOrder/SO/{order}?$expand=Details calls per engine after ' + $wuTxt + ' untimed warm-up calls, with the suite''s API session, on ' + $(if ($S.endpoint) { $S.endpoint } else { 'the Default endpoint' })
    if (@($S.endpointsThatFailed).Count) { $how += '; ' + (@($S.endpointsThatFailed) -join '; ') + ' (that version did not answer on every engine, so it was not used)' }
    return ('End-to-end API read: ' + ($parts -join '; ') + ' (' + $how + '; dry run 3l, informational, never ranked)')
}

function Get-CacheDefeatText {
    # Dry run 3f(a), printed as recorded by the dry run: statements executed on PerfSQL (execution_count delta),
    # operations issued, statements per operation by design, Prepare statements, expected statements and its "equal".
    param($Probe)
    if ($null -eq $Probe -or $Probe -is [string] -or -not (Test-IsMap $Probe)) { return [string]$Probe }
    $parts = @()
    foreach ($code in (Get-Keys $Probe)) {
        $p = Get-Field $Probe $code
        if (-not (Test-IsMap $p)) { $parts += ($code + ' = ' + [string]$p); continue }
        $hasNew = (Test-MapHasKey $p 'expectedStatements') -or (Test-MapHasKey $p 'operationsIssued')
        if ($hasNew -or (Test-MapHasKey $p 'queriesIssued')) {
            $inst = [string](Get-Field $p 'instance')
            $t = $code + $(if ($inst) { ' on ' + $inst } else { '' }) + ': statements executed ' + (Format-EnvValue (Get-Field $p 'executionCountDelta'))
            if ($hasNew) {
                $t += ', operations issued ' + (Format-EnvValue (Get-Field $p 'operationsIssued'))
                if (Test-MapHasKey $p 'statementsPerOpByDesign') { $t += ', statements per operation by design ' + (Format-EnvValue (Get-Field $p 'statementsPerOpByDesign')) }
                if (Test-MapHasKey $p 'prepareStatements') { $t += ', Prepare statements ' + (Format-EnvValue (Get-Field $p 'prepareStatements')) }
                $t += ', expected statements ' + (Format-EnvValue (Get-Field $p 'expectedStatements'))
            }
            else { $t += ', operations issued ' + (Format-EnvValue (Get-Field $p 'queriesIssued')) + ' (this dry run compared statements with operations; expected statements were not recorded)' }
            $t += ', equal ' + (Format-EnvValue (Get-Field $p 'equal'))
            $note = [string](Get-Field $p 'note'); if ($note) { $t += ' (' + $note + ')' }
            $parts += $t
        }
        else { $m = [ordered]@{}; Get-LeafMap $p $code $m; $parts += ((@($m.Keys) | ForEach-Object { $_ + ' = ' + $m[$_] }) -join '; ') }
    }
    return ($parts -join '; ')
}

function Get-StatementsPerOpValues {
    param($Spo)
    if ($null -eq $Spo -or $Spo -is [string] -or -not (Test-IsMap $Spo)) { return [string]$Spo }
    return (((Get-Keys $Spo) | ForEach-Object { $t = $_; $t + ' ' + (((Get-Keys (Get-Field $Spo $t)) | ForEach-Object { (Get-EngineName $_) + ' ' + [string](Get-Field (Get-Field $Spo $t) $_) }) -join ', ') }) -join '; ')
}

function Get-CollationCapture {
    # Contract C3: databases.<Engine>.collation of the environment capture (start, else end).
    param($Data, [string]$Engine)
    foreach ($doc in @($Data.start, $Data.end)) {
        if ($null -eq $doc) { continue }
        $c = Get-PathValue $doc ('databases.' + $Engine + '.collation')
        if (Test-IsMap $c) { return , $c }
    }
    return $null
}

function Get-ColumnCollationSummary {
    # "<collation> (<number of text columns>)" for the three most used column collations.
    param($Map)
    if (-not (Test-IsMap $Map)) { return $null }
    $rows = @((Get-Keys $Map) | ForEach-Object { [pscustomobject]@{ name = $_; n = ConvertTo-Num (Get-MapValue $Map $_) } } | Sort-Object @{ Expression = { 0 + $_.n }; Descending = $true }, name)
    if ($rows.Count -eq 0) { return $null }
    $txt = (@($rows | Select-Object -First 3 | ForEach-Object { $_.name + ' (' + ('{0:N0}' -f (0 + $_.n)) + ')' }) -join ', ')
    if ($rows.Count -gt 3) { $txt += ' (and ' + ($rows.Count - 3) + ' more collations)' }
    return $txt
}

function Get-AccentProbeText {
    # The accent probe of "Find a customer by part of the name" (BAccount.AcctName contains quebec / Qu-e-acute-bec /
    # QU-E-acute-BEC) on one engine, as hits per search term.
    param($A, [string]$Engine)
    $c = $null
    if ($A.cells -and $A.cells.Contains('SCR_CUSTOMER_SEARCH')) { $c = @($A.cells['SCR_CUSTOMER_SEARCH'] | Where-Object { $_.engine -eq $Engine })[0] }
    if (-not $c -or -not $c.probes) { return 'accent probe not captured' }
    $keys = @(@($c.probes.Keys) | Where-Object { $_ -like 'probe.accent.*' })
    if ($keys.Count -eq 0) { return 'accent probe not captured' }
    if (@($keys | Where-Object { $_ -notmatch '^probe\.accent\.\d+\.' }).Count -eq 0) { $keys = @($keys | Sort-Object { [int]($_ -replace '^probe\.accent\.(\d+)\..*$', '$1') }) }
    $short = @($keys | ForEach-Object { $_ -replace '^probe\.accent\.(\d+\.)?', '' })
    $vals = @($keys | ForEach-Object { $x = $c.probes[$_]; if ($null -eq $x -or [string]$x -eq '') { '?' } else { [string]$x } })
    return ('observed: hits for ' + ($short -join '/') + ' = ' + ($vals -join '/'))
}

function Get-SqlServerCollationSense {
    # "case-insensitive, accent-sensitive" from a SQL Server collation name (_CI_/_CS_, _AI/_AS).
    param([string]$Name)
    if (-not $Name) { return $null }
    $c = if ($Name -match '(?i)_CI(_|$)') { 'case-insensitive' } elseif ($Name -match '(?i)_CS(_|$)') { 'case-sensitive' } else { $null }
    $a = if ($Name -match '(?i)_AI(_|$)') { 'accent-insensitive' } elseif ($Name -match '(?i)_AS(_|$)') { 'accent-sensitive' } else { $null }
    $x = @($c, $a | Where-Object { $_ })
    if ($x.Count) { return ($x -join ', ') }
    return $null
}

function Get-CollationCell {
    # Disclosure Table 2, "Collation / text search", from contract C3 (databases.<Engine>.collation). Both layers are
    # described: the database default and the collation of Acumatica's text columns, plus how Acumatica's LIKE compares
    # and the accent probe actually observed. A missing value is printed as "(not captured)", never guessed.
    param($Data, $A, [object[]]$Src, [string]$Engine)
    $c = Get-CollationCapture $Data $Engine
    $probe = Get-AccentProbeText $A $Engine
    $dbDefault = Get-Field $c 'databaseDefault'
    $probeCol = [string](Get-Field $c 'probeColumn'); if (-not $probeCol) { $probeCol = 'BAccount.AcctName' }
    $probeColColl = Get-Field $c 'probeColumnCollation'
    $colSummary = Get-ColumnCollationSummary (Get-Field $c 'columnCollations')
    switch ($Engine) {
        'SQLServer' {
            if ($null -eq $dbDefault) { $dbDefault = Find-Setting $Src @('collation_name') }
            $sense = Get-SqlServerCollationSense ([string]$(if ($probeColColl) { $probeColColl } else { $dbDefault }))
            $cols = if ($colSummary -or $probeColColl) { 'text columns: ' + (Format-EnvValue $colSummary) + '; ' + $probeCol + ' ' + (Format-EnvValue $probeColColl) } else { 'column collation (not captured)' }
            return ('database default ' + (Format-EnvValue $dbDefault) + '; ' + $cols + '. LIKE compares with the column collation' + $(if ($sense) { ': ' + $sense } else { '' }) + ' (' + $(if ($sense -and -not $probeColColl) { 'read from the database default; ' } else { '' }) + $probe + ')')
        }
        'MySQL' {
            if ($null -eq $dbDefault) { $dbDefault = Find-Setting $Src @('collation_server') }
            $cols = if ($colSummary -or $probeColColl) { 'Acumatica''s text columns: ' + (Format-EnvValue $colSummary) + '; ' + $probeCol + ' ' + (Format-EnvValue $probeColColl) } else { 'Acumatica''s column collation (not captured)' }
            return ('server/database default ' + (Format-EnvValue $dbDefault) + '; ' + $cols + '. Acumatica''s LIKE adds COLLATE utf8mb4_unicode_ci: case- and accent-insensitive (' + $probe + ')')
        }
        'PostgreSQL' {
            $lp = Get-Field $c 'localeProvider'
            if ($null -eq $lp) { $lp = Find-Setting $Src @('datlocprovider') }
            if ($null -eq $dbDefault) { $dbDefault = Find-Setting $Src @('datcollate') }
            $lpName = switch -Regex ([string]$lp) { '^(?i)(c|libc)$' { 'libc' } '^(?i)(i|icu)$' { 'ICU' } '^(?i)(b|builtin)$' { 'builtin' } '^$' { $null } default { [string]$lp } }
            $defTxt = if ($null -eq $dbDefault -or [string]$dbDefault -eq '') { 'database default (not captured)' } else { 'database default ' + $(if ($lpName) { $lpName + ' ' } else { '' }) + [string]$dbDefault + $(if (-not $lpName) { ' (locale provider not captured)' } else { '' }) }
            # the collation of Acumatica's text columns: the probe column's, else the most used one that is not "default"
            $colName = [string]$probeColColl
            if (-not $colName) {
                $cc = Get-Field $c 'columnCollations'
                $colName = [string](@((Get-Keys $cc) | Where-Object { $_ -ne 'default' } | Sort-Object @{ Expression = { 0 + (ConvertTo-Num (Get-MapValue $cc $_)) }; Descending = $true }) | Select-Object -First 1)
            }
            $icu = @(@(Get-Field $c 'icuCollations') | Where-Object { (Test-IsMap $_) -and [string](Get-Field $_ 'name') -eq $colName })[0]
            $colTxt = if ($colName -eq 'default') { 'Acumatica''s text columns use the database default' } elseif ($colName) { 'Acumatica''s text columns use ' + $colName } else { 'Acumatica''s column collation (not captured)' }
            if ($icu) {
                $prov = [string](Get-Field $icu 'provider'); $provName = switch -Regex ($prov) { '^(?i)(i|icu)$' { 'ICU' } '^(?i)(c|libc)$' { 'libc' } '^(?i)(b|builtin)$' { 'builtin' } default { $prov } }
                $det = Get-Field $icu 'deterministic'
                $detTxt = if ($null -eq $det) { 'deterministic: (not captured)' } elseif (ConvertTo-Flag $det) { 'deterministic' } else { 'nondeterministic' }
                $loc = [string](Get-Field $icu 'locale')
                $strength = if ($loc -match '(?i)ks-level1') { 'case- and accent-insensitive for =, sorting and grouping' } elseif ($loc -match '(?i)ks-level2') { 'case-insensitive, accent-sensitive for =, sorting and grouping' } else { $null }
                $colTxt = 'Acumatica''s text columns use its ' + $(if ($provName) { $provName + ' ' } else { '' }) + 'collation ' + $colName + ' (' + $detTxt + '; locale ' + (Format-EnvValue $loc) + ')' + $(if ($strength) { ': ' + $strength } else { '' })
            }
            elseif ($colName -and $colName -ne 'default') { $colTxt += ' (collation details not captured)' }
            return ($defTxt + '; ' + $colTxt + $(if ($colSummary) { ' (text columns: ' + $colSummary + ')' } else { '' }) + '. LIKE becomes ILIKE with COLLATE "default" (the database default): case-insensitive, accent-sensitive (' + $probe + ')')
        }
    }
    return '(not captured)'
}

function ConvertTo-UtcTime {
    # An ISO timestamp (or a DateTime) as a UTC DateTime, or $null.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    $d = [datetime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
    if ([datetime]::TryParse([string]$Value, $script:Inv, $styles, [ref]$d)) { return $d }
    return $null
}

function Format-UtcMinute {
    param($Value)
    $d = ConvertTo-UtcTime $Value
    if ($null -eq $d) { return [string]$Value }
    return ($d.ToString('yyyy-MM-dd HH:mm', $script:Inv) + 'Z')
}

function Format-ThrottleFailure {
    # One failure of a licence-telemetry gate (Get-PcThrottleVerdict text), with the engine's display name. The error
    # text of an engine whose licence tables could not be read is not published (it stays in the campaign files).
    param([string]$Text)
    $t = $Text.Trim()
    if ($t -match '^(SQLServer|MySQL|PostgreSQL):\s*(.*)$') {
        $eng = $Matches[1]; $rest = $Matches[2]
        if ($rest -match '^(?i)(licence monitor not readable)') { $rest = 'licence monitor not readable (the error is in the campaign files)' }
        $t = (Get-EngineName $eng) + ': ' + $rest
    }
    elseif ($t -match '(?i)not readable') { $t = 'licence monitor not readable (the error is in the campaign files)' }
    # the reading's checkpoint is printed once per gate
    $t = $t -replace ' since \d{4}-\d\d-\d\dT[0-9:.]+Z?', ''
    if ($t.Length -gt 220) { $t = $t.Substring(0, 217) + '...' }
    return $t
}

function Get-ThrottleGates {
    # E14 backstop (contract C5): Run-Campaign's licence-telemetry gates (post-part-1, pre-Block-D, after Block D), from
    # the full records in throttle-readings.json (checkpoints[]) or the summaries in run-campaign-state.json
    # (throttleReadings[]). Each reading covers its checkpoint (sinceUtc) up to the monitor's write before checkedAtUtc,
    # so the latest record of a gate counts; earlier records of the same gate are only noted.
    param($Data)
    $ids = @($Data.campaignIds | Where-Object { $_ })
    $list = @()
    $tr = $Data.throttleReadings
    if (Test-IsMap $tr) {
        $trId = [string](Get-Field $tr 'campaignId')
        if (-not $trId -or $ids.Count -eq 0 -or $ids -contains $trId) { $list = @(@(Get-Field $tr 'checkpoints') | Where-Object { Test-IsMap $_ }) }
        else { Write-Warning ('throttle-readings.json belongs to campaign ' + $trId + ': not used.') }
    }
    if ($list.Count -eq 0 -and (Test-IsMap $Data.runCampaignState)) {
        $stId = [string](Get-Field $Data.runCampaignState 'campaignId')
        if (-not $stId -or $ids.Count -eq 0 -or $ids -contains $stId) { $list = @(@(Get-Field $Data.runCampaignState 'throttleReadings') | Where-Object { Test-IsMap $_ }) }
    }
    $byName = [ordered]@{}
    foreach ($r in $list) {
        $name = [string](Get-Field $r 'name'); if (-not $name) { $name = '(unnamed reading)' }
        $okRaw = Get-Field $r 'ok'
        $ok = ($null -ne $okRaw) -and (ConvertTo-Flag $okRaw)
        $failures = @(@(Get-Field $r 'failures') | Where-Object { $null -ne $_ -and [string]$_ -ne '' } | ForEach-Object { Format-ThrottleFailure ([string]$_) })
        $waitOk = Get-Field (Get-Field $r 'wait') 'ok'
        if (($null -ne $waitOk -and -not (ConvertTo-Flag $waitOk)) -or (-not $ok -and $failures.Count -eq 0)) {
            $failures += 'the licence monitor''s 10-minute write covering the last run was not seen in time, so the reading is incomplete'
        }
        $prev = $(if ($byName.Contains($name)) { $byName[$name] } else { $null })
        $byName[$name] = [pscustomobject]@{
            name = $name; sinceUtc = [string](Get-Field $r 'sinceUtc'); checkedAtUtc = [string](Get-Field $r 'checkedAtUtc')
            since = ConvertTo-UtcTime (Get-Field $r 'sinceUtc'); checkedAt = ConvertTo-UtcTime (Get-Field $r 'checkedAtUtc')
            ok = [bool]$ok; failures = $failures
            attempts = $(if ($prev) { $prev.attempts + 1 } else { 1 })
            earlierFailed = $(if ($prev) { $prev.earlierFailed -or -not $prev.ok } else { $false })
        }
    }
    return , @($byName.Values)
}

function Get-ThrottleUncovered {
    # The parts of the campaign (part 1 = Blocks A-C, Block D) whose runs no passed licence-telemetry reading covers
    # (reading since <= first run start and taken after the last run start).
    param($Data, [object[]]$Gates)
    $groups = [ordered]@{ 'part 1 (Blocks A-C)' = @(); 'Block D' = @() }
    foreach ($r in @($Data.runs)) {
        $b = [string](Get-Field $r 'block')
        if (-not $b -or $b -eq 'G') { continue }
        $t = ConvertTo-UtcTime (Get-Field $r 'startedAtUtc')
        if ($null -eq $t) { continue }
        $g = $(if ($b -eq 'D') { 'Block D' } else { 'part 1 (Blocks A-C)' })
        $groups[$g] = @($groups[$g]) + $t
    }
    $out = @()
    foreach ($g in @($groups.Keys)) {
        $ts = @($groups[$g] | Sort-Object)
        if ($ts.Count -eq 0) { continue }
        $first = $ts[0]; $last = $ts[-1]
        $cov = @($Gates | Where-Object { $_.ok -and $null -ne $_.since -and $null -ne $_.checkedAt -and $_.since -le $first -and $_.checkedAt -ge $last })
        if ($cov.Count -eq 0) { $out += $g }
    }
    return , $out
}

function Get-EnvCaptureLabel {
    # "Block A repetition 2" (or the capture time) of one ENV_CAPTURE
    param($Ec)
    $b = [string](Get-Field $Ec 'block'); $rep = Get-Field $Ec 'repetitionNo'
    if ($b) { return ('Block ' + $b + $(if ($null -ne $rep -and [string]$rep -ne '') { ' repetition ' + [string]$rep } else { '' })) }
    return ('captured ' + (Format-UtcMinute (Get-Field $Ec 'capturedAtUtc')))
}

function Get-SqlThrottlingText {
    # E14 (user decision 2026-10-04): Acumatica's SQL throttle of unlicensed sites (PX.Data LeakyBucketSqlThrottling)
    # is switched off on all three sites with <add key="sqlThrottling:Enabled" value="false" />. Two proofs:
    #  - contract C1: env.app.sqlThrottling.optionsEnabled = false in EVERY ENV_CAPTURE on every engine (a capture
    #    without env.app.sqlThrottling is not a proof and is named);
    #  - contract C5 backstop: Run-Campaign's licence-telemetry gates (no SQL throttling, no reduced mode in ChartID 8
    #    since the checkpoint on all three), covering part 1 and Block D.
    # "Proven" only when both hold. Without any C1 data the web.config facts of the environment capture are reported.
    param($Data, [string[]]$Engines)
    $all = $(if (@($Engines).Count -eq 3) { 'all three sites' } else { 'every site' })
    $per = [ordered]@{}
    foreach ($e in @($Engines)) { $per[$e] = [ordered]@{ captures = 0; withC1 = 0; off = 0; other = @(); noC1 = @() } }
    foreach ($ec in @($Data.envCaptures)) {
        $eng = Get-InstanceEngine $Data ([string](Get-Field $ec 'instance'))
        if (-not $per.Contains($eng)) { continue }
        $per[$eng].captures++
        $st = Get-PathValue $ec 'env.app.sqlThrottling'
        if (-not (Test-IsMap $st)) { $per[$eng].noC1 += (Get-EnvCaptureLabel $ec); continue }
        $per[$eng].withC1++
        $oe = Get-Field $st 'optionsEnabled'
        if ($oe -is [bool] -and -not $oe) { $per[$eng].off++ }
        else {
            $er = [string](Get-Field $st 'error')
            if ($er.Length -gt 120) { $er = $er.Substring(0, 117) + '...' }
            $per[$eng].other += ('optionsEnabled ' + $(if ($null -eq $oe) { 'null' } else { [string]$oe }) + $(if ($er) { ' (' + $er + ')' } else { '' }))
        }
    }
    $anyC1 = @($per.Keys | Where-Object { $per[$_].withC1 -gt 0 }).Count -gt 0
    $capCounts = ((@($per.Keys) | ForEach-Object { (Get-EngineName $_) + ' ' + $per[$_].captures }) -join ', ')
    $capProblems = @()
    if ($anyC1) {
        foreach ($e in @($per.Keys)) {
            $x = $per[$e]
            if ($x.captures -eq 0) { $capProblems += ((Get-EngineName $e) + ': no environment capture'); continue }
            if ($x.off -ne $x.withC1) { $capProblems += ((Get-EngineName $e) + ': ' + ($x.withC1 - $x.off) + ' of ' + $x.captures + ' captures not off (' + (@($x.other | Select-Object -Unique | Select-Object -First 2) -join '; ') + ')') }
            if (@($x.noC1).Count) { $capProblems += ((Get-EngineName $e) + ': ' + @($x.noC1).Count + ' of ' + $x.captures + ' captures without the runtime state (' + (@($x.noC1 | Select-Object -First 3) -join ', ') + $(if (@($x.noC1).Count -gt 3) { ' and ' + (@($x.noC1).Count - 3) + ' more' } else { '' }) + ')') }
        }
    }
    $capProven = $anyC1 -and @($Engines).Count -gt 0 -and $capProblems.Count -eq 0

    # licence-telemetry backstop
    $gates = Get-ThrottleGates $Data; $gates = @($gates)
    $failedGates = @($gates | Where-Object { -not $_.ok })
    $uncovered = @()
    if ($gates.Count) { $uncovered = Get-ThrottleUncovered $Data $gates; $uncovered = @($uncovered) }
    $gateNames = ((@($gates) | ForEach-Object { $_.name + ' since ' + (Format-UtcMinute $_.sinceUtc) }) -join ', ')
    $gateFailTxt = ((@($failedGates) | ForEach-Object { 'licence telemetry ' + $_.name + ' since ' + (Format-UtcMinute $_.sinceUtc) + ': ' + (@($_.failures) -join '; ') }) -join '; ')
    $earlier = @($gates | Where-Object { $_.ok -and $_.earlierFailed } | ForEach-Object { $_.name })
    $earlierTxt = $(if ($earlier.Count) { ' (an earlier reading of ' + ($earlier -join ', ') + ' did not pass; the latest reading covers the same period)' } else { '' })
    $delays = 'Acumatica''s SQL throttle of unlicensed sites delays SQL calls once too much SQL time builds up; results of the affected sites may include its delays'

    if ($anyC1) {
        if ($capProven -and $gates.Count -and $failedGates.Count -eq 0 -and $uncovered.Count -eq 0) {
            return ('off on ' + $all + ' (sqlThrottling:Enabled=false); a licensed on-premises installation never starts this throttle. Proven at run time: the setting in effect was off in every environment capture (' + $capCounts + '), and Acumatica''s own licence telemetry recorded no SQL throttling and no reduced mode on any of the three sites (readings ' + $gateNames + ')' + $earlierTxt)
        }
        if (-not $capProven -or $failedGates.Count) {
            $why = @($capProblems)
            if ($failedGates.Count) { $why += $gateFailTxt }
            $good = @()
            if ($capProven) { $good += ('the setting in effect was off in every environment capture (' + $capCounts + ')') }
            if ($gates.Count -and $failedGates.Count -eq 0) { $good += ('Acumatica''s licence telemetry recorded no SQL throttling and no reduced mode (readings ' + $gateNames + ')') }
            elseif ($gates.Count -eq 0) { $good += 'Acumatica''s licence telemetry was not read for this campaign' }
            return ('NOT proven off on ' + $all + ': ' + ($why -join '; ') + $(if ($good.Count) { ' (' + ($good -join '; ') + ')' } else { '' }) + '. ' + $delays)
        }
        # every capture off, every reading passed, but the backstop is missing or does not cover the whole campaign
        $gap = $(if ($gates.Count -eq 0) { 'Acumatica''s licence telemetry (the backstop) was not read for this campaign' } else { 'Acumatica''s licence telemetry recorded no SQL throttling and no reduced mode in the readings taken (' + $gateNames + '), but no reading covers ' + ($uncovered -join ' or ') })
        return ('off on ' + $all + ' (sqlThrottling:Enabled=false); a licensed on-premises installation never starts this throttle. The setting in effect was off in every environment capture (' + $capCounts + '); ' + $gap + ', so the run-time proof is incomplete' + $earlierTxt)
    }

    # no runtime state in any capture: the web.config facts of the environment capture (appSettings.sqlThrottling,
    # mirrored as webConfig['sqlThrottling:Enabled'] by Get-PerfEnvironment)
    $facts = @()
    $insts = Get-PathValue $Data.start 'acumatica.instances'
    foreach ($i in (Get-Keys $insts)) {
        $entry = Get-Field $insts $i
        $v = Get-Field (Get-Field $entry 'appSettings') 'sqlThrottling'
        if ($null -eq $v) {
            $wc = Get-Field $entry 'webConfig'
            foreach ($k in @('sqlThrottling:Enabled', 'sqlThrottlingEnabled', 'sqlThrottling')) { $v = Get-Field $wc $k; if ($null -ne $v) { break } }
        }
        $facts += [pscustomobject]@{ engine = (Get-InstanceEngine $Data $i); value = $v }
    }
    $isOff = { param($x) ([string]$x).Trim() -match '^(?i)false$' }
    $offEngines = @($facts | Where-Object { & $isOff $_.value } | ForEach-Object { $_.engine } | Select-Object -Unique)
    $webOff = $facts.Count -gt 0 -and @($facts | Where-Object { -not (& $isOff $_.value) }).Count -eq 0 -and @($Engines | Where-Object { $offEngines -notcontains $_ }).Count -eq 0
    if ($failedGates.Count) {
        return ('NOT proven off on ' + $all + ': ' + $gateFailTxt + $(if ($webOff) { ' (set off in web.config on ' + $all + '; the runtime state was not captured)' } else { '' }) + '. ' + $delays)
    }
    $gateOk = $(if ($gates.Count -and $uncovered.Count -eq 0) { '; Acumatica''s licence telemetry recorded no SQL throttling and no reduced mode (readings ' + $gateNames + ')' + $earlierTxt } elseif ($gates.Count) { '; Acumatica''s licence telemetry recorded no SQL throttling and no reduced mode in the readings taken (' + $gateNames + '), but no reading covers ' + ($uncovered -join ' or ') } else { '' })
    if ($webOff) { return ('set off in web.config on ' + $all + ' (sqlThrottling:Enabled=false); a licensed on-premises installation never starts this throttle. The runtime state was not captured' + $gateOk) }
    return ('(not captured): whether Acumatica''s SQL throttle of unlicensed sites was off is not recorded in this campaign' + $gateOk)
}

function Get-AppCpuCores {
    # Acumatica (w3wp) CPU in the measured phase, in cores: result.appCpuMs / result.phasesMs.measured, for runs with 4 or
    # more users and a measured phase of at least 5 s (the runs that keep Acumatica busy).
    param($A)
    $out = [ordered]@{}
    $users = @{}; foreach ($t in @($A.tests)) { $users[$t.code] = $t.users }
    foreach ($e in @($A.engines)) {
        $vals = @(foreach ($r in @($A.runs | Where-Object { $_.engine -eq $e -and $_.valid -and -not $_.isWarmup -and $users.ContainsKey($_.testCode) -and $users[$_.testCode] -ge 4 })) {
                $app = ConvertTo-Num (Get-Field $r.result 'appCpuMs'); $ms = ConvertTo-Num (Get-PathValue $r.result 'phasesMs.measured')
                if ($null -ne $app -and $null -ne $ms -and $ms -ge 5000 -and $app -gt 0) { $app / $ms }
            })
        if ($vals.Count) { $out[$e] = [ordered]@{ runs = $vals.Count; medianCores = (Get-Median ([double[]]$vals)); maxCores = (($vals | Measure-Object -Maximum).Maximum) } }
    }
    return $out
}

function Get-PCoreShareText {
    # "(about 0.67 performance cores on average)" for a random 2-core pick, from the host's performance/efficiency core
    # counts when the environment capture has them; otherwise $null (never guessed).
    param($Data)
    $h = @((Get-Field $Data.start 'host'))
    $p = ConvertTo-Num (Find-Setting $h @('pCores', 'performanceCores'))
    $e = ConvertTo-Num (Find-Setting $h @('eCores', 'efficiencyCores'))
    if ($null -eq $p -or $null -eq $e -or ($p + $e) -le 0) { return $null }
    return ('on this CPU with ' + [int]$p + ' performance and ' + [int]$e + ' efficiency cores, about ' + ([Math]::Round(2.0 * $p / ($p + $e), 2)).ToString($script:Inv) + ' performance cores on average')
}

function Get-AffinityText {
    # User decision 2026-10-04: Acumatica's CPU pinning of unlicensed sites is kept as installed (ResourceGovernor pins
    # each w3wp to 2 random cores, redrawn every 60 s; the licence observer briefly widens it to 4 random cores every
    # 5-30 min); recorded and disclosed only. A random pick mixes performance and efficiency cores, so short tests are
    # noisier. Observed: contract C1 env.app.processAffinity (bits of the affinity mask at each ENV_CAPTURE: snapshots
    # of a mask that changes every minute) and the Acumatica CPU of the busy runs.
    param($Data, $A)
    $share = Get-PCoreShareText $Data
    $txt = 'Acumatica default for an unlicensed site: each site''s worker process is pinned to 2 random cores, picked again every minute (briefly 4); kept as installed, identically on all three sites. A random pick can land on performance or efficiency cores' + $(if ($share) { ' (' + $share + ')' } else { '' }) + ', so short tests are noisier'
    $bits = [ordered]@{}; $lcpu = $null
    foreach ($ec in @($Data.envCaptures)) {
        $pa = Get-PathValue $ec 'env.app.processAffinity'
        if (-not (Test-IsMap $pa)) { continue }
        $b = ConvertTo-Num (Get-Field $pa 'bits'); $pc = ConvertTo-Num (Get-Field $pa 'processorCount')
        if ($null -ne $pc) { $lcpu = $pc }
        if ($null -eq $b) { continue }
        $eng = Get-InstanceEngine $Data ([string](Get-Field $ec 'instance'))
        if (-not $bits.Contains($eng)) { $bits[$eng] = @() }
        $bits[$eng] += [int]$b
    }
    if ($bits.Count) {
        $txt += '. Cores in the worker process''s affinity mask at the environment captures (snapshots of a mask that changes every minute' + $(if ($lcpu) { '; of ' + [int]$lcpu + ' logical CPUs' } else { '' }) + '): ' + ((@($A.engines) | ForEach-Object { $e = $_; (Get-EngineName $e) + ' ' + $(if ($bits.Contains($e)) { (@($bits[$e] | Sort-Object -Unique) -join '/') + ' (' + @($bits[$e]).Count + ' captures)' } else { '(not captured)' }) }) -join ', ')
    }
    else { $txt += '. Affinity mask at the environment captures: (not captured)' }
    $cores = Get-AppCpuCores $A
    if ($cores.Count) {
        $txt += '. Acumatica CPU in the measured phase of the runs with 4 or more users: ' + ((@($cores.Keys) | ForEach-Object { (Get-EngineName $_) + ' median ' + (Format-Sig3 $cores[$_].medianCores) + ' cores (max ' + (Format-Sig3 $cores[$_].maxCores) + ')' }) -join ', ')
    }
    return $txt
}

function Get-SqlLogChainText {
    # SPEC 6.5 / D1: the SQL Server log chain as checked live by Run-Campaign before the campaign (run-campaign-state.json).
    param($Data)
    $lc = Get-Field $Data.runCampaignState 'sqlLogChain'
    if (-not (Test-IsMap $lc)) { return $null }
    $active = Get-Field $lc 'active'
    $detail = [string](Get-Field $lc 'detail')
    $when = [string](Get-Field $lc 'checkedAtUtc')
    $head = if ($null -eq $active) { 'log chain state not recorded' } elseif (ConvertTo-Flag $active) { 'log chain active' } else { 'log chain inactive' }
    return ($head + $(if ($detail) { ' (' + $detail + ')' } else { '' }) + $(if ($when) { ', checked ' + $when } else { '' }))
}

function Get-EnvChanges {
    # SPEC 6.4: every difference between the start and end environment captures other than uptime and other volatile
    # fields (listed by Get-PerfEnvironment in volatileFields) is listed in the README. Keys added by
    # Add-EnvShapeAliases (copies of other keys) are skipped, so each change appears once.
    param($Data)
    $out = @()
    if (-not $Data.start -or -not $Data.end) { return , $out }
    $a = [ordered]@{}; Get-EnvLeafMap $Data.start '' $a
    $b = [ordered]@{}; Get-EnvLeafMap $Data.end '' $b
    $volatile = @(@(Get-Field $Data.start 'volatileFields') | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $volatile += @('volatileFields', 'errors', 'sqlServer', 'mySql', 'postgreSql', 'drivers', 'host.cpuName', 'host.logicalCpus', 'host.powerScheme', 'host.osCaption', 'antivirus.exclusions', 'kind', 'options')
    $keys = @($a.Keys) + @($b.Keys | Where-Object { -not $a.Contains($_) })
    $short = { param([string]$s) if ($null -eq $s) { return $null }; if ($s.Length -gt 200) { return $s.Substring(0, 200) + '...' }; return $s }
    foreach ($k in $keys) {
        if ($k -match '(?i)(uptime|capturedAt|generatedAt|lastBoot|bootTime|databaseSizeMb$|\.query_store$|^label$)') { continue }
        if (@($volatile | Where-Object { $k -eq $_ -or $k.StartsWith($_ + '.') -or $k.StartsWith($_ + '[') }).Count -gt 0) { continue }
        $va = if ($a.Contains($k)) { $a[$k] } else { $null }
        $vb = if ($b.Contains($k)) { $b[$k] } else { $null }
        if ($va -is [System.Collections.IList] -or $vb -is [System.Collections.IList]) {
            # a list of plain values (for example running services) is compared as a set
            $sa = @($va | Where-Object { $null -ne $_ }); $sb = @($vb | Where-Object { $null -ne $_ })
            $added = @($sb | Where-Object { $sa -notcontains $_ }); $removed = @($sa | Where-Object { $sb -notcontains $_ })
            if ($added.Count -or $removed.Count) {
                $out += [ordered]@{ key = $k; start = (& $short ('removed: ' + $(if ($removed.Count) { $removed -join ', ' } else { 'none' }))); end = (& $short ('added: ' + $(if ($added.Count) { $added -join ', ' } else { 'none' }))) }
            }
            continue
        }
        if ([string]$va -ne [string]$vb) { $out += [ordered]@{ key = $k; start = (& $short ([string]$va)); end = (& $short ([string]$vb)) } }
    }
    return , $out
}

function Get-EnvLeafMap {
    # Like Get-LeafMap, but a list of plain values is kept as one leaf (a sorted string array) so that start and end
    # can be compared as sets instead of position by position.
    param($Obj, [string]$Prefix, [System.Collections.IDictionary]$Into)
    if ($null -eq $Obj) { return }
    if (Test-IsMap $Obj) {
        foreach ($k in (Get-Keys $Obj)) {
            if ($Obj -is [System.Collections.IDictionary]) { $item = $Obj[$k] } else { $item = $Obj.PSObject.Properties[$k].Value }
            Get-EnvLeafMap $item $(if ($Prefix) { $Prefix + '.' + $k } else { $k }) $Into
        }
        return
    }
    if (Test-IsList $Obj) {
        $items = @($Obj)
        if (@($items | Where-Object { (Test-IsMap $_) -or (Test-IsList $_) }).Count -eq 0) {
            $Into[$Prefix] = [string[]]@($items | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
            return
        }
        $i = 0
        foreach ($x in $items) {
            $name = $null
            if (Test-IsMap $x) { foreach ($nk in @('name', 'Name', 'Variable_name', 'key')) { $nv = Get-Field $x $nk; if ($nv) { $name = [string]$nv; break } } }
            Get-EnvLeafMap $x ($Prefix + '[' + $(if ($name) { $name } else { $i }) + ']') $Into
            $i++
        }
        return
    }
    $Into[$Prefix] = [string]$Obj
}

function Get-Diagnostics {
    param($Data, [object[]]$Runs, [object[]]$Tests, $Cells, [string[]]$Engines, [int]$NSlots)
    $d = [ordered]@{}
    # position effect: mean of value / cell median - 1 by running position (1st, 2nd, 3rd)
    $pos = @{ 1 = @(); 2 = @(); 3 = @() }
    foreach ($t in $Tests) {
        foreach ($c in @($Cells[$t.code])) {
            if ($null -eq $c.median -or (Test-Inf $c.median) -or $c.median -le 0) { continue }
            foreach ($r in $c.selectedRuns) {
                if ($r.capped -or -not $r.pos) { continue }
                $tv = Get-TimePerUnit $r.headlineValue $t.higherIsBetter $false
                if ($null -ne $tv -and $pos.ContainsKey([int]$r.pos)) { $pos[[int]$r.pos] += ($tv / $c.median - 1.0) }
            }
        }
    }
    $d.positionEffectPct = @(1, 2, 3 | ForEach-Object { if ($pos[$_].Count) { Get-Round (100.0 * (($pos[$_] | Measure-Object -Average).Average)) 3 } else { $null } })
    # drift: median of repetitions 4-6 vs 1-3
    $drift = [ordered]@{}
    $half = [int][Math]::Floor($NSlots / 2)
    foreach ($t in $Tests) {
        $row = [ordered]@{}
        foreach ($c in @($Cells[$t.code])) {
            $a = [double[]]@(); $b = [double[]]@()
            for ($i = 0; $i -lt $c.timePerUnitMs.Count; $i++) {
                $v = $c.timePerUnitMs[$i]
                if ($null -eq $v -or (Test-Inf $v)) { continue }
                if ($i -lt $half) { $a += $v } else { $b += $v }
            }
            $row[$c.engine] = $(if ($a.Count -and $b.Count) { Get-Round (100.0 * ((Get-Median $b) / (Get-Median $a) - 1.0)) 3 } else { $null })
        }
        $drift[$t.code] = $row
    }
    $d.driftPct = $drift
    # throttle indicator: % Processor Performance and temperature sampled by the suite
    $thr = [ordered]@{}
    foreach ($e in $Engines) {
        $er = @($Runs | Where-Object { $_.engine -eq $e -and -not $_.isWarmup -and $null -ne $_.perfAvgPct })
        $tc = @($Runs | Where-Object { $_.engine -eq $e -and $null -ne $_.tempC })
        $thr[$e] = [ordered]@{ meanProcessorPerformancePct = $(if ($er.Count) { Get-Round (($er | Measure-Object -Property perfAvgPct -Average).Average) 2 } else { $null }); maxTempC = $(if ($tc.Count) { ($tc | Measure-Object -Property tempC -Maximum).Maximum } else { $null }); runs = $er.Count }
    }
    $d.throttleIndicator = $thr
    foreach ($k in @('cacheDefeatProbe', 'aaCalibration', 'statementsPerOp', 'transportAB', 'apiReadMs', 'spillsAndJit', 'sqlServerPlanCheck')) {
        $d[$k] = $(if ($Data.diagnosticsIn.Contains($k)) { $Data.diagnosticsIn[$k] } else { 'not provided' })
    }
    # End-to-end API read (dry run 3l, contract C4): only the measurement fields are published (analysis.json, README);
    # diagnostics.apiReadProbe is read for the not-available reason (endpoint and exception type) and never copied.
    $d.apiReadMs = Get-ApiReadPublished $d.apiReadMs
    $d.apiReadSummary = Get-ApiReadSummary $Data $d.apiReadMs $Cells $Runs $Engines
    # SQL Server plan check (dry run 3m) may also be recorded in decisions.json
    if ($d.sqlServerPlanCheck -is [string] -and $Data.decisions) { $pc = Get-Field $Data.decisions 'sqlServerPlanCheck'; if ($null -ne $pc) { $d.sqlServerPlanCheck = $pc } }
    # Statements per operation and spills/JIT from the DryRun -Diagnostics engine counters. The suite stores them per
    # run as diagnostics = { engine, start, end, delta = { counter: value } } (Get-PerfEnvironment -EngineCounters);
    # a flat diagnostics object (counters at the top level) is read as well.
    $spo = [ordered]@{}
    $sj = [ordered]@{}
    foreach ($r in @($Runs | Where-Object { $_.diagnostics })) {
        $dl = Get-Field $r.diagnostics 'delta'
        if (-not (Test-IsMap $dl)) { $dl = $r.diagnostics }
        $cnt = $null
        foreach ($k in @('batchRequests', 'Batch Requests/sec', 'Questions', 'pgssCalls', 'pgStatStatementsCalls', 'calls', 'statements')) { $x = ConvertTo-Num (Get-Field $dl $k); if ($null -ne $x) { $cnt = $x; break } }
        $ops = (Get-RunCpu $r); $n = if ($ops) { $ops.ops } else { $r.opsCount }
        if ($null -ne $cnt -and $n) { if (-not $spo.Contains($r.testCode)) { $spo[$r.testCode] = [ordered]@{} }; $spo[$r.testCode][$r.engine] = Get-Round ($cnt / $n) 2 }
        # spills to disk and JIT per report test (dry run 3d, Table 2)
        if ($r.family -ne 'Reports' -and $r.testCode -notlike 'RPT_*') { continue }
        $txt = $null
        switch ($r.engine) {
            'SQLServer' {
                $sp = ConvertTo-Num (Get-Field $dl 'totalSpills')
                if ($null -ne $sp) { $txt = $(if ($sp -gt 0) { 'spilled to tempdb (total_spills +' + (Format-Sig3 $sp) + ')' } else { 'no spill' }) }
            }
            'MySQL' {
                $tmp = ConvertTo-Num (Get-Field $dl 'Created_tmp_disk_tables'); $smp = ConvertTo-Num (Get-Field $dl 'Sort_merge_passes')
                if ($null -ne $tmp -or $null -ne $smp) {
                    $txt = $(if ((0 + $tmp) -gt 0 -or (0 + $smp) -gt 0) { 'Created_tmp_disk_tables +' + (Format-Sig3 (0 + $tmp)) + ', Sort_merge_passes +' + (Format-Sig3 (0 + $smp)) } else { 'no on-disk temporary table or sort merge pass' })
                }
            }
            'PostgreSQL' {
                $tf = ConvertTo-Num (Get-Field $dl 'tempFiles'); $tb = ConvertTo-Num (Get-Field $dl 'tempBytes'); $jf = ConvertTo-Num (Get-Field $dl 'jitFunctions')
                $partsPg = @()
                if ($null -ne $tf) { $partsPg += $(if ($tf -gt 0) { 'temp_files +' + (Format-Sig3 $tf) + $(if ($null -ne $tb) { ' (' + (Format-Sig3 ($tb / 1MB)) + ' MB)' } else { '' }) } else { 'temp_files 0' }) }
                if ($null -ne $jf) { $partsPg += $(if ($jf -gt 0) { 'JIT used (' + (Format-Sig3 $jf) + ' functions)' } else { 'JIT not used' }) }
                elseif ($partsPg.Count) { $partsPg += 'JIT not measured (pg_stat_statements not loaded)' }
                if ($partsPg.Count) { $txt = $partsPg -join '; ' }
            }
        }
        if ($txt) { if (-not $sj.Contains($r.testCode)) { $sj[$r.testCode] = [ordered]@{} }; $sj[$r.testCode][$r.engine] = $txt }
    }
    if ($spo.Count -gt 0) {
        # hand-entered diagnostics.statementsPerOp values are kept (they override a derived value of the same test and engine)
        $manualSpo = $Data.diagnosticsIn['statementsPerOp']
        if (Test-IsMap $manualSpo) { foreach ($t in (Get-Keys $manualSpo)) { foreach ($e in (Get-Keys (Get-Field $manualSpo $t))) { if (-not $spo.Contains($t)) { $spo[$t] = [ordered]@{} }; $spo[$t][$e] = Get-Field (Get-Field $manualSpo $t) $e } } }
        $d.statementsPerOp = $spo
    }
    # an explicit diagnostics.spillsAndJit (hand-entered) overrides the derived values, test by test and engine by engine
    if ($sj.Count -gt 0) {
        $manual = $Data.diagnosticsIn['spillsAndJit']
        if (Test-IsMap $manual) { foreach ($t in (Get-Keys $manual)) { foreach ($e in (Get-Keys (Get-Field $manual $t))) { if (-not $sj.Contains($t)) { $sj[$t] = [ordered]@{} }; $sj[$t][$e] = Get-Field (Get-Field $manual $t) $e } } }
        $d.spillsAndJit = $sj
    }
    # Residue tables (dry run 3n, SPEC 5.4 item 19): tables whose row count changed, from table-counts-*.json
    $d.residueTables = Get-ResidueTables $Data $Engines
    # The campaign's residue (contract C2): campaign end against the campaign baseline, exact row counts per engine
    $d.campaignResidue = Get-CampaignResidue $Data $Engines
    # Start/end environment differences (SPEC 6.4), listed in the environment fragment
    $d.environmentChanges = Get-EnvChanges $Data
    # background work left behind, per block: database CPU used while its engine was idle / CPU used in its own runs
    $bg = [ordered]@{}
    foreach ($blk in @($Runs | Where-Object { $_.block -and $_.block -ne 'G' } | ForEach-Object { $_.block } | Select-Object -Unique | Sort-Object)) {
        $row = [ordered]@{}
        foreach ($e in $Engines) {
            $own = 0.0; $idle = 0.0
            foreach ($r in @($Runs | Where-Object { $_.block -eq $blk })) {
                if ($r.engine -eq $e) { $c = Get-RunCpu $r; if ($c -and $null -ne $c.dbCpuMs) { $own += $c.dbCpuMs } }
                else { $o = Get-OthersCpu $r; if ($o.ContainsKey($e)) { $idle += $o[$e] } }
            }
            $row[$e] = $(if ($own -gt 0) { Get-Round (100.0 * $idle / $own) 2 } else { $null })
        }
        $bg[$blk] = $row
    }
    $d.backgroundLeftBehindPct = $bg
    $st = [ordered]@{}
    foreach ($blk in @($Runs | Where-Object { $_.block -and $_.block -ne 'G' } | ForEach-Object { $_.block } | Select-Object -Unique | Sort-Object)) {
        $br = @($Runs | Where-Object { $_.block -eq $blk -and $_.status -ne 'Failed' })
        $to = @($br | Where-Object { $_.settleTimedOut }).Count
        $st[$blk] = $(if ($br.Count) { Get-Round (100.0 * $to / $br.Count) 2 } else { $null })
    }
    $d.settleTimeoutsPct = $st
    $out = @()
    foreach ($t in $Tests) { foreach ($c in @($Cells[$t.code])) { foreach ($o in @($c.outliers)) { $out += [ordered]@{ testCode = $t.code; engine = $c.engine; repetitionNo = $o.repetitionNo; ratioToCellMedian = $o.ratio } } } }
    $d.outliers = [ordered]@{ total = $out.Count; rule = ('value outside [{0}, {1}] x the cell median; flagged and counted, never re-run or dropped' -f $TieRule.outlierLow, $TieRule.outlierHigh); items = $out }
    # Block D data differences: D-affected keys of the latest Block D ENV_CAPTURE per instance, gate warnings, failed operations
    $dd = [ordered]@{ dAffectedKeys = [ordered]@{}; differs = $false; gateWarnings = @(); failedOps = [ordered]@{} }
    $latest = @{}
    foreach ($ec in @($Data.envCaptures | Where-Object { [string](Get-Field $_ 'block') -eq 'D' })) {
        $inst = [string](Get-Field $ec 'instance'); $rep = ConvertTo-Num (Get-Field $ec 'repetitionNo')
        if (-not $latest.ContainsKey($inst) -or $rep -gt (ConvertTo-Num (Get-Field $latest[$inst] 'repetitionNo'))) { $latest[$inst] = $ec }
    }
    foreach ($inst in $latest.Keys) {
        $map = [ordered]@{}; Get-LeafMap (Get-PathValue $latest[$inst] 'env.dataFingerprint.dAffected') '' $map
        foreach ($k in $map.Keys) { if (-not $dd.dAffectedKeys.Contains($k)) { $dd.dAffectedKeys[$k] = [ordered]@{} }; $dd.dAffectedKeys[$k][$inst] = $map[$k] }
    }
    foreach ($k in @($dd.dAffectedKeys.Keys)) { if (@($dd.dAffectedKeys[$k].Values | Select-Object -Unique).Count -gt 1) { $dd.differs = $true } }
    $dd.gateWarnings = @($Data.events | Where-Object { [string](Get-Field $_ 'kind') -eq 'GateWarning' -and ([string](Get-Field $_ 'detail')) -match '(?i)G2d|block d' } | ForEach-Object { [string](Get-Field $_ 'detail') })
    foreach ($r in @($Runs | Where-Object { $_.block -eq 'D' })) {
        $fo = @(Get-PathValue $r.result 'errors.failedOps')
        if ($fo.Count -gt 0 -and $fo[0]) { if (-not $dd.failedOps.Contains($r.instance)) { $dd.failedOps[$r.instance] = @() }; $dd.failedOps[$r.instance] += @($fo | ForEach-Object { $r.testCode + ' rep ' + $r.rep + ': ' + $_ }) }
    }
    $d.blockDDataDiff = $dd
    $ev = [ordered]@{}
    foreach ($e in @($Data.events)) { $k = [string](Get-Field $e 'kind'); if (-not $k) { continue }; if ($ev.Contains($k)) { $ev[$k]++ } else { $ev[$k] = 1 } }
    $d.events = $ev
    $inv = [ordered]@{}
    foreach ($r in @($Runs | Where-Object { $_.testCode -ne 'ENV_CAPTURE' })) { $k = if ($r.isWarmup) { 'warm-up' } else { $r.status }; if ($inv.Contains($k)) { $inv[$k]++ } else { $inv[$k] = 1 } }
    $d.runInventory = $inv
    $mism = @()
    foreach ($t in $Tests) { foreach ($c in @($Cells[$t.code])) { for ($i = 0; $i -lt $c.slots.Count; $i++) { $s = $c.slots[$i]; if ($null -ne $s.suiteUsedInAnalysis -and $s.source -ne 'empty' -and -not (ConvertTo-Flag $s.suiteUsedInAnalysis)) { $mism += ('{0} {1} repetition {2}' -f $t.code, $c.engine, $s.rep) } } } }
    $d.suiteAnalysisSetMismatches = $mism
    return $d
}

#endregion

#region ---------------------------------------------------------------- report text (README fragments)

function Get-FamilyChartSections {
    param($A, [string[]]$FamilyKeys, [switch]$Compact)
    $sections = @()
    foreach ($fk in $FamilyKeys) {
        if (-not $A.families.Contains($fk)) { continue }
        $fam = $A.families[$fk]
        $groups = @()
        foreach ($t in @($A.tests | Where-Object { $_.family -eq $fk })) {
            $v = $A.verdicts[$t.code]; $spec = $A.specs[$t.code]
            $g = [ordered]@{ label = $t.displayName; note = $null; bars = @(); na = $null }
            if (-not $v.comparable) { $g.na = 'n/a: not comparable (' + $v.reason + ')'; $groups += $g; continue }
            $cells = @($A.cells[$t.code])
            $finite = @($cells | Where-Object { $null -ne $_.median -and -not (Test-Inf $_.median) -and @($v.rankedEngines) -contains $_.engine } | ForEach-Object { [double]$_.median })
            if ($finite.Count -eq 0) { $finite = @($cells | Where-Object { $null -ne $_.median -and -not (Test-Inf $_.median) } | ForEach-Object { [double]$_.median }) }
            $fastest = if ($finite.Count) { [double]($finite | Measure-Object -Minimum).Minimum } else { $null }
            $t1 = if (@($v.tiers).Count) { @($v.tiers[0]) } else { @() }
            $fastestEngine = @($cells | Where-Object { $null -ne $_.median -and $_.median -eq $fastest } | ForEach-Object { $_.engine })[0]
            if ($v.resultsDiffer) { $g.note = 'results differ: no verdict' }
            foreach ($e in $A.engines) {
                $c = @($cells | Where-Object { $_.engine -eq $e })[0]
                if (-not $c -or $c.nValid -eq 0) { continue }
                $ex = @($v.excludedEngines | Where-Object { $_.engine -eq $e })[0]
                $abs = Format-CellMedian $c $spec
                if ($c.cappedCell) {
                    $g.bars += [ordered]@{ engine = $e; capped = $true; rel = $null; endLabel = $script:GE + ' limit ' + $script:MIDDOT + ' ' + $c.cappedText; tooltip = (Get-EngineName $e) + ': ' + $c.cappedText; excluded = $false }
                    continue
                }
                $rel = if ($fastest) { $c.median / $fastest } else { $null }
                $prefix = if ($e -ne $fastestEngine -and $t1 -contains $e -and $t1 -contains $fastestEngine) { $script:APPROX + ' ' } else { '' }
                $suffix = if ($ex) { ' (' + $(if ($ex.why -eq 'errors') { $ex.detail } else { 'different answer' }) + ')' } else { '' }
                $nTxt = if ($c.nValid -lt $c.nSlots) { ', n=' + $c.nValid } else { '' }
                $g.bars += [ordered]@{
                    engine = $e; capped = $false; rel = $rel
                    relMin = $(if ($fastest -and $null -ne $c.min) { $c.min / $fastest } else { $null }); relMax = $(if ($fastest -and $null -ne $c.max) { $c.max / $fastest } else { $null })
                    endLabel = $prefix + (Format-Ratio $rel) + ' ' + $script:MIDDOT + ' ' + $abs + $suffix + $nTxt
                    tooltip = ('{0} - {1}: median {2} ({3}); {4} of the fastest' -f (Get-EngineName $e), $t.displayName, $abs, (Format-CellRange $c $spec), (Format-Ratio $rel))
                    excluded = [bool]$ex
                }
            }
            $groups += $g
        }
        $sections += [ordered]@{ title = $fam.displayName + $(if ($fam.label) { ' ' + $fam.label } else { '' }); groups = $groups }
    }
    return , $sections
}

function Get-CampaignFacts {
    param($Data, $A)
    $m = $Data.meta
    $profile = [string](Get-Field $m 'profile'); if (-not $profile) { $profile = 'unknown' }
    return [ordered]@{
        ids = ($Data.campaignIds -join ', '); profile = $profile; preliminary = ($profile -ne 'Full')
        started = [string](Get-Field $m 'startedAtUtc'); completed = [string](Get-Field $m 'completedAtUtc')
        repetitions = $A.nSlots; warmUp = ConvertTo-Flag (Get-Field $m 'warmUpRepetition'); blocks = (@(Get-Field $m 'blocks') -join ', ')
        endpoint = [string](Get-Field $m 'endpoint'); repoCommit = [string](Get-Field $m 'repoCommit')
        notes = @(Get-Field $m 'notes')
    }
}

function New-ReadmeFragments {
    param($Data, $A, [string]$ChartPrefix)
    $md = New-Object System.Text.StringBuilder
    $facts = Get-CampaignFacts $Data $A
    $engs = $A.engines
    $hdrEngines = ($engs | ForEach-Object { Get-EngineName $_ }) -join ' | '
    $sepEngines = ($engs | ForEach-Object { '---' }) -join '|'
    $add = { param([string]$s) [void]$md.AppendLine($s) }
    $mysqlRR = Test-MySqlRepeatableRead $Data
    $e10Rejected = $false
    if ($Data.decisions) { $e10 = Get-Field $Data.decisions 'E10'; if ($null -ne $e10) { $e10Rejected = -not (ConvertTo-Flag $e10) } }
    $isoSentence = "MySQL runs Acumatica's transactions at a stricter isolation level by default, which locks more rows; this is how Acumatica ships it."
    $cpuSentence = 'Differences here come mostly from how Acumatica works with each database on a shared machine; a separate database server may shrink them.'
    $clientSentence = 'SQL Server used a same-machine shortcut (shared memory) that a separate database server cannot use; MySQL encrypted its connection.'

    & $add '<!-- Generated by scripts/New-PerfDBBenchmarkReport.ps1. README fragments for WP9 (SPEC section 7). Each fragment starts with a "fragment:" comment. Do not edit by hand; re-run the report instead. -->'
    & $add ('<!-- campaign: {0}; profile: {1}; generated {2} -->' -f $facts.ids, $facts.profile, [DateTime]::UtcNow.ToString('o'))
    & $add ''
    & $add '# PerfDBBenchmark 2026 R2: results'
    & $add ''
    if ($facts.preliminary) {
        & $add ('> **Preliminary:** campaign profile "{0}". These results are not publishable (only the Full profile with 6 repetitions is).' -f $facts.profile)
        & $add ''
    }
    foreach ($n in @($facts.notes)) { if ($n) { & $add ('> **Campaign note:** ' + $n); & $add '' } }

    & $add '<!-- fragment:not-comparable-notice (SPEC 7.8, verbatim) -->'
    & $add '> The numbers on this page replace the results published for Acumatica 2026 R1 (build 26.100.0168, March 2026). Do not compare the two. The earlier runs timed data setup together with the measured operation, re-read cached query results instead of the database, ran about two parallel workers while reporting twelve, used different database memory settings, and ran each test once. They are kept for reference in docs/history/2026R1-results.md (git commit 9fb66d2).'
    & $add ''

    # ---- results at a glance ----
    & $add '<!-- fragment:at-a-glance (SPEC 7.1 item 5) -->'
    & $add '## Results at a glance'
    & $add ''
    & $add ('Each cell shows the family index (1.00 = fastest on every test, computed over the tests listed under the table) and the summary word: "Leads", "Tied" or "x.xx' + $script:TIMES + ' slower (typical)". "Not noticeable" differences count as ties.')
    & $add ''
    & $add ('| Family | ' + $hdrEngines + ' |')
    & $add ('|---|' + $sepEngines + '|')
    foreach ($fk in $A.families.Keys) {
        $fam = $A.families[$fk]
        $cells = @()
        foreach ($e in $engs) {
            $idx = $fam.index[$e]
            $word = $fam.cell[$e]
            if ($word -match 'slower') { $cells += (Get-MdCell $word) }
            elseif ($null -ne $idx) { $cells += ('**' + $word + '** (' + ([double]$idx).ToString('0.00', $script:Inv) + ')') }
            else { $cells += $word }
        }
        & $add ('| ' + $fam.displayName + $(if ($fam.label) { ' *' + $fam.label + '*' } else { '' }) + ' | ' + ($cells -join ' | ') + ' |')
    }
    & $add ''
    foreach ($fk in $A.families.Keys) {
        $fam = $A.families[$fk]
        $names = @($fam.indexTests | ForEach-Object { $c = $_; ($A.tests | Where-Object { $_.code -eq $c }).displayName })
        $line = '- **' + $fam.displayName + '** index over: ' + $(if ($names.Count) { $names -join '; ' } else { 'no test (every test is listed as left out)' }) + '.'
        if (@($fam.excludedTests).Count) { $line += ' Left out: ' + ((@($fam.excludedTests) | ForEach-Object { $_.displayName + ' (' + $_.why + ')' }) -join '; ') + '.' }
        & $add $line
    }
    & $add ''
    & $add ('![Results at a glance](' + $ChartPrefix + 'at-a-glance.svg)')
    & $add ''

    # ---- decision guide ----
    & $add '<!-- fragment:decision-guide (SPEC 7.5) -->'
    & $add '## Which database should I choose?'
    & $add ''
    foreach ($b in (Get-DecisionGuide $Data $A $mysqlRR $e10Rejected)) { & $add ('- ' + $b) }
    & $add ''
    & $add '**Is the faster database worth its extra cost?** Only you can weigh it: the families you care about, how big the difference is in your own units (seconds per report, orders per minute), and the licence and operating cost of each database (see Not measured here).'
    & $add ''

    # ---- tie rule ----
    & $add '<!-- fragment:tie-rule (SPEC 7.2.2, verbatim) -->'
    & $add '## How we decide "faster"'
    & $add ''
    & $add ('> We call a database **faster** on a test only if its typical (median) result is at least 5% better (more when the test is noisy) **and** it won almost all (at least 86%) of the head-to-head comparisons between its runs and the other database''s runs. Below a 20% difference we say **slightly faster**; **much faster** means at least 1.5 times as fast. When a difference is too small for a person to notice ' + $script:MDASH + ' for example less than a tenth of a second when opening a screen ' + $script:MDASH + ' we say so and count it as a tie in the summary. Everything else is a **tie**. The rule protects against run-to-run noise on this machine, not against differences in hardware or configuration. A database that returned a different answer or failed some saves is not ranked on that test; one that hit the time limit is ranked last.')
    & $add ''

    # ---- results by family ----
    & $add '<!-- fragment:results-by-family (SPEC 7.1 item 6) -->'
    & $add '## Results by family'
    & $add ''
    foreach ($fk in $A.families.Keys) {
        $fam = $A.families[$fk]; $info = $script:FamilyInfo[$fk]
        & $add ('<!-- fragment:family-' + $fk + ' -->')
        & $add ('### ' + $fam.displayName + $(if ($fam.label) { ' ' + $fam.label } else { '' }))
        & $add ''
        if ($info) {
            & $add ('**What this simulates:** ' + $info.what)
            & $add ''
            $why = $info.why
            # SPEC FR-M11 / 6.6 3l: the pointer to dry-run step 3l stays only when 3l measured the end-to-end API read on
            # every engine (the HTML report is rendered from this same text)
            if ($fk -eq 'Screens' -and -not $A.diagnostics.apiReadSummary.available) { $why = [regex]::Replace($why, '\s*\(dry-run step 3l[^)]*\)', '') }
            if (($fk -eq 'ManyUsers' -or $fk -eq 'InvoiceRelease') -and $mysqlRR) { $why += ' ' + $isoSentence }
            & $add ('**Why it matters when choosing a database:** ' + $why)
            & $add ''
        }
        if ($info) { & $add ('![' + $fam.displayName + '](' + $ChartPrefix + $info.chart + ')'); & $add '' }
        & $add ('| Test | ' + $hdrEngines + ' | Verdict |')
        & $add ('|---|' + $sepEngines + '|---|')
        $famTests = @($A.tests | Where-Object { $_.family -eq $fk })
        foreach ($t in $famTests) {
            $v = $A.verdicts[$t.code]; $spec = $A.specs[$t.code]
            $vals = @()
            foreach ($e in $engs) {
                $c = @($A.cells[$t.code] | Where-Object { $_.engine -eq $e })[0]
                $txt = Format-CellRange $c $spec
                $ex = @($v.excludedEngines | Where-Object { $_.engine -eq $e })[0]
                if ($ex) { $txt += ' ' + $script:MDASH + ' ' + $(if ($ex.why -eq 'errors') { $ex.detail } else { 'different answer' }) }
                $vals += (Get-MdCell $txt)
            }
            $unit = if ($spec.kind -eq 'rate') { $spec.per } else { $spec.long }
            & $add ('| ' + (Get-MdCell $t.displayName) + ' <br>*' + (Get-MdCell $unit) + '* | ' + ($vals -join ' | ') + ' | ' + (Get-MdCell $v.sentenceMd) + ' |')
        }
        & $add ''
        $notesOut = @()
        foreach ($t in $famTests) {
            $v = $A.verdicts[$t.code]
            if ($v.parityNote) { $notesOut += ('**' + $t.displayName + ':** ' + $v.parityNote) }
            elseif ($t.parityExpected -and $v.comparable -and $v.parity -eq 'same') { $notesOut += ('**' + $t.displayName + ':** identical answer on ' + $(if ($A.engines.Count -eq 3) { 'all three' } else { Join-EngineNames $A.engines }) + '.') }
            if ($v.probes) { $notesOut += ('**' + $t.displayName + ', same answer?** ' + (Get-ProbeSentence $v.probes $A.engines)) }
        }
        if ($notesOut.Count) { & $add '**Correctness:**'; & $add ''; foreach ($n in $notesOut) { & $add ('- ' + $n) }; & $add '' }
        $multi = @($famTests | Where-Object { $_.users -gt 1 -and $_.higherIsBetter })
        if ($multi.Count -gt 0) {
            & $add '**Concurrency details** (p95 wait, failed saves, retries, deadlocks, steady-state throughput):'
            & $add ''
            foreach ($t in $multi) {
                foreach ($e in $engs) { $c = @($A.cells[$t.code] | Where-Object { $_.engine -eq $e })[0]; $s = Get-ConcurrencySentence $t $c $A.specs[$t.code]; if ($s) { & $add ('- ' + $s) } }
            }
            & $add ''
            & $add 'Clerks and people here work non-stop with no pause between documents, so they load the system like a much larger real team.'
            & $add ''
        }
        $shares = @($engs | Where-Object { $null -ne $fam.dbCpuShare[$_] } | ForEach-Object { (Get-EngineName $_) + ' ' + (Format-Pct (100.0 * $fam.dbCpuShare[$_])) })
        if ($shares.Count) {
            & $add ('**Database share of CPU** (database process CPU / (database + Acumatica CPU) over this family''s runs): ' + ($shares -join ', ') + '.')
            $avg = (@($engs | Where-Object { $null -ne $fam.dbCpuShare[$_] } | ForEach-Object { $fam.dbCpuShare[$_] }) | Measure-Object -Average).Average
            if ($null -ne $avg -and (100.0 * $avg) -lt $TieRule.cpuAttributionBelowPct) { & $add $cpuSentence }
            & $add ''
        }
        if ($e10Rejected -and @('Screens', 'OrderEntry', 'Core') -contains $fk) { & $add $clientSentence; & $add '' }
        if ($fk -eq 'ManyUsers') {
            & $add ('![Orders per minute with more clerks](' + $ChartPrefix + 'scaling-orders.svg)')
            & $add ''
            if (@($A.derived.hotItemPenalty).Count) {
                & $add ('**Hot-item penalty** (orders per minute with spread products ' + $script:NDASH + ' everyone selling the best-seller; higher = bigger penalty):')
                & $add ''
                & $add ('| Clerks | ' + $hdrEngines + ' |')
                & $add ('|---|' + $sepEngines + '|')
                foreach ($u in @($A.derived.hotItemPenalty | ForEach-Object { $_.users } | Select-Object -Unique | Sort-Object)) {
                    $vals = @($engs | ForEach-Object { $e = $_; $h = @($A.derived.hotItemPenalty | Where-Object { $_.users -eq $u -and $_.engine -eq $e })[0]; if ($h) { (Format-Ratio $h.penalty) + ' (' + (Format-Sig3 $h.spreadOpsPerMin) + ' ' + $script:ARROW + ' ' + (Format-Sig3 $h.hotOpsPerMin) + '/min)' } else { 'n/a' } })
                    & $add ('| ' + $u + ' | ' + ($vals -join ' | ') + ' |')
                }
                & $add ''
            }
        }
        if ($fk -eq 'Core' -and @($A.derived.speedup1Uto8U).Count) {
            & $add ('![Speed-up from 1 to 8 workers](' + $ChartPrefix + 'speedup-core.svg)')
            & $add ''
        }
    }

    # ---- correctness and parity ----
    & $add '<!-- fragment:parity (SPEC 7.4: correctness is a table, not a chart) -->'
    & $add '## Correctness and parity'
    & $add ''
    & $add ('| Test | Same answer on every database? |')
    & $add '|---|---|'
    foreach ($t in @($A.tests | Where-Object { $_.parityExpected })) {
        $v = $A.verdicts[$t.code]
        $txt = if (-not $v.comparable) { 'n/a (not comparable)' } elseif ($v.parity -eq 'same') { 'identical on ' + $(if ($A.engines.Count -eq 3) { 'all three' } else { Join-EngineNames $A.engines }) } elseif ($v.parityNote) { $v.parityNote } else { 'n/a' }
        & $add ('| ' + (Get-MdCell $t.displayName) + ' | ' + (Get-MdCell $txt) + ' |')
        if ($v.probes) { & $add ('| Same answer? (' + (Get-MdCell $t.displayName) + ', accent probe) | ' + (Get-MdCell (Get-ProbeSentence $v.probes $A.engines)) + ' |') }
    }
    & $add ''

    # ---- how we measured ----
    & $add '<!-- fragment:how-we-measured (SPEC 7.1 item 7) -->'
    & $add '## How we measured'
    & $add ''
    foreach ($b in (Get-HowWeMeasured $Data $A $e10Rejected)) { & $add ('- ' + $b) }
    & $add ''

    # ---- environment ----
    & $add '<!-- fragment:environment (SPEC 7.6) -->'
    & $add '## Test environment'
    & $add ''
    [void]$md.Append((Get-DisclosureTables $Data $A))

    # ---- limits / not measured ----
    & $add '<!-- fragment:limits (SPEC 7.7) -->'
    & $add '## Limits of this test'
    & $add ''
    foreach ($b in (Get-Limits $Data $A $e10Rejected)) { & $add ('- ' + $b) }
    & $add ''
    & $add '<!-- fragment:not-measured (SPEC 7.7) -->'
    & $add '## Not measured here: other things to weigh'
    & $add ''
    & $add '- **Support status and end of life.** [WP9: Acumatica''s supported-platform list for 2026 R2 and each vendor''s end-of-life date, verified against Oracle''s and Acumatica''s published documents and cited with link and access date. The user requirement states that MySQL 8.0 reached end of life in April 2026 and that Acumatica 2026 R1/R2 list only MySQL 8.0.]'
    & $add '- SQL Server Standard or Express (only Developer edition was tested).'
    & $add '- Licence cost.'
    & $add '- Team familiarity and tooling.'
    & $add '- Hosting and managed-service options.'
    & $add '- Operational effort: vacuum and index maintenance, backup and restore time, upgrade time. The backup durations are not published, because the methods differ.'
    & $add ''

    # ---- appendix ----
    & $add '<!-- fragment:methodology-appendix (SPEC 7.6) -->'
    & $add '## Methodology appendix'
    & $add ''
    [void]$md.Append((Get-AppendixMd $Data $A))

    & $add '<!-- fragment:glossary (SPEC 7.3) -->'
    & $add '## Glossary'
    & $add ''
    & $add '- **median:** the middle of the six runs.'
    & $add '- **p95:** 95% of operations were at least this fast.'
    & $add '- **tie:** the difference is too small or too inconsistent to count.'
    & $add '- **not noticeable:** a real but very small difference.'
    & $add '- **parity:** every database returned the same answer.'
    & $add '- **retry:** Acumatica repeated a save after a database conflict.'
    & $add '- **isolation level:** how strictly a database keeps simultaneous transactions apart.'
    & $add ''
    & $add 'Created by AcuPower LTD ([acupowererp.com](https://acupowererp.com)).'
    return $md.ToString()
}

function Get-ProbeSentence {
    param($Probes, [string[]]$Engines)
    # Keys are "probe.accent.<n>.<term>" (WP3 numbers the terms so that no two keys differ only in case, which
    # Windows PowerShell 5.1 cannot parse); older files use "probe.accent.<term>".
    $keys = @($Probes.Keys)
    $short = @($keys | ForEach-Object { $_ -replace '^probe\.(accent\.)?(\d+\.)?', '' })
    $vals = @($Engines | ForEach-Object { $e = $_; (Get-EngineName $e) + ' ' + (($keys | ForEach-Object { $x = $Probes[$_][$e]; if ($null -eq $x -or $x -eq '') { '?' } else { $x } }) -join ' / ') })
    $same = $true
    foreach ($k in $keys) { if (@($Engines | ForEach-Object { [string]$Probes[$k][$_] } | Select-Object -Unique).Count -gt 1) { $same = $false } }
    $txt = 'hits for ' + ($short -join ' / ') + ': ' + ($vals -join '; ') + '.'
    if ($same) { return 'Yes. ' + $txt }
    $plainKey = @($keys | Where-Object { $_ -match '^probe\.accent\.' -and (($_ -replace '^probe\.accent\.(\d+\.)?', '') -cmatch '^[a-z]+$') })[0]
    if ($plainKey) {
        $finds = @($Engines | Where-Object { (ConvertTo-Num $Probes[$plainKey][$_]) -gt 0 })
        $nofinds = @($Engines | Where-Object { $finds -notcontains $_ })
        if ($finds.Count -gt 0 -and $nofinds.Count -gt 0) {
            return 'No. ' + (Join-EngineNames $finds) + ' also ' + $(if ($finds.Count -eq 1) { 'finds' } else { 'find' }) + " accented names (such as 'Revenu Qu" + [char]0x00E9 + "bec') when you search without the accent ('" + ($plainKey -replace '^probe\.accent\.(\d+\.)?', '') + "'); " + (Join-EngineNames $nofinds) + ' ' + $(if ($nofinds.Count -eq 1) { 'does' } else { 'do' }) + ' not (accent-sensitive). Speed is reported separately. ' + $txt
        }
    }
    return 'No. ' + $txt
}

function Get-FamilyTier1 {
    param($A, [string]$Family)
    if (-not $A.families.Contains($Family)) { return @() }
    $fam = $A.families[$Family]
    return @($A.engines | Where-Object { $fam.cell[$_] -eq 'Leads' -or $fam.cell[$_] -eq 'Tied' })
}

function Get-FamilyTypicalDiff {
    # Largest typical difference of a family in the reader's units: max over its index tests of (slowest - fastest).
    param($A, [string]$Family)
    if (-not $A.families.Contains($Family)) { return $null }
    $best = $null; $bestTxt = $null
    foreach ($code in $A.families[$Family].indexTests) {
        $cells = @($A.cells[$code] | Where-Object { $null -ne $_.median -and -not (Test-Inf $_.median) })
        if ($cells.Count -lt 2) { continue }
        $lo = ($cells | Sort-Object median)[0]; $hi = ($cells | Sort-Object median)[-1]
        $rel = $hi.median / $lo.median
        if ($null -eq $best -or $rel -gt $best) {
            $best = $rel
            $spec = $A.specs[$code]
            $t = @($A.tests | Where-Object { $_.code -eq $code })[0]
            if ($spec.kind -eq 'rate') { $bestTxt = $t.displayName + ', ' + (Format-Sig3 $hi.medianHeadline) + ' vs ' + (Format-Sig3 $lo.medianHeadline) + ' ' + $spec.per }
            else { $bestTxt = $t.displayName + ', ' + (Format-TimeValue $lo.median $spec) + ' vs ' + (Format-TimeValue $hi.median $spec) + ' ' + $spec.per }
        }
    }
    return [ordered]@{ ratio = $best; text = $bestTxt }
}

function Get-DecisionGuide {
    param($Data, $A, [bool]$MysqlRR, [bool]$E10Rejected)
    $out = @()
    $allE = $A.engines
    $isoSentence = "MySQL runs Acumatica's transactions at a stricter isolation level by default, which locks more rows; this is how Acumatica ships it."
    $cpuSentence = 'Differences here come mostly from how Acumatica works with each database on a shared machine; a separate database server may shrink them.'
    $cpuNote = {
        param([string[]]$fams)
        foreach ($f in $fams) {
            if (-not $A.families.Contains($f)) { continue }
            $vals = @($A.families[$f].dbCpuShare.Values | Where-Object { $null -ne $_ })
            if ($vals.Count -and (100.0 * ($vals | Measure-Object -Average).Average) -lt $TieRule.cpuAttributionBelowPct) { return ' ' + $cpuSentence }
        }
        return ''
    }

    # 1. small team, everyday screens
    $s1 = @(Get-FamilyTier1 $A 'Screens'); $o1 = @(Get-FamilyTier1 $A 'OrderEntry')
    if ($s1.Count -eq $allE.Count -and $o1.Count -eq $allE.Count) { $t = 'Any of the three will feel the same.' }
    else {
        $parts = @()
        foreach ($f in @('Screens', 'OrderEntry')) {
            if (-not $A.families.Contains($f)) { continue }
            $t1 = @(Get-FamilyTier1 $A $f); $d = Get-FamilyTypicalDiff $A $f
            $parts += ($A.families[$f].displayName + ': ' + $(if ($t1.Count -eq $allE.Count) { 'all three in the fastest group' } elseif ($t1.Count) { (Join-EngineNames $t1) + ' in the fastest group' } else { 'no clear leader' }) + $(if ($d -and $d.text -and $t1.Count -ne $allE.Count) { '; largest difference: ' + $d.text } else { '' }))
        }
        $t = ($parts -join '; ') + '.'
    }
    if ($E10Rejected) { $t += ' SQL Server used a same-machine shortcut (shared memory) that a separate database server cannot use; MySQL encrypted its connection.' }
    $out += ('**A small team working mostly in everyday screens:** ' + $t + (& $cpuNote @('Screens', 'OrderEntry')))

    # 2. many people entering data at once
    $mu = $A.families['ManyUsers']; $oe = $A.families['OrderEntry']
    $both = @($allE | Where-Object { $mu -and $oe -and $mu.leader -eq $_ -and $oe.leader -eq $_ })
    if ($both.Count -eq 1) { $t = (Get-EngineName $both[0]) + ' leads both Many simultaneous users and Order entry.' }
    else {
        $spread = @($allE | ForEach-Object { if ($mu) { $mu.index[$_] } } | Where-Object { $null -ne $_ })
        $within = if ($spread.Count) { Format-Pct (100.0 * (([double]($spread | Measure-Object -Maximum).Maximum) - 1.0)) } else { 'n/a' }
        $u16 = @($A.tests | Where-Object { $_.family -eq 'ManyUsers' } | Sort-Object users -Descending | Select-Object -First 1)
        $maxU = if ($u16.Count) { $u16[0].users } else { 16 }
        $t = "All three handled $maxU clerks working non-stop; differences were within $within (typical, family index)."
    }
    $fails = @()
    foreach ($e in $allE) {
        $n = 0; foreach ($tt in @($A.tests | Where-Object { $_.family -eq 'ManyUsers' })) { $c = @($A.cells[$tt.code] | Where-Object { $_.engine -eq $e })[0]; if ($c) { $n += $c.errors } }
        $fails += ((Get-EngineName $e) + ' ' + $n)
    }
    $t += ' Failed saves: ' + ($fails -join ', ') + '.'
    $hot = @($A.derived.hotItemPenalty | Sort-Object users -Descending)
    if ($hot.Count) {
        $u = $hot[0].users
        $t += (' Hot-item penalty with {0} clerks: ' -f $u) + ((@($hot | Where-Object { $_.users -eq $u }) | ForEach-Object { (Get-EngineName $_.engine) + ' ' + (Format-Ratio $_.penalty) }) -join ', ') + '.'
    }
    if ($MysqlRR) { $t += ' ' + $isoSentence }
    $out += ('**Many people entering data at once (order desks, warehouse):** ' + $t + (& $cpuNote @('ManyUsers', 'OrderEntry')))

    # 3. heavy month-end, GL and sales reporting
    $rp = $A.families['Reports']; $ir = $A.families['InvoiceRelease']
    $both = @($allE | Where-Object { $rp -and $ir -and $rp.leader -eq $_ -and $ir.leader -eq $_ })
    if ($both.Count -eq 1) { $t = (Get-EngineName $both[0]) + ' leads both Reports & month-end and Invoice release to GL.' }
    else {
        $parts = @()
        foreach ($f in @('Reports', 'InvoiceRelease')) { if ($A.families.Contains($f)) { $t1 = @(Get-FamilyTier1 $A $f); $parts += ($A.families[$f].displayName + ': ' + $(if ($A.families[$f].leader -ne 'none') { (Get-EngineName $A.families[$f].leader) + ' leads' } elseif ($t1.Count) { (Join-EngineNames $t1) + ' in the fastest group' } else { 'no clear leader' })) } }
        $t = 'No database leads both families. ' + ($parts -join '; ') + '.'
    }
    foreach ($code in @('RPT_TRIAL_BALANCE', 'RPT_GL_ACCOUNT_DETAILS')) {
        if ($A.verdicts.Contains($code)) { $tt = @($A.tests | Where-Object { $_.code -eq $code })[0]; $t += ' ' + $tt.displayName + ': ' + $A.verdicts[$code].sentenceMd }
    }
    $sp = $A.diagnostics.spillsAndJit
    if ($sp -and -not ($sp -is [string])) { $t += ' Sort spills and JIT use per report are listed in the methodology appendix.' }
    if ($MysqlRR -and $ir) { $t += ' ' + $isoSentence }
    $out += ('**Heavy month-end, GL and sales reporting:** ' + $t + (& $cpuNote @('Reports', 'InvoiceRelease')))

    # 4. imports, integrations and bulk changes
    $codes = @($A.tests | Where-Object { $_.code -match '^CORE_(INSERT|UPDATE|DELETE)_' -and $A.verdicts[$_.code].comparable } | ForEach-Object { $_.code })
    if ($codes.Count) {
        $t1count = @{}; foreach ($e in $allE) { $t1count[$e] = 0 }
        foreach ($code in $codes) { $v = $A.verdicts[$code]; if (@($v.tiers).Count) { foreach ($e in @($v.tiers[0])) { $t1count[$e]++ } } }
        $lead = @($allE | Where-Object { (100.0 * $t1count[$_] / $codes.Count) -ge $TieRule.leadTier1SharePct })
        $t = $(if ($lead.Count) { (Join-EngineNames $lead) + ' ' + $(if ($lead.Count -eq 1) { 'was' } else { 'were' }) + ' in the fastest group on most insert, update and delete tests (' + (($lead | ForEach-Object { '{0} of {1}' -f $t1count[$_], $codes.Count }) -join ', ') + ').' } else { 'No database was in the fastest group on most insert, update and delete tests.' })
        $sp = @($A.derived.speedup1Uto8U | Where-Object { $_.prefix -match 'INSERT|UPDATE|DELETE' })
        foreach ($op in @($sp | ForEach-Object { $_.operation } | Select-Object -Unique)) { $t += ' 1 ' + $script:ARROW + ' 8 worker speed-up, ' + $op + ': ' + ((@($sp | Where-Object { $_.operation -eq $op }) | ForEach-Object { (Get-EngineName $_.engine) + ' ' + (Format-Ratio $_.speedup) }) -join ', ') + '.' }
    }
    else { $t = 'No comparable insert, update or delete result.' }
    if ($E10Rejected) { $t += ' SQL Server used a same-machine shortcut (shared memory) that a separate database server cannot use; MySQL encrypted its connection.' }
    $out += ('**Imports, integrations and bulk changes:** ' + $t + (& $cpuNote @('Core')))

    # 5-6. fixed sentences
    $out += '**Expecting data volumes to grow:** Not measured directly: every test used one dataset of about 2.8 GB that fits in memory on all three. The closest hints are the GL account details and deep-paging tests on the 302,000-line ledger; test with your own data size.'
    $out += '**A mixed workload:** There is no overall winner: compare the families you run most in the results-at-a-glance table. Running reports and order entry at the same time was not tested.'

    # 7. cost-sensitive / open source: pairwise tallies over every comparable test
    $tally = @()
    foreach ($pairDef in @(@('PostgreSQL', 'SQLServer'), @('MySQL', 'SQLServer'), @('PostgreSQL', 'MySQL'))) {
        $x = $pairDef[0]; $y = $pairDef[1]
        if ($allE -notcontains $x -or $allE -notcontains $y) { continue }
        $f = @(); $tie = @(); $s = @()
        foreach ($t in $A.tests) {
            $v = $A.verdicts[$t.code]
            if (-not $v.comparable -or -not $v.pairLookup) { continue }
            $p = $v.pairLookup[$x + '|' + $y]
            if (-not $p) { continue }
            if ($p.practical -eq 'tie') { $tie += $t.displayName } elseif ($p.faster -eq $x) { $f += $t.displayName } else { $s += $t.displayName }
        }
        $m = $f.Count + $tie.Count + $s.Count
        if ($m -eq 0) { continue }
        $line = '{0} was faster / tied / slower than {1} on {2} / {3} / {4} of {5} tests' -f (Get-EngineName $x), (Get-EngineName $y), $f.Count, $tie.Count, $s.Count, $m
        $lists = @()
        if ($f.Count) { $lists += ('faster: ' + ($f -join '; ')) }
        if ($s.Count) { $lists += ('slower: ' + ($s -join '; ')) }
        $tally += ($line + $(if ($lists.Count) { ' (' + ($lists -join '. ') + ')' } else { '' }) + '.')
    }
    $out += ('**Cost-sensitive, or preferring open source:** ' + ($tally -join ' ') + ' SQL Server was measured on Developer edition, which has every Enterprise feature; Standard and Express limit memory, CPU and some query features.')

    # 8. correctness
    $diffs = @($A.tests | Where-Object { $A.verdicts[$_.code].parity -eq 'differs' } | ForEach-Object { $_.displayName + ': ' + $A.verdicts[$_.code].parityNote })
    $probes = @($A.tests | Where-Object { $A.verdicts[$_.code].probes } | ForEach-Object { Get-ProbeSentence $A.verdicts[$_.code].probes $allE })
    $t = 'Any "different answer" outranks any speed result. ' + $(if ($diffs.Count) { ($diffs -join ' ') } else { 'Every database returned the same answer on every comparable test.' }) + $(if ($probes.Count) { ' Accent search: ' + ($probes -join ' ') } else { '' })
    $out += ('**Search results and data correctness:** ' + $t)
    return $out
}

function Get-HowWeMeasured {
    param($Data, $A, [bool]$E10Rejected)
    $m = $Data.meta
    $rot = @(Get-Field $m 'rotation')
    $rotTxt = if ($rot.Count) { ($rot | ForEach-Object { (@($_) | ForEach-Object { [string]$_ }) -join ' ' + $script:ARROW + ' ' }) -join '; ' } else { 'the six orders of the three instances' }
    $out = @()
    $out += ('Tests run in blocks (A: everyday screens and reports; B: platform basics; C: order entry and many users; D: invoice release, last and on a second night). Each block starts with a discarded warm-up repetition, then ' + $A.nSlots + ' repetitions; every repetition runs the three databases in a different order (' + $rotTxt + '), test by test.')
    $out += 'Every run warms up first (untimed warm-up passes or warm-up documents). Only the measured operation is timed: setup, data preparation, verification and cleanup are not.'
    $out += 'In the order-entry tests the measured pass starts right after the untimed deletion of the warm-up orders, with no pause, on every database; background clean-up that a database does after those deletes can overlap the measured pass.'
    $out += 'With several users, a pass is timed by the wall clock from the common start to the last user''s finish, so it also includes each user''s screen reset between two documents (as when a clerk opens a fresh screen); that reset reads the database''s row-version stamp once per document, a small query whose cost differs slightly between the databases.'
    $out += ('Each value is the median of the ' + $A.nSlots + ' repetitions (the analysis set): a failed run is replaced by its re-run, which always repeats all three databases in the same order; outliers are flagged but never re-run or dropped.')
    $out += 'With several users, deadlocks, lock waits and time-outs are part of the result (shown as failed saves). A run in which an operation failed for any other reason, or in which nothing succeeded, is invalid: the test itself is broken there, so the run is flagged and not re-run automatically.'
    $out += ('Tie rule in one sentence: a database is faster only when its median is at least ' + $TieRule.minGapPct + '% better (more for noisy tests) and it won at least 86% of the run pairings; differences too small to notice count as ties (see "How we decide faster").')
    $out += 'The results describe Acumatica running on each database on this machine, not raw database speed.'
    $out += 'Deleting a record includes Acumatica''s attachment check for that record, as on every document.'
    $out += 'Document numbers come from a separate connection, so every saved document commits twice (numbering and document).'
    if ($E10Rejected) { $out += 'Client connection: SQL Server used shared memory (same machine only); MySQL used TLS; PostgreSQL plain TCP. The dry-run A/B result is in the methodology appendix.' }
    else { $out += 'Client connection: all three databases were reached over loopback TCP without encryption.' }
    $out += '"Users" are worker threads inside one Acumatica process (the instances are unlicensed: 2 users / 2 API users), working with no think time.'
    return $out
}

function Get-Limits {
    param($Data, $A, [bool]$E10Rejected)
    $out = @()
    $out += 'One laptop: the client, Acumatica and all three databases share 24 hybrid cores. A database that uses more CPU also slows Acumatica; with a separate database server this effect is smaller.'
    $out += 'One SalesDemo dataset (about 2.8 GB; it fits in memory on all three; largest table 302,000 rows). Behaviour at larger data volumes was not measured.'
    $out += 'Settings as installed apart from memory (Table 2), not tuned for this test. Whether tuning changes a verdict is checked only by the optional sensitivity mini-run (E11).'
    $out += 'SQL Server results come from Developer edition (Enterprise features).'
    $out += $(if ($E10Rejected) { 'Client connection: SQL Server used shared memory and MySQL used TLS; PostgreSQL used plain TCP (see the dry-run A/B in the appendix).' } else { 'Client connection: all three over loopback TCP without encryption.' })
    $out += 'Running reports and order entry at the same time (mixed load) was not tested.'
    $out += 'Unlicensed local instances (2 users / 2 API users); "users" are in-process workers with no think time, so 16 workers represent a much larger real team.'
    $share = Get-PCoreShareText $Data
    $out += 'Acumatica pins the worker process of an unlicensed site to 2 random cores, picked again every minute (briefly 4); this was kept as installed, identically on all three sites (Table 1). A random pick can land on performance or efficiency cores' + $(if ($share) { ' (' + $share + ')' } else { '' }) + ', so short tests are noisier: one database''s short runs can land on slower cores by chance. Tests that keep Acumatica busy (several users, order entry, invoices) are limited by those 2 cores on every database, which can make the differences between databases smaller.'
    $out += 'Windows only.'
    $out += 'Results describe Acumatica on each database, not raw database speed.'
    $out += 'A separate database server was not tested. Every request then pays a network round trip on every engine, so relative gaps in tests with many small requests shrink.'
    return $out
}

function Format-EnvValue { param($Value) if ($null -eq $Value -or [string]$Value -eq '') { return '(not captured)' } return [string]$Value }

function Get-DisclosureTables {
    param($Data, $A)
    $sb = New-Object System.Text.StringBuilder
    $add = { param([string]$s) [void]$sb.AppendLine($s) }
    $start = $Data.start
    $engs = $A.engines
    $hdr = ($engs | ForEach-Object { Get-EngineName $_ }) -join ' | '
    $sep = ($engs | ForEach-Object { '---' }) -join '|'

    # Table 1
    & $add '### Table 1: host and application'
    & $add ''
    & $add '| Item | Value |'
    & $add '|---|---|'
    $host1 = @($start)
    $cpu = Find-Setting $host1 @('cpuName', 'cpu', 'processor')
    $cores = Find-Setting $host1 @('cores', 'numberOfCores'); $lcpu = Find-Setting $host1 @('logicalCpus', 'numberOfLogicalProcessors')
    $ram = Find-Setting $host1 @('ramGb', 'totalPhysicalMemoryGb', 'ram')
    & $add ('| Machine | ' + (Get-MdCell (Format-EnvValue (Find-Setting $host1 @('model', 'machineModel')))) + ' |')
    & $add ('| CPU | ' + (Get-MdCell ((Format-EnvValue $cpu) + $(if ($cores) { '; ' + $cores + ' cores' } else { '' }) + $(if ($lcpu) { ', ' + $lcpu + ' logical' } else { '' }))) + ' |')
    & $add ('| RAM | ' + (Get-MdCell ((Format-EnvValue $ram) + $(if ($ram) { ' GB' } else { '' }))) + ' |')
    $disk = Find-Setting $host1 @('friendlyName', 'disk', 'storage')
    & $add ('| Storage | ' + (Get-MdCell (Format-EnvValue $disk)) + ' |')
    & $add ('| OS | ' + (Get-MdCell (Format-EnvValue (Find-Setting $host1 @('os', 'osCaption', 'caption')))) + ' |')
    & $add ('| Power plan | ' + (Get-MdCell (Format-EnvValue (Find-Setting $host1 @('powerScheme', 'powerPlan')))) + ' |')
    $build = $null
    foreach ($ec in @($Data.envCaptures)) { $build = Find-Setting @((Get-Field $ec 'env')) @('pxDataVersion', 'pxDataFileVersion', 'acumaticaBuild', 'PX.Data.dll'); if ($build) { break } }
    if (-not $build) { $build = Find-Setting $host1 @('pxDataVersion', 'pxDataFileVersion', 'pxDataFileVersionInstaller', 'acumaticaBuild') }
    & $add ('| Acumatica | ' + (Format-EnvValue $build) + ' |')
    $wc = $null
    foreach ($ec in @($Data.envCaptures)) { $wc = Get-PathValue $ec 'env.webConfig'; if ($wc) { break } }
    if ($wc) { $wct = ((Get-Keys $wc) | ForEach-Object { $_ + '=' + [string](Get-Field $wc $_) }) -join '; ' } else { $wct = $null }
    & $add ('| web.config flags | ' + (Get-MdCell (Format-EnvValue $wct)) + ' |')
    $dlls = @($A.runs | Where-Object { $_.dll } | ForEach-Object { $_.dll } | Select-Object -Unique)
    & $add ('| Customization DLL SHA-256 | ' + (Get-MdCell ((Format-EnvValue ($dlls -join ', ')) + '; repo commit ' + (Format-EnvValue (Get-Field $Data.meta 'repoCommit')))) + ' |')
    $fp = $null
    foreach ($ec in @($Data.envCaptures)) { $fp = Get-PathValue $ec 'env.dataFingerprint'; if ($fp) { break } }
    $counts = Get-Field $fp 'counts'
    $fpTxt = if ($counts) { ((Get-Keys $counts) | Where-Object { $_ -match 'GLTran|ARTran|SOLine|SOOrder' } | ForEach-Object { $_ + ' ' + ('{0:N0}' -f (ConvertTo-Num (Get-Field $counts $_))) }) -join '; ' } else { $null }
    $fph = Get-Field $fp 'dataFingerprintHash'
    $sizes = @($engs | ForEach-Object { $sz = Find-Setting (Get-EngineEnvSources $Data $_) @('databaseSizeMb', 'sizeMb', 'databaseSize'); if ($sz) { (Get-EngineName $_) + ' ' + $sz + ' MB' } })
    & $add ('| Dataset | ' + (Get-MdCell ('SalesDemo tenant 2: ' + (Format-EnvValue $fpTxt) + $(if ($fph) { '; data fingerprint ' + $fph } else { '' }) + $(if ($sizes.Count) { '; database size ' + ($sizes -join ', ') } else { '' }))) + ' |')
    & $add '| Licence | unlicensed: 2 users / 2 API users; users in these tests are threads inside Acumatica |'
    # fairness disclosures from the captures (user decisions 2026-10-04: E14 throttle off; CPU pinning kept as installed)
    & $add ('| Acumatica SQL throttle (unlicensed sites) | ' + (Get-MdCell (Get-SqlThrottlingText $Data $engs)) + ' |')
    & $add ('| Acumatica worker CPU pinning (unlicensed sites) | ' + (Get-MdCell (Get-AffinityText $Data $A)) + ' |')
    & $add ''
    & $add 'Client, Acumatica and all three databases share this one machine; only one database is busy at a time.'
    & $add ''

    # Table 2
    & $add '### Table 2: database settings'
    & $add ''
    & $add ('| Setting | ' + $hdr + ' |')
    & $add ('|---|' + $sep + '|')
    $src = @{}; foreach ($e in $engs) { $src[$e] = Get-EngineEnvSources $Data $e }
    $row = {
        param([string]$Label, [scriptblock]$Fn)
        $vals = @($engs | ForEach-Object { Get-MdCell (& $Fn $_) })
        & $add ('| ' + $Label + ' | ' + ($vals -join ' | ') + ' |')
    }
    & $row 'Version and edition' {
        param($e)
        switch ($e) {
            'SQLServer' { (Format-EnvValue (Find-Setting $src[$e] @('productVersion', 'dbmsVersionLabel', 'version'))) + '; ' + (Format-EnvValue (Find-Setting $src[$e] @('edition'))) + '. **Developer edition: every Enterprise feature; not representative of Standard or Express**' }
            default { Format-EnvValue (Find-Setting $src[$e] @('version', 'server_version', 'dbmsVersionLabel')) }
        }
    }
    & $row 'Set at install (before this campaign)' { param($e) switch ($e) { 'SQLServer' { 'engine defaults (max server memory had been 30 GB)' } 'MySQL' { "from Acumatica's guidance: buffer pool 8G, redo log capacity 1G, log buffer 16M, read_rnd_buffer 1M, max_allowed_packet 64M, flush_log_at_trx_commit 1, lower_case_table_names 1, utf8mb4" } 'PostgreSQL' { 'engine defaults' } } }
    & $row 'Changed for this campaign' { param($e) switch ($e) { 'SQLServer' { 'max (and min) server memory 8 GB; client connection per E10' } 'MySQL' { 'none in the server; client connection per E10' } 'PostgreSQL' { 'shared_buffers 2 GB (was 128 MB), effective_cache_size 8 GB; client connection per E10' } } }
    & $add ('| Acumatica''s documented recommendation | ' + (($engs | ForEach-Object { '[WP9: look up and cite]' }) -join ' | ') + ' |')
    & $row 'Memory setting (captured) and what it covers' {
        param($e)
        switch ($e) {
            'SQLServer' { 'max server memory ' + (Format-EnvValue (Find-Setting $src[$e] @('max server memory (MB)'))) + ' MB, min ' + (Format-EnvValue (Find-Setting $src[$e] @('min server memory (MB)'))) + ' MB: covers the buffer pool, plan cache and query memory' }
            'MySQL' { 'innodb_buffer_pool_size ' + (Format-EnvValue (Find-Setting $src[$e] @('innodb_buffer_pool_size'))) + ': covers the data and index cache only' }
            'PostgreSQL' { 'shared_buffers ' + (Format-EnvValue (Find-Setting $src[$e] @('shared_buffers'))) + ', effective_cache_size ' + (Format-EnvValue (Find-Setting $src[$e] @('effective_cache_size'))) + ': shared_buffers is the database''s own cache; the Windows file cache adds to it without a limit; effective_cache_size is only a planner hint' }
        }
    }
    & $row 'Database size' { param($e) $v = Find-Setting $src[$e] @('databaseSizeMb', 'sizeMb', 'databaseSize'); if ($v) { $v + ' MB; the whole database fits in memory' } else { '(not captured)' } }
    $cc = Get-Field $Data.meta 'clientConnection'
    & $row 'Client connection' { param($e) $inst = @($Data.instanceEngines.Keys | Where-Object { $Data.instanceEngines[$_] -eq $e })[0]; $v = if ($inst) { Get-Field $cc $inst } else { $null }; if (-not $v -and $Data.start) { $v = Get-Field (Get-Field $Data.start 'clientConnection') $inst }; Format-EnvValue $v }
    & $row 'Driver shipped with Acumatica' { param($e) $d = Find-Setting @((Get-Field $Data.start 'drivers')) @($(switch ($e) { 'SQLServer' { 'sqlServer' } 'MySQL' { 'mySql' } 'PostgreSQL' { 'postgreSql' } })); if ($d) { $d } else { switch ($e) { 'SQLServer' { '(not captured: SQL Server client library and version)' } 'MySQL' { 'MySqlConnector 1.3.14' } 'PostgreSQL' { 'Npgsql 6.0.13' } } } }
    $iso = Get-IsolationByEngine $Data
    & $row 'Isolation Acumatica actually runs with' { param($e) Format-EnvValue $iso[$e] }
    & $row 'Commit durability' {
        param($e)
        switch ($e) {
            'SQLServer' { $lct = Get-SqlLogChainText $Data; (Format-EnvValue (Find-Setting $src[$e] @('recovery_model_desc', 'recoveryModel'))) + ' recovery, log flushed at commit' + $(if ($lct) { '; ' + $lct + '; log backups between blocks and before Block D only while the chain is active' } else { ' (+ log backups between blocks if the chain is active)' }) }
            'MySQL' { 'flush_log_at_trx_commit=' + (Format-EnvValue (Find-Setting $src[$e] @('innodb_flush_log_at_trx_commit'))) + '; binary log ' + (Format-EnvValue (Find-Setting $src[$e] @('log_bin'))) + ', sync_binlog=' + (Format-EnvValue (Find-Setting $src[$e] @('sync_binlog'))) }
            'PostgreSQL' { 'synchronous_commit=' + (Format-EnvValue (Find-Setting $src[$e] @('synchronous_commit'))) + '; wal_level=' + (Format-EnvValue (Find-Setting $src[$e] @('wal_level'))) }
        }
    }
    & $row 'Query parallelism' {
        param($e)
        switch ($e) {
            'SQLServer' { 'MAXDOP ' + (Format-EnvValue (Find-Setting $src[$e] @('max degree of parallelism'))) + ', cost threshold ' + (Format-EnvValue (Find-Setting $src[$e] @('cost threshold for parallelism'))) }
            'MySQL' { 'none for ordinary queries' }
            'PostgreSQL' { 'max_parallel_workers_per_gather=' + (Format-EnvValue (Find-Setting $src[$e] @('max_parallel_workers_per_gather'))) + '; JIT ' + (Format-EnvValue (Find-Setting $src[$e] @('jit'))) }
        }
    }
    & $row 'Sort/hash memory per query' { param($e) switch ($e) { 'SQLServer' { 'dynamic grant' } 'MySQL' { 'sort_buffer_size ' + (Format-EnvValue (Find-Setting $src[$e] @('sort_buffer_size'))) } 'PostgreSQL' { 'work_mem ' + (Format-EnvValue (Find-Setting $src[$e] @('work_mem'))) } } }
    $spills = $A.diagnostics.spillsAndJit
    & $row 'Reports that spilled to disk / used JIT (dry run 3d)' { param($e) if ($spills -and (Test-IsMap $spills)) { $x = @((Get-Keys $spills) | ForEach-Object { $t = $_; $v = Get-Field (Get-Field $spills $t) $e; if ($v) { $t + ': ' + $v } }); if ($x.Count) { $x -join '; ' } else { '(not captured)' } } else { '(not captured)' } }
    & $row 'Statistics refresh before the campaign' { param($e) switch ($e) { 'SQLServer' { 'UPDATE STATISTICS, default sampling, every table' } 'MySQL' { 'ANALYZE TABLE, every table' } 'PostgreSQL' { 'VACUUM (ANALYZE), default target' } } }
    & $row 'Instrumentation on during the campaign' { param($e) switch ($e) { 'SQLServer' { 'Query Store ' + (Format-EnvValue (Find-Setting $src[$e] @('queryStore', 'query_store'))) + ' (default)' } 'MySQL' { 'performance_schema ' + (Format-EnvValue (Find-Setting $src[$e] @('performance_schema'))) + ' (default)' } 'PostgreSQL' { 'none (pg_stat_statements only in the dry run, if E12)' } } }
    # contract C3 (databases.<Engine>.collation): database default and Acumatica's column collation, LIKE, observed probe
    & $row 'Collation / text search' { param($e) Get-CollationCell $Data $A $src[$e] $e }
    & $row 'Login used by Acumatica' { param($e) switch ($e) { 'SQLServer' { 'Windows login IIS APPPOOL\PerfSQL' } 'MySQL' { 'acumatica (ALL on schema)' } 'PostgreSQL' { 'acumatica (SUPERUSER)' } } }
    $av = Find-Setting @((Get-Field $Data.start 'antivirus')) @('exclusions', 'antivirus')
    & $row 'Antivirus exclusion of data folder; scheduled scans' { param($e) Format-EnvValue $av }
    & $row 'Background work left behind (per block)' { param($e) $x = @($A.diagnostics.backgroundLeftBehindPct.Keys | ForEach-Object { $b = $_; $v = $A.diagnostics.backgroundLeftBehindPct[$b][$e]; if ($null -ne $v) { $b + ' ' + (Format-Pct $v) } }); if ($x.Count) { $x -join ', ' } else { '(not captured)' } }
    & $add ''
    & $add 'All other settings are as installed (listed in full in the campaign JSON); none was tuned for this test.'
    & $add ''

    # Table 3
    & $add '### Table 3: test parameters'
    & $add ''
    $cp = Get-Field $Data.meta 'coreParams'
    $sg = Get-Field $Data.meta 'settleGate'
    & $add '| Parameter | Value |'
    & $add '|---|---|'
    & $add ('| Platform basics | N = ' + (Format-EnvValue $(if ($null -ne (ConvertTo-Num (Get-Field $cp 'records'))) { '{0:N0}' -f (ConvertTo-Num (Get-Field $cp 'records')) } else { $null })) + ' records, C = ' + (Format-EnvValue (Get-Field $cp 'chunkSize')) + ' rows per chunk and commit, W = 8 workers, ' + (Format-EnvValue (Get-Field $cp 'iterations')) + ' measured passes |')
    & $add ('| Repetitions | ' + $A.nSlots + ' measured repetitions per test and database' + $(if (ConvertTo-Flag (Get-Field $Data.meta 'warmUpRepetition')) { ' + one discarded warm-up repetition per block' } else { '' }) + ' |')
    $rot = @(Get-Field $Data.meta 'rotation')
    & $add ('| Rotation | ' + (Get-MdCell ($(if ($rot.Count) { ($rot | ForEach-Object { (@($_) | ForEach-Object { [string]$_ }) -join ' ' + $script:ARROW + ' ' }) -join '; ' } else { '(not captured)' }))) + ' |')
    & $add ('| Blocks | ' + (Format-EnvValue (@(Get-Field $Data.meta 'blocks') -join ', ')) + ' (two nights: A' + $script:NDASH + 'C, then D) |')
    if ($sg) { & $add ('| Settle gate | CPU < ' + (Get-Field $sg 'cpuPct') + '%, disk < ' + (Get-Field $sg 'diskMBps') + ' MB/s over ' + (Get-Field $sg 'windowSec') + ' s (min wait ' + (Get-Field $sg 'minWaitSec') + ' s, timeout ' + (Get-Field $sg 'timeoutSec') + ' s); Blocks B' + $script:NDASH + 'D also other database processes < ' + (Get-PathValue $sg 'blocksBCD.otherDbCpuPctOfCore') + '% of a core and < ' + (Get-PathValue $sg 'blocksBCD.otherDbIoMBps') + ' MB/s; ' + (Get-Field $sg 'coolDownSecAfterMultiUser') + ' s cool-down after runs with 8 or more workers |') }
    & $add '| Pinned business date | 2026-06-30 (period 202606), branch PRODWHOLE, warehouse WHOLESALE |'
    $budgets = @($A.tests | ForEach-Object { $code = $_.code; $b = @($A.runs | Where-Object { $_.testCode -eq $code -and -not $_.isWarmup } | ForEach-Object { ConvertTo-Num (Get-Field $_.raw 'runBudgetSec') } | Where-Object { $_ } | Select-Object -Unique); if ($b.Count) { $_.shortLabel + ' ' + ($b -join '/') + ' s' } })
    $budgetVals = @($budgets | ForEach-Object { ($_ -split ' ')[-2] } | Select-Object -Unique)
    $budgetTxt = if ($budgets.Count -eq 0) { '15 min (engine default) for every test' } elseif ($budgetVals.Count -eq 1) { $budgetVals[0] + ' s for every test' } else { $budgets -join '; ' }
    & $add ('| Run budgets | ' + (Get-MdCell $budgetTxt) + ' |')
    & $add '| Pools | 500 sales orders, 78 customers, 91 items, 20 search fragments, 14 years, 12 periods, 56 GL accounts, 20 customers and 613 stock items for order entry, 72 non-stock items for invoices |'
    $floors = (($TieRule.floors.Keys) | ForEach-Object { $k = $_; $f = $TieRule.floors[$k]; $k + ': ' + ((@($f.Keys) | ForEach-Object { $(if ($_ -eq 'absMs') { '< ' + $f[$_] + ' ms' } else { '< ' + $f[$_] + '%' }) }) -join ' or ') }) -join '; '
    & $add ('| Tie rule | gap >= max(' + $TieRule.minGapPct + '%, ' + $TieRule.cvMultiplier + ' ' + $script:TIMES + ' robust CV) and U <= floor(' + $TieRule.maxUShare + ' nA nB); slightly faster below ' + $TieRule.slightlyFasterBelowPct + '%; much faster at ' + $TieRule.muchFasterRatio + $script:TIMES + '; at least ' + $TieRule.minValidSlots + ' valid runs per database |')
    & $add ('| Practical floors (not noticeable) | ' + (Get-MdCell $floors) + ' |')
    & $add ''
    & $add '| Test | Users | Operations per pass | Measured passes | Warm-up passes | Reader unit |'
    & $add '|---|---|---|---|---|---|'
    foreach ($t in $A.tests) { & $add ('| ' + (Get-MdCell $t.displayName) + ' | ' + $t.users + ' | ' + (Format-EnvValue $t.defaultOpsPerPass) + ' | ' + (Format-EnvValue $t.defaultPasses) + ' | ' + (Format-EnvValue $t.defaultWarmUpPasses) + ' | ' + (Get-MdCell $t.readerUnit) + ' |') }
    & $add ''

    # Table 4
    & $add '### Table 4: where the CPU went'
    & $add ''
    & $add ('Per family and database: database CPU per operation, Acumatica (w3wp) CPU per operation and the database share, over the analysis-set runs (whole run, untimed phases included, divided by every operation the run executed). The untimed phases include data preparation and cleanup, for example re-creating the 10,000 records before each delete pass and deleting the orders after each order-entry pass, so these figures are upper bounds of the CPU per measured operation.')
    & $add ''
    & $add ('| Family | ' + (($engs | ForEach-Object { (Get-EngineName $_) + ': DB ms/op' + ' | ' + (Get-EngineName $_) + ': Acumatica ms/op | ' + (Get-EngineName $_) + ': DB share' }) -join ' | ') + ' |')
    & $add ('|---|' + (($engs | ForEach-Object { '---|---|---' }) -join '|') + '|')
    foreach ($fk in $A.families.Keys) {
        $vals = @()
        foreach ($e in $engs) {
            $db = 0.0; $app = 0.0; $ops = 0.0
            foreach ($t in @($A.tests | Where-Object { $_.family -eq $fk })) { foreach ($c in @($A.cells[$t.code] | Where-Object { $_.engine -eq $e })) { foreach ($r in $c.selectedRuns) { $cpu = Get-RunCpu $r; if ($cpu -and $null -ne $cpu.dbCpuMs -and $null -ne $cpu.appCpuMs -and $cpu.ops) { $db += $cpu.dbCpuMs; $app += $cpu.appCpuMs; $ops += $cpu.ops } } } }
            if ($ops -gt 0) { $vals += @((Format-Sig3 ($db / $ops)), (Format-Sig3 ($app / $ops)), (Format-Pct (100.0 * $db / [Math]::Max(1e-9, $db + $app)))) }
            else { $vals += @('n/a', 'n/a', 'n/a') }
        }
        & $add ('| ' + $A.families[$fk].displayName + ' | ' + ($vals -join ' | ') + ' |')
    }
    & $add ''
    $spo = $A.diagnostics.statementsPerOp
    if ($spo -and (Test-IsMap $spo)) {
        & $add ($script:StatementCounterHead + ' ' + $script:StatementCounterTail + ' Dry run 3f: ' + (Get-StatementsPerOpValues $spo) + '.')
        & $add ''
    }

    # Start/end differences (SPEC 6.4: every difference other than uptime is listed)
    & $add '### Environment changes during the campaign'
    & $add ''
    $chg = @($A.diagnostics.environmentChanges)
    if (-not $Data.start -or -not $Data.end) { & $add '- Not checked: the start and end environment captures were not both available.' }
    elseif ($chg.Count -eq 0) { & $add '- None: the start and end environment captures agree (uptime, sizes and other volatile fields excluded).' }
    else {
        foreach ($c in @($chg | Select-Object -First 40)) { & $add ('- ' + (Get-MdCell $c.key) + ': ' + (Get-MdCell (Format-EnvValue $c.start)) + ' ' + $script:ARROW + ' ' + (Get-MdCell (Format-EnvValue $c.end))) }
        if ($chg.Count -gt 40) { & $add ('- ... and ' + ($chg.Count - 40) + ' more (analysis.json, diagnostics.environmentChanges).') }
    }
    & $add ''
    return $sb.ToString()
}

function Get-AppendixMd {
    param($Data, $A)
    $sb = New-Object System.Text.StringBuilder
    $add = { param([string]$s) [void]$sb.AppendLine($s) }
    $d = $A.diagnostics
    $nc = @($A.tests | Where-Object { -not $A.verdicts[$_.code].comparable })
    & $add '### Tests that are not comparable'
    & $add ''
    if ($nc.Count) { foreach ($t in $nc) { & $add ('- **' + $t.displayName + '** (' + $t.code + '): ' + $A.verdicts[$t.code].reason + '.') } }
    else { & $add '- None: every test passed the comparability gate (at least 5 valid runs per database; one parameter set, methodology and DLL; unchanged environment; identical master data).' }
    foreach ($n in $A.notes) { & $add ('- Note: ' + $n) }
    & $add ''
    & $add '### Run inventory and events'
    & $add ''
    & $add ('- Runs by status: ' + (((@($d.runInventory.Keys)) | ForEach-Object { $_ + ' ' + $d.runInventory[$_] }) -join ', ') + '.')
    if (@($d.events.Keys).Count) { & $add ('- Events: ' + (((@($d.events.Keys)) | ForEach-Object { $_ + ' ' + $d.events[$_] }) -join ', ') + '.') }
    foreach ($ev in @($Data.events | Where-Object { @('Stuck', 'GateWarning', 'AppRestart', 'ParamsMismatch', 'Abort', 'Preflight') -contains [string](Get-Field $_ 'kind') })) {
        & $add ('- ' + [string](Get-Field $ev 'kind') + $(if (Get-Field $ev 'instance') { ' (' + [string](Get-Field $ev 'instance') + ')' } else { '' }) + ': ' + [string](Get-Field $ev 'detail'))
    }
    if (@($d.suiteAnalysisSetMismatches).Count) { & $add ('- The suite''s usedInAnalysis flags differ from this report''s analysis set for: ' + ($d.suiteAnalysisSetMismatches -join '; ') + '. The report''s rule (SPEC 7.2.0) is used.') }
    & $add ''
    & $add '### Diagnostics'
    & $add ''
    $pe = @($d.positionEffectPct)
    & $add ('- **Position effect** (mean deviation from the cell median by running position 1st / 2nd / 3rd): ' + (($pe | ForEach-Object { if ($null -ne $_) { Format-Pct $_ } else { 'n/a' } }) -join ' / ') + '.' + $(if (@($pe | Where-Object { $null -ne $_ -and [Math]::Abs($_) -gt $TieRule.positionEffectNotePct }).Count) { ' The running position had an effect above ' + $TieRule.positionEffectNotePct + '%; the rotation gives every database each position equally often.' } else { '' }))
    $drift = @(); foreach ($k in $d.driftPct.Keys) { foreach ($e in $d.driftPct[$k].Keys) { $v = $d.driftPct[$k][$e]; if ($null -ne $v -and [Math]::Abs($v) -ge 5) { $drift += ($k + ' ' + (Get-EngineName $e) + ' ' + (Format-Pct $v)) } } }
    & $add ('- **Drift** (median of repetitions 4' + $script:NDASH + '6 vs 1' + $script:NDASH + '3): ' + $(if ($drift.Count) { 'at least 5% on ' + ($drift -join '; ') } else { 'below 5% on every test and database' }) + '.')
    & $add ('- **Outliers:** ' + $d.outliers.total + ' (' + $d.outliers.rule + ')' + $(if ($d.outliers.total) { ': ' + ((@($d.outliers.items) | ForEach-Object { $_.testCode + ' ' + (Get-EngineName $_.engine) + ' repetition ' + $_.repetitionNo + ' (' + $_.ratioToCellMedian + $script:TIMES + ')' }) -join '; ') } else { '' }) + '.')
    & $add ('- **Settle-gate time-outs** by block: ' + ((@($d.settleTimeoutsPct.Keys) | ForEach-Object { $_ + ' ' + $(if ($null -ne $d.settleTimeoutsPct[$_]) { Format-Pct $d.settleTimeoutsPct[$_] } else { 'n/a' }) }) -join ', ') + ' (warning above ' + $TieRule.settleTimeoutWarnPct + '%).')
    & $add ('- **Background work left behind** (database CPU while its engine was idle / its CPU in its own runs), by block: ' + ((@($d.backgroundLeftBehindPct.Keys) | ForEach-Object { $b = $_; $b + ': ' + ((@($d.backgroundLeftBehindPct[$b].Keys) | ForEach-Object { (Get-EngineName $_) + ' ' + $(if ($null -ne $d.backgroundLeftBehindPct[$b][$_]) { Format-Pct $d.backgroundLeftBehindPct[$b][$_] } else { 'n/a' }) }) -join ', ') }) -join '; ') + '.')
    & $add ('- **Throttle indicator** (mean % Processor Performance during runs; highest temperature): ' + ((@($d.throttleIndicator.Keys) | ForEach-Object { (Get-EngineName $_) + ' ' + $(if ($null -ne $d.throttleIndicator[$_].meanProcessorPerformancePct) { Format-Pct $d.throttleIndicator[$_].meanProcessorPerformancePct } else { 'n/a' }) + $(if ($null -ne $d.throttleIndicator[$_].maxTempC) { ', max ' + (Format-Sig3 $d.throttleIndicator[$_].maxTempC) + ' C' } else { '' }) }) -join '; ') + '.')
    $bd = $d.blockDDataDiff
    $bdTxt = if ($bd.differs) { 'the data changed by Block D differ between instances: ' + ((@($bd.dAffectedKeys.Keys) | Where-Object { @($bd.dAffectedKeys[$_].Values | Select-Object -Unique).Count -gt 1 } | ForEach-Object { $k = $_; $k + ' ' + ((@($bd.dAffectedKeys[$k].Keys) | ForEach-Object { $_ + ' ' + $bd.dAffectedKeys[$k][$_] }) -join ' / ') }) -join '; ') } else { 'no difference in the data changed by Block D' }
    if (@($bd.failedOps.Keys).Count) { $bdTxt += '. Failed operations: ' + ((@($bd.failedOps.Keys) | ForEach-Object { $_ + ' ' + (@($bd.failedOps[$_]) -join ', ') }) -join '; ') }
    if (@($bd.gateWarnings).Count) { $bdTxt += '. Gate log: ' + ((@($bd.gateWarnings) -join ' ').TrimEnd('.')) }
    & $add ('- **Block D data differences** (gate G2d): ' + $bdTxt + '.')
    foreach ($k in @('transportAB', 'apiReadMs', 'sqlServerPlanCheck', 'cacheDefeatProbe', 'aaCalibration', 'statementsPerOp', 'spillsAndJit')) {
        $label = @{ transportAB = 'Transport A/B (dry run 3k)'; sqlServerPlanCheck = 'SQL Server plan check: batch mode or parallelism in the report plans (dry run 3m)'; cacheDefeatProbe = 'Cache-defeat proof (dry run 3f)'; aaCalibration = 'A/A robust CV, % (dry run 3h)'; spillsAndJit = 'Sort spills and JIT (dry run 3d)' }[$k]
        $v = $d[$k]
        switch ($k) {
            # SPEC FR-M11 / 6.6 3l: the sentence per engine, or "not available (<endpoint>: <exception type>)"; only the
            # measurement fields of diagnostics.apiReadMs are published, never the probe
            'apiReadMs' {
                $at = Get-ApiReadText $d.apiReadSummary
                & $add ('- **End-to-end API read:** ' + $at.Substring('End-to-end API read: '.Length) + '.')
            }
            'cacheDefeatProbe' { & $add ('- **' + $label + ':** ' + (Get-CacheDefeatText $v) + '.') }
            'statementsPerOp' { & $add ('- **' + $script:StatementCounterHead + '** ' + $script:StatementCounterTail + ' Dry run 3f: ' + (Get-StatementsPerOpValues $v) + '.') }
            default {
                $txt = if ($v -is [string]) { $v } else { $m = [ordered]@{}; Get-LeafMap $v '' $m; ((@($m.Keys) | ForEach-Object { $_ + ' = ' + $m[$_] }) -join '; ') }
                & $add ('- **' + $label + ':** ' + $txt + '.')
            }
        }
    }
    # residue tables (contract C2): the campaign end against the campaign baseline, exact row counts per engine; an
    # engine without exact counts is named as not captured. Without those two files: every table-count capture (3n).
    $cr = $d.campaignResidue
    $res = @($d.residueTables)
    if ($cr) {
        & $add ('- **Residue tables (campaign end against the campaign baseline taken after the dry run''s clean-up, exact row counts):** ' + (Get-CampaignResidueText $cr) + '.')
        $dry = @($res | Where-Object { $_.source -notmatch '^table-counts-campaign-' })
        if ($dry.Count) { & $add ('- The dry-run table counts (3n: ' + (@($dry | ForEach-Object { $(if ($_.label) { $_.label } else { $_.source }) }) -join ', ') + ') are listed in analysis.json (diagnostics.residueTables).') }
    }
    elseif ($res.Count -eq 0) { & $add '- **Residue tables (dry run 3n):** not provided (no table-counts-*.json next to the input or embedded in it).' }
    else {
        foreach ($rt in $res) {
            $parts = @()
            foreach ($e in @($rt.changedTables.Keys)) {
                if ($rt.notCaptured -and $rt.notCaptured.Contains($e)) { continue }
                $rows = @($rt.changedTables[$e])
                $shown = @($rows | Select-Object -First 15 | ForEach-Object { Format-ResidueRow $_ })
                $more = if ($rows.Count -gt 15) { ' and ' + ($rows.Count - 15) + ' more' } else { '' }
                $parts += ((Get-EngineName $e) + ': ' + $(if ($rows.Count) { ($shown -join ', ') + $more } else { 'no table changed' }))
            }
            foreach ($e in @($rt.notCaptured.Keys)) { $parts += ((Get-EngineName $e) + ': not captured (' + $rt.notCaptured[$e] + '), so its residue is not known') }
            if (-not $rt.baselineFile -and @($rt.changedTables.Keys).Count -eq 0) { $parts += 'no baseline to compare with' }
            $softTxt = @(Get-Keys $rt.softDeleted | ForEach-Object { $e = $_; $sd = Get-Field $rt.softDeleted $e; $kv = @(Get-Keys $sd | ForEach-Object { $_ + ' ' + [string](Get-Field $sd $_) }); if ($kv.Count) { (Get-EngineName $e) + ' ' + ($kv -join ', ') } })
            if ($softTxt.Count) { $parts += ('soft-deleted / archived rows: ' + ($softTxt -join '; ')) }
            & $add ('- **Residue tables (dry run 3n), ' + $(if ($rt.label) { $rt.label } else { $rt.source }) + ':** ' + ($parts -join '. ') + '.')
        }
    }
    & $add ''
    return $sb.ToString()
}

#endregion

#region ---------------------------------------------------------------- analysis.json

function New-AnalysisJson {
    param($Data, $A)
    $cells = @()
    foreach ($t in $A.tests) {
        foreach ($c in @($A.cells[$t.code])) {
            $cells += [ordered]@{
                testCode = $t.code; engine = $c.engine; instance = $c.instance; nValid = $c.nValid; nSlots = $c.nSlots
                cappedRuns = $c.cappedRuns; cappedCell = $c.cappedCell; values = $c.values
                dbCpuMsPerOp = $c.dbCpuMsPerOp; appCpuMsPerOp = $c.appCpuMsPerOp; dbCpuShare = $c.dbCpuShare
                timePerUnitMs = $c.timePerUnitMs; median = $c.median; min = $c.min; max = $c.max
                robustCvPct = $c.robustCvPct; noisy = $c.noisy; relToFastest = $c.relToFastest; medianP95Ms = $c.medianP95Ms
                errors = $c.errors; deadlocks = $c.deadlocks; retries = $c.retries; lockViolations = $c.lockViolations; timeouts = $c.timeouts
                rowsReturned = $c.rowsReturned; checksum = $c.checksum; outliers = @($c.outliers).Count; settleTimeouts = $c.settleTimeouts
                capped = ($c.cappedRuns -gt 0)
                medianHeadline = $c.medianHeadline; minHeadline = $c.minHeadline; maxHeadline = $c.maxHeadline
                displayMedian = (Format-CellMedian $c $A.specs[$t.code]); display = (Format-CellRange $c $A.specs[$t.code])
                slots = $c.slots
            }
        }
    }
    $verdicts = @()
    foreach ($t in $A.tests) {
        $v = $A.verdicts[$t.code]
        $pairs = @($v.pairs | ForEach-Object {
                [ordered]@{ faster = $_.faster; slower = $_.slower; gapPct = $_.gapPct; thresholdPct = $_.thresholdPct; u = $_.u; uMax = $_.uMax
                    label = $_.statLabel; noticeable = $_.noticeable; practicalLabel = $_.practical; displayLabel = $_.label
                    absDiffMsPerUnit = $_.absDiffMsPerUnit; medianFastMs = $_.mFast; medianSlowMs = $_.mSlow; nFast = $_.nFast; nSlow = $_.nSlow
                    cvFastPct = $_.cvFastPct; cvSlowPct = $_.cvSlowPct; wins = $_.strictWins; pairings = $_.pairings; signTest = $_.signTest }
            })
        $verdicts += [ordered]@{
            testCode = $t.code; displayName = $t.displayName; family = $t.family; comparable = $v.comparable; reason = $v.reason
            parity = $v.parity; parityNote = $v.parityNote; resultsDiffer = $v.resultsDiffer
            excludedEngines = @($v.excludedEngines); pairs = $pairs; tiers = @($v.tiers | ForEach-Object { , @($_) }); tierNotes = @($v.tierNotes)
            cappedEngines = @($v.cappedEngines); probes = $v.probes
            headline = $v.headline; sentenceMarkdown = $v.sentenceMd
            displayUnit = $(if ($A.specs[$t.code].kind -eq 'rate') { $A.specs[$t.code].per } else { $A.specs[$t.code].long })
        }
    }
    $families = @()
    foreach ($fk in $A.families.Keys) {
        $f = $A.families[$fk]
        $families += [ordered]@{
            family = $f.family; displayName = $f.displayName; label = $f.label; index = $f.index; indexTests = @($f.indexTests); excludedTests = @($f.excludedTests)
            leader = $f.leader; cell = $f.cell; tier1Share = $f.tier1Share; dbCpuShare = $f.dbCpuShare; comparableTests = @($f.comparableTests)
        }
    }
    return [ordered]@{
        schemaVersion = 2; campaignIds = @($Data.campaignIds); generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        generator = 'scripts/New-PerfDBBenchmarkReport.ps1'; profile = [string](Get-Field $Data.meta 'profile'); methodologyVersion = [string](Get-Field $Data.meta 'methodologyVersion')
        tieRule = $TieRule; engines = @($A.engines); repetitions = $A.nSlots
        cells = $cells; verdicts = $verdicts; families = $families; derived = $A.derived; diagnostics = $A.diagnostics
        notComparable = @($A.tests | Where-Object { -not $A.verdicts[$_.code].comparable } | ForEach-Object { [ordered]@{ testCode = $_.code; reason = $A.verdicts[$_.code].reason } })
        notes = @($A.notes)
    }
}

#endregion

#region ---------------------------------------------------------------- HTML

function New-HtmlReport {
    param($Data, $A, [string]$Markdown, [hashtable]$Svgs)
    $body = Convert-MarkdownToHtml $Markdown $Svgs
    $facts = Get-CampaignFacts $Data $A
    $title = 'PerfDBBenchmark 2026 R2 results ' + $script:MDASH + ' campaign ' + $facts.ids
    $css = @'
body { margin: 0; background: #ffffff; color: #1f2937; font: 15px/1.55 system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; }
main { max-width: 1040px; margin: 0 auto; padding: 24px 20px 64px; }
h1 { font-size: 28px; margin: 8px 0 12px; }
h2 { font-size: 22px; margin: 36px 0 10px; padding-top: 8px; border-top: 1px solid #e5e7eb; }
h3 { font-size: 18px; margin: 26px 0 8px; }
p, li { max-width: 72em; }
blockquote { margin: 14px 0; padding: 10px 16px; background: #f8fafc; border-left: 4px solid #0072B2; }
blockquote p { margin: 0; }
table { border-collapse: collapse; margin: 10px 0 16px; width: 100%; font-size: 14px; }
th, td { border: 1px solid #e5e7eb; padding: 6px 8px; text-align: left; vertical-align: top; }
th { background: #f3f4f6; }
tr:nth-child(even) td { background: #fafafa; }
code { background: #f3f4f6; padding: 1px 4px; border-radius: 4px; }
figure.chart { margin: 14px 0; overflow-x: auto; }
figure.chart svg { max-width: 100%; height: auto; }
.meta { color: #4b5563; font-size: 13px; }
'@
    $meta = ('<p class="meta">Campaign {0} {1} profile {2} {1} {3} measured repetitions {1} generated {4} by scripts/New-PerfDBBenchmarkReport.ps1</p>' -f (ConvertTo-XmlText $facts.ids), $script:MIDDOT, (ConvertTo-XmlText $facts.profile), $A.nSlots, ([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm') + ' UTC'))
    $html = "<!DOCTYPE html>`n<html lang=`"en`">`n<head>`n<meta charset=`"utf-8`">`n<meta name=`"viewport`" content=`"width=device-width, initial-scale=1`">`n<title>" + (ConvertTo-XmlText $title) + "</title>`n<style>`n" + $css + "</style>`n</head>`n<body>`n<main>`n" + $meta + "`n" + $body + "</main>`n</body>`n</html>`n"
    return $html
}

#endregion

#region ---------------------------------------------------------------- main

function Invoke-Report {
    param([string[]]$Paths, [string]$Out, [string]$ChartPrefix)
    $data = Import-Campaign $Paths
    if (-not $Out) { $Out = $data.inputDirs[0] }
    if (-not (Test-Path -LiteralPath $Out)) { New-Item -ItemType Directory -Force -Path $Out | Out-Null }
    $Out = (Resolve-Path -LiteralPath $Out).ProviderPath
    $chartDir = Join-Path $Out 'charts'
    if (-not (Test-Path -LiteralPath $chartDir)) { New-Item -ItemType Directory -Force -Path $chartDir | Out-Null }

    $a = Invoke-Analysis $data

    # charts
    $svgs = @{}
    $atGlance = New-RelativeBarChart -Title 'Results at a glance' -Subtitle ('Median of ' + $a.nSlots + ' repetitions per test and database, relative to the fastest database on each test.') -Sections (Get-FamilyChartSections $a @($a.families.Keys) -Compact) -Compact
    $svgs['at-a-glance.svg'] = $atGlance
    foreach ($fk in $a.families.Keys) {
        $info = $script:FamilyInfo[$fk]
        $file = if ($info) { $info.chart } else { 'family-' + $fk.ToLowerInvariant() + '.svg' }
        $fam = $a.families[$fk]
        $svgs[$file] = New-RelativeBarChart -Title ($fam.displayName + $(if ($fam.label) { ' ' + $fam.label } else { '' })) -Subtitle ('Median of ' + $a.nSlots + ' repetitions; each test on its own relative scale; the absolute median is printed after the ratio.') -Sections (Get-FamilyChartSections $a @($fk))
    }
    if (@($a.derived.scaling).Count) { $svgs['scaling-orders.svg'] = New-ScalingChart $a.derived.scaling }
    if (@($a.derived.speedup1Uto8U).Count) { $svgs['speedup-core.svg'] = New-SpeedupChart $a.derived.speedup1Uto8U }
    foreach ($k in $svgs.Keys) { Write-Utf8File (Join-Path $chartDir $k) $svgs[$k] }

    # analysis.json
    $json = ConvertTo-JsonText (New-AnalysisJson $data $a) 0 3
    Write-Utf8File (Join-Path $Out 'analysis.json') ($json + "`n")

    # README fragments and HTML
    $md = New-ReadmeFragments $data $a $ChartPrefix
    Write-Utf8File (Join-Path $Out 'README-results.md') $md
    $inline = @{}
    foreach ($k in $svgs.Keys) { $inline[$k] = ($svgs[$k] -replace '^<\?xml[^>]*\?>\s*', '') }
    $mdForHtml = New-ReadmeFragments $data $a 'charts/'
    $campaignName = ($data.campaignIds | Select-Object -First 1)
    if (-not $campaignName) { $campaignName = 'campaign' }
    $htmlPath = Join-Path $Out ('PerfDBBenchmark-' + $campaignName + '.html')
    Write-Utf8File $htmlPath (New-HtmlReport $data $a $mdForHtml $inline)

    # console summary
    $nc = @($a.tests | Where-Object { -not $a.verdicts[$_.code].comparable })
    Write-Host ('Report written to {0}' -f $Out)
    Write-Host ('  analysis.json, {0}, README-results.md, charts\{1}' -f (Split-Path -Leaf $htmlPath), (($svgs.Keys | Sort-Object) -join ', '))
    Write-Host ('  {0} tests, {1} not comparable; profile {2}.' -f @($a.tests).Count, $nc.Count, [string](Get-Field $data.meta 'profile'))
    foreach ($t in $a.tests) { Write-Host ('  {0,-28} {1}' -f $t.code, $a.verdicts[$t.code].headline) }
    return [ordered]@{ notComparable = $nc.Count; profile = [string](Get-Field $data.meta 'profile') }
}

$prevCulture = [Threading.Thread]::CurrentThread.CurrentCulture
$exitCode = 0
try {
    [Threading.Thread]::CurrentThread.CurrentCulture = $script:Inv
    if ($SelfTest) {
        $ok = Invoke-SelfTest
        if (-not $ok) { $exitCode = 1 }
    }
    # 'powershell -File' passes '-InputJson a.json,b.json' as one string: split it when that string is not a file.
    if ($InputJson) { $InputJson = @($InputJson | ForEach-Object { if ($_ -like '*,*' -and -not (Test-Path -LiteralPath $_)) { $_ -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } } else { $_ } }) }
    if ($exitCode -eq 0 -and $InputJson) {
        $res = Invoke-Report $InputJson $OutDir $ChartUrlPrefix
        if ($Publish) {
            if ($res.profile -ne 'Full') { Write-Warning ("Profile '{0}' is preliminary and is never published." -f $res.profile); $exitCode = 3 }
            elseif ($res.notComparable -gt 0 -and -not $AllowPartial) { Write-Warning ("{0} test(s) are not comparable; publish with -AllowPartial to list them as excluded." -f $res.notComparable); $exitCode = 2 }
        }
    }
    elseif (-not $SelfTest -and -not $InputJson) {
        throw 'Specify -InputJson <campaign json> (and optionally -OutDir), or -SelfTest.'
    }
}
catch {
    Write-Error -ErrorRecord $_ -ErrorAction Continue
    $exitCode = 1
}
finally {
    [Threading.Thread]::CurrentThread.CurrentCulture = $prevCulture
}
exit $exitCode

#endregion
