<#
.SYNOPSIS
    Evaluate errors for the KAVIDE ITI_SUBFL scenario via Elasticsearch.

.DESCRIPTION
    Queries Elasticsearch for error workflow entries of scenario
    ITI_SUBFL_KAVIDE_speichern_v01_3287 within a date range, environment, and
    optional instance. Unique case numbers (BK._CASENO) are determined from the
    error hits. For each case number the script reports the number of errors,
    details for the first occurrence (timestamp, BusinessCaseId, BK._STATUS_TEXT
    error text), and a parsed `ZugangVonKostenstelle` value extracted from
    MessageData1 (XML). A JSON-serialized list of all error occurrences is
    included so every error per case number is visible, and `ZugangVonKostenstelle`
    is evaluated for each error. The script also gathers workflow successes for
    the same case numbers and summarizes the number of successes grouped by
    BK.SUBFL_subid, BK.SUBFL_category, and BK.SUBFL_subcategory. Results are
    written to the console with colored sections showing the case number and the
    timestamp range (first to last error), followed by successes and individual
    error details, and exported to a CSV file in the specified OutputDirectory.

    An optional ignore list can be supplied via a text file containing one phrase
    per line. Any error whose text contains an ignore phrase is skipped and will
    not be reported or considered for success lookups.

.PARAMETER StartDate
    Inclusive start date for @timestamp filtering (local time). Defaults to the
    start of the current day if omitted. If EndDate is not supplied, it is set
    to the end of the StartDate day.

.PARAMETER EndDate
    Inclusive end date for @timestamp filtering (local time).

.PARAMETER Environment
    Environment value to match (production, staging, testing). Defaults to
    production.

.PARAMETER Instance
    Specific server instance name to filter (optional).

.PARAMETER ElasticUrl
    Full Elasticsearch _search URL. Defaults to the logs-orchestra.journals
    index pattern.

.PARAMETER ElasticApiKey
    Elasticsearch API key string. If omitted, ElasticApiKeyPath is used.

.PARAMETER ElasticApiKeyPath
    Path to a file containing the Elasticsearch API key.

.PARAMETER OutputDirectory
    Directory where the CSV summary is written. Defaults to a folder named
    Output beside this script.

.PARAMETER IgnoreListPath
    Path to a text file containing phrases (one per line) that, when found in the
    error text, cause the entry to be ignored.

