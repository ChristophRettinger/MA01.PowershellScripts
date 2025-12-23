<#
.SYNOPSIS
    Retrieve patient- and case-related HCM Subscription Flow activity from Elasticsearch.

.DESCRIPTION
    Queries Elasticsearch for Subscription Flow (SUBFL) HCM messages in production and
    groups results by case, category, and workflow state so that patient history can be
    inspected directly in the console. The base filter enforces the HCM message type,
    excludes REQ_RESP workflow patterns, and limits output-stage records to the known
    SUBFL senders. Results are split into ERROR and non-ERROR segments, then grouped by
    `BK._CASENO_ISH`, `BK.SUBFL_category`, `BK.SUBFL_subcategory`,
    `BK.SUBFL_changeart`, and `WorkflowPattern`. For each group the script lists the
    Input stage range and counts plus Output stage ranges grouped by receiver
    (`BK.SUBFL_party`).

    When a `BK._PID_ISH_OLD` value is discovered in any hit, the script automatically
    re-runs the search for that PID in `BK._PID_ISH` and merges the data. If only a
    case number is supplied, the script first queries by case and then repeats the
    search for the associated PID(s) to include patient-level records without case
    identifiers.

.PARAMETER StartDate
    Optional inclusive start date for the time range filter applied to the specified
    `ElasticTimeField`.

.PARAMETER EndDate
    Optional inclusive end date for the time range filter applied to the specified
    `ElasticTimeField`.

.PARAMETER ElasticTimeField
    Name of the Elasticsearch time field to filter and sort by. Defaults to
    `@timestamp`.

.PARAMETER ElasticUrl
    Full Elasticsearch _search URL (including index pattern). Defaults to
    `https://es-obs.apps.zeus.wien.at/logs-subscriptionflow.journals*/_search`.

.PARAMETER ElasticApiKey
    Elasticsearch API key string. If omitted, ElasticApiKeyPath is used.

.PARAMETER ElasticApiKeyPath
    Path to a file containing the Elasticsearch API key. Defaults to `.\elastic.key`.

.PARAMETER OutputDirectory
    Directory where a JSON export of the collected hits is written. Defaults to an
    `Output` folder beside this script.

.PARAMETER PIDISH
    Patient identifier (BK._PID_ISH). When provided, all related cases and transfers
    for the patient are retrieved.

.PARAMETER CASENO
    Case identifier. The script infers whether it is `BK._CASENO_ISH` (10 digits),
    `BK._CASENO_BC` (9 alphanumeric characters), or `BK._CASENO`
    (two 8-digit numbers separated by whitespace) and uses the matching field for
    searching.

.PARAMETER MOVENO
    Optional movement identifier (BK._MOVENO) to further narrow case results.

.EXAMPLE
    ./Get-PatientInfo.ps1 -PIDISH 0000869517 -StartDate '2025-05-01' -EndDate '2025-05-07'

.EXAMPLE
    ./Get-PatientInfo.ps1 -CASENO 7622000264 -MOVENO 00042 -ElasticApiKeyPath ~/.eskey
#>

param(
    [Parameter(Mandatory=$false)]
    [datetime]$StartDate,

    [Parameter(Mandatory=$false)]
    [datetime]$EndDate,

    [Parameter(Mandatory=$false)]
    [string]$ElasticTimeField = '@timestamp',

    [Parameter(Mandatory=$false)]
    [string]$ElasticUrl = 'https://es-obs.apps.zeus.wien.at/logs-subscriptionflow.journals*/_search',

    [Parameter(Mandatory=$false)]
    [string]$ElasticApiKey,

    [Parameter(Mandatory=$false)]
    [string]$ElasticApiKeyPath = (Join-Path -Path $PSScriptRoot -ChildPath 'elastic.key'),

    [Parameter(Mandatory=$false)]
    [string]$OutputDirectory = (Join-Path -Path $PSScriptRoot -ChildPath 'Output'),

    [Parameter(Mandatory=$false)]
    [string]$PIDISH,

    [Parameter(Mandatory=$false)]
    [string]$CASENO,

    [Parameter(Mandatory=$false)]
    [string]$MOVENO
)
Write-Host $ElasticApiKeyPath
$sharedHelpersDirectory = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Common'
$sharedHelpersPath = Join-Path -Path $sharedHelpersDirectory -ChildPath 'ElasticSearchHelpers.ps1'
if (-not (Test-Path -Path $sharedHelpersPath)) {
    throw "Shared Elastic helper not found at '$sharedHelpersPath'."
}
. $sharedHelpersPath

