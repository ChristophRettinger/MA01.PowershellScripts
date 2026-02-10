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
    (`BK.SUBFL_party`). The case/movement header is deduped by case and movement
    (not BusinessCaseId) while still showing any BusinessCaseId or MSGID values
    discovered. Overview headers include case type (BK._CASETYPE) and the AID
    (BK._CASENO). Detail grouping includes case type and movement after the PID
    value, with case type shown as a single-character suffix on the PID.

    When a `BK._PID_ISH_OLD` value is discovered in any hit, the script automatically
    re-runs the search for that PID in `BK._PID_ISH` and merges the data. If only a
    case number is supplied, the script first queries by case and then repeats the
    search for the associated PID(s) to include patient-level records without case
    identifiers while excluding other cases belonging to the same patient.

.PARAMETER StartDate
    Optional inclusive start date for the time range filter applied to the specified
    `ElasticTimeField`. If omitted and EndDate is also omitted, the script derives
    StartDate from Timespan (or 15 minutes by default) as EndDate minus Timespan.

.PARAMETER EndDate
    Optional inclusive end date for the time range filter applied to the specified
    `ElasticTimeField`.

.PARAMETER Timespan
    Optional duration used to derive EndDate from StartDate. Accepts either a
    TimeSpan value (for example `00:30:00`) or a numeric value interpreted as
    minutes. Cannot be used together with EndDate.

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

.PARAMETER IgnoreChangeArt
    When set, do not group or display `BK.SUBFL_changeart` values.

.PARAMETER ShowAllCategories
    When set, display all categories. When omitted, limits output to PATIENT, CASE,
    MERGE, and SPLIT categories.

.PARAMETER IncludeElgaRelevant
    When set (default), include `BK._ELGA_RELEVANT` in the grouping and display it as
    "Elga". Use `-IncludeElgaRelevant:$false` to omit this field.

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
    [object]$Timespan,

    [Parameter(Mandatory=$false)]
    [string]$ElasticTimeField = '@timestamp',

    [Parameter(Mandatory=$false)]
    [string]$ElasticUrl = 'https://es-obs.apps.zeus.wien.at/logs-orchestra.journals*/_search',

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
    [string]$MOVENO,

    [Parameter(Mandatory=$false)]
    [switch]$IgnoreChangeArt,

    [Parameter(Mandatory=$false)]
    [switch]$ShowAllCategories,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeElgaRelevant = $true
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

$includeEndDate = $PSBoundParameters.ContainsKey('EndDate')
if ($includeEndDate -and $PSBoundParameters.ContainsKey('Timespan')) {
    throw 'Specify either EndDate or Timespan, not both.'
}

if (-not $includeEndDate) {
    $effectiveTimespan = Resolve-EffectiveTimespan -Value $Timespan
    if ($StartDate) {
        $EndDate = $StartDate.Add($effectiveTimespan)
    } else {
        $EndDate = Get-Date
        $StartDate = $EndDate.Subtract($effectiveTimespan)
    }
    $includeEndDate = $true
}

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
        'CASE' { return 'Yellow' }
        'PATIENT' { return 'White' }
        'DIAGNOSIS' { return 'Gray' }
        'INSURANCE' { return 'Gray' }
        'MERGE' { return 'Blue' }
        'CLASSIFICATION' { return 'Gray' }
        'SPLIT' { return 'Blue' }
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

    $parsed = New-Object DateTime
    if ($value -is [System.DateTimeOffset]) { return $value.UtcDateTime }

    $stringValue = $value.ToString()
    if ([datetime]::TryParse(
        $stringValue,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$parsed
    )) {
        return $parsed
    }
    return $null
}

function Get-ElgaDisplayValue {
    param(
        [object]$Source
    )

    $value = Get-ElasticSourceValue -Source $Source -FieldPath 'BK._ELGA_RELEVANT'
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace($value)) {
        return '(none)'
    }

    return $value.ToString().ToLowerInvariant()
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
$caseFilterValue = if ($CASENO) { $CASENO.Trim() } else { $null }

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

