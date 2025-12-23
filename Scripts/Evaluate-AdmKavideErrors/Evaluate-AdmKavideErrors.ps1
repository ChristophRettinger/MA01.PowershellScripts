<#
.SYNOPSIS
    Evaluate errors for the KAVIDE ITI_SUBFL scenario via Elasticsearch.

.DESCRIPTION
    Queries Elasticsearch in two phases for the scenario
    ITI_SUBFL_KAVIDE_speichern_v01_3287 within a date range, environment, and
    optional instance. First, errors are collected (WorkflowPattern = ERROR) to
    identify case numbers (BK._CASENO) that should be analyzed. For each case
    number, a second Elasticsearch query fetches all matching events for that
    case to build the summary. The script reports the number of errors, details
    for the first occurrence (timestamp, BusinessCaseId, BK._STATUS_TEXT error
    text), and a parsed `ZugangVonKostenstelle` value extracted from
    MessageData1 (XML). A JSON-serialized list of all error occurrences is
    included so every error per case number is visible, and
    `ZugangVonKostenstelle` is evaluated for each error. The script also gathers
    workflow successes for the same case numbers and summarizes the number of
    successes grouped by BK.SUBFL_subid, BK.SUBFL_category, and
    BK.SUBFL_subcategory. Progress bars track the Elasticsearch fetch of error
    cases and the per-case detail queries. Results are written to the console
    with colored sections showing the case number and the timestamp range (first
    to last message), followed by successes and individual error details, and
    exported to a CSV file in the specified OutputDirectory.

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
    Path to a file containing the Elasticsearch API key. Defaults to '.\elastic.key'.

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
    [string]$ElasticApiKeyPath = '.\elastic.key',

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
    @{ term = @{ 'Environment' = $Environment } }
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

$errorFilters = @($filters + @{ term = @{ 'WorkflowPattern' = 'ERROR' } })
$errorBody = @{
    size = 1000
    query = @{ bool = @{ filter = $errorFilters } }
    _source = @('@timestamp','BusinessCaseId','BK._STATUS_TEXT','BK._CASENO')
}

$errorHitsCollected = 0
$onErrorPage = {
    param($page, $hits, $total)
    $script:errorHitsCollected += $hits.Count
    Write-Progress -Activity 'Collecting error cases' -Status "Page $page ($($script:errorHitsCollected) errors)" -PercentComplete 0 -Id 1
}

try {
    $errorHits = Invoke-ElasticScrollSearch -ElasticUrl $ElasticUrl -Headers $headers -Body $errorBody -TimeoutSec 120 -OnPage $onErrorPage
} catch {
    Write-Error $_.Exception.Message
    return
}

Write-Progress -Activity 'Collecting error cases' -Completed -Id 1

