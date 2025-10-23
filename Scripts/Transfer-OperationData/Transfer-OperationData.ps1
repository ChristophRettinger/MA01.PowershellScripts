<#
.SYNOPSIS
  Transfers operation data from BiztalkApplicationData to OrchestraOperationData in controlled batches.

.DESCRIPTION
  Reads rows from dbo.DataStore in the BiztalkApplicationData database, starting after the last processed
  DataStoreId recorded in the configuration file. The script sends each row to the OrchestraOperationData
  database by executing dbo.StoreOperationData_v1. Processing occurs in batches of up to 100 records that
  are written within a single transaction; after each batch commits, the configuration file is updated once
  with the last processed DataStoreId. Batching continues until the requested maximum number of rows is
  reached, pausing between batches to control load. A progress bar reflects overall advancement.

.PARAMETER SourceServer
  The SQL Server instance hosting the BiztalkApplicationData database. Accepts the same format as the
  Server portion of a typical connection string (e.g. server name, server\\instance, or hostname:port).

.PARAMETER TargetServer
  The SQL Server instance hosting the OrchestraOperationData database.

.PARAMETER ConfigFile
  Path to the JSON file used to store the last processed DataStoreId. The file is created if it does not exist.

.PARAMETER MaxRecords
  Maximum number of records to transfer in this run. Processing stops early if the source does not contain
  enough new records.

.PARAMETER DelayBetweenBatches
  Number of seconds to wait between batches. Defaults to one second.

.EXAMPLE
  .\Transfer-OperationData.ps1 -SourceServer "sql-biztalk" -TargetServer "sql-orchestra" \
      -ConfigFile "C:\\Ops\\TransferState.json" -MaxRecords 1000 -DelayBetweenBatches 2

.NOTES
  The configuration file stores JSON in the format: { "LastDataStoreId": <number> }.
  Integrated security is used for both SQL Server connections.
#>
param(
    [Parameter(Mandatory = $true)]
    [string] $SourceServer,

    [Parameter(Mandatory = $true)]
    [string] $TargetServer,

    [Parameter(Mandatory = $true)]
    [string] $ConfigFile,

    [Parameter(Mandatory = $true)]
    [int] $MaxRecords,

    [Parameter(Mandatory = $false)]
    [int] $DelayBetweenBatches = 1
)

if ($MaxRecords -le 0) {
    Write-Error "MaxRecords must be greater than zero."
    return
}

Add-Type -AssemblyName System.Data

$batchSize = 100
$activityName = 'Transferring operation data'

function Get-LastProcessedDataStoreId {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        return $null
    }

    try {
        $raw = Get-Content -Path $Path -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }

        $config = $raw | ConvertFrom-Json
        if ($config -and ($config.PSObject.Properties.Name -contains 'LastDataStoreId')) {
            return [long]$config.LastDataStoreId
        }
    }
    catch {
        Write-Warning "Unable to read configuration from '$Path'. Starting from the beginning. $_"
    }

    return $null
}

function Save-LastProcessedDataStoreId {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [long] $DataStoreId
    )

    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path -Path $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $configObject = [pscustomobject]@{ LastDataStoreId = $DataStoreId }
    $json = $configObject | ConvertTo-Json -Depth 2

    try {
        Set-Content -Path $Path -Value $json -Encoding UTF8
    }
    catch {
        throw "Failed to persist last DataStoreId to '$Path'. $_"
    }
}

$lastProcessedId = Get-LastProcessedDataStoreId -Path $ConfigFile
if ($null -eq $lastProcessedId) {
    $lastProcessedId = 0
}

$sourceConnectionString = "Server=$SourceServer;Database=BiztalkApplicationData;Integrated Security=SSPI;TrustServerCertificate=True;"
$targetConnectionString = "Server=$TargetServer;Database=OrchestraOperationData;Integrated Security=SSPI;TrustServerCertificate=True;"

$processedCount = 0

$sourceConnection = $null
$targetConnection = $null
$storeCommand = $null