if (-not $PIDISH -and -not $CASENO) {
    Write-Error 'Provide either PIDISH or CASENO to search for patient information.'
    return
}

if ($PIDISH) { $PIDISH = $PIDISH.Trim() }
if ($CASENO) { $CASENO = $CASENO.Trim() }
if ($MOVENO) { $MOVENO = $MOVENO.Trim() }

function Get-CaseFieldName {
    param(
        [string]$CaseNumber
    )

    if ([string]::IsNullOrWhiteSpace($CaseNumber)) { return $null }

    $trimmed = $CaseNumber.Trim()
    if ($trimmed -match '^\d{10}$') { return 'BK._CASENO_ISH' }
    if ($trimmed -match '^\w{9}$') { return 'BK._CASENO_BC' }
    if ($trimmed -match '^\d{8}\s+\d{8}$') { return 'BK._CASENO' }
    return $null
}

function Get-CategoryColor {
    param(
        [string]$Category
    )

    if ([string]::IsNullOrWhiteSpace($Category)) { return 'White' }

    switch ($Category.ToUpperInvariant()) {
        'PATIENT' { return 'Yellow' }
        'CASE' { return 'White' }
        'DIAGNOSIS' { return 'Gray' }
        'INSURANCE' { return 'Gray' }
        'MERGE' { return 'Red' }
        'CLASSIFICATION' { return 'Gray' }
        'SPLIT' { return 'Red' }
        default { return 'Cyan' }
    }
}

function Convert-ToTimestamp {
    param(
        [object]$Source,
        [string]$TimeField
    )

    $value = Get-ElasticSourceValue -Source $Source -FieldPath $TimeField
    if (-not $value -and $TimeField -ne '@timestamp') {
        $value = Get-ElasticSourceValue -Source $Source -FieldPath '@timestamp'
    }

    if ($value -is [datetime]) { return $value }

    if ([string]::IsNullOrWhiteSpace($value)) { return $null }

    $parsed = $null
    if ([datetime]::TryParse($value, [ref]$parsed)) { return $parsed }
    return $null
}

function Get-PidValuesFromHits {
    param(
        [object[]]$Hits
    )

    $pidSet = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($hit in $Hits) {
        $src = $hit._source
        foreach ($path in @('BK._PID_ISH','BK._PID_ISH_OLD')) {
            $pidValue = Get-ElasticSourceValue -Source $src -FieldPath $path
            if (-not [string]::IsNullOrWhiteSpace($pidValue)) {
                $null = $pidSet.Add($pidValue)
            }
        }
    }
    return $pidSet
}

function New-IdentityClause {
    param(
        [string[]]$PidFilters,
        [string]$CaseField,
        [string]$CaseValue,
        [bool]$IncludeCase
    )

    $shouldClauses = @()

    if ($PidFilters -and $PidFilters.Count -gt 0) {
        foreach ($pidish in $PidFilters) {
            if ([string]::IsNullOrWhiteSpace($pidish)) { continue }
            $shouldClauses += @{ term = @{ 'BK._PID_ISH' = $pidish } }
        }
    }

    if ($IncludeCase -and $CaseField -and $CaseValue) {
        $shouldClauses += @{ term = @{ $CaseField = $CaseValue } }
    } elseif ($IncludeCase -and -not $CaseField -and $CaseValue) {
        foreach ($field in @('BK._CASENO_ISH','BK._CASENO_BC','BK._CASENO')) {
            $shouldClauses += @{ term = @{ $field = $CaseValue } }
        }
    }

    if (-not $shouldClauses -or $shouldClauses.Count -eq 0) {
        throw 'No PIDISH or case clause available for the search query.'
    }

    return @{ bool = @{ should = $shouldClauses; minimum_should_match = 1 } }
}

