<#
.SYNOPSIS
    Compare ADM changelog entries with Elasticsearch to identify missing records.

.DESCRIPTION
    Queries the orch.CHANGE_LOG_TAB_SAV table in the ADM database for the minimum
    and maximum CL_ID values plus the total count within a specified STO_STAMP
    range. Elasticsearch is queried for the same ID range using
    BK.SUBFL_sourceid filtered by AdmRecord/Input/production plus an expanded
    time window controlled by IncreaseElasticDateRange. Missing IDs present in
    the database but absent from Elasticsearch are written to a file in the
    specified OutputDirectory.

.PARAMETER StartDate
    Inclusive start date used to filter STO_STAMP (DB) and the time field in Elasticsearch.
    If omitted, defaults to the current day start (00:00:00). If neither EndDate
    nor Timespan is supplied, EndDate defaults to StartDate plus 15 minutes.

.PARAMETER EndDate
    Optional inclusive end date used to filter STO_STAMP (DB) and the time field in Elasticsearch.

.PARAMETER Timespan
    Optional duration used to derive EndDate from StartDate. Accepts either a
    TimeSpan value (for example `00:30:00`) or a numeric value interpreted as
    minutes. Cannot be used together with EndDate.

.PARAMETER DatabaseServerConnection
    SQL Server host and port in the format 'host,port'. Defaults to
    ServerConfig.psd1 (SqlServer.Adm.Connection). Integrated security is used for authentication.
    The database is fixed to ADM.

.PARAMETER ElasticUrl
    Full Elasticsearch _search URL (including index pattern and query params).
    Defaults to ServerConfig.psd1 (Elasticsearch.OrchestraSearchUrl).

.PARAMETER ElasticTimeField
    Name of the time field in Elasticsearch to filter on. Defaults to '@timestamp'.

.PARAMETER ResetCredentials
    Discard the saved Elasticsearch credential and prompt for a new API key.

.PARAMETER IncreaseElasticDateRange
    Number of hours to extend the Elasticsearch time range beyond the DB range.
    Subtracts this from StartDate and adds to EndDate for Elasticsearch only. Defaults to 4.

.PARAMETER OutputDirectory
    Directory where missing-ID files are written when DB and ES counts differ.
    Defaults to '<script folder>/Output'.

.EXAMPLE
    ./Process-MissingADM.ps1 -StartDate '2025-09-03'

    Runs the query for records processed after 3 September 2025 and outputs the
    min, max, and count of CL_ID values from both SQL and Elasticsearch, writing
    any missing IDs to the Output directory.
#>

param(
    [Parameter(Mandatory=$false)]
    [datetime]$StartDate,

    [Parameter(Mandatory=$false)]
    [datetime]$EndDate,

    [Parameter(Mandatory=$false)]
    [object]$Timespan,

    [Parameter(Mandatory=$false)]
    [string]$DatabaseServerConnection = '',

    [Parameter(Mandatory=$false)]
    [string]$ElasticUrl = '',

    [Parameter(Mandatory=$false)]
    [string]$ElasticTimeField = '@timestamp',

    [Parameter(Mandatory=$false)]
    [switch]$ResetCredentials,

    [Parameter(Mandatory=$false)]
    [int]$IncreaseElasticDateRange = 4,

    [Parameter(Mandatory=$false)]
    [string]$OutputDirectory = (Join-Path -Path $PSScriptRoot -ChildPath 'Output')
)

$sharedHelpersDirectory = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Common'
$sharedHelpersPath = Join-Path -Path $sharedHelpersDirectory -ChildPath 'ElasticSearchHelpers.ps1'
if (-not (Test-Path -Path $sharedHelpersPath)) {
    throw "Shared Elastic helper not found at '$sharedHelpersPath'."
}
. $sharedHelpersPath
. (Join-Path $sharedHelpersDirectory 'ServerConfig.ps1')

# Determine effective StartDate/EndDate defaults
$includeEndDate = $PSBoundParameters.ContainsKey('EndDate')
if ($includeEndDate -and $PSBoundParameters.ContainsKey('Timespan')) {
    throw 'Specify either EndDate or Timespan, not both.'
}

if (-not $PSBoundParameters.ContainsKey('StartDate')) {
    $StartDate = [datetime]::Today
}

if (-not $includeEndDate) {
    $effectiveTimespan = Resolve-EffectiveTimespan -Value $Timespan
    $EndDate = $StartDate.Add($effectiveTimespan)
    $includeEndDate = $true
}

