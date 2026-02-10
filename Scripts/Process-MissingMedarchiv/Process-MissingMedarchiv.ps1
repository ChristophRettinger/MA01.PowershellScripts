<#
.SYNOPSIS
    Compare database changelog entries with Elasticsearch to identify missing records.

.DESCRIPTION
    Queries the CHANGELOG_HISTORY table for the minimum and maximum CL_ID_BIG values
    and the total count of records within a specified processing time range. In
    addition, queries Elasticsearch for the same metrics using BK.SUBFL_sourceid
    (CL_ID_BIG) filtered by BK.SUBFL_sourcedb (mapped from the database name).
    
    The mapping between on-prem database names and Elasticsearch index names is
    provided via a CSV (columns: Anstalt,DatabaseName,ElasticName). By default, the
    script loads `DatabaseMappings.csv` from the script folder. Elasticsearch paging
    reuses the Invoke-ElasticScrollSearch helper from Scripts/Common/ElasticSearchHelpers.ps1
    to keep scroll handling consistent between scripts.

.PARAMETER StartDate
    The inclusive start date used to filter PROCESSINGTIME (DB) and the time field in Elasticsearch.
    If omitted, defaults to the current day start (00:00:00). If neither EndDate
    nor Timespan is supplied, EndDate defaults to StartDate plus 15 minutes.

.PARAMETER EndDate
    The optional inclusive end date used to filter PROCESSINGTIME (DB) and the time field in Elasticsearch.

.PARAMETER Timespan
    Optional duration used to derive EndDate from StartDate. Accepts either a
    TimeSpan value (for example `00:30:00`) or a numeric value interpreted as
    minutes. Cannot be used together with EndDate.

.PARAMETER DatabaseServerConnection
    SQL Server host and port in the format 'host,port'. Defaults to
    'MedarchivSql.wienkav.at,1433'. Integrated security is used for authentication.

    The database to query is resolved from the mapping CSV using the provided Anstalt.

.PARAMETER Anstalt
    Identifier for the institution, or 'All' to process all entries
    from the mapping CSV. No default.

.PARAMETER ElasticUrl
    Full Elasticsearch _search URL (including index pattern and query params).
    Defaults to 'https://es-obs.apps.zeus.wien.at/logs-orchestra.journals*/_search'.

.PARAMETER MappingCsvPath
    Path to the CSV containing database-to-elastic name mappings. Defaults to
    '<script folder>/DatabaseMappings.csv'.

.PARAMETER ElasticTimeField
    Name of the time field in Elasticsearch to filter on. Defaults to '@timestamp'.

.PARAMETER ElasticApiKey
    Elasticsearch API key as a string. Sent as 'Authorization: ApiKey <key>'.
    If omitted and ElasticApiKeyPath is provided, the key is read from file.

.PARAMETER ElasticApiKeyPath
    Path to a file containing the Elasticsearch API key. Used if ElasticApiKey is not provided.
    Defaults to '.\elastic.key'.

.PARAMETER IncludeElastic
    When specified, also performs the Elasticsearch query and includes its
    min/max/count in the result table. Otherwise only DB results are shown.

.PARAMETER IncreaseElasticDateRange
    Number of hours to extend the Elasticsearch time range beyond the DB range.
    Subtracts this from StartDate and adds to EndDate for Elasticsearch only. Defaults to 4.

.PARAMETER OutputDirectory
    Directory where missing-ID files are written when DB and ES counts differ.
    Defaults to '<script folder>/Output'. One file per Anstalt.

.EXAMPLE
    ./Process-MissingMedarchiv.ps1 -StartDate '2025-09-03'

    Runs the query for records processed after 3 September 2025 and outputs the
    min, max, and count of CL_ID_BIG values with the Anstalt identifier from both
    SQL and Elasticsearch (if mapping and access are available).
#>