$caseField = Get-CaseFieldName -CaseNumber $CASENO
if ($CASENO -and -not $caseField) {
    Write-Warning 'Case number did not match known patterns. Searching all known identifiers.'
}

$headers = @{ 'Content-Type' = 'application/json' }
if ($PSBoundParameters.ContainsKey('ElasticApiKey') -and $ElasticApiKey) {
    $headers['Authorization'] = "ApiKey $ElasticApiKey"
} elseif ($ElasticApiKeyPath) {
    if (Test-Path -Path $ElasticApiKeyPath) {
        $key = Get-Content -Path $ElasticApiKeyPath -Raw
        if (-not [string]::IsNullOrWhiteSpace($key)) {
            $headers['Authorization'] = "ApiKey $($key.Trim())"
        }
    } else {
        Write-Warning "ElasticApiKeyPath '$ElasticApiKeyPath' not found. Requests will be sent without authentication."
    }
}

$baseMust = @(
    @{ term = @{ 'BK.SUBFL_messagetype' = 'HCM' } },
    @{ term = @{ 'Environment' = 'production' } },
    @{ bool = @{ should = @(
        @{ term = @{ 'BK.SUBFL_stage' = 'Input' } },
        @{ bool = @{ must = @(
            @{ term = @{ 'BK.SUBFL_stage' = 'Output' } },
            @{ terms = @{ 'ScenarioName' = @('ITI_SUBFL_KAVIDE_speichern_v01_3287','ITI_SUBFL_Sense_senden_4292') } }
        ) } }
    ); minimum_should_match = 1 } }
)

$mustNot = @(@{ term = @{ 'WorkflowPattern' = 'REQ_RESP' } })

if ($StartDate -or $EndDate) {
    $rangeEntry = @{ range = @{ ($ElasticTimeField) = @{} } }
    if ($StartDate) { $rangeEntry.range[$ElasticTimeField].gte = $StartDate.ToString('o') }
    if ($EndDate) { $rangeEntry.range[$ElasticTimeField].lte = $EndDate.ToString('o') }
    $baseMust += $rangeEntry
}

if ($MOVENO) {
    $baseMust += @{ term = @{ 'BK._MOVENO' = $MOVENO.Trim() } }
}

function Invoke-PatientQuery {
    param(
        [string[]]$PidFilters,
        [bool]$IncludeCase
    )

    $mustClauses = @($baseMust)
    
    $identityClause = $null
    try {
        $identityClause = New-IdentityClause -PidFilters $PidFilters -CaseField $caseField -CaseValue $CASENO -IncludeCase $IncludeCase
    } catch {
        Write-Error $_
        return @()
    }

    $mustClauses += $identityClause
    
    $body = @{
        size = 500
        sort = @(@{ $ElasticTimeField = @{ order = 'asc' } })
        query = @{ bool = @{ must = $mustClauses; must_not = $mustNot } }        
    }

    $hits = Invoke-ElasticScrollSearch -ElasticUrl $ElasticUrl -Headers $headers -Body $body -TimeoutSec 120
    return $hits
}

$collectedHits = @{}
function Add-Hits {
    param([object[]]$Hits)
    foreach ($hit in $Hits) {
        $identifier = $hit._id
        if (-not $collectedHits.ContainsKey($identifier)) {
            $collectedHits[$identifier] = $hit
        }
    }
}

$initialPidFilters = @()
if ($PIDISH) { $initialPidFilters += $PIDISH.Trim() }

$initialHits = Invoke-PatientQuery -PidFilters $initialPidFilters -IncludeCase $true
Add-Hits -Hits $initialHits

