<#
.SYNOPSIS
    Reads SUBFL data from Elasticsearch and writes it into SQL Server.

.DESCRIPTION
    Queries Elasticsearch with date, instance, and ScenarioName filters, using the
    shared Invoke-ElasticScrollSearch helper for paged retrieval. For each hit, the
    script extracts MSGID/BusinessCaseId, scenario/process fields, and selected
    SUBFL business key values and writes them to dbo.ElasticData in SQL Server.

    The BK.SUBFL_subid_list value is normalized to a comma-separated string and also
    transformed into XML (<subids><subid>...</subid></subids>) for future SQL queries.

.PARAMETER StartDate
    Inclusive start date for @timestamp filtering.

.PARAMETER EndDate
    Inclusive end date for @timestamp filtering.

.PARAMETER Instance
    Optional Orchestra instance filter.

.PARAMETER ScenarioName
    ScenarioName wildcard filter. Defaults to *SUBFL*.

.PARAMETER Database
    SQL Server target database name. Defaults to ServerConfig.psd1 (SqlServer.ElasticData.Database).

.PARAMETER Server
    SQL Server target server name. Defaults to ServerConfig.psd1 (SqlServer.ElasticData.Connection).

.PARAMETER ElasticUrl
    Elasticsearch _search URL.

.PARAMETER ResetCredentials
    Discard the saved Elasticsearch credential and prompt for a new API key.

.PARAMETER OutputDirectory
    Optional directory to write a plain-text run summary. A timestamped file is created inside this directory when set.

.EXAMPLE
    ./Write-ElasticDataToDatabase.ps1 -StartDate (Get-Date).Date -EndDate (Get-Date)
#>
param(
    [Parameter(Mandatory=$true)]
    [datetime]$StartDate,

    [Parameter(Mandatory=$true)]
    [datetime]$EndDate,

    [Parameter(Mandatory=$false)]
    [string]$Instance,

    [Parameter(Mandatory=$false)]
    [string]$ScenarioName = '*SUBFL*',

    [Parameter(Mandatory=$false)]
    [string]$Database = '',

    [Parameter(Mandatory=$false)]
    [string]$Server = '',

    [Parameter(Mandatory=$false)]
    [string]$ElasticUrl = '',

    [Parameter(Mandatory=$false)]
    [switch]$ResetCredentials,

    [Parameter(Mandatory=$false)]
    [string]$OutputDirectory = ''
)

$sharedHelpersDirectory = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Common'
$sharedHelpersPath = Join-Path -Path $sharedHelpersDirectory -ChildPath 'ElasticSearchHelpers.ps1'
if (-not (Test-Path -Path $sharedHelpersPath)) {
    throw "Shared Elastic helper not found at '$sharedHelpersPath'."
}
. $sharedHelpersPath
. (Join-Path $sharedHelpersDirectory 'ServerConfig.ps1')

