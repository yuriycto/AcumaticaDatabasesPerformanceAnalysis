param(
    [string[]]$Instances = @("PerfPG", "PerfrMySQL", "PerfSQL"),
    [string]$Username = "admin",
    [string]$Password = "PerformanceTest",
    [int]$RemoteDebuggingPort = 9245,
    [int]$NumberOfRecords = 10,
    [int]$Iterations = 1,
    [int]$BatchSize = 5,
    [int]$MaxThreads = 2,
    [string]$ChromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$artifactsRoot = Join-Path $repoRoot "artifacts"
$chromeProfileRoot = Join-Path $artifactsRoot ("chrome-smoke-profile-" + [guid]::NewGuid().ToString("N"))

function Start-HeadlessChrome {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExecutablePath,
        [Parameter(Mandatory = $true)]
        [string]$ProfilePath,
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    if (-not (Test-Path -LiteralPath $ExecutablePath)) {
        throw "Google Chrome was not found: $ExecutablePath"
    }

    New-Item -Path $ProfilePath -ItemType Directory -Force | Out-Null

    $process = Start-Process -FilePath $ExecutablePath -ArgumentList @(
        "--headless=new",
        "--disable-gpu",
        "--remote-debugging-port=$Port",
        "--user-data-dir=$ProfilePath",
        "about:blank"
    ) -PassThru

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt 15) {
        try {
            $null = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/json/version" -UseBasicParsing
            return $process
        }
        catch {
            Start-Sleep -Milliseconds 500
        }
    }

    throw "Chrome DevTools endpoint on port $Port did not become available."
}

function Get-CdpTargetUrl {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list"
    $pageTarget = $targets | Where-Object { $_.type -eq "page" } | Select-Object -First 1
    if ($null -eq $pageTarget) {
        throw "No page target was exposed by Chrome DevTools."
    }

    return [string]$pageTarget.webSocketDebuggerUrl
}

function Connect-Cdp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WebSocketUrl
    )

    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    [void]$socket.ConnectAsync([Uri]$WebSocketUrl, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    return $socket
}

function Receive-CdpMessage {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.WebSockets.ClientWebSocket]$Socket
    )

    $buffer = New-Object byte[] 65536
    $stream = [System.IO.MemoryStream]::new()

    try {
        do {
            $segment = [ArraySegment[byte]]::new($buffer)
            $result = $Socket.ReceiveAsync($segment, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
            if ($result.Count -gt 0) {
                $stream.Write($buffer, 0, $result.Count)
            }
        }
        while (-not $result.EndOfMessage)

        return [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
    }
    finally {
        $stream.Dispose()
    }
}

$script:CdpMessageId = 0

function Invoke-CdpCommand {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [Parameter(Mandatory = $true)]
        [string]$Method,
        [hashtable]$Params = @{}
    )

    $messageId = [System.Threading.Interlocked]::Increment([ref]$script:CdpMessageId)
    $payload = @{
        id = $messageId
        method = $Method
    }

    if ($Params.Count -gt 0) {
        $payload.params = $Params
    }

    $json = $payload | ConvertTo-Json -Compress -Depth 100
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $segment = [ArraySegment[byte]]::new($bytes)
    [void]$Socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()

    while ($true) {
        $responseText = Receive-CdpMessage -Socket $Socket
        if ([string]::IsNullOrWhiteSpace($responseText)) {
            continue
        }

        $response = $responseText | ConvertFrom-Json
        $hasId = $response.PSObject.Properties.Name -contains "id"
        $hasError = $response.PSObject.Properties.Name -contains "error"

        if ($hasId -and $null -ne $response.id -and [int]$response.id -eq $messageId) {
            if ($hasError -and $null -ne $response.error) {
                throw "CDP $Method failed: $($response.error.message)"
            }

            return $response
        }
    }
}

function Invoke-Js {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [Parameter(Mandatory = $true)]
        [string]$Expression
    )

    $response = Invoke-CdpCommand -Socket $Socket -Method "Runtime.evaluate" -Params @{
        expression = $Expression
        returnByValue = $true
        awaitPromise = $true
    }

    $hasExceptionDetails = $response.result.PSObject.Properties.Name -contains "exceptionDetails"
    if ($hasExceptionDetails -and $null -ne $response.result.exceptionDetails) {
        throw "JavaScript execution failed."
    }

    $runtimeResult = $response.result.result
    if ($runtimeResult.PSObject.Properties.Name -contains "value") {
        return $runtimeResult.value
    }

    if ($runtimeResult.PSObject.Properties.Name -contains "description") {
        return $runtimeResult.description
    }

    return $runtimeResult
}

