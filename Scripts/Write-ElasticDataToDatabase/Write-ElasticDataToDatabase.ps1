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
    ScenarioName wildcard filter (for example SUBFL*).

.PARAMETER Database
    SQL Server target database name. Defaults to ElasticData.

.PARAMETER Server
    SQL Server target server name. Defaults to evolux.wienkav.at.

.PARAMETER ElasticUrl
    Elasticsearch _search URL.

.PARAMETER ElasticApiKey
    Optional Elasticsearch API key.

.PARAMETER ElasticApiKeyPath
    Optional path to a file containing the Elasticsearch API key.

.EXAMPLE
    ./Write-ElasticDataToDatabase.ps1 -StartDate (Get-Date).Date -EndDate (Get-Date) -ScenarioName 'SUBFL*'
#>
param(
    [Parameter(Mandatory=$true)]
    [datetime]$StartDate,

    [Parameter(Mandatory=$true)]
    [datetime]$EndDate,

    [Parameter(Mandatory=$false)]
    [string]$Instance,

    [Parameter(Mandatory=$true)]
    [string]$ScenarioName,

    [Parameter(Mandatory=$false)]
    [string]$Database = 'ElasticData',

    [Parameter(Mandatory=$false)]
    [string]$Server = 'evolux.wienkav.at',

    [Parameter(Mandatory=$false)]
    [string]$ElasticUrl = 'https://es-obs.apps.zeus.wien.at/logs-orchestra.journals*/_search',

    [Parameter(Mandatory=$false)]
    [string]$ElasticApiKey,

    [Parameter(Mandatory=$false)]
    [string]$ElasticApiKeyPath = (Join-Path -Path $PSScriptRoot -ChildPath 'elastic.key')
)

$sharedHelpersDirectory = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Common'
$sharedHelpersPath = Join-Path -Path $sharedHelpersDirectory -ChildPath 'ElasticSearchHelpers.ps1'
if (-not (Test-Path -Path $sharedHelpersPath)) {
    throw "Shared Elastic helper not found at '$sharedHelpersPath'."
}
. $sharedHelpersPath

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

$headers = @{}
if (-not [string]::IsNullOrWhiteSpace($ElasticApiKey)) {
    $headers['Authorization'] = "ApiKey $ElasticApiKey"
} elseif ($ElasticApiKeyPath -and (Test-Path -Path $ElasticApiKeyPath)) {
    $apiKeyFromFile = (Get-Content -Path $ElasticApiKeyPath -Raw).Trim()
    if (-not [string]::IsNullOrWhiteSpace($apiKeyFromFile)) {
        $headers['Authorization'] = "ApiKey $apiKeyFromFile"
    }
}

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

Write-Host 'Querying Elasticsearch...'
$hits = Invoke-ElasticScrollSearch -ElasticUrl $ElasticUrl -Body $body -Headers $headers -TimeoutSec 120 -OnPage $pageProgress
Write-Progress -Id 1 -Activity 'Loading Elasticsearch data' -Completed

if (-not $hits -or $hits.Count -eq 0) {
    Write-Host 'No Elasticsearch hits found for the given filter.'
    return
}

$table = [System.Data.DataTable]::new()
$null = $table.Columns.Add('MSGID', [string])
$null = $table.Columns.Add('ScenarioName', [string])
$null = $table.Columns.Add('ProcessName', [string])
$null = $table.Columns.Add('ProcesssStarted', [string])
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

    Write-Host "Writing $($table.Rows.Count) rows to [$($Database)].[dbo].[ElasticData] on $($Server)..."
    $bulkCopy.WriteToServer($table)
    Write-Host 'Finished writing rows to SQL Server.'
}
finally {
    if ($bulkCopy) { $bulkCopy.Close() }
    if ($connection.State -ne [System.Data.ConnectionState]::Closed) { $connection.Close() }
    $connection.Dispose()
}
