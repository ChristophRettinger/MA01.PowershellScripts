<#
.SYNOPSIS
    Retrieve patient and case details from Elasticsearch for SUBFL HCM messages.

.DESCRIPTION
    Queries Elasticsearch for HCM records in production, covering both Input
    documents and Output records for the Sense and KAVIDE senders. The script
    filters by patient ID (PID), case number (CASENO), and movement number
    (MOVENO), and can optionally restrict results by a time range. Results are
    sorted by timestamp and printed in contiguous segments that separate ERROR
    workflow entries from OK entries. Each segment is grouped by case, category,
    subcategory, change type, and workflow pattern, with per-stage summaries for
    Inputs and Outputs (Outputs are additionally grouped by party).

    When records contain BK._PID_ISH_OLD, the script performs an additional query
    using that value against BK._PID_ISH to include historical data. If a case
    number is supplied without a PID, the PID discovered in the first query is
    used to fetch patient-level data so that records without case context are
    also included. All matching hits are deduplicated by Elasticsearch _id before
    processing.

.PARAMETER StartDate
    Optional inclusive start date for timestamp filtering. If omitted, no lower
    bound is applied.

.PARAMETER EndDate
    Optional inclusive end date for timestamp filtering. If omitted, no upper
    bound is applied.

.PARAMETER ElasticTimeField
    Timestamp field to filter and sort on in Elasticsearch. Defaults to
    '@timestamp'.

.PARAMETER ElasticApiKey
    Elasticsearch API key string. If omitted, ElasticApiKeyPath is used.

.PARAMETER ElasticApiKeyPath
    Path to a file containing the Elasticsearch API key. Defaults to '.\elastic.key'.

.PARAMETER OutputDirectory
    Directory where helper artifacts are written (currently the merged hit dump).
    Defaults to an Output folder next to the script.

.PARAMETER PID
    Patient identifier used for querying. Matches BK._PID_ISH or BK._PID.

.PARAMETER CASENO
    Case number used for querying. The script detects whether the value matches
    BK._CASENO (8 digits, whitespace, 8 digits), BK._CASENO_ISH (10 digits), or
    BK._CASENO_BC (9 alphanumeric characters) and filters on the matching field.

.PARAMETER MOVENO
    Movement identifier. When supplied, filters on BK._MOVENO.

.EXAMPLE
    ./Get-PatientInfo.ps1 -CASENO 7622000264 -ElasticApiKeyPath ~/.eskey

    Queries HCM production data for the specified case number, expands to the
    associated patient ID, and prints grouped OK/ERROR segments ordered by time.
#>
param(
    [Parameter(Mandatory=$false)]
    [datetime]$StartDate,

    [Parameter(Mandatory=$false)]
    [datetime]$EndDate,

    [Parameter(Mandatory=$false)]
    [string]$ElasticUrl = 'https://es-obs.apps.zeus.wien.at/logs-orchestra.journals*/_search',

    [Parameter(Mandatory=$false)]
    [string]$ElasticTimeField = '@timestamp',

    [Parameter(Mandatory=$false)]
    [string]$ElasticApiKey,

    [Parameter(Mandatory=$false)]
    [string]$ElasticApiKeyPath = '.\elastic.key',

    [Parameter(Mandatory=$false)]
    [string]$OutputDirectory = (Join-Path -Path $PSScriptRoot -ChildPath 'Output'),

    [Parameter(Mandatory=$false)]
    [string]$PID,

    [Parameter(Mandatory=$false)]
    [string]$CASENO,

    [Parameter(Mandatory=$false)]
    [string]$MOVENO
)

$sharedHelpersDirectory = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Common'
$sharedHelpersPath = Join-Path -Path $sharedHelpersDirectory -ChildPath 'ElasticSearchHelpers.ps1'
if (-not (Test-Path -Path $sharedHelpersPath)) {
    throw "Shared Elastic helper not found at '$sharedHelpersPath'."
}
. $sharedHelpersPath

if (-not $PID -and -not $CASENO) {
    throw 'Provide at least PID or CASENO for querying.'
}

try {
    if (-not (Test-Path -Path $OutputDirectory)) {
        $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    }
} catch {
    Write-Warning "Failed to ensure output directory '$OutputDirectory': $_"
}

$apiKey = $null
if ($PSBoundParameters.ContainsKey('ElasticApiKey') -and $ElasticApiKey) {
    $apiKey = $ElasticApiKey.Trim()
} elseif ($ElasticApiKeyPath) {
    if (-not (Test-Path -Path $ElasticApiKeyPath)) {
        throw "ElasticApiKeyPath '$ElasticApiKeyPath' not found. Provide a valid path or use -ElasticApiKey."
    }
    $apiKey = (Get-Content -Path $ElasticApiKeyPath -Raw).Trim()
}