try {
    $sourceConnection = [System.Data.SqlClient.SqlConnection]::new($sourceConnectionString)
    $sourceConnection.Open()

    $targetConnection = [System.Data.SqlClient.SqlConnection]::new($targetConnectionString)
    $targetConnection.Open()

    $storeCommand = $targetConnection.CreateCommand()
    $storeCommand.CommandType = [System.Data.CommandType]::StoredProcedure
    $storeCommand.CommandText = 'dbo.StoreOperationData_v1'

    $null = $storeCommand.Parameters.Add('@ProcessKeyType', [System.Data.SqlDbType]::NVarChar, 50)
    $null = $storeCommand.Parameters.Add('@ProcessKey', [System.Data.SqlDbType]::NVarChar, 255)
    $null = $storeCommand.Parameters.Add('@Name', [System.Data.SqlDbType]::NVarChar, 50)
    $null = $storeCommand.Parameters.Add('@Data', [System.Data.SqlDbType]::NVarChar, 255)
    $null = $storeCommand.Parameters.Add('@Msg', [System.Data.SqlDbType]::NVarChar, -1)

    $storeCommand.Parameters['@ProcessKeyType'].Value = 'AF-ZPS/BMI'
    $storeCommand.Parameters['@Name'].Value = 'EntityID'
    $storeCommand.Parameters['@Msg'].Value = [DBNull]::Value

    while ($processedCount -lt $MaxRecords) {
        $remaining = $MaxRecords - $processedCount
        $currentBatchSize = [Math]::Min($batchSize, $remaining)
        $batchStartLastProcessedId = $lastProcessedId
        $processedInBatch = 0
        $batchRows = @()

        $sourceCommand = $sourceConnection.CreateCommand()
        try {
            $sourceCommand.CommandText = @"
SELECT TOP (@TakeCount) DataStoreId, ProcessKeyType, ProcessKey, Data1
FROM dbo.DataStore
WHERE DataStoreId > @LastId
ORDER BY DataStoreId ASC;
"@

            $null = $sourceCommand.Parameters.Add('@TakeCount', [System.Data.SqlDbType]::Int)
            $null = $sourceCommand.Parameters.Add('@LastId', [System.Data.SqlDbType]::BigInt)

            $sourceCommand.Parameters['@TakeCount'].Value = $currentBatchSize
            $sourceCommand.Parameters['@LastId'].Value = [long]$lastProcessedId

            $reader = $sourceCommand.ExecuteReader()
            try {
                while ($reader.Read()) {
                    $batchRows += [pscustomobject]@{
                        DataStoreId = [long]$reader['DataStoreId']
                        ProcessKey  = [string]$reader['ProcessKey']
                        Data1       = $reader['Data1']
                    }
                }
            }
            finally {
                if ($reader) { $reader.Close() }
            }
        }
        finally {
            if ($sourceCommand) { $sourceCommand.Dispose() }
        }

        if ($batchRows.Count -eq 0) {
            break
        }

        $transaction = $null
        $transactionCommitted = $false

        try {
            $transaction = $targetConnection.BeginTransaction()
            $storeCommand.Transaction = $transaction

            foreach ($row in $batchRows) {
                $storeCommand.Parameters['@ProcessKey'].Value = if ($row.ProcessKey) { $row.ProcessKey } else { [DBNull]::Value }
                $storeCommand.Parameters['@Data'].Value = if ($null -ne $row.Data1 -and $row.Data1 -ne '') { [string]$row.Data1 } else { [DBNull]::Value }

                $storeCommand.ExecuteNonQuery() | Out-Null

                $lastProcessedId = [long]$row.DataStoreId
                $processedCount++
                $processedInBatch++

                $percentComplete = if ($MaxRecords -gt 0) { [int](($processedCount / $MaxRecords) * 100) } else { 0 }
                $status = "Processed $processedCount of $MaxRecords (DataStoreId $lastProcessedId)"
                Write-Progress -Activity $activityName -Status $status -PercentComplete $percentComplete

                if ($processedCount -ge $MaxRecords) {
                    break
                }
            }

            $transaction.Commit()
            $transactionCommitted = $true

            if ($processedInBatch -gt 0) {
                Save-LastProcessedDataStoreId -Path $ConfigFile -DataStoreId $lastProcessedId
            }
        }
        catch {
            $errorRecord = $_

            if (-not $transactionCommitted) {
                $lastProcessedId = $batchStartLastProcessedId

                try {
                    if ($transaction) {
                        $transaction.Rollback()
                    }
                }
                catch {
                    Write-Warning "Failed to roll back transaction: $_"
                }
            }

            throw $errorRecord
        }
        finally {
            $storeCommand.Transaction = $null

            if ($transaction) {
                $transaction.Dispose()
            }
        }

        if ($processedCount -ge $MaxRecords) {
            break
        }

        Start-Sleep -Seconds $DelayBetweenBatches
    }
}
finally {
    Write-Progress -Activity $activityName -Completed

    if ($storeCommand) { $storeCommand.Dispose() }
    if ($sourceConnection) { $sourceConnection.Dispose() }
    if ($targetConnection) { $targetConnection.Dispose() }
}

Write-Host "Transferred $processedCount record(s). Last DataStoreId processed: $lastProcessedId."
