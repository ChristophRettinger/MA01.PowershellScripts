<#
.SYNOPSIS
    Retrieve and group Orchestra workflow errors from Elasticsearch.

.DESCRIPTION
    Queries Elasticsearch for failed Orchestra scenario executions within a time range.
    Filters by scenario name, environment, and instance. Extracts an error message
    from BK._STATUS_TEXT, BK._ERROR_TEXT, or the ErrorString element in
    WorkflowMessage1 (XML). The error text is normalized by applying regex
    replacements specified in an optional configuration file. Each replacement may
    include an optional `Condition` regex that must match the error text for the
    `Pattern`/`Replacement` pair to be applied. An overview table of unique errors
    and their occurrence counts is always written to the console.

    Depending on the chosen mode, matching documents can also be written to disk:
      - Overview : only show the summary table (default)
      - All      : create a JSON file for every error occurrence
      - OneOfType: create a JSON file for each unique error text containing all occurrences

.PARAMETER StartDate
    Inclusive start date for @timestamp filtering (local time). Defaults to today's
    start if omitted. If EndDate is not supplied, it is set to the end of StartDate's day.

.PARAMETER EndDate
    Inclusive end date for @timestamp filtering (local time).

.PARAMETER ScenarioName
    Name (or substring) of the scenario to filter in Elasticsearch.

.PARAMETER Environment
    Environment value to match (production, staging, testing). Defaults to production.

.PARAMETER Instance
    Specific server instance name to filter (optional).

.PARAMETER ElasticUrl
    Full Elasticsearch _search URL. Defaults to the logs-orchestra.journals index pattern.

.PARAMETER ElasticApiKey
    Elasticsearch API key string. If omitted, ElasticApiKeyPath is used.

.PARAMETER ElasticApiKeyPath
    Path to a file containing the Elasticsearch API key.

.PARAMETER OutputDirectory
    Directory where result files are written for modes All or OneOfType. Defaults to
    a folder named Output beside this script.

.PARAMETER Mode
    Output mode: Overview, All, or OneOfType. Defaults to Overview.

.PARAMETER Configuration
    Path to a JSON configuration file containing a property `RegexReplacements` with
    an array of objects `{ "Pattern": "...", "Replacement": "...", "Condition": "..." }`
    used to normalize error messages. `Condition` is an optional regex pattern that
    must match the error text for the replacement to be applied.

