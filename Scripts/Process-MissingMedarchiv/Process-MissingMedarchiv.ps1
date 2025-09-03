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
    script loads `DatabaseMappings.csv` from the script folder.

.PARAMETER StartDate
    The inclusive start date used to filter PROCESSINGTIME (DB) and the time field in Elasticsearch.
    If omitted, defaults to the current day start (00:00:00) and the script will
    automatically use the end of the same day (23:59:59.999) as EndDate.

.PARAMETER EndDate
    The optional inclusive end date used to filter PROCESSINGTIME (DB) and the time field in Elasticsearch.

.PARAMETER DatabaseServerConnection
    SQL Server host and port in the format 'host,port'. Defaults to
    'MedarchivSql.wienkav.at,1433'. Integrated security is used for authentication.

    The database to query is resolved from the mapping CSV using the provided Anstalt.

.PARAMETER Anstalt
    Identifier for the institution, or 'All' to process all entries
    from the mapping CSV. No default.

.PARAMETER ElasticUrl
    Full Elasticsearch _search URL (including index pattern and query params).
    Defaults to 'https://es-obs.apps.zeus.wien.at/logs-orchestra.journals*/_search?batched_reduce_size=64&ccs_minimize_roundtrips=true&ignore_unavailable=true&preference=1722936418923'.

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

.PARAMETER IncludeElastic
    When specified, also performs the Elasticsearch query and includes its
    min/max/count in the result table. Otherwise only DB results are shown.

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
    [string]$DatabaseServerConnection = 'MedarchivSql.wienkav.at,1433',

    [Parameter(Mandatory=$true)]
    [string]$Anstalt,

    [Parameter(Mandatory=$false)]
    [string]$ElasticUrl = 'https://es-obs.apps.zeus.wien.at/logs-orchestra.journals*/_search?batched_reduce_size=64&ccs_minimize_roundtrips=true&ignore_unavailable=true&preference=1722936418923',

    [Parameter(Mandatory=$false)]
    [string]$MappingCsvPath = (Join-Path -Path $PSScriptRoot -ChildPath 'DatabaseMappings.csv'),

    [Parameter(Mandatory=$false)]
    [string]$ElasticTimeField = '@timestamp'
,

    [Parameter(Mandatory=$false)]
    [string]$ElasticApiKey,

    [Parameter(Mandatory=$false)]
    [string]$ElasticApiKeyPath
,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeElastic
)

# Determine effective StartDate/EndDate defaults for whole current day if omitted
$includeEndDate = $PSBoundParameters.ContainsKey('EndDate')
if (-not $PSBoundParameters.ContainsKey('StartDate')) {
    $StartDate = [datetime]::Today
    if (-not $includeEndDate) {
        $EndDate = $StartDate.Date.AddDays(1).AddMilliseconds(-1)
        $includeEndDate = $true
    }
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
    } elseif ($PSBoundParameters.ContainsKey('ElasticApiKeyPath') -and $ElasticApiKeyPath) {
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

foreach ($map in $targetMappings) {
    $anst = $map.Anstalt
    $dbName = $map.DatabaseName
    $elasticName = $map.ElasticName

    # Prepare connection string using integrated security per database
    $connectionString = "Server=$DatabaseServerConnection;Database=$dbName;Integrated Security=True;TrustServerCertificate=True;"

    $dbMin = $null; $dbMax = $null; $dbCount = $null
    try {
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
    }
    catch {
        Write-Warning "[$anst/$dbName] Failed to query database: $_"
    }

    $esMin = $null; $esMax = $null; $esCount = $null
    if ($IncludeElastic -and $apiKey) {
        try {
            # Build Elasticsearch query body per anstalt/database
            $filters = @()
            $filters += @{ term = @{ 'BK.SUBFL_sourcedb.keyword' = $elasticName } }

            $range = @{ gte = $StartDate.ToString('o') }
            if ($includeEndDate) { $range.lte = $EndDate.ToString('o') }
            $filters += @{ range = @{ $ElasticTimeField = $range } }

            $esBody = @{ 
                size = 0
                query = @{ bool = @{ filter = $filters } }
                aggs = @{ 
                    min_id = @{ min = @{ field = 'BK.SUBFL_sourceid' } }
                    max_id = @{ max = @{ field = 'BK.SUBFL_sourceid' } }
                    count_id = @{ value_count = @{ field = 'BK.SUBFL_sourceid' } }
                }
            } | ConvertTo-Json -Depth 8

            $esResponse = Invoke-RestMethod -Method Post -Uri $ElasticUrl -Headers $headers -Body $esBody -TimeoutSec 120

            if ($esResponse.aggregations) {
                $esMin = $esResponse.aggregations.min_id.value
                $esMax = $esResponse.aggregations.max_id.value
                $esCount = $esResponse.aggregations.count_id.value
            } elseif ($esResponse.hits) {
                $esCount = $esResponse.hits.total.value
            }
        }
        catch {
            Write-Warning "[$anst/$elasticName] Elasticsearch query failed: $_"
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
}

if ($results.Count -gt 0) {
    $results | Format-Table -AutoSize
} else {
    Write-Warning 'No results to display.'
}