.EXAMPLE
    ./Evaluate-AdmKavideErrors.ps1 -StartDate (Get-Date).AddDays(-1) `
        -Environment production -ElasticApiKeyPath ~/.eskey
#>
param(
    [Parameter(Mandatory=$false)]
    [datetime]$StartDate,

    [Parameter(Mandatory=$false)]
    [datetime]$EndDate,

    [Parameter(Mandatory=$false)]
    [ValidateSet('production','staging','testing')]
    [string]$Environment = 'production',

    [Parameter(Mandatory=$false)]
    [string]$Instance,

    [Parameter(Mandatory=$false)]
    [string]$ElasticUrl = 'https://es-obs.apps.zeus.wien.at/logs-orchestra.journals*/_search',

[Parameter(Mandatory=$false)]
[string]$ElasticApiKey,

[Parameter(Mandatory=$false)]
[string]$ElasticApiKeyPath,

[Parameter(Mandatory=$false)]
[string]$OutputDirectory = (Join-Path -Path $PSScriptRoot -ChildPath 'Output'),

[Parameter(Mandatory=$false)]
[string]$IgnoreListPath = (Join-Path -Path $PSScriptRoot -ChildPath 'AdmKavideErrors.ignorelist.txt')
)

$sharedHelpersDirectory = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Common'
$sharedHelpersPath = Join-Path -Path $sharedHelpersDirectory -ChildPath 'ElasticSearchHelpers.ps1'
if (-not (Test-Path -Path $sharedHelpersPath)) {
    throw "Shared Elastic helper not found at '$sharedHelpersPath'."
}
. $sharedHelpersPath

$includeEnd = $PSBoundParameters.ContainsKey('EndDate')
if (-not $PSBoundParameters.ContainsKey('StartDate')) {
    $StartDate = [datetime]::Today
    if (-not $includeEnd) {
        $EndDate = $StartDate.Date.AddDays(1).AddMilliseconds(-1)
        $includeEnd = $true
    }
}

$headers = @{}
if ($ElasticApiKey) {
    $headers['Authorization'] = "ApiKey $ElasticApiKey"
} elseif ($ElasticApiKeyPath -and (Test-Path $ElasticApiKeyPath)) {
    $k = Get-Content -Path $ElasticApiKeyPath -Raw
    $headers['Authorization'] = "ApiKey $k"
}

function Get-IgnorePhrases {
    param(
        [string]$Path
    )

    $phrases = @()
    if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -Path $Path)) {
        $phrases = Get-Content -Path $Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }

    return $phrases
}

function Test-IgnoredErrorText {
    param(
        [string]$ErrorText,
        [string[]]$IgnorePhrases
    )

    if (-not $IgnorePhrases -or [string]::IsNullOrWhiteSpace($ErrorText)) { return $false }

    foreach ($phrase in $IgnorePhrases) {
        if (-not [string]::IsNullOrWhiteSpace($phrase) -and ($ErrorText.IndexOf($phrase, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)) {
            return $true
        }
    }

    return $false
}

$ignorePhrases = Get-IgnorePhrases -Path $IgnoreListPath

function Get-ZugangVonKostenstelle {
    param(
        [string]$MessageData
    )

    if ([string]::IsNullOrWhiteSpace($MessageData)) { return $null }
    try {
        [xml]$xml = $MessageData
        $node = $xml.SelectSingleNode('//ZugangVonKostenstelle')
        if ($node) { return $node.InnerText }
    } catch {
        # Ignore parse errors and return null
    }
    return $null
}

$filters = @(
    @{ term = @{ 'ScenarioName' = 'ITI_SUBFL_KAVIDE_speichern_v01_3287' } },
    @{ term = @{ 'Environment' = $Environment } },
    @{ term = @{ 'WorkflowPattern' = 'ERROR' } }
)
if ($Instance) { $filters += @{ term = @{ 'Instance' = $Instance } } }

$range = @{ gte = $StartDate.ToUniversalTime().ToString('o') }
if ($includeEnd) { $range.lte = $EndDate.ToUniversalTime().ToString('o') }
$filters += @{ range = @{ '@timestamp' = $range } }

$sourceFields = @(
    '@timestamp','ScenarioName','Environment','Instance','WorkflowPattern',
    'BusinessCaseId','BK._STATUS_TEXT','BK._CASENO','BK.SUBFL_subid',
    'BK.SUBFL_category','BK.SUBFL_subcategory','MessageData1'
)

$body = @{
    size = 1000
    query = @{ bool = @{ filter = $filters } }
    _source = $sourceFields
} | ConvertTo-Json -Depth 6

try {
    $errorHits = Invoke-ElasticScrollSearch -ElasticUrl $ElasticUrl -Headers $headers -Body $body -TimeoutSec 120
} catch {
    Write-Error $_.Exception.Message
    return
}

if ($errorHits.Count -eq 0) {
    Write-Warning 'No errors found for specified criteria.'
    return
}

$errorsByCaseno = @{}
foreach ($hit in $errorHits) {
    $caseNo = Get-ElasticSourceValue -Source $hit._source -FieldPath 'BK._CASENO'
    if ([string]::IsNullOrWhiteSpace($caseNo)) { continue }
    $statusText = Get-ElasticSourceValue -Source $hit._source -FieldPath 'BK._STATUS_TEXT'
    if (Test-IgnoredErrorText -ErrorText $statusText -IgnorePhrases $ignorePhrases) { continue }
    if (-not $errorsByCaseno.ContainsKey($caseNo)) { $errorsByCaseno[$caseNo] = @() }
    $errorsByCaseno[$caseNo] += $hit
}

$uniqueCasenos = $errorsByCaseno.Keys

$successFilters = @(
    @{ term = @{ 'ScenarioName' = 'ITI_SUBFL_KAVIDE_speichern_v01_3287' } },
    @{ term = @{ 'Environment' = $Environment } },
    @{ term = @{ 'WorkflowPattern' = 'SUCCESS' } },
    @{ terms = @{ 'BK._CASENO.keyword' = $uniqueCasenos } }
)
if ($Instance) { $successFilters += @{ term = @{ 'Instance' = $Instance } } }
$successFilters += @{ range = @{ '@timestamp' = $range } }

$successBody = @{
    size = 1000
    query = @{ bool = @{ filter = $successFilters } }
    _source = $sourceFields
} | ConvertTo-Json -Depth 6

$successHits = @()
if ($uniqueCasenos.Count -gt 0) {
    try {
        $successHits = Invoke-ElasticScrollSearch -ElasticUrl $ElasticUrl -Headers $headers -Body $successBody -TimeoutSec 120
    } catch {
        Write-Warning $_.Exception.Message
    }
}

$successCounts = @{}
foreach ($hit in $successHits) {
    $caseNo = Get-ElasticSourceValue -Source $hit._source -FieldPath 'BK._CASENO'
    if ([string]::IsNullOrWhiteSpace($caseNo)) { continue }
    $subId = Get-ElasticSourceValue -Source $hit._source -FieldPath 'BK.SUBFL_subid'
    $category = Get-ElasticSourceValue -Source $hit._source -FieldPath 'BK.SUBFL_category'
    $subcategory = Get-ElasticSourceValue -Source $hit._source -FieldPath 'BK.SUBFL_subcategory'
    $key = "$subId|$category|$subcategory"
    if (-not $successCounts.ContainsKey($caseNo)) { $successCounts[$caseNo] = @{} }
    if (-not $successCounts[$caseNo].ContainsKey($key)) { $successCounts[$caseNo][$key] = 0 }
    $successCounts[$caseNo][$key]++
}

$results = @()
foreach ($caseNo in ($errorsByCaseno.Keys | Sort-Object)) {
    $caseErrors = $errorsByCaseno[$caseNo] | Sort-Object { [datetime](Get-ElasticSourceValue -Source $_._source -FieldPath '@timestamp') }

    $errorDetails = foreach ($hit in $caseErrors) {
        $timestamp = Get-ElasticSourceValue -Source $hit._source -FieldPath '@timestamp'
        $businessCaseId = Get-ElasticSourceValue -Source $hit._source -FieldPath 'BusinessCaseId'
        $statusText = Get-ElasticSourceValue -Source $hit._source -FieldPath 'BK._STATUS_TEXT'
        $zugang = Get-ZugangVonKostenstelle -MessageData (Get-ElasticSourceValue -Source $hit._source -FieldPath 'MessageData1')

        [pscustomobject]@{
            Timestamp = $timestamp
            BusinessCaseId = $businessCaseId
            StatusText = $statusText
            ZugangVonKostenstelle = $zugang
        }
    }

    $firstError = $errorDetails | Select-Object -First 1
    $lastError = $errorDetails | Select-Object -Last 1
    $timestamp = $firstError.Timestamp
    $lastTimestamp = $lastError.Timestamp
    $businessCaseId = $firstError.BusinessCaseId
    $statusText = $firstError.StatusText
    $zugang = $firstError.ZugangVonKostenstelle

    $successSummary = '0'
    if ($successCounts.ContainsKey($caseNo)) {
        $fragments = foreach ($entry in ($successCounts[$caseNo].GetEnumerator() | Sort-Object Name)) {
            $parts = $entry.Key -split '\|',3
            $subId = $parts[0]
            $cat = if ($parts.Count -gt 1) { $parts[1] } else { '' }
            $subcat = if ($parts.Count -gt 2) { $parts[2] } else { '' }
            "$subId/$cat/$($subcat): $($entry.Value)"
        }
        $successSummary = [string]::Join('; ', $fragments)
    }

    $results += [pscustomobject]@{
        CaseNo = $caseNo
        ErrorCount = $caseErrors.Count
        FirstErrorTimestamp = $timestamp
        LastErrorTimestamp = $lastTimestamp
        FirstErrorBusinessCaseId = $businessCaseId
        FirstErrorStatusText = $statusText
        ZugangVonKostenstelle = $zugang
        ErrorDetails = ($errorDetails | ConvertTo-Json -Depth 6 -Compress)
        Successes = $successSummary
    }

    $rangeText = "${timestamp} - ${lastTimestamp}"
    Write-Host "Case $caseNo (${rangeText})" -ForegroundColor Cyan
    Write-Host "  Successes: $successSummary" -ForegroundColor Green
    Write-Host "  Errors ($($caseErrors.Count)):" -ForegroundColor Yellow
    foreach ($detail in $errorDetails) {
        $detailLine = "    [$($detail.Timestamp)] BCID=$($detail.BusinessCaseId) Status='$($detail.StatusText)' Zugang='$($detail.ZugangVonKostenstelle)'"
        Write-Host $detailLine -ForegroundColor Red
    }
}

if (-not (Test-Path -Path $OutputDirectory)) {
    $null = New-Item -Path $OutputDirectory -ItemType Directory -Force
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outPath = Join-Path -Path $OutputDirectory -ChildPath "AdmKavideErrors_${stamp}.csv"
$results | Export-Csv -Path $outPath -NoTypeInformation -Encoding UTF8
Write-Host "Saved summary to $outPath"