.EXAMPLE
    ./Evaluate-OrchestraErrorsViaElastic.ps1 -ScenarioName MyScenario `
        -Environment production -ElasticApiKeyPath ~/.eskey
#>
param(
    [Parameter(Mandatory=$false)]
    [datetime]$StartDate,

    [Parameter(Mandatory=$false)]
    [datetime]$EndDate,

    [Parameter(Mandatory=$true)]
    [string]$ScenarioName,

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
    [ValidateSet('Overview','All','OneOfType')]
    [string]$Mode = 'Overview',

    [Parameter(Mandatory=$false)]
    [string]$Configuration = (Join-Path -Path $PSScriptRoot -ChildPath 'Evaluate-OrchestraErrorsViaElastic.config.json')
)

# Determine default StartDate/EndDate (full day if StartDate omitted)
$includeEnd = $PSBoundParameters.ContainsKey('EndDate')
if (-not $PSBoundParameters.ContainsKey('StartDate')) {
    $StartDate = [datetime]::Today
    if (-not $includeEnd) {
        $EndDate = $StartDate.Date.AddDays(1).AddMilliseconds(-1)
        $includeEnd = $true
    }
}

# Build request headers with API key
$headers = @{}
if ($ElasticApiKey) {
    $headers['Authorization'] = "ApiKey $ElasticApiKey"
} elseif ($ElasticApiKeyPath -and (Test-Path $ElasticApiKeyPath)) {
    $k = Get-Content -Path $ElasticApiKeyPath -Raw
    $headers['Authorization'] = "ApiKey $k"
}

# Load regex replacements from configuration
$replacements = @()
if (Test-Path $Configuration) {
    try {
        $cfg = Get-Content -Path $Configuration -Raw | ConvertFrom-Json
        if ($cfg.RegexReplacements) { $replacements = $cfg.RegexReplacements }
    } catch {
        Write-Warning "Failed to read configuration: $_"
    }
}

# Compose Elasticsearch query filters
$scenarioFragment = $ScenarioName.Replace('*','\*').Replace('?','\?')
$scenarioWildcard = "*$scenarioFragment*"
$scenarioFilter = @{
    wildcard = @{
        'ScenarioName' = @{
            value = $scenarioWildcard
            case_insensitive = $true
        }
    }
}

$filters = @(
    $scenarioFilter,
    @{ term = @{ 'Environment' = $Environment } },
    @{ term = @{ 'WorkflowPattern' = 'ERROR' } }
)
if ($Instance) { $filters += @{ term = @{ 'Instance' = $Instance } } }

$range = @{ gte = $StartDate.ToUniversalTime().ToString('o') }
if ($includeEnd) { $range.lte = $EndDate.ToUniversalTime().ToString('o') }
$filters += @{ range = @{ '@timestamp' = $range } }

$body = @{
    size = 1000
    query = @{ bool = @{ filter = $filters } }
    _source = @(
        '@timestamp','ScenarioName','Environment','Instance','WorkflowPattern',
        'BK._STATUS_TEXT','BK._ERROR_TEXT','WorkflowMessage1'
    )
} | ConvertTo-Json -Depth 6

# Perform initial search with scrolling
$searchUri = if ($ElasticUrl -match '\?') { "$ElasticUrl&scroll=1m" } else { "$ElasticUrl?scroll=1m" }

$scrollUri = "$(([uri]$ElasticUrl).Scheme)://$(([uri]$ElasticUrl).Authority)/_search/scroll"

$rawHits = New-Object System.Collections.Generic.List[pscustomobject]
try {
    $resp = Invoke-RestMethod -Method Post -Uri $searchUri -Headers $headers -Body $body -TimeoutSec 120
    if ($resp.error) {
        Write-Error "Elasticsearch error: $($resp.error.type) - $($resp.error.reason)"
        return
    }
    $scrollId = $resp._scroll_id
    $hits = @($resp.hits.hits)
    foreach ($h in $hits) { $rawHits.Add($h) }
    while ($hits.Count -gt 0) {
        $scrollBody = @{ scroll = '1m'; scroll_id = $scrollId } | ConvertTo-Json
        $sresp = Invoke-RestMethod -Method Post -Uri $scrollUri -Headers $headers -Body $scrollBody -TimeoutSec 120
        if ($sresp.error) {
            Write-Error "Elasticsearch scroll error: $($sresp.error.type) - $($sresp.error.reason)"
            break
        }
        $scrollId = $sresp._scroll_id
        $hits = @($sresp.hits.hits)
        if ($hits.Count -eq 0) { break }
        foreach ($h in $hits) { $rawHits.Add($h) }
    }
} catch {
    Write-Error "Elasticsearch query failed: $_"
    return
}

if ($rawHits.Count -eq 0) {
    Write-Warning 'No errors found for specified criteria.'
    return
}

# Extract error text, apply replacements, and build normalized items
$items = foreach ($r in $rawHits) {
    $src = $r._source
    $err = $src.'BK._STATUS_TEXT'
    if ([string]::IsNullOrWhiteSpace($err)) { $err = $src.'BK._ERROR_TEXT' }
    if ([string]::IsNullOrWhiteSpace($err) -and $src.WorkflowMessage1) {
        try {
            [xml]$xml = $src.WorkflowMessage1
            $node = $xml.SelectSingleNode('//ErrorString')
            if ($node) { $err = $node.InnerText }
        } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($err)) { $err = '(unknown error)' }
    foreach ($rep in $replacements) {
        try {
            if (-not $rep.Condition -or [regex]::IsMatch($err, $rep.Condition)) {
                $err = [regex]::Replace($err, $rep.Pattern, $rep.Replacement)
            }
        } catch {}
    }
    [pscustomobject]@{
        Error  = $err
        Source = $src
    }
}

$groups = $items | Group-Object -Property Error | Sort-Object Count -Descending

$groups | Select-Object @{Name='ErrorText';Expression={$_.Name}}, @{Name='Instances';Expression={$_.Count}} | Format-Table -AutoSize

# Handle output modes
if ($Mode -ne 'Overview') {
    if (-not (Test-Path $OutputDirectory)) {
        $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    }

    if ($Mode -eq 'All') {
        $i = 0
        foreach ($it in $items) {
            $safe = [regex]::Replace($it.Error, '[^a-zA-Z0-9_-]', '_')
            $timestamp = Get-Date -Format 'yyyyMMddHHmmssfff'
            $file = Join-Path $OutputDirectory "$timestamp`_$i`_$safe.json"
            $it.Source | ConvertTo-Json -Depth 10 | Set-Content -Path $file -Encoding UTF8
            $i++
        }
    } elseif ($Mode -eq 'OneOfType') {
        foreach ($g in $groups) {
            $safe = [regex]::Replace($g.Name, '[^a-zA-Z0-9_-]', '_')
            $file = Join-Path $OutputDirectory "$safe.json"
            ($g.Group | ForEach-Object { $_.Source }) | ConvertTo-Json -Depth 10 | Set-Content -Path $file -Encoding UTF8
        }
    }
}
