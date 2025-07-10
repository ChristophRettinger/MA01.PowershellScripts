<#
.SYNOPSIS
    Analyzes RAG usage metadata and outputs a combined JSON with statistics and field frequency counts.

.DESCRIPTION
    For each relevant field (KeyTopics, Category, UseCase, Intent, Domain, etc.), this script:
    - Normalizes and counts distinct values
    - Computes Min, Max, Average, and Median for numeric fields
    - Writes a unified JSON object to file

.PARAMETER InputFile
    JSON input file path.

.PARAMETER OutputFile
    Path to write the output JSON file.

.PARAMETER Limit
    Minimum frequency threshold for values to appear in output (default is 1).

.EXAMPLE
    .\Analyze-RAG-Metadata.ps1 -InputFile ".\rag_data.json" -OutputFile ".\analysis.json" -Limit 2
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$InputFile,

    [Parameter(Mandatory = $true)]
    [string]$OutputFile,

    [Parameter(Mandatory = $false)]
    [int]$Limit = 1
)

function Get-Median {
    param (
        [double[]]$values
    )
    $sorted = $values | Sort-Object
    $count = $sorted.Count
    if ($count -eq 0) { return $null }

    if ($count % 2 -eq 1) {
        return $sorted[ [int]($count / 2) ]
    } else {
        $mid1 = $sorted[($count / 2) - 1]
        $mid2 = $sorted[($count / 2)]
        return [Math]::Round((($mid1 + $mid2) / 2), 2)
    }
}

# Fields to count occurrences for
$fieldNames = @(
    'KeyTopics',
    'Category',
    'UseCase',
    'Intent',
    'Domain',
    'UserPersona',
    'ContainsSensitiveData',
    'ModelUsed'
)

# Numeric fields to summarize
$metricFields = @(
    'ConfidenceScore',
    'MessageCount',
    'TotalTokens',
    'ConversationDurationHours'
)

# Initialize counters
$fieldCounters = @{}
foreach ($field in $fieldNames) {
    $fieldCounters[$field] = @{}
}

# Read data
$data = Get-Content $InputFile -Raw | ConvertFrom-Json
$totalCount = $data.Count

# Collect numeric values
$metrics = @{}
foreach ($metric in $metricFields) {
    $metrics[$metric] = @()
}

# Analyze each record
foreach ($item in $data) {
    foreach ($field in $fieldNames) {
        $value = $item.$field
        if ($value) {
            $entries = $value -split ','
            foreach ($entry in $entries) {
                $norm = $entry.Trim().ToLower()
                if (-not [string]::IsNullOrWhiteSpace($norm)) {
                    if ($fieldCounters[$field].ContainsKey($norm)) {
                        $fieldCounters[$field][$norm]++
                    } else {
                        $fieldCounters[$field][$norm] = 1
                    }
                }
            }
        }
    }

    foreach ($metric in $metricFields) {
        if ($item.PSObject.Properties[$metric] -and ($item.$metric -match '^\d+(\.\d+)?$')) {
            $metrics[$metric] += [double]$item.$metric
        }
    }
}

# Create result structure
$result = @{}

# Add distinct value counts per field
$fieldResults = @{}
foreach ($field in $fieldNames) {
    $counts = $fieldCounters[$field].GetEnumerator() |
        Where-Object { $_.Value -ge $Limit } |
        Sort-Object -Property Value -Descending |
        ForEach-Object {
            [PSCustomObject]@{
                Value = $_.Key
                Count = $_.Value
            }
        }
    $fieldResults[$field] = $counts
}

# Add metric summaries
$statResults = @{}
foreach ($metric in $metricFields) {
    $values = $metrics[$metric]
    if ($values.Count -gt 0) {
        $statResults[$metric] = @{
            Min    = ($values | Measure-Object -Minimum).Minimum
            Max    = ($values | Measure-Object -Maximum).Maximum
            Avg    = [Math]::Round(($values | Measure-Object -Average).Average, 2)
            Median = Get-Median -values $values
        }
    }
}

# Combine into final output
$output = @{
    TotalCount   = $totalCount
    Statistics   = $statResults
    FieldCounts  = $fieldResults
}

# Write to file
$output | ConvertTo-Json -Depth 5 | Out-File -FilePath $OutputFile -Encoding UTF8

Write-Host "âœ… Analysis complete. Output written to '$OutputFile'."