param(
    [Parameter(Mandatory=$false)]
    [datetime]$StartDate,

    [Parameter(Mandatory=$false)]
    [datetime]$EndDate,

    [Parameter(Mandatory=$false)]
    [object]$Timespan,

    [Parameter(Mandatory=$false)]
    [string]$DatabaseServerConnection = 'MedarchivSql.wienkav.at,1433',

    [Parameter(Mandatory=$false)]
    [string]$Anstalt = 'All',

    [Parameter(Mandatory=$false)]
    [string]$ElasticUrl = 'https://es-obs.apps.zeus.wien.at/logs-orchestra.journals*/_search',

    [Parameter(Mandatory=$false)]
    [string]$MappingCsvPath = (Join-Path -Path $PSScriptRoot -ChildPath 'DatabaseMappings.csv'),

    [Parameter(Mandatory=$false)]
    [string]$ElasticTimeField = '@timestamp',

    [Parameter(Mandatory=$false)]
    [string]$ElasticApiKey,

    [Parameter(Mandatory=$false)]
    [string]$ElasticApiKeyPath = (Join-Path -Path $PSScriptRoot -ChildPath 'elastic.key'),

    [Parameter(Mandatory=$false)]
    [int]$IncreaseElasticDateRange = 4,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeElastic = $true,

    [Parameter(Mandatory=$false)]
    [string]$OutputDirectory = (Join-Path -Path $PSScriptRoot -ChildPath 'Output')
)

$sharedHelpersDirectory = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Common'
$sharedHelpersPath = Join-Path -Path $sharedHelpersDirectory -ChildPath 'ElasticSearchHelpers.ps1'
if (-not (Test-Path -Path $sharedHelpersPath)) {
    throw "Shared Elastic helper not found at '$sharedHelpersPath'."
}
. $sharedHelpersPath

function Resolve-EffectiveTimespan {
    param(
        [object]$Value,
        [int]$DefaultMinutes = 15
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace("$Value")) {
        return [timespan]::FromMinutes($DefaultMinutes)
    }

    if ($Value -is [timespan]) { return $Value }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        return [timespan]::FromMinutes([double]$Value)
    }

    $minutes = 0.0
    $textValue = "$Value".Trim()
    if ([double]::TryParse($textValue, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$minutes)) {
        return [timespan]::FromMinutes($minutes)
    }

    $parsedTimeSpan = [timespan]::Zero
    if ([timespan]::TryParse($textValue, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedTimeSpan)) {
        return $parsedTimeSpan
    }

    throw "Invalid Timespan '$Value'. Provide a number (minutes) or a TimeSpan value."
}

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

# Load mappings
if (-not (Test-Path -Path $MappingCsvPath)) {
    Write-Error "Mapping CSV not found at '$MappingCsvPath'. Cannot resolve Anstalt mappings."
    return
}
$mappings = Import-Csv -Path $MappingCsvPath

# Select target mappings
if ($Anstalt -and $Anstalt.Trim().ToLower() -eq 'all') {
    $targetMappings = $mappings
} else {
    $targetMappings = $mappings | Where-Object { $_.Anstalt -eq "$Anstalt" }
    if (-not $targetMappings) {
        Write-Error "No mapping found for Anstalt '$Anstalt' in '$MappingCsvPath'."
        return
    }
}

# Build SQL query with parameter placeholders
$query = "SELECT MIN(CL_ID_BIG) AS CL_ID_BIG_Min, MAX(CL_ID_BIG) AS CL_ID_BIG_Max, COUNT(*) AS RecordCount FROM CHANGELOG_HISTORY WHERE PROCESSINGTIME >= @StartDate"
if ($includeEndDate) {
    $query += " AND PROCESSINGTIME <= @EndDate"
}

# Resolve ES API key once if IncludeElastic
$apiKey = $null
$headers = @{ 'Content-Type' = 'application/json' }
if ($IncludeElastic) {
    if ($PSBoundParameters.ContainsKey('ElasticApiKey') -and $ElasticApiKey) {
        $apiKey = $ElasticApiKey.Trim()
    } elseif ($ElasticApiKeyPath) {
        if (-not (Test-Path -Path $ElasticApiKeyPath)) {
            Write-Warning "ElasticApiKeyPath '$ElasticApiKeyPath' not found. Elasticsearch results will be omitted."
        } else {
            $apiKey = (Get-Content -Path $ElasticApiKeyPath -Raw).Trim()
        }
    }
    if ($apiKey) {
        $headers['Authorization'] = "ApiKey $apiKey"
    } else {
        Write-Warning 'No Elasticsearch API key provided. Provide -ElasticApiKey or -ElasticApiKeyPath to enable ES query.'
    }
}