if (-not $errorHits -or $errorHits.Count -eq 0) {
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

if ($errorsByCaseno.Count -eq 0) {
    Write-Warning 'No errors found for specified criteria.'
    return
}

$caseNumbers = $errorsByCaseno.Keys | Sort-Object
$totalCases = $caseNumbers.Count
$caseIndex = 0

$results = @()
foreach ($caseNo in $caseNumbers) {
    $caseIndex++
    $percentComplete = [int](($caseIndex / $totalCases) * 100)
    Write-Progress -Activity 'Processing cases' -Status "Case $caseNo ($caseIndex of $totalCases)" -PercentComplete $percentComplete -Id 2

    $caseFilters = @($filters + @{ term = @{ 'BK._CASENO' = $caseNo } })
    $caseBody = @{
        size = 1000
        query = @{ bool = @{ filter = $caseFilters } }
        _source = $sourceFields
    }

    try {
        $caseHits = Invoke-ElasticScrollSearch -ElasticUrl $ElasticUrl -Headers $headers -Body $caseBody -TimeoutSec 120
    } catch {
        Write-Error "Failed to retrieve details for case $($caseNo): $($_.Exception.Message)"
        continue
    }

    if (-not $caseHits -or $caseHits.Count -eq 0) { continue }

    $caseErrors = @()
    foreach ($hit in $caseHits) {
        $workflowPattern = Get-ElasticSourceValue -Source $hit._source -FieldPath 'WorkflowPattern'
        if ($workflowPattern -ne 'ERROR') { continue }

        $statusText = Get-ElasticSourceValue -Source $hit._source -FieldPath 'BK._STATUS_TEXT'
        if (Test-IgnoredErrorText -ErrorText $statusText -IgnorePhrases $ignorePhrases) { continue }
        $caseErrors += $hit
    }

    if (-not $caseErrors -or $caseErrors.Count -eq 0) { continue }

    $successCounts = @{}
    foreach ($hit in $caseHits) {
        $workflowPattern = Get-ElasticSourceValue -Source $hit._source -FieldPath 'WorkflowPattern'
        if ($workflowPattern -ne 'OUT') { continue }

        $subId = Get-ElasticSourceValue -Source $hit._source -FieldPath 'BK.SUBFL_subid'
        $category = Get-ElasticSourceValue -Source $hit._source -FieldPath 'BK.SUBFL_category'
        $subcategory = Get-ElasticSourceValue -Source $hit._source -FieldPath 'BK.SUBFL_subcategory'
        $key = "$subId|$category|$subcategory"
        if (-not $successCounts.ContainsKey($key)) { $successCounts[$key] = 0 }
        $successCounts[$key]++
    }

    if ($caseErrors.Count -gt 1) {
        $caseErrors = $caseErrors | Sort-Object { [datetime](Get-ElasticSourceValue -Source $_._source -FieldPath '@timestamp') }
    }
    $caseEvents = $caseHits | Sort-Object { [datetime](Get-ElasticSourceValue -Source $_._source -FieldPath '@timestamp') }

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
    if ($successCounts.Count -gt 0) {
        $fragments = foreach ($entry in ($successCounts.GetEnumerator() | Sort-Object Name)) {
            $parts = $entry.Key -split '\|',3
            $subId = $parts[0]
            $cat = if ($parts.Count -gt 1) { $parts[1] } else { '' }
            $subcat = if ($parts.Count -gt 2) { $parts[2] } else { '' }
            if ($subcat) { 
                "$cat $($subcat) ($subId): $($entry.Value)"
            }
            else {
               "$cat ($subId): $($entry.Value)"
            }
        }
        $successSummary = [string]::Join('   ', $fragments)
    }

    $firstCaseTimestamp = Get-ElasticSourceValue -Source ($caseEvents | Select-Object -First 1)._source -FieldPath '@timestamp'
    $lastCaseTimestamp = Get-ElasticSourceValue -Source ($caseEvents | Select-Object -Last 1)._source -FieldPath '@timestamp'

    $formattedFirstRange = ([datetime]::Parse($firstCaseTimestamp)).ToString('yyyy-MM-dd HH:mm:ss')
    $formattedLastRange = ([datetime]::Parse($lastCaseTimestamp)).ToString('yyyy-MM-dd HH:mm:ss')
    $formattedFirstError = ([datetime]::Parse($timestamp)).ToString('yyyy-MM-dd HH:mm:ss')
    $formattedLastError = ([datetime]::Parse($lastTimestamp)).ToString('yyyy-MM-dd HH:mm:ss')

    $results += [pscustomobject]@{
        CaseNo = $caseNo
        ErrorCount = $caseErrors.Count
        FirstErrorTimestamp = $formattedFirstError
        LastErrorTimestamp = $formattedLastError
        FirstErrorBusinessCaseId = $businessCaseId
        FirstErrorStatusText = $statusText
        ZugangVonKostenstelle = $zugang
        ErrorDetails = ($errorDetails | ConvertTo-Json -Depth 6 -Compress)
        Successes = $successSummary
    }

    $rangeText = "${formattedFirstRange} - ${formattedLastRange}"
    Write-Host "Case $caseNo (${rangeText})" -ForegroundColor Cyan
    Write-Host "  Successes: $successSummary" -ForegroundColor Green
    Write-Host "  Errors ($($caseErrors.Count)):" -ForegroundColor Yellow
    foreach ($detail in $errorDetails) {
        $detailTimestamp = ([datetime]::Parse($detail.Timestamp)).ToString('yyyy-MM-dd HH:mm:ss')
        $detailLine = "    ${detailTimestamp}  $($detail.BusinessCaseId)  ZugangVonKostenstelle: $($detail.ZugangVonKostenstelle)"
        Write-Host $detailLine
        $detailLine = "    Status='$($detail.StatusText.trim())'"
        Write-Host $detailLine
    }
    Write-Host ""
}

Write-Progress -Activity 'Processing cases' -Completed -Id 2

if (-not (Test-Path -Path $OutputDirectory)) {
    $null = New-Item -Path $OutputDirectory -ItemType Directory -Force
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outPath = Join-Path -Path $OutputDirectory -ChildPath "AdmKavideErrors_${stamp}.csv"
$results | Export-Csv -Path $outPath -NoTypeInformation -Encoding UTF8
Write-Host "Saved summary to $outPath"
