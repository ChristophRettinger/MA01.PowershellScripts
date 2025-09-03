<#
.SYNOPSIS
    Compare database changelog entries with Elasticsearch to identify missing records.

.DESCRIPTION
    Queries the CHANGELOG_HISTORY table for the minimum and maximum CL_ID_BIG values
    and the total count of records within a specified processing time range. The
    results are displayed alongside the Anstalt identifier. Future extensions may
    integrate an Elasticsearch lookup to find missing records.

.PARAMETER StartDate
    The inclusive start date used to filter PROCESSINGTIME.

.PARAMETER EndDate
    The optional inclusive end date used to filter PROCESSINGTIME.

.PARAMETER DatabaseServerConnection
    SQL Server host and port in the format 'host,port'. Defaults to
    'MedarchivSql.wienkav.at,1433'. Integrated security is used for authentication.

.PARAMETER DatabaseName
    The name of the database to query. Defaults to 'MA_INDEX_KAR'.

.PARAMETER Anstalt
    Identifier for the institution. Defaults to 9173.

.EXAMPLE
    ./Process-MissingMedarchiv.ps1 -StartDate '2025-09-03'

    Runs the query for records processed after 3 September 2025 and outputs the
    min, max, and count of CL_ID_BIG values with the Anstalt identifier.
#>

param(
    [Parameter(Mandatory=$true)]
    [datetime]$StartDate,

    [Parameter(Mandatory=$false)]
    [datetime]$EndDate,

    [Parameter(Mandatory=$false)]
    [string]$DatabaseServerConnection = 'MedarchivSql.wienkav.at,1433',

    [Parameter(Mandatory=$false)]
    [string]$DatabaseName = 'MA_INDEX_KAR',

    [Parameter(Mandatory=$false)]
    [int]$Anstalt = 9173
)

# Build SQL query with parameter placeholders
$query = "SELECT MIN(CL_ID_BIG) AS CL_ID_BIG_Min, MAX(CL_ID_BIG) AS CL_ID_BIG_Max, COUNT(*) AS RecordCount FROM CHANGELOG_HISTORY WHERE PROCESSINGTIME >= @StartDate"
if ($PSBoundParameters.ContainsKey('EndDate')) {
    $query += " AND PROCESSINGTIME <= @EndDate"
}

# Prepare connection string using integrated security
$connectionString = "Server=$DatabaseServerConnection;Database=$DatabaseName;Integrated Security=True;TrustServerCertificate=True;"

try {
    $connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
    $command = $connection.CreateCommand()
    $command.CommandText = $query
    $null = $command.Parameters.Add('@StartDate', [System.Data.SqlDbType]::DateTime)
    $command.Parameters['@StartDate'].Value = $StartDate
    if ($PSBoundParameters.ContainsKey('EndDate')) {
        $null = $command.Parameters.Add('@EndDate', [System.Data.SqlDbType]::DateTime)
        $command.Parameters['@EndDate'].Value = $EndDate
    }

    $connection.Open()
    $reader = $command.ExecuteReader()
    if ($reader.Read()) {
        $min = $reader['CL_ID_BIG_Min']
        $max = $reader['CL_ID_BIG_Max']
        $count = $reader['RecordCount']

        # Display the output in the requested format
        Write-Output "Anstalt Min Max Count"
        Write-Output "$Anstalt $min $max $count"
    } else {
        Write-Warning 'Query returned no rows.'
    }
    $reader.Close()
    $connection.Close()
}
catch {
    Write-Error "Failed to query database: $_"
}

# Placeholder for future Elasticsearch comparison logic
# Write-Verbose 'Elasticsearch comparison not yet implemented.'
