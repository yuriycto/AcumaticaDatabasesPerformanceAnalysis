param(
    [string]$InstanceRoot = "E:\Instances2\26.100.0168",
    [string]$PreferredBuildInstance = "PerfSQL",
    [string]$Configuration = "Release",
    [string]$ProductVersion = "26.100",
    [int]$CustomizationLevel = 10,
    [string]$PackageName = "PerfDBBenchmark",
    [switch]$SkipDotNetBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$coreProjectPath = Join-Path $repoRoot "src\PerfDBBenchmark.Core\PerfDBBenchmark.Core.csproj"
$coreDllPath = Join-Path $repoRoot "src\PerfDBBenchmark.Core\bin\$Configuration\net48\PerfDBBenchmark.Core.dll"
$customizationRoot = Join-Path $repoRoot "customization\PerfDBBenchmark"
$pagePath = Join-Path $customizationRoot "Pages\AC\AC301000.aspx"
$modernUiRoot = Join-Path $customizationRoot "FrontendSources\screen\src\development\screens\AC\AC301000"
$modernUiHtmlPath = Join-Path $modernUiRoot "AC301000.html"
$modernUiTsPath = Join-Path $modernUiRoot "AC301000.ts"
$modernUiViewsPath = Join-Path $modernUiRoot "views.ts"
$packageDllFolder = Join-Path $customizationRoot "Bin"
$packageDllPath = Join-Path $packageDllFolder "PerfDBBenchmark.Core.dll"
$projectXmlPath = Join-Path $customizationRoot "project.xml"
$artifactsFolder = Join-Path $repoRoot "artifacts"
$packagePath = Join-Path $artifactsFolder "$PackageName.zip"

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function ConvertTo-CompressedBase64 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $inputBytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $memoryStream = [System.IO.MemoryStream]::new()
    $deflateStream = [System.IO.Compression.DeflateStream]::new($memoryStream, [System.IO.Compression.CompressionMode]::Compress, $true)
    $deflateStream.Write($inputBytes, 0, $inputBytes.Length)
    $deflateStream.Dispose()
    $compressedBytes = $memoryStream.ToArray()
    $memoryStream.Dispose()
    return [Convert]::ToBase64String($compressedBytes)
}

function Get-PxCommandLinePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$PreferredInstance
    )

    $preferredPath = Join-Path $Root "$PreferredInstance\Bin\PX.CommandLine.exe"
    if (Test-Path -LiteralPath $preferredPath) {
        return $preferredPath
    }

    $matches = Get-ChildItem -LiteralPath $Root -Recurse -Filter "PX.CommandLine.exe" -File | Sort-Object FullName
    if ($matches.Count -eq 0) {
        throw "PX.CommandLine.exe was not found under '$Root'."
    }

    return $matches[0].FullName
}