# Ensure output directory exists
try {
    if (-not (Test-Path -Path $OutputDirectory)) {
        $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    }
}
catch {
    Write-Warning "Failed to ensure output directory '$OutputDirectory': $_"
}

$_cfg = Get-ServerConfig
if ([string]::IsNullOrWhiteSpace($DatabaseServerConnection)) {
    $DatabaseServerConnection = $_cfg.SqlServer.Adm.Connection
}
if ([string]::IsNullOrWhiteSpace($ElasticUrl)) {
    $ElasticUrl = $_cfg.Elasticsearch.OrchestraSearchUrl
}

$credPath = Join-Path -Path $PSScriptRoot -ChildPath 'elastic.credentials.clixml'
$elasticCred = Resolve-ElasticCredential -CredentialPath $credPath -Reset:$ResetCredentials
$headers = @{
    'Content-Type' = 'application/json'
    'Authorization' = "ApiKey $($elasticCred.GetNetworkCredential().Password)"
}

$databaseName = 'ADM'
$connectionString = "Server=$DatabaseServerConnection;Database=$databaseName;Integrated Security=True;TrustServerCertificate=True;"

# Build SQL query with parameter placeholders
$query = "SELECT MIN(CL_ID) AS CL_ID_Min, MAX(CL_ID) AS CL_ID_Max, COUNT(*) AS RecordCount FROM orch.CHANGE_LOG_TAB_SAV WHERE STO_STAMP >= @StartDate"
if ($includeEndDate) {
    $query += " AND STO_STAMP <= @EndDate"
}

$dbMin = $null
$dbMax = $null
$dbCount = $null

try {
    $connection = [System.Data.SqlClient.SqlConnection]::new($connectionString)
    $command = $connection.CreateCommand()
    $command.CommandText = $query
    $null = $command.Parameters.Add('@StartDate', [System.Data.SqlDbType]::DateTime)
    $command.Parameters['@StartDate'].Value = $StartDate
    if ($includeEndDate) {
        $null = $command.Parameters.Add('@EndDate', [System.Data.SqlDbType]::DateTime)
        $command.Parameters['@EndDate'].Value = $EndDate
    }

    $connection.Open()
    $reader = $command.ExecuteReader()
    if ($reader.Read()) {
        $dbMin = $reader['CL_ID_Min']
        $dbMax = $reader['CL_ID_Max']
        $dbCount = $reader['RecordCount']
    }
    $reader.Close()
    $connection.Close()
}
catch {
    throw "[$databaseName] Failed to query database: $_"
}

$esMin = $null
$esMax = $null
$esCount = $null
$esDistinct = $null
$esQuerySucceeded = $false

if ($dbCount -and $dbCount -gt 0) {
    try {
        # Build Elasticsearch query body - fetch documents via scroll
        $filters = @()
        $filters += @{ term = @{ 'BK.SUBFL_messagetype' = 'AdmRecord' } }
        $filters += @{ term = @{ 'BK.SUBFL_stage' = 'Input' } }
        $filters += @{ term = @{ 'Environment' = 'production' } }
        $filters += @{ range = @{ 'BK.SUBFL_sourceid' = @{ gte = $dbMin; lte = $dbMax } } }

        # Expand ES time range by IncreaseElasticDateRange hours on both sides
        $esStart = $StartDate.AddHours(-1 * [double]$IncreaseElasticDateRange)
        $range = @{ gte = $esStart.ToString('o') }
        if ($includeEndDate) {
            $esEnd = $EndDate.AddHours([double]$IncreaseElasticDateRange)
            $range.lte = $esEnd.ToString('o')
        }
        $filters += @{ range = @{ $ElasticTimeField = $range } }

        $esBody = @{
            size = 1000
            query = @{ bool = @{ filter = $filters } }
            _source = @('BK.SUBFL_sourceid')
        } | ConvertTo-Json -Depth 6

        $pageProgress = {
            param($PageNumber, $PageHits, $TotalHits)
            $statusText = "ES scrolling (page $PageNumber) collected $TotalHits"
            Write-Progress -Id 2 -Activity 'Elasticsearch' -Status $statusText -PercentComplete (50 + [int]([Math]::Min(45, $PageNumber * 5)))
        }

        $rawHits = Invoke-ElasticScrollSearch -ElasticUrl $ElasticUrl -Headers $headers -Body $esBody -TimeoutSec 120 -OnPage $pageProgress

        $ids = [System.Collections.Generic.List[string]]::new()
        foreach ($hit in $rawHits) {
            $val = $hit._source.BK.SUBFL_sourceid
            if ($null -ne $val -and "$val" -ne '') {
                [void]$ids.Add([string]$val)
            }
        }

        # Distinct IDs and compute min/max/count
        $distinct = $ids | Where-Object { $_ } | Select-Object -Unique
        $esDistinct = $distinct
        $esCount = ($distinct | Measure-Object).Count

        # Try numeric min/max, fallback to string ordering
        $nums = @()
        foreach ($s in $distinct) {
            $n = 0L
            if ([long]::TryParse($s, [ref]$n)) { $nums += $n }
        }
        if ($nums.Count -gt 0) {
            $esMin = ($nums | Measure-Object -Minimum).Minimum
            $esMax = ($nums | Measure-Object -Maximum).Maximum
        }
        elseif ($distinct.Count -gt 0) {
            $sorted = $distinct | Sort-Object
            $esMin = $sorted[0]
            $esMax = $sorted[-1]
        }

        $esQuerySucceeded = $true
        Write-Progress -Id 2 -Activity 'Elasticsearch' -Status 'ES aggregation done' -PercentComplete 100 -Completed
    }
    catch {
        throw "[$databaseName] Elasticsearch query failed: $($_.Exception.Message)"
    }
}