if (-not $apiKey) {
    throw 'No Elasticsearch API key provided. Supply -ElasticApiKey or -ElasticApiKeyPath.'
}

$headers = @{
    'Content-Type' = 'application/json'
    'Authorization' = "ApiKey $apiKey"
}

$baseFilters = @(
    @{ term = @{ 'BK.SUBFL_messagetype' = 'HCM' } },
    @{ term = @{ 'Environment' = 'production' } },
    @{
        bool = @{
            should = @(
                @{ term = @{ 'BK.SUBFL_stage' = 'Input' } },
                @{
                    bool = @{
                        must = @(
                            @{ term = @{ 'BK.SUBFL_stage' = 'Output' } },
                            @{ terms = @{ 'ScenarioName' = @('ITI_SUBFL_KAVIDE_speichern_v01_3287','ITI_SUBFL_Sense_senden_4292') } }
                        )
                    }
                }
            )
            minimum_should_match = 1
        }
    },
    @{ bool = @{ must_not = @(@{ term = @{ 'WorkflowPattern' = 'REQ_RESP' } }) } }
)

$hasDateFilter = $PSBoundParameters.ContainsKey('StartDate') -or $PSBoundParameters.ContainsKey('EndDate')
if ($hasDateFilter) {
    $range = @{}
    if ($PSBoundParameters.ContainsKey('StartDate') -and $StartDate) {
        $range['gte'] = $StartDate.ToString('o')
    }
    if ($PSBoundParameters.ContainsKey('EndDate') -and $EndDate) {
        $range['lte'] = $EndDate.ToString('o')
    }
    if ($range.Count -gt 0) {
        $baseFilters += @{ range = @{ $ElasticTimeField = $range } }
    }
}

function Get-CasenoFieldName {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Value
    )

    if ($Value -match '^\d{8}\s+\d{8}$') { return 'BK._CASENO' }
    if ($Value -match '^\d{10}$') { return 'BK._CASENO_ISH' }
    if ($Value -match '^\w{9}$') { return 'BK._CASENO_BC' }
    return $null
}

function New-ElasticBody {
    param(
        [Parameter(Mandatory=$true)]
        [System.Collections.IEnumerable]$Filters
    )

    return @{
        size = 500
        sort = @(@{ $ElasticTimeField = @{ order = 'asc' } })
        query = @{
            bool = @{
                filter = @($Filters)
            }
        }
    }
}

function Invoke-ElasticQuery {
    param(
        [Parameter(Mandatory=$true)]
        [System.Collections.IEnumerable]$Filters,

        [Parameter(Mandatory=$true)]
        [string]$Label
    )

    $body = New-ElasticBody -Filters $Filters
    Write-Host "Querying Elasticsearch ($Label)..." -ForegroundColor Cyan
    $hits = Invoke-ElasticScrollSearch -ElasticUrl $ElasticUrl -Body $body -Headers $headers -ScrollKeepAlive '2m' -OnPage {
        param($PageNumber,$PageHits,$TotalCount)
        Write-Host ("  Collected {0} hits after page {1}" -f $TotalCount, $PageNumber) -ForegroundColor DarkCyan
    }
    Write-Host ("  Returned {0} total hits" -f $hits.Count) -ForegroundColor DarkGreen
    return $hits
}

$filters = @($baseFilters)
$hasCaseFilter = $false
$hasMoveFilter = $false
$needPatientExpansion = $false

if ($PID) {
    $filters += @{
        bool = @{
            should = @(
                @{ term = @{ 'BK._PID_ISH' = $PID } },
                @{ term = @{ 'BK._PID' = $PID } }
            )
            minimum_should_match = 1
        }
    }
}

if ($CASENO) {
    $fieldName = Get-CasenoFieldName -Value $CASENO
    if (-not $fieldName) {
        Write-Warning "CASENO '$CASENO' does not match known patterns; skipping case filter."
    } else {
        $filters += @{ term = @{ $fieldName = $CASENO } }
        $hasCaseFilter = $true
    }
}

if ($MOVENO) {
    $filters += @{ term = @{ 'BK._MOVENO' = $MOVENO } }
    $hasMoveFilter = $true
}

$initialHits = Invoke-ElasticQuery -Filters $filters -Label 'initial'

$allHitsById = @{}
foreach ($hit in $initialHits) {
    if (-not $allHitsById.ContainsKey($hit._id)) {
        $allHitsById[$hit._id] = $hit
    }
}

$seenPatientIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$pendingPatientIds = [System.Collections.Generic.Queue[string]]::new()