function New-PerfProjectXml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,
        [Parameter(Mandatory = $true)]
        [int]$Level
    )

    $zeroGuid = "00000000-0000-0000-0000-000000000000"
    $screenNodeId = "0e8a89be-ef59-4f57-afc0-fc6c9f8410e1"
    $workspaceId = "c25529f2-1e7e-4c34-ae75-0a524245d166"
    $subcategoryId = "f80fbdb2-bfad-4f79-bfce-3d9a5a5dd1b9"
    $areaId = "588d2f44-a933-4031-a845-a57255c1250e"

    $siteMapNode = @"
    <SiteMapNode>
        <data-set>
            <relations format-version="4" relations-version="20240201" main-table="SiteMap">
                <link from="MUIScreen (NodeID)" to="SiteMap (NodeID)" />
                <link from="MUIWorkspace (WorkspaceID)" to="MUIScreen (WorkspaceID)" type="FromMaster" linkname="workspaceToScreen" split-location="yes" updateable="True" />
                <link from="MUISubcategory (SubcategoryID)" to="MUIScreen (SubcategoryID)" type="FromMaster" updateable="True" />
                <link from="MUITile (ScreenID)" to="SiteMap (ScreenID)" />
                <link from="MUIWorkspace (WorkspaceID)" to="MUITile (WorkspaceID)" type="FromMaster" linkname="workspaceToTile" split-location="yes" updateable="True" />
                <link from="MUIArea (AreaID)" to="MUIWorkspace (AreaID)" type="FromMaster" updateable="True" />
                <link from="MUIPinnedScreen (NodeID, WorkspaceID)" to="MUIScreen (NodeID, WorkspaceID)" type="WeakIfEmpty" isEmpty="Username" />
                <link from="MUIFavoriteWorkspace (WorkspaceID)" to="MUIWorkspace (WorkspaceID)" type="WeakIfEmpty" isEmpty="Username" />
            </relations>
            <layout>
                <table name="SiteMap">
                    <table name="MUIScreen" uplink="(NodeID) = (NodeID)">
                        <table name="MUIPinnedScreen" uplink="(NodeID, WorkspaceID) = (NodeID, WorkspaceID)" />
                    </table>
                    <table name="MUITile" uplink="(ScreenID) = (ScreenID)" />
                </table>
                <table name="MUIWorkspace">
                    <table name="MUIFavoriteWorkspace" uplink="(WorkspaceID) = (WorkspaceID)" />
                </table>
                <table name="MUISubcategory" />
                <table name="MUIArea" />
            </layout>
            <data>
                <SiteMap>
                    <row Title="Perf DB Benchmark" Url="~/Pages/AC/AC301000.aspx" ScreenID="AC301000" NodeID="$screenNodeId" ParentID="$zeroGuid" SelectedUI="T">
                        <MUIScreen IsPortal="0" WorkspaceID="$workspaceId" Order="10" SubcategoryID="$subcategoryId" />
                    </row>
                </SiteMap>
                <MUIWorkspace>
                    <row IsPortal="0" WorkspaceID="$workspaceId" Order="610" Title="AcuPower Tools" Icon="assessment" AreaID="$areaId" ScreenID="WSAP0000" IsSystem="0" />
                </MUIWorkspace>
                <MUISubcategory>
                    <row IsPortal="0" SubcategoryID="$subcategoryId" Order="100" Name="Performance" Icon="" IsSystem="0" />
                </MUISubcategory>
                <MUIArea>
                    <row IsPortal="0" AreaID="$areaId" Order="30" Name="Configuration" />
                </MUIArea>
            </data>
        </data-set>
    </SiteMapNode>
"@

    $perfTestRecordSchema = @'
<table name="PerfTestRecord">
  <col name="CompanyID" type="Int" default="Zero" />
  <col name="RecordID" type="Int" identity="true" />
  <col name="BatchID" type="NVarChar(64)" />
  <col name="OperationType" type="NVarChar(32)" />
  <col name="Iteration" type="Int" default="Zero" />
  <col name="Sequence" type="Int" default="Zero" />
  <col name="PayloadText" type="NVarChar(255)" nullable="true" />
  <col name="PayloadValue" type="Int" default="Zero" />
  <col name="BLOB" type="VarBinary(MAX)" nullable="true" />
  <col name="FileURL" type="NVarChar(255)" nullable="true" />
  <col name="NoteID" type="UniqueIdentifier" />
  <col name="tstamp" type="Timestamp" />
  <col name="CreatedByID" type="UniqueIdentifier" />
  <col name="CreatedByScreenID" type="Char(8)" />
  <col name="CreatedDateTime" type="DateTime" />
  <col name="LastModifiedByID" type="UniqueIdentifier" />
  <col name="LastModifiedByScreenID" type="Char(8)" />
  <col name="LastModifiedDateTime" type="DateTime" />
  <index name="PerfTestRecord_NoteID" unique="true">
    <col name="NoteID" />
    <col name="CompanyID" />
  </index>
  <index name="PerfTestRecord_BatchID_Sequence">
    <col name="CompanyID" />
    <col name="BatchID" />
    <col name="Sequence" />
  </index>
  <index name="PerfTestRecord_PK" clustered="true" primary="true" unique="true">
    <col name="CompanyID" />
    <col name="RecordID" />
  </index>
</table>
'@

    $perfTestResultSchema = @'