# Collect results for all Anstalten
$results = @()

# Initialize progress tracking for overall run
$overallActivity = 'Processing Anstalten'
$idx = 0
$total = ($targetMappings | Measure-Object).Count
Write-Progress -Id 1 -Activity $overallActivity -Status 'Starting…' -PercentComplete 0

# Ensure output directory exists (for potential missing-IDs files)
try { if (-not (Test-Path -Path $OutputDirectory)) { $null = New-Item -ItemType Directory -Path $OutputDirectory -Force } } catch { Write-Warning "Failed to ensure output directory '$OutputDirectory': $_" }

foreach ($map in $targetMappings) {
    $idx++
    $anst = $map.Anstalt
    $dbName = $map.DatabaseName
    $elasticName = $map.ElasticName

    # Update overall progress for current item
    $overallPct = if ($total -gt 0) { [int]((($idx - 1) * 100) / $total) } else { 0 }
    Write-Progress -Id 1 -Activity $overallActivity -Status "Anstalt $anst ($idx/$total)" -PercentComplete $overallPct

    # Prepare connection string using integrated security per database
    $connectionString = "Server=$DatabaseServerConnection;Database=$dbName;Integrated Security=True;TrustServerCertificate=True;"

    $dbMin = $null; $dbMax = $null; $dbCount = $null
    try {
        Write-Progress -Id 2 -ParentId 1 -Activity "Anstalt $anst" -Status 'DB query' -PercentComplete 10
        $connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
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
            $dbMin = $reader['CL_ID_BIG_Min']
            $dbMax = $reader['CL_ID_BIG_Max']
            $dbCount = $reader['RecordCount']
        }
        $reader.Close()
        $connection.Close()
        Write-Progress -Id 2 -ParentId 1 -Activity "Anstalt $anst" -Status 'DB query done' -PercentComplete 40
    }
    catch {
        Write-Warning "[$anst/$dbName] Failed to query database: $_"
        Write-Progress -Id 2 -ParentId 1 -Activity "Anstalt $anst" -Status 'DB query failed' -PercentComplete 40
    }

    $esMin = $null; $esMax = $null; $esCount = $null
    $esDistinct = $null
    $esQuerySucceeded = $false
    if ($IncludeElastic -and $apiKey -and $dbCount -and $dbCount -gt 0) {
        try {
            Write-Progress -Id 2 -ParentId 1 -Activity "Anstalt $anst" -Status 'ES initial search' -PercentComplete 50
            # Build Elasticsearch query body per anstalt/database - fetch documents (no aggs)
            $filters = @()
            $filters += @{ term = @{ 'BK.SUBFL_sourcedb' = $elasticName } }
            $filters += @{ term = @{ 'ScenarioName' = 'ITI_SUBFL_MedArchiv_auslesen_4086' } }
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
                $pcInner = 60 + [int]([Math]::Min(35, $PageNumber * 5))
                $statusText = "ES scrolling (page $PageNumber) collected $TotalHits"
                Write-Progress -Id 2 -ParentId 1 -Activity "Anstalt $anst" -Status $statusText -PercentComplete $pcInner
            }

            $rawHits = Invoke-ElasticScrollSearch -ElasticUrl $ElasticUrl -Headers $headers -Body $esBody -TimeoutSec 120 -OnPage $pageProgress

            $ids = [System.Collections.Generic.List[string]]::new()
            foreach ($hit in $rawHits) {
                $val = $hit._source.BK.SUBFL_sourceid
                if ($null -ne $val -and "$val" -ne '') { [void]$ids.Add([string]$val) }
            }

            # Distinct IDs and compute min/max/count
            $distinct = $ids | Where-Object { $_ } | Select-Object -Unique
            $esDistinct = $distinct
            $esCount = ($distinct | Measure-Object).Count

            # Try numeric min/max, fallback to string ordering
            $nums = @()
            foreach ($s in $distinct) { $n = 0L; if ([long]::TryParse($s, [ref]$n)) { $nums += $n } }
            if ($nums.Count -gt 0) {
                $esMin = ($nums | Measure-Object -Minimum).Minimum
                $esMax = ($nums | Measure-Object -Maximum).Maximum
            } elseif ($distinct.Count -gt 0) {
                $sorted = $distinct | Sort-Object
                $esMin = $sorted[0]
                $esMax = $sorted[-1]
            }
            Write-Progress -Id 2 -ParentId 1 -Activity "Anstalt $anst" -Status 'ES aggregation done' -PercentComplete 95
            $esQuerySucceeded = $true
        }
        catch {
            Write-Error "[$anst/$elasticName] Elasticsearch query failed: $($_.Exception.Message)"
        }
    }

    # If counts differ, compute and write missing IDs present in DB but not in ES
    if ($IncludeElastic -and $apiKey -and $esQuerySucceeded -and $dbCount -ne $esCount) {
        try {
            Write-Progress -Id 2 -ParentId 1 -Activity "Anstalt $anst" -Status 'Computing missing IDs' -PercentComplete 96

            # Fetch distinct IDs from DB for the same time range
            $idsQuery = "SELECT DISTINCT CL_ID_BIG FROM CHANGELOG_HISTORY WHERE PROCESSINGTIME >= @StartDate"
            if ($includeEndDate) { $idsQuery += " AND PROCESSINGTIME <= @EndDate" }

            $dbIds = New-Object System.Collections.Generic.List[string]
            $connection2 = New-Object System.Data.SqlClient.SqlConnection $connectionString
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
            $reader2.Close(); $connection2.Close()

            # Build ES set
            $esSet = New-Object System.Collections.Generic.HashSet[string]
            if ($esDistinct) { foreach($e in $esDistinct){ [void]$esSet.Add([string]$e) } }

            # Compute missing present in DB but not ES
            $missing = New-Object System.Collections.Generic.List[string]
            foreach ($d in $dbIds) { if (-not $esSet.Contains([string]$d)) { [void]$missing.Add([string]$d) } }

            # Write file if any missing
            if ($missing.Count -gt 0) {
                $datePartStart = $StartDate.ToString('yyyyMMddTHHmmss')
                $datePartEnd = if ($includeEndDate) { $EndDate.ToString('yyyyMMddTHHmmss') } else { 'open' }
                $fileName = "MissingIds_${anst}_${dbName}_${datePartStart}_${datePartEnd}.txt"
                $filePath = Join-Path -Path $OutputDirectory -ChildPath $fileName
                $missing | Sort-Object {[long]$_} -ErrorAction SilentlyContinue | Set-Content -Path $filePath -Encoding UTF8
                Write-Host "[$anst/$dbName] Wrote missing IDs to: $filePath"
            } else {
                Write-Host "[$anst/$dbName] No missing IDs to write."
            }

            Write-Progress -Id 2 -ParentId 1 -Activity "Anstalt $anst" -Status 'Missing IDs written' -PercentComplete 98
        }
        catch {
            Write-Warning "[$anst/$dbName] Failed computing/writing missing IDs: $_"
        }
    }

    $results += [pscustomobject]@{
        Anstalt      = $anst
        DatabaseName = $dbName
        ElasticName  = $elasticName
        DbMin        = $dbMin
        DbMax        = $dbMax
        DbCount      = $dbCount
        EsMin        = $esMin
        EsMax        = $esMax
        EsCount      = $esCount
    }

    # Complete per-anstalt progress
    Write-Progress -Id 2 -ParentId 1 -Activity "Anstalt $anst" -Status 'Done' -PercentComplete 100 -Completed
}

if ($results.Count -gt 0) {
    $results | Format-Table -AutoSize
} else {
    Write-Warning 'No results to display.'
}

# Complete overall progress
Write-Progress -Id 1 -Activity $overallActivity -Status 'Completed' -PercentComplete 100 -Completed