$mustNot = @(
    @{ term = @{ 'WorkflowPattern' = 'REQ_RESP' } },
    @{ term = @{ 'BK.SUBFL_drop' = $true } }
)

if ($StartDate -or $includeEndDate) {
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
$caseFieldPaths = @('BK._CASENO_ISH','BK._CASENO_BC','BK._CASENO')
function Get-CaseValuesFromSource {
    param([object]$Source)

    $values = @()
    foreach ($field in $caseFieldPaths) {
        $value = Get-ElasticSourceValue -Source $Source -FieldPath $field
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $values += $value
        }
    }
    return $values
}

function ShouldIncludeCaseResult {
    param(
        [object]$Hit,
        [string]$TargetCase
    )

    if (-not $TargetCase) { return $true }

    $source = $Hit._source
    $caseValues = Get-CaseValuesFromSource -Source $source
    if (-not $caseValues -or $caseValues.Count -eq 0) {
        return $true
    }

    foreach ($caseValue in $caseValues) {
        if ($caseValue -eq $TargetCase) { return $true }
    }

    return $false
}

function Add-Hits {
    param([object[]]$Hits)
    foreach ($hit in $Hits) {
        if (-not (ShouldIncludeCaseResult -Hit $hit -TargetCase $caseFilterValue)) {
            continue
        }
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

if (-not $ShowAllCategories) {
    $allowedCategories = @('PATIENT','CASE','MERGE','SPLIT')
    $orderedHits = $orderedHits | Where-Object {
        $categoryValue = Get-ElasticSourceValue -Source $_._source -FieldPath 'BK.SUBFL_category'
        if (-not $categoryValue) { return $false }
        return $allowedCategories -contains $categoryValue.ToString().ToUpperInvariant()
    }
}

if ($pidValues.Count -gt 0) {
    Write-Host "PID(s): $($pidValues -join ', ')" -ForegroundColor Cyan
}

$headerMap = @{}
foreach ($hit in $orderedHits) {
    $src = $hit._source
    $caseIsh = Get-ElasticSourceValue -Source $src -FieldPath 'BK._CASENO_ISH'
    $aid = Get-ElasticSourceValue -Source $src -FieldPath 'BK._CASENO'
    $moveNo = Get-ElasticSourceValue -Source $src -FieldPath 'BK._MOVENO'
    $pidish = Get-ElasticSourceValue -Source $src -FieldPath 'BK._PID_ISH'
    $caseType = Get-ElasticSourceValue -Source $src -FieldPath 'BK._CASETYPE'
    $key = "${caseIsh}|${aid}|${moveNo}|${pidish}|${caseType}"
    if (-not $headerMap.ContainsKey($key)) {
        $headerMap[$key] = @{
            CASETYPE = if ($caseType) { $caseType } else { '-' }
            CASENO_ISH = if ($caseIsh) { $caseIsh } else { '-' }
            AID = if ($aid) { $aid } else { '-' }
            MOVENO = if ($moveNo) { $moveNo } else { '-' }
            PIDISH = if ($pidish) { $pidish } else { '-' }
        }
    }
}

if ($headerMap.Values.Count -gt 0) {
    $headerRows = foreach ($entry in $headerMap.Values) {        
        [PSCustomObject]@{
            CASETYPE = $entry.CASETYPE
            CASENO_ISH = $entry.CASENO_ISH
            AID = $entry.AID
            MOVENO = $entry.MOVENO
            PIDISH = $entry.PIDISH
        }
    }

    $headerRows | Where-Object { $_.CASENO_ISH -ne "-" -or $_.AID -ne "-" } | Sort-Object CASENO_ISH, MOVENO | Format-Table -AutoSize
}

$categoryList = [System.Collections.Generic.List[string]]::new()
$categorySet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($hit in $orderedHits) {
    $categoryValue = Get-ElasticSourceValue -Source $hit._source -FieldPath 'BK.SUBFL_category'
    if ([string]::IsNullOrWhiteSpace($categoryValue)) { continue }
    $normalizedCategory = $categoryValue.ToString().ToUpperInvariant()
    if ($categorySet.Add($normalizedCategory)) {
        $null = $categoryList.Add($normalizedCategory)
    }
}

if ($categoryList.Count -gt 0) {
    Write-Host "Occurring Categories: " -NoNewline
    for ($idx = 0; $idx -lt $categoryList.Count; $idx++) {
        $categoryName = $categoryList[$idx]
        $color = Get-CategoryColor -Category $categoryName
        Write-Host $categoryName -ForegroundColor $color -NoNewline
        if ($idx -lt ($categoryList.Count - 1)) {
            Write-Host " " -NoNewline
        }
    }
    Write-Host ""
}

$segments = @{}
$currentWorkflowPattern = ""
$counter = 0

foreach($hit in $orderedHits) {
    $workflowPattern = Get-ElasticSourceValue -Source $hit._source -FieldPath 'WorkflowPattern'

    if ($currentWorkflowPattern -ne $workflowPattern) {
        $currentWorkflowPattern = $workflowPattern
        $counter = $counter + 1
        if ($workflowPattern -eq "ERROR") {
            $segments[$counter] = @{ WorkflowPattern = "ERROR"; Hits = @() }
        }
        else {
            $segments[$counter] = @{ WorkflowPattern = "OK"; Hits = @() }
        }
    }

    $segments[$counter].Hits += $hit

}

for ($i=1; $i -le $counter; $i++) {
    $segmentHits = $segments[$i].Hits
    $segmentKey = $segments[$i].WorkflowPattern

    if (-not $segmentHits -or $segmentHits.Count -eq 0) {
        Write-Host "No $segmentKey records." -ForegroundColor DarkGray
        continue
    }

    $segmentTitle = if ($segmentKey -eq 'ERROR') { 'WorkflowPattern = ERROR' } else { 'WorkflowPattern <> ERROR' }
    #Write-Host "\n$segmentTitle" -ForegroundColor Magenta

    $grouped = $segmentHits | Group-Object -Property {
        $src = $_._source
        $caseIsh = Get-ElasticSourceValue -Source $src -FieldPath 'BK._CASENO_ISH'
        $pidIsh = Get-ElasticSourceValue -Source $src -FieldPath 'BK._PID_ISH'
        $pidIshOld = Get-ElasticSourceValue -Source $src -FieldPath 'BK._PID_ISH_OLD'
        $moveNo = Get-ElasticSourceValue -Source $src -FieldPath 'BK._MOVENO'
        $caseType = Get-ElasticSourceValue -Source $src -FieldPath 'BK._CASETYPE'
        $category = Get-ElasticSourceValue -Source $src -FieldPath 'BK.SUBFL_category'
        $subcat = Get-ElasticSourceValue -Source $src -FieldPath 'BK.SUBFL_subcategory'
        $pattern = Get-ElasticSourceValue -Source $src -FieldPath 'WorkflowPattern'
        $change = Get-ElasticSourceValue -Source $src -FieldPath 'BK.SUBFL_changeart'
        $elgaRelevant = if ($IncludeElgaRelevant) { Get-ElgaDisplayValue -Source $src } else { $null }

        $parts = @($caseIsh, $pidIsh, $caseType, $moveNo, $pidIshOld, $category, $subcat)
        if ($IncludeElgaRelevant) { $parts += $elgaRelevant }
        if (-not $IgnoreChangeArt) { $parts += $change }
        $parts += $pattern
        return ($parts -join '|')
    }

    foreach ($group in $grouped) {
        $parts = $group.Name -split '\|'
        $caseIsh = if ($parts.Count -gt 0 -and $parts[0]) { $parts[0] } else { '-' }
        $pidIsh = if ($parts.Count -gt 1 -and $parts[1]) { $parts[1] } else { '-' }
        $caseType = if ($parts.Count -gt 2 -and $parts[2]) { $parts[2] } else { '' }
        $moveNo = if ($parts.Count -gt 3 -and $parts[3]) { $parts[3] } else { '-' }
        $pidIshOld = if ($parts.Count -gt 4 -and $parts[4]) { $parts[4] } else { '' }
        if ($pidIshOld) { $pidIshOld = "from $pidIshOld" }
        $category = if ($parts.Count -gt 5 -and $parts[5]) { $parts[5] } else { '-' }
        $subcategory = if ($parts.Count -gt 6 -and $parts[6]) { $parts[6] } else { '-' }
        $elgaIndex = if ($IncludeElgaRelevant) { 7 } else { -1 }
        $changeIndex = if ($IgnoreChangeArt) { -1 } else { if ($IncludeElgaRelevant) { 8 } else { 7 } }
        $patternIndex = if ($IgnoreChangeArt) { if ($IncludeElgaRelevant) { 8 } else { 7 } } else { if ($IncludeElgaRelevant) { 9 } else { 8 } }
        $elgaRelevant = if ($IncludeElgaRelevant -and $elgaIndex -ge 0 -and $parts.Count -gt $elgaIndex -and $parts[$elgaIndex]) { $parts[$elgaIndex] } else { '' }
        $changeType = if ($changeIndex -ge 0 -and $parts.Count -gt $changeIndex -and $parts[$changeIndex]) { $parts[$changeIndex] } else { '-' }
        $pattern = if ($parts.Count -gt $patternIndex -and $parts[$patternIndex]) { $parts[$patternIndex] } else { '-' }

        $color = Get-CategoryColor -Category $category
        $elgaText = if ($IncludeElgaRelevant) { " | Elga $($elgaRelevant)" } else { '' }
        $changeText = if ($IgnoreChangeArt) { '' } else { " | Change $($changeType)" }
        $caseTypeSuffix = if ($caseType) { " $($caseType)" } else { '' }
        $moveText = if ($moveNo -and $moveNo -ne '-') { " $($moveNo)" } else { '' }
        $pidOldText = if ($pidIshOld) { " $($pidIshOld)" } else { '' }
        Write-Host "`nCase $($caseIsh)$($caseTypeSuffix)$($moveText) | PID $($pidIsh)$($pidOldText)$($elgaText) | $($category) / $($subcategory)$($changeText)" -ForegroundColor $color -NoNewline
        if ($pattern -eq "ERROR") {
            Write-host "  $($pattern)" -ForegroundColor Red
        }
        else {
            Write-Host ""
        }

        $inputs = @($group.Group | Where-Object { (Get-ElasticSourceValue -Source $_._source -FieldPath 'BK.SUBFL_stage') -eq 'Input' })
        if ($inputs -and $inputs.Count -gt 0) {
            $firstInput = Convert-ToTimestamp -Source $inputs[0]._source -TimeField $ElasticTimeField
            $lastInput = Convert-ToTimestamp -Source $inputs[-1]._source -TimeField $ElasticTimeField
            Write-Host "  Input: $($inputs.Count) item(s), $($firstInput.ToString('yyyy-MM-dd HH:mm:ss')) - $($lastInput.ToString('yyyy-MM-dd HH:mm:ss'))"
        } else {
            Write-Host '  Input: none'
        }

        $outputs = @($group.Group | Where-Object { (Get-ElasticSourceValue -Source $_._source -FieldPath 'BK.SUBFL_stage') -eq 'Output' })
        if ($outputs -and $outputs.Count -gt 0) {
            $partyGroups = $outputs | Group-Object -Property { Get-ElasticSourceValue -Source $_._source -FieldPath 'BK.SUBFL_party' }
            foreach ($party in $partyGroups) {
                $partyName = if ($party.Name) { $party.Name } else { '-' }
                $firstOut = Convert-ToTimestamp -Source $party.Group[0]._source -TimeField $ElasticTimeField
                $lastOut = Convert-ToTimestamp -Source $party.Group[-1]._source -TimeField $ElasticTimeField
                Write-Host "  Output -> $($partyName): $($party.Count) item(s), $($firstOut.ToString('yyyy-MM-dd HH:mm:ss')) - $($lastOut.ToString('yyyy-MM-dd HH:mm:ss'))"
            }
        } else {
            Write-Host '  Output: none'
        }
    }
}
Write-host ""