# If counts differ, compute and write missing IDs present in DB but not in ES
if ($esQuerySucceeded -and $dbCount -ne $esCount) {
    try {
        $idsQuery = "SELECT DISTINCT CL_ID FROM orch.CHANGE_LOG_TAB_SAV WHERE STO_STAMP >= @StartDate"
        if ($includeEndDate) { $idsQuery += " AND STO_STAMP <= @EndDate" }

        $dbIds = [System.Collections.Generic.List[string]]::new()
        $connection2 = [System.Data.SqlClient.SqlConnection]::new($connectionString)
        $command2 = $connection2.CreateCommand()
        $command2.CommandText = $idsQuery
        $null = $command2.Parameters.Add('@StartDate', [System.Data.SqlDbType]::DateTime)
        $command2.Parameters['@StartDate'].Value = $StartDate
        if ($includeEndDate) {
            $null = $command2.Parameters.Add('@EndDate', [System.Data.SqlDbType]::DateTime)
            $command2.Parameters['@EndDate'].Value = $EndDate
        }
        $connection2.Open()
        $reader2 = $command2.ExecuteReader()
        while ($reader2.Read()) {
            $v = $reader2[0]
            if ($null -ne $v) { [void]$dbIds.Add([string]$v) }
        }
        $reader2.Close()
        $connection2.Close()

        # Build ES set
        $esSet = [System.Collections.Generic.HashSet[string]]::new()
        if ($esDistinct) { foreach ($e in $esDistinct) { [void]$esSet.Add([string]$e) } }

        # Compute missing present in DB but not ES
        $missing = [System.Collections.Generic.List[string]]::new()
        foreach ($d in $dbIds) {
            if (-not $esSet.Contains([string]$d)) { [void]$missing.Add([string]$d) }
        }

        # Write file if any missing
        if ($missing.Count -gt 0) {
            $datePartStart = $StartDate.ToString('yyyyMMddTHHmmss')
            $datePartEnd = if ($includeEndDate) { $EndDate.ToString('yyyyMMddTHHmmss') } else { 'open' }
            $fileName = "MissingIds_ADM_${datePartStart}_${datePartEnd}.txt"
            $filePath = Join-Path -Path $OutputDirectory -ChildPath $fileName
            $missing | Sort-Object {[long]$_} -ErrorAction SilentlyContinue | Set-Content -Path $filePath -Encoding UTF8
            Write-Host "[ADM] Wrote missing IDs to: $($filePath)" -ForegroundColor Green
        }
        else {
            Write-Host '[ADM] No missing IDs to write.' -ForegroundColor Yellow
        }
    }
    catch {
        throw "[$databaseName] Failed computing/writing missing IDs: $_"
    }
}

$result = [pscustomobject]@{
    Database = $databaseName
    DbMin    = $dbMin
    DbMax    = $dbMax
    DbCount  = $dbCount
    EsMin    = $esMin
    EsMax    = $esMax
    EsCount  = $esCount
}

$result | Format-Table -AutoSize