<table name="PerfTestResult">
  <col name="CompanyID" type="Int" default="Zero" />
  <col name="ResultID" type="Int" identity="true" />
  <col name="InstanceName" type="NVarChar(64)" />
  <col name="DatabaseType" type="NVarChar(64)" />
  <col name="TestCode" type="NVarChar(64)" />
  <col name="TestCategory" type="NVarChar(64)" />
  <col name="ExecutionMode" type="NVarChar(24)" />
  <col name="DisplayName" type="NVarChar(128)" />
  <col name="RecordsCount" type="Int" nullable="true" />
  <col name="Iterations" type="Int" nullable="true" />
  <col name="BatchSize" type="Int" nullable="true" />
  <col name="MaxThreads" type="Int" nullable="true" />
  <col name="ElapsedMs" type="Int" nullable="true" />
  <col name="Notes" type="NVarChar(1024)" nullable="true" />
  <col name="CapturedAtUtc" type="DateTime" nullable="true" />
  <col name="BLOB" type="VarBinary(MAX)" nullable="true" />
  <col name="FileURL" type="NVarChar(255)" nullable="true" />
  <col name="NoteID" type="UniqueIdentifier" />
  <col name="tstamp" type="Timestamp" />
  <col name="CreatedByID" type="UniqueIdentifier" />
  <col name="CreatedByScreenID" type="Char(8)" />
  <col name="CreatedDateTime" type="DateTime" />
  <col name="LastModifiedByID" type="UniqueIdentifier" />
  <col name="LastModifiedByScreenID" type="Char(8)" />
  <col name="LastModifiedDateTime" type="DateTime" />
  <index name="PerfTestResult_NoteID" unique="true">
    <col name="NoteID" />
    <col name="CompanyID" />
  </index>
  <index name="PerfTestResult_TestCode_CapturedAtUtc">
    <col name="CompanyID" />
    <col name="TestCode" />
    <col name="CapturedAtUtc" />
  </index>
  <index name="PerfTestResult_PK" clustered="true" primary="true" unique="true">
    <col name="CompanyID" />
    <col name="ResultID" />
  </index>
</table>
'@

    return @"
<Customization level="$Level" description="PerfDBBenchmark by AcuPower LTD (acupowererp.com) for performance analysis" product-version="$Version">
    <File AppRelativePath="Bin\PerfDBBenchmark.Core.dll" />
    <File AppRelativePath="Pages\AC\AC301000.aspx" />
    <File AppRelativePath="FrontendSources\screen\src\development\screens\AC\AC301000\AC301000.html" />
    <File AppRelativePath="FrontendSources\screen\src\development\screens\AC\AC301000\AC301000.ts" />
    <File AppRelativePath="FrontendSources\screen\src\development\screens\AC\AC301000\views.ts" />
$siteMapNode
    <Sql TableName="PerfTestRecord" TableSchemaXml="#CDATA">
        <CDATA name="TableSchemaXml"><![CDATA[$perfTestRecordSchema]]></CDATA>
    </Sql>
    <Sql TableName="PerfTestResult" TableSchemaXml="#CDATA">
        <CDATA name="TableSchemaXml"><![CDATA[$perfTestResultSchema]]></CDATA>
    </Sql>
</Customization>
"@
}

if (-not (Test-Path -LiteralPath $customizationRoot)) {
    throw "Customization root was not found: $customizationRoot"
}

if (-not (Test-Path -LiteralPath $pagePath)) {
    throw "The AC301000 page markup was not found: $pagePath"
}

if (-not (Test-Path -LiteralPath $modernUiHtmlPath)) {
    throw "The AC301000 modern UI markup was not found: $modernUiHtmlPath"
}

if (-not (Test-Path -LiteralPath $modernUiTsPath)) {
    throw "The AC301000 modern UI TypeScript file was not found: $modernUiTsPath"
}

if (-not (Test-Path -LiteralPath $modernUiViewsPath)) {
    throw "The AC301000 modern UI view model file was not found: $modernUiViewsPath"
}

if (-not (Test-Path -LiteralPath $projectXmlPath)) {
    throw "The customization project manifest was not found: $projectXmlPath"
}

if (-not $SkipDotNetBuild) {
    Write-Host "Building PerfDBBenchmark.Core ($Configuration)..." -ForegroundColor Cyan
    & dotnet build $coreProjectPath -c $Configuration
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet build failed with exit code $LASTEXITCODE."
    }
}

if (-not (Test-Path -LiteralPath $coreDllPath)) {
    throw "The compiled DLL was not found: $coreDllPath"
}

New-Item -Path $packageDllFolder -ItemType Directory -Force | Out-Null
New-Item -Path $artifactsFolder -ItemType Directory -Force | Out-Null
Copy-Item -LiteralPath $coreDllPath -Destination $packageDllPath -Force

if (Test-Path -LiteralPath $packagePath) {
    Remove-Item -LiteralPath $packagePath -Force
}

$pxCommandLinePath = Get-PxCommandLinePath -Root $InstanceRoot -PreferredInstance $PreferredBuildInstance
Write-Host "Using PX.CommandLine: $pxCommandLinePath" -ForegroundColor DarkCyan

& $pxCommandLinePath /method BuildProject /in $customizationRoot /out $packagePath
if ($LASTEXITCODE -ne 0) {
    throw "PX.CommandLine BuildProject failed with exit code $LASTEXITCODE."
}

Write-Host "Customization project manifest preserved: $projectXmlPath" -ForegroundColor Green
Write-Host "Customization package built: $packagePath" -ForegroundColor Green