function Register-PatientId {
    param(
        [Parameter(Mandatory=$false)]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    if (-not $seenPatientIds.Contains($Value)) {
        $null = $seenPatientIds.Add($Value)
        $pendingPatientIds.Enqueue($Value)
    }
}

function Collect-PidsFromHits {
    param(
        [Parameter(Mandatory=$true)]
        [System.Collections.IEnumerable]$Hits
    )

    foreach ($hit in $Hits) {
        $pidIsh = Get-ElasticSourceValue -Source $hit._source -FieldPath 'BK._PID_ISH'
        Register-PatientId -Value $pidIsh
        $oldPid = Get-ElasticSourceValue -Source $hit._source -FieldPath 'BK._PID_ISH_OLD'
        Register-PatientId -Value $oldPid
    }
}

Collect-PidsFromHits -Hits $initialHits
$needPatientExpansion = $hasCaseFilter -or $hasMoveFilter

while ($pendingPatientIds.Count -gt 0) {
    $batch = @()
    while ($pendingPatientIds.Count -gt 0 -and $batch.Count -lt 50) {
        $batch += $pendingPatientIds.Dequeue()
    }

    if (-not $needPatientExpansion -and $PID -and $batch -contains $PID -and $batch.Count -eq 1) {
        continue
    }

    $patientFilters = @($baseFilters)
    $patientFilters += @{ terms = @{ 'BK._PID_ISH' = $batch } }
    $patientHits = Invoke-ElasticQuery -Filters $patientFilters -Label ("patient expansion for PID(s) {0}" -f ($batch -join ', '))
    foreach ($hit in $patientHits) {
        if (-not $allHitsById.ContainsKey($hit._id)) {
            $allHitsById[$hit._id] = $hit
        }
    }
    Collect-PidsFromHits -Hits $patientHits
    $needPatientExpansion = $true
}

if ($allHitsById.Count -eq 0) {
    Write-Host 'No matching records found.' -ForegroundColor Yellow
    return
}

$documents = foreach ($hit in $allHitsById.Values) {
    $src = $hit._source
    $timestampValue = Get-ElasticSourceValue -Source $src -FieldPath $ElasticTimeField
    $timestamp = $null
    if ($timestampValue) {
        try {
            $timestamp = [datetime]::Parse($timestampValue, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        } catch {
            $timestamp = $timestampValue
        }
    }

    [pscustomobject]@{
        Id = $hit._id
        Timestamp = $timestamp
        WorkflowPattern = Get-ElasticSourceValue -Source $src -FieldPath 'WorkflowPattern'
        Stage = Get-ElasticSourceValue -Source $src -FieldPath 'BK.SUBFL_stage'
        Category = Get-ElasticSourceValue -Source $src -FieldPath 'BK.SUBFL_category'
        Subcategory = Get-ElasticSourceValue -Source $src -FieldPath 'BK.SUBFL_subcategory'
        ChangeArt = Get-ElasticSourceValue -Source $src -FieldPath 'BK.SUBFL_changeart'
        Party = Get-ElasticSourceValue -Source $src -FieldPath 'BK.SUBFL_party'
        CaseIsh = Get-ElasticSourceValue -Source $src -FieldPath 'BK._CASENO_ISH'
        MoveNo = Get-ElasticSourceValue -Source $src -FieldPath 'BK._MOVENO'
        BusinessCaseId = (Get-ElasticSourceValue -Source $src -FieldPath 'BusinessCaseId') ?? (Get-ElasticSourceValue -Source $src -FieldPath 'MSGID')
        Aid = Get-ElasticSourceValue -Source $src -FieldPath 'BK._PID'
        PidIsh = Get-ElasticSourceValue -Source $src -FieldPath 'BK._PID_ISH'
        ScenarioName = Get-ElasticSourceValue -Source $src -FieldPath 'ScenarioName'
    }
} | Sort-Object -Property Timestamp, Id

$pidList = ($documents | Where-Object { $_.PidIsh } | Select-Object -ExpandProperty PidIsh -Unique)
if ($pidList) {
    Write-Host ("PID(s): {0}" -f ($pidList -join ', ')) -ForegroundColor Green
}

$caseGroups = $documents | Where-Object { $_.CaseIsh } | Group-Object -Property CaseIsh
if ($caseGroups.Count -gt 0) {
    Write-Host 'Case overview:' -ForegroundColor Cyan
    foreach ($caseGroup in $caseGroups) {
        $moves = $caseGroup.Group | Where-Object { $_.MoveNo } | Select-Object -ExpandProperty MoveNo -Unique
        $bcs = $caseGroup.Group | Where-Object { $_.BusinessCaseId } | Select-Object -ExpandProperty BusinessCaseId -Unique
        $aids = $caseGroup.Group | Where-Object { $_.Aid } | Select-Object -ExpandProperty Aid -Unique
        $moveText = if ($moves) { $moves -join ', ' } else { '-' }
        $bcText = if ($bcs) { $bcs -join ', ' } else { '-' }
        $aidText = if ($aids) { $aids -join ', ' } else { '-' }
        Write-Host ("  CASENO (ISH): {0} | MOVENO: {1} | BC: {2} | AID: {3}" -f $caseGroup.Name, $moveText, $bcText, $aidText) -ForegroundColor White
    }
}

$colorMap = @{
    'PATIENT' = 'Yellow'
    'CASE' = 'White'
    'DIAGNOSIS' = 'Gray'
    'INSURANCE' = 'Gray'
    'MERGE' = 'Red'
    'CLASSIFICATION' = 'Gray'
    'SPLIT' = 'Red'
}

$segments = @()
$currentSegment = $null
foreach ($doc in $documents) {
    $isError = $false
    if ($doc.WorkflowPattern -and $doc.WorkflowPattern -ieq 'ERROR') { $isError = $true }
    if (-not $currentSegment -or $currentSegment.IsError -ne $isError) {
        $currentSegment = @{
            IsError = $isError
            Items = New-Object System.Collections.Generic.List[object]
        }
        $segments += $currentSegment
    }
    $null = $currentSegment.Items.Add($doc)
}

Write-Host ''
foreach ($segment in $segments) {
    $segmentItems = $segment.Items
    if (-not $segmentItems -or $segmentItems.Count -eq 0) { continue }

    $firstTimestamp = ($segmentItems | Select-Object -ExpandProperty Timestamp -First 1)
    $lastTimestamp = ($segmentItems | Select-Object -ExpandProperty Timestamp -Last 1)
    $rangeText = if ($firstTimestamp -and $lastTimestamp) {
        "{0:u} - {1:u}" -f $firstTimestamp, $lastTimestamp
    } elseif ($firstTimestamp) {
        "{0:u}" -f $firstTimestamp
    } else {
        'No timestamp'
    }

    $label = if ($segment.IsError) { 'ERROR' } else { 'OK' }
    $labelColor = if ($segment.IsError) { 'Red' } else { 'Green' }
    Write-Host ("{0} ({1} records) | {2}" -f $label, $segmentItems.Count, $rangeText) -ForegroundColor $labelColor

    $grouped = $segmentItems | Group-Object -Property CaseIsh, Category, Subcategory, ChangeArt, WorkflowPattern
    foreach ($group in $grouped) {
        $sample = $group.Group | Select-Object -First 1
        $color = if ($sample.Category -and $colorMap.ContainsKey($sample.Category)) { $colorMap[$sample.Category] } else { 'DarkGray' }
        $header = "  Case: {0} | Category: {1} | Subcategory: {2} | Change: {3} | Pattern: {4}" -f (
            if ($sample.CaseIsh) { $sample.CaseIsh } else { '-' },
            if ($sample.Category) { $sample.Category } else { '-' },
            if ($sample.Subcategory) { $sample.Subcategory } else { '-' },
            if ($sample.ChangeArt) { $sample.ChangeArt } else { '-' },
            if ($sample.WorkflowPattern) { $sample.WorkflowPattern } else { '-' }
        )
        Write-Host $header -ForegroundColor $color

        $inputs = $group.Group | Where-Object { $_.Stage -eq 'Input' }
        if ($inputs.Count -gt 0) {
            $inputFirst = ($inputs | Select-Object -ExpandProperty Timestamp -First 1)
            $inputLast = ($inputs | Select-Object -ExpandProperty Timestamp -Last 1)
            Write-Host ("    Input : {0:u} - {1:u} (count {2})" -f $inputFirst, $inputLast, $inputs.Count) -ForegroundColor $color
        }

        $outputs = $group.Group | Where-Object { $_.Stage -eq 'Output' }
        if ($outputs.Count -gt 0) {
            $outputGroups = $outputs | Group-Object -Property Party
            foreach ($outputGroup in $outputGroups) {
                $outputFirst = ($outputGroup.Group | Select-Object -ExpandProperty Timestamp -First 1)
                $outputLast = ($outputGroup.Group | Select-Object -ExpandProperty Timestamp -Last 1)
                $partyName = if ($outputGroup.Name) { $outputGroup.Name } else { '-' }
                Write-Host ("    Output ({0}): {1:u} - {2:u} (count {3})" -f $partyName, $outputFirst, $outputLast, $outputGroup.Count) -ForegroundColor $color
            }
        }
    }
    Write-Host ''
}

$outputPath = Join-Path -Path $OutputDirectory -ChildPath 'Get-PatientInfo-hits.json'
try {
    $documents | ConvertTo-Json -Depth 6 | Set-Content -Path $outputPath -Encoding UTF8
    Write-Host ("Wrote merged hits to {0}" -f $outputPath) -ForegroundColor DarkGreen
} catch {
    Write-Warning "Failed to write merged hits to '$outputPath': $_"
}