$queuedPids = [System.Collections.Queue]::new()
$searchedPids = [System.Collections.Generic.HashSet[string]]::new()
foreach ($pidish in $initialPidFilters) { if ($pidish) { $null = $searchedPids.Add($pidish) } }

$discovered = Get-PidValuesFromHits -Hits $initialHits
foreach ($pidish in $discovered) {
    if (-not $searchedPids.Contains($pidish)) {
        $queuedPids.Enqueue($pidish)
        $null = $searchedPids.Add($pidish)
    }
}

if (-not $PIDISH -and $queuedPids.Count -eq 0 -and $CASENO) {
    Write-Warning 'No PID discovered from case search; results may only include case-bound records.'
}

while ($queuedPids.Count -gt 0) {
    $pidValue = [string]$queuedPids.Dequeue()
    if (-not $pidValue) { continue }

    $nextHits = Invoke-PatientQuery -PidFilters @($pidValue) -IncludeCase $false
    Add-Hits -Hits $nextHits

    $newPids = Get-PidValuesFromHits -Hits $nextHits
    foreach ($pidish in $newPids) {
        if (-not $searchedPids.Contains($pidish)) {
            $queuedPids.Enqueue($pidish)
            $null = $searchedPids.Add($pidish)
        }
    }
}

if ($collectedHits.Count -eq 0) {
    Write-Host 'No matching documents found for the supplied parameters.'
    return
}

try {
    if (-not (Test-Path -Path $OutputDirectory)) {
        $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    }
    $exportName = "PatientInfo_{0:yyyyMMdd_HHmmss}.json" -f (Get-Date)
    $exportPath = Join-Path -Path $OutputDirectory -ChildPath $exportName
    $collectedHits.Values | ConvertTo-Json -Depth 15 | Set-Content -Path $exportPath
    Write-Host "Exported raw hits to $exportPath"
} catch {
    Write-Warning "Failed to write export to $($OutputDirectory): $_"
}

$orderedHits = $collectedHits.Values | Sort-Object { Convert-ToTimestamp -Source $_._source -TimeField $ElasticTimeField }

$pidValues = @()
foreach ($hit in $orderedHits) {
    $val = Get-ElasticSourceValue -Source $hit._source -FieldPath 'BK._PID_ISH'
    if (-not [string]::IsNullOrWhiteSpace($val) -and $pidValues -notcontains $val) { $pidValues += $val }
}

if ($pidValues.Count -gt 0) {
    Write-Host "PID(s): $($pidValues -join ', ')" -ForegroundColor Cyan
}

$headerMap = @{}
foreach ($hit in $orderedHits) {
    $src = $hit._source
    $caseIsh = Get-ElasticSourceValue -Source $src -FieldPath 'BK._CASENO_ISH'
    $moveNo = Get-ElasticSourceValue -Source $src -FieldPath 'BK._MOVENO'
    $businessCase = Get-ElasticSourceValue -Source $src -FieldPath 'BusinessCaseId'
    if (-not $businessCase) { $businessCase = Get-ElasticSourceValue -Source $src -FieldPath 'MSGID' }
    $aid = Get-ElasticSourceValue -Source $src -FieldPath 'BK._PID_ISH'
    $key = "${caseIsh}|${moveNo}|${businessCase}|${aid}"
    if (-not $headerMap.ContainsKey($key)) {
        $headerMap[$key] = [PSCustomObject]@{
            CASENO_ISH = if ($caseIsh) { $caseIsh } else { '-' }
            MOVENO = if ($moveNo) { $moveNo } else { '-' }
            BC = if ($businessCase) { $businessCase } else { '-' }
            AID = if ($aid) { $aid } else { '-' }
        }
    }
}

if ($headerMap.Values.Count -gt 0) {
    Write-Host 'Cases and movements:' -ForegroundColor Cyan
    $headerMap.Values | Sort-Object CASENO_ISH, MOVENO | Format-Table -AutoSize
}