function ConvertTo-StringValue {
    param([object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $parts = @()
        foreach ($entry in $Value) {
            if ($null -eq $entry) { continue }
            $parts += "$entry"
        }
        return [string]::Join(',', $parts)
    }

    return "$Value"
}

function ConvertTo-SubIdListXml {
    param([string]$SubIdList)

    if ([string]::IsNullOrWhiteSpace($SubIdList)) {
        return '<subids />'
    }

    $subIds = $SubIdList.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($subIds.Count -eq 0) {
        return '<subids />'
    }

    $xmlBuilder = [System.Text.StringBuilder]::new()
    $null = $xmlBuilder.Append('<subids>')
    foreach ($subId in $subIds) {
        $escaped = [System.Security.SecurityElement]::Escape($subId)
        $null = $xmlBuilder.Append("<subid>$escaped</subid>")
    }
    $null = $xmlBuilder.Append('</subids>')
    return $xmlBuilder.ToString()
}

<#
════════════════════════════════════════════════════════
  SCRIPT BODY
════════════════════════════════════════════════════════
#>

$_cfg = Get-ServerConfig
if ([string]::IsNullOrWhiteSpace($Server)) {
    $Server = $_cfg.SqlServer.ElasticData.Connection
}
if ([string]::IsNullOrWhiteSpace($Database)) {
    $Database = $_cfg.SqlServer.ElasticData.Database
}
if ([string]::IsNullOrWhiteSpace($ElasticUrl)) {
    $ElasticUrl = $_cfg.Elasticsearch.OrchestraSearchUrl
}

$credPath = Join-Path -Path $PSScriptRoot -ChildPath 'elastic.credentials.clixml'
$elasticCred = Resolve-ElasticCredential -CredentialPath $credPath -Reset:$ResetCredentials
$headers = @{ 'Authorization' = "ApiKey $($elasticCred.GetNetworkCredential().Password)" }

$filters = @(
    @{ range = @{ '@timestamp' = @{ gte = $StartDate.ToString('o'); lte = $EndDate.ToString('o') } } },
    @{ wildcard = @{ 'ScenarioName' = @{ value = $ScenarioName } } }
)

if (-not [string]::IsNullOrWhiteSpace($Instance)) {
    $filters += @{ term = @{ 'Instance' = $Instance } }
}

$body = @{
    size = 1000
    query = @{ bool = @{ filter = $filters } }
    _source = @(
        '@timestamp',
        'BusinessCaseId',
        'MSGID',
        'ScenarioName',
        'ProcessName',
        'BK.SUBFL_changeart',
        'BK.SUBFL_category',
        'BK.SUBFL_subcategory',
        'BK._HCMMSGEVENT',
        'BK.SUBFL_subid',
        'BK.SUBFL_subid_list'
    )
}

$script:pageCount = 0
$pageProgress = {
    param($PageNumber, $PageHits, $TotalCollected)

    $script:pageCount = $PageNumber
    Write-Progress -Id 1 -Activity 'Loading Elasticsearch data' -Status "Page $($PageNumber) - collected $($TotalCollected)" -PercentComplete 0
}

Write-Host 'Querying Elasticsearch...' -ForegroundColor Cyan
$hits = Invoke-ElasticScrollSearch -ElasticUrl $ElasticUrl -Body $body -Headers $headers -TimeoutSec 120 -OnPage $pageProgress
Write-Progress -Id 1 -Activity 'Loading Elasticsearch data' -Completed

if (-not $hits -or $hits.Count -eq 0) {
    Write-Host 'No Elasticsearch hits found for the given filter.' -ForegroundColor Yellow
    return
}

$table = [System.Data.DataTable]::new()
$null = $table.Columns.Add('MSGID', [string])
$null = $table.Columns.Add('ScenarioName', [string])
$null = $table.Columns.Add('ProcessName', [string])
$null = $table.Columns.Add('ProcesssStarted', [string])
$null = $table.Columns.Add('BK_SUBFL_changeart', [string])
$null = $table.Columns.Add('BK_SUBFL_category', [string])
$null = $table.Columns.Add('BK_SUBFL_subcategory', [string])
$null = $table.Columns.Add('BK_HCMMSGEVENT', [string])
$null = $table.Columns.Add('BK_SUBFL_subid', [string])
$null = $table.Columns.Add('BK_SUBFL_subid_list', [string])
$null = $table.Columns.Add('BK_SUBFL_subid_list_xml', [string])

$totalHits = $hits.Count
for ($index = 0; $index -lt $totalHits; $index++) {
    $hit = $hits[$index]
    $source = $hit._source

    $msgId = ConvertTo-StringValue (Get-ElasticSourceValue -Source $source -FieldPath 'MSGID')
    if ([string]::IsNullOrWhiteSpace($msgId)) {
        $msgId = ConvertTo-StringValue (Get-ElasticSourceValue -Source $source -FieldPath 'BusinessCaseId')
    }

    $scenario = ConvertTo-StringValue (Get-ElasticSourceValue -Source $source -FieldPath 'ScenarioName')
    $processName = ConvertTo-StringValue (Get-ElasticSourceValue -Source $source -FieldPath 'ProcessName')
    $processStarted = ConvertTo-StringValue (Get-ElasticSourceValue -Source $source -FieldPath '@timestamp')
    $changeArt = ConvertTo-StringValue (Get-ElasticSourceValue -Source $source -FieldPath 'BK.SUBFL_changeart')
    $category = ConvertTo-StringValue (Get-ElasticSourceValue -Source $source -FieldPath 'BK.SUBFL_category')
    $subCategory = ConvertTo-StringValue (Get-ElasticSourceValue -Source $source -FieldPath 'BK.SUBFL_subcategory')
    $hcmMsgEvent = ConvertTo-StringValue (Get-ElasticSourceValue -Source $source -FieldPath 'BK._HCMMSGEVENT')
    $subId = ConvertTo-StringValue (Get-ElasticSourceValue -Source $source -FieldPath 'BK.SUBFL_subid')

    $subIdListRaw = Get-ElasticSourceValue -Source $source -FieldPath 'BK.SUBFL_subid_list'
    $subIdList = ConvertTo-StringValue $subIdListRaw
    $subIdListXml = ConvertTo-SubIdListXml -SubIdList $subIdList

    $row = $table.NewRow()
    $row['MSGID'] = $msgId
    $row['ScenarioName'] = $scenario
    $row['ProcessName'] = $processName
    $row['ProcesssStarted'] = $processStarted
    $row['BK_SUBFL_changeart'] = $changeArt
    $row['BK_SUBFL_category'] = $category
    $row['BK_SUBFL_subcategory'] = $subCategory
    $row['BK_HCMMSGEVENT'] = $hcmMsgEvent
    $row['BK_SUBFL_subid'] = $subId
    $row['BK_SUBFL_subid_list'] = $subIdList
    $row['BK_SUBFL_subid_list_xml'] = $subIdListXml
    $null = $table.Rows.Add($row)

    $percent = [int]((($index + 1) / [Math]::Max(1, $totalHits)) * 100)
    Write-Progress -Id 2 -Activity 'Transforming Elasticsearch hits' -Status "Record $($index + 1) / $($totalHits)" -PercentComplete $percent
}
Write-Progress -Id 2 -Activity 'Transforming Elasticsearch hits' -Completed

$connectionString = "Server=$($Server);Database=$($Database);Integrated Security=True;TrustServerCertificate=True;"
$connection = [System.Data.SqlClient.SqlConnection]::new($connectionString)
$bulkCopy = $null

try {
    $connection.Open()

    $bulkCopy = [System.Data.SqlClient.SqlBulkCopy]::new($connection)
    $bulkCopy.DestinationTableName = '[dbo].[ElasticData]'
    $bulkCopy.BatchSize = 2000
    $bulkCopy.BulkCopyTimeout = 0

    foreach ($column in $table.Columns) {
        $null = $bulkCopy.ColumnMappings.Add($column.ColumnName, $column.ColumnName)
    }

    Write-Host "Writing $($table.Rows.Count) rows to [$($Database)].[dbo].[ElasticData] on $($Server)..." -ForegroundColor Cyan
    $bulkCopy.WriteToServer($table)
    Write-Host 'Finished writing rows to SQL Server.' -ForegroundColor Green
}
finally {
    if ($bulkCopy) { $bulkCopy.Close() }
    if ($connection.State -ne [System.Data.ConnectionState]::Closed) { $connection.Close() }
    $connection.Dispose()
}

if (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) {
    if (-not (Test-Path -Path $OutputDirectory)) {
        $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    }
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $outputPath = Join-Path -Path $OutputDirectory -ChildPath "WriteElasticData_$timestamp.txt"
    @(
        "StartDate : $StartDate"
        "EndDate   : $EndDate"
        "Server    : $Server"
        "Database  : $Database"
        "Rows      : $($table.Rows.Count)"
    ) | Set-Content -Path $outputPath -Encoding UTF8
    Write-Host "Summary written to '$outputPath'" -ForegroundColor Cyan
}