function Wait-ForJs {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [Parameter(Mandatory = $true)]
        [string]$Expression,
        [string]$ConditionDescription = "browser condition",
        [int]$TimeoutSeconds = 30,
        [int]$DelayMilliseconds = 500
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try {
            $value = Invoke-Js -Socket $Socket -Expression $Expression
            if ($value) {
                return $value
            }
        }
        catch {
        }

        Start-Sleep -Milliseconds $DelayMilliseconds
    }

    throw "Timed out while waiting for $ConditionDescription."
}

function Navigate-Browser {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [int]$WarmupSeconds = 4
    )

    Invoke-CdpCommand -Socket $Socket -Method "Page.navigate" -Params @{ url = $Url } | Out-Null
    Start-Sleep -Seconds $WarmupSeconds
}

function Test-Instance {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [Parameter(Mandatory = $true)]
        [string]$AppPath
    )

    $loginUrl = "http://localhost/$AppPath/Frames/Login.aspx?ReturnUrl=%2f$AppPath"
    $screenUrl = "http://localhost/$AppPath/Pages/AC/AC301000.aspx"

    Navigate-Browser -Socket $Socket -Url $loginUrl -WarmupSeconds 4
    Wait-ForJs -Socket $Socket -Expression "!!document.getElementById('txtUser') && !!document.getElementById('txtPass')" -ConditionDescription "login fields on $AppPath" -TimeoutSeconds 30 | Out-Null

    $fillLogin = @"
(() => {
  const setValue = (id, value) => {
    const element = document.getElementById(id);
    if (!element) {
      return false;
    }

    element.focus();
    element.value = value;
    element.dispatchEvent(new Event('input', { bubbles: true }));
    element.dispatchEvent(new Event('change', { bubbles: true }));
    element.blur();
    return true;
  };

  return setValue('txtUser', '$Username') && setValue('txtPass', '$Password');
})()
"@

    $filled = Invoke-Js -Socket $Socket -Expression $fillLogin
    if (-not $filled) {
        throw "Login fields could not be populated for $AppPath."
    }

    $loginClicked = Invoke-Js -Socket $Socket -Expression @"
(() => {
  const button = document.getElementById('btnLogin');
  if (!button) {
    return false;
  }

  button.click();
  return true;
})()
"@
    if (-not $loginClicked) {
        throw "Login button was not found for $AppPath."
    }

    Start-Sleep -Seconds 8
    Wait-ForJs -Socket $Socket -Expression "!window.location.href.includes('Login.aspx')" -ConditionDescription "post-login redirect on $AppPath" -TimeoutSeconds 45 | Out-Null

    Navigate-Browser -Socket $Socket -Url $screenUrl -WarmupSeconds 12
    Wait-ForJs -Socket $Socket -Expression "document.body && document.body.innerText.includes('PerfDBBenchmark') && !!document.getElementById('ctl00_phG_tabBenchmark_t2_btnSeqWrite')" -ConditionDescription "AC301000 benchmark screen on $AppPath" -TimeoutSeconds 60 | Out-Null
    try {
        Wait-ForJs -Socket $Socket -Expression @"
(() => {
  const db = document.getElementById('ctl00_phF_frmEnvironment_edCurrentDatabase');
  const inst = document.getElementById('ctl00_phF_frmEnvironment_edCurrentInstance');
  return !!db && !!inst && (!!db.value || !!inst.value);
})()
"@ -ConditionDescription "environment labels on $AppPath" -TimeoutSeconds 20 | Out-Null
    }
    catch {
    }

    $environment = Invoke-Js -Socket $Socket -Expression @"
(() => ({
  currentDatabase: document.getElementById('ctl00_phF_frmEnvironment_edCurrentDatabase')?.value ?? null,
  currentInstance: document.getElementById('ctl00_phF_frmEnvironment_edCurrentInstance')?.value ?? null
}))()
"@

    $initialRowCount = [int](Invoke-Js -Socket $Socket -Expression "document.querySelectorAll('#ctl00_phG_tabBenchmark_t3_gridResults tr').length")

    $setParameters = @"
(() => {
  const updates = [
    ['ctl00_phG_tabBenchmark_t1_frmParameters_edNumberOfRecords', '$NumberOfRecords'],
    ['ctl00_phG_tabBenchmark_t1_frmParameters_edIterations', '$Iterations'],
    ['ctl00_phG_tabBenchmark_t1_frmParameters_edParallelBatchSize', '$BatchSize'],
    ['ctl00_phG_tabBenchmark_t1_frmParameters_edParallelMaxThreads', '$MaxThreads']
  ];

  for (const [id, value] of updates) {
    const element = document.getElementById(id);
    if (!element) {
      return { ok: false, missing: id };
    }

    element.focus();
    element.value = value;
    element.dispatchEvent(new Event('input', { bubbles: true }));
    element.dispatchEvent(new Event('change', { bubbles: true }));
    element.blur();
  }

  return { ok: true };
})()
"@

    $parameterResult = Invoke-Js -Socket $Socket -Expression $setParameters
    if (-not $parameterResult.ok) {
        throw "Failed to populate parameters on $AppPath. Missing: $($parameterResult.missing)"
    }

    Invoke-Js -Socket $Socket -Expression @"