$segments = @{
    'ERROR' = $orderedHits | Where-Object { (Get-ElasticSourceValue -Source $_._source -FieldPath 'WorkflowPattern') -eq 'ERROR' }
    'OTHER' = $orderedHits | Where-Object { (Get-ElasticSourceValue -Source $_._source -FieldPath 'WorkflowPattern') -ne 'ERROR' }
}

foreach ($segmentKey in @('ERROR','OTHER')) {
    $segmentHits = $segments[$segmentKey]
    if (-not $segmentHits -or $segmentHits.Count -eq 0) {
        Write-Host "No $segmentKey records." -ForegroundColor DarkGray
        continue
    }

    $segmentTitle = if ($segmentKey -eq 'ERROR') { 'WorkflowPattern = ERROR' } else { 'WorkflowPattern <> ERROR' }
    Write-Host "\n$segmentTitle" -ForegroundColor Magenta

    $grouped = $segmentHits | Group-Object -Property {
        $src = $_._source
        $caseIsh = Get-ElasticSourceValue -Source $src -FieldPath 'BK._CASENO_ISH'
        $category = Get-ElasticSourceValue -Source $src -FieldPath 'BK.SUBFL_category'
        $subcat = Get-ElasticSourceValue -Source $src -FieldPath 'BK.SUBFL_subcategory'
        $change = Get-ElasticSourceValue -Source $src -FieldPath 'BK.SUBFL_changeart'
        $pattern = Get-ElasticSourceValue -Source $src -FieldPath 'WorkflowPattern'
        return "$($caseIsh)|$($category)|$($subcat)|$($change)|$($pattern)"
    }

    foreach ($group in $grouped) {
        $parts = $group.Name -split '\|'
        $caseIsh = if ($parts.Count -gt 0 -and $parts[0]) { $parts[0] } else { '-' }
        $category = if ($parts.Count -gt 1 -and $parts[1]) { $parts[1] } else { '-' }
        $subcategory = if ($parts.Count -gt 2 -and $parts[2]) { $parts[2] } else { '-' }
        $changeType = if ($parts.Count -gt 3 -and $parts[3]) { $parts[3] } else { '-' }
        $pattern = if ($parts.Count -gt 4 -and $parts[4]) { $parts[4] } else { '-' }

        $color = Get-CategoryColor -Category $category
        Write-Host "Case $($caseIsh) | Category $($category) / $($subcategory) | Change $($changeType) | Pattern $($pattern)" -ForegroundColor $color

        $inputs = $group.Group | Where-Object { (Get-ElasticSourceValue -Source $_._source -FieldPath 'BK.SUBFL_stage') -eq 'Input' }
        if ($inputs -and $inputs.Count -gt 0) {
            $firstInput = Convert-ToTimestamp -Source $inputs[0]._source -TimeField $ElasticTimeField
            $lastInput = Convert-ToTimestamp -Source $inputs[-1]._source -TimeField $ElasticTimeField
            Write-Host "  Input: $($inputs.Count) item(s), first $($firstInput), last $($lastInput)"
        } else {
            Write-Host '  Input: none'
        }

        $outputs = $group.Group | Where-Object { (Get-ElasticSourceValue -Source $_._source -FieldPath 'BK.SUBFL_stage') -eq 'Output' }
        if ($outputs -and $outputs.Count -gt 0) {
            $partyGroups = $outputs | Group-Object -Property { Get-ElasticSourceValue -Source $_._source -FieldPath 'BK.SUBFL_party' }
            foreach ($party in $partyGroups) {
                $partyName = if ($party.Name) { $party.Name } else { '-' }
                $firstOut = Convert-ToTimestamp -Source $party.Group[0]._source -TimeField $ElasticTimeField
                $lastOut = Convert-ToTimestamp -Source $party.Group[-1]._source -TimeField $ElasticTimeField
                Write-Host "  Output -> $($partyName): $($party.Count) item(s), first $($firstOut), last $($lastOut)"
            }
        } else {
            Write-Host '  Output: none'
        }
    }
}