(() => {
  document.getElementById('ctl00_phG_tabBenchmark_tab2')?.click();
  return true;
})()
"@ | Out-Null
    Start-Sleep -Seconds 1

    $buttonClicked = Invoke-Js -Socket $Socket -Expression @"
(() => {
  const button = document.getElementById('ctl00_phG_tabBenchmark_t2_btnSeqWrite');
  if (!button) {
    return false;
  }

  button.click();
  return true;
})()
"@
    if (-not $buttonClicked) {
        throw "Sequential Write button was not found on $AppPath."
    }

    $longOperationObserved = $false
    try {
        Wait-ForJs -Socket $Socket -Expression "document.body && document.body.innerText.includes('Executing. Press to abort')" -ConditionDescription "Sequential Write long operation start on $AppPath" -TimeoutSeconds 20 | Out-Null
        $longOperationObserved = $true
    }
    catch {
    }

    if ($longOperationObserved) {
        Wait-ForJs -Socket $Socket -Expression "document.body && !document.body.innerText.includes('Executing. Press to abort')" -ConditionDescription "Sequential Write long operation completion on $AppPath" -TimeoutSeconds 180 | Out-Null
    }
    else {
        Start-Sleep -Seconds 8
    }

    Invoke-Js -Socket $Socket -Expression @"
(() => {
  document.getElementById('ctl00_phG_tabBenchmark_tab3')?.click();
  return true;
})()
"@ | Out-Null
    Start-Sleep -Seconds 3

    $rowCountAfter = [int](Invoke-Js -Socket $Socket -Expression "document.querySelectorAll('#ctl00_phG_tabBenchmark_t3_gridResults tr').length")

    $gridText = Invoke-Js -Socket $Socket -Expression @"
(() => {
  const grid = document.getElementById('ctl00_phG_tabBenchmark_t3_gridResults');
  return grid ? grid.innerText : '';
})()
"@

    $messageText = Invoke-Js -Socket $Socket -Expression @"
(() => {
  const msg = document.getElementById('msgBox_cont');
  return msg ? msg.innerText.trim() : '';
})()
"@

    $expectedInstance = if ([string]::IsNullOrWhiteSpace([string]$environment.currentInstance)) { $AppPath } else { [string]$environment.currentInstance }
    $hasExpectedResult = $gridText -match "Sequential Write" -and $gridText -match [regex]::Escape($expectedInstance)
    if (-not $hasExpectedResult) {
        throw "Sequential Write did not appear in the results grid for $AppPath."
    }

    return [pscustomobject]@{
        AppPath = $AppPath
        ScreenUrl = $screenUrl
        CurrentDatabase = $environment.currentDatabase
        CurrentInstance = $environment.currentInstance
        InitialRowCount = $initialRowCount
        FinalRowCount = [int]$rowCountAfter
        GridContainsSequentialWrite = [bool]($gridText -match "Sequential Write")
        LongOperationObserved = $longOperationObserved
        MessageText = [string]$messageText
        Success = $true
    }
}

if (-not (Test-Path -LiteralPath $artifactsRoot)) {
    New-Item -Path $artifactsRoot -ItemType Directory -Force | Out-Null
}

$results = New-Object System.Collections.Generic.List[object]
$chromeProcess = $null
$socket = $null

try {
    $chromeProcess = Start-HeadlessChrome -ExecutablePath $ChromePath -ProfilePath $chromeProfileRoot -Port $RemoteDebuggingPort
    $wsUrl = Get-CdpTargetUrl -Port $RemoteDebuggingPort
    $socket = Connect-Cdp -WebSocketUrl $wsUrl

    Invoke-CdpCommand -Socket $socket -Method "Page.enable" | Out-Null
    Invoke-CdpCommand -Socket $socket -Method "Runtime.enable" | Out-Null

    foreach ($instance in $Instances) {
        try {
            $results.Add((Test-Instance -Socket $socket -AppPath $instance))
        }
        catch {
            $results.Add([pscustomobject]@{
                AppPath = $instance
                ScreenUrl = "http://localhost/$instance/Pages/AC/AC301000.aspx"
                CurrentDatabase = $null
                CurrentInstance = $null
                InitialRowCount = $null
                FinalRowCount = $null
                GridContainsSequentialWrite = $false
                MessageText = $_.Exception.Message
                Success = $false
            })
        }
    }
}
finally {
    if ($null -ne $socket) {
        try {
            if ($socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                [void]$socket.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
            }
        }
        catch {
        }
        $socket.Dispose()
    }

    if ($null -ne $chromeProcess -and -not $chromeProcess.HasExited) {
        Stop-Process -Id $chromeProcess.Id -Force
    }
}

$results | ConvertTo-Json -Depth 6
