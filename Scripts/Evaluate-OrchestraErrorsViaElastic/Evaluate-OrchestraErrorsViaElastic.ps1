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

    Elasticsearch paging is handled by the shared Invoke-ElasticScrollSearch helper
    located in Scripts/Common/ElasticSearchHelpers.ps1 so that scroll handling
    stays consistent across scripts. Depending on the chosen mode, matching
    documents can also be written to disk:
      - Overview : only show the summary table (default)
      - All      : create a formatted XML file for every error occurrence containing
                   the `Timestamp`, the original `ErrorMessage`, selected `Keys`,
                   and the message content embedded as XML nodes (optionally
                   filtered by `MessagePart`, which keeps elements whose
                   `@src` attribute starts with the supplied value)
      - OneOfType: create a formatted XML file for each unique error text containing
                   only the first matching error occurrence with the same structure as above.
    Output files include the first 20 characters of the normalized error text,
    the current date, and a counter to guarantee unique file names.

.PARAMETER StartDate
    Inclusive start date for @timestamp filtering (local time). Defaults to today's
    start if omitted. If neither EndDate nor Timespan is supplied, EndDate
    defaults to StartDate plus 15 minutes.

.PARAMETER EndDate
    Inclusive end date for @timestamp filtering (local time).

.PARAMETER Timespan
    Optional duration used to derive EndDate from StartDate. Accepts either a
    TimeSpan value (for example `00:30:00`) or a numeric value interpreted as
    minutes. Cannot be used together with EndDate.

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
    Path to a file containing the Elasticsearch API key. Defaults to '.\elastic.key'.

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

.PARAMETER MessagePart
    Optional message identifier. When provided, the XML files written by modes All or
    OneOfType include only the message nodes whose `@src` attribute starts with the
    supplied value (equivalent to using `starts-with(@src,'MessagePart')` in XPath),
    keeping the filtered nodes embedded as XML instead of the full message payload.

.PARAMETER BusinessKeys
    List of fields to extract from the Elasticsearch document and embed under the
    `Keys` property of generated files. Defaults to `BK._CASENO_ISH` and
    `BusinessCaseId`.

.EXAMPLE
    ./Evaluate-OrchestraErrorsViaElastic.ps1 -ScenarioName MyScenario `
        -Environment production -ElasticApiKeyPath ~/.eskey
#>
param(
    [Parameter(Mandatory=$false)]
    [datetime]$StartDate,

    [Parameter(Mandatory=$false)]
    [datetime]$EndDate,

    [Parameter(Mandatory=$false)]
    [object]$Timespan,

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
    [string]$ElasticApiKeyPath = (Join-Path -Path $PSScriptRoot -ChildPath 'elastic.key'),

    [Parameter(Mandatory=$false)]
    [string]$OutputDirectory = (Join-Path -Path $PSScriptRoot -ChildPath 'Output'),

    [Parameter(Mandatory=$false)]
    [ValidateSet('Overview','All','OneOfType')]
    [string]$Mode = 'Overview',

    [Parameter(Mandatory=$false)]
    [string]$Configuration = (Join-Path -Path $PSScriptRoot -ChildPath 'Evaluate-OrchestraErrorsViaElastic.config.json'),

    [Parameter(Mandatory=$false)]
    [string]$MessagePart,

    [Parameter(Mandatory=$false)]
    [string[]]$BusinessKeys = @('BK._CASENO_ISH','BusinessCaseId')
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

# Determine default StartDate/EndDate
$includeEnd = $PSBoundParameters.ContainsKey('EndDate')
if ($includeEnd -and $PSBoundParameters.ContainsKey('Timespan')) {
    throw 'Specify either EndDate or Timespan, not both.'
}

if (-not $PSBoundParameters.ContainsKey('StartDate')) {
    $StartDate = [datetime]::Today
}

if (-not $includeEnd) {
    $effectiveTimespan = Resolve-EffectiveTimespan -Value $Timespan
    $EndDate = $StartDate.Add($effectiveTimespan)
    $includeEnd = $true
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

$effectiveBusinessKeys = @()
if ($BusinessKeys) {
    foreach ($bk in $BusinessKeys) {
        if ([string]::IsNullOrWhiteSpace($bk)) { continue }
        if ($effectiveBusinessKeys -notcontains $bk) { $effectiveBusinessKeys += $bk }
    }
}

function Get-SafeErrorFragment {
    param(
        [string]$ErrorText
    )

    if ([string]::IsNullOrWhiteSpace($ErrorText)) { $ErrorText = 'error' }
    $fragment = if ($ErrorText.Length -gt 20) { $ErrorText.Substring(0,20) } else { $ErrorText }
    $safe = [regex]::Replace($fragment, '[^a-zA-Z0-9_-]', '_')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'error' }
    return $safe
}

function Get-KeysSnapshot {
    param(
        [object]$Keys
    )

    $snapshot = [ordered]@{}
    if ($null -ne $Keys) {
        foreach ($entry in $Keys.GetEnumerator()) {
            $snapshot[$entry.Key] = $entry.Value
        }
    }
    return $snapshot
}

function Get-MessagePartNodes {
    param(
        [System.Xml.XmlDocument]$Document,
        [string]$MessagePart
    )

    $matches = @()
    if (-not $Document -or [string]::IsNullOrEmpty($MessagePart)) {
        return $matches
    }

    $candidates = $Document.SelectNodes("//*[local-name()='Data' and @src]")
    if (-not $candidates) {
        return $matches
    }

    foreach ($candidate in $candidates) {
        $srcAttribute = $candidate.Attributes['src']
        if ($srcAttribute -and $srcAttribute.Value.StartsWith($MessagePart, [System.StringComparison]::Ordinal)) {
            $matches += $candidate.SelectNodes("*[1]")
        }
    }

    return $matches
}

function New-ErrorXmlDocument {
    param(
        [object]$Keys,
        [object]$Timestamp,
        [string]$ErrorMessage,
        [string]$MessageText,
        [string]$MessagePart
    )

    $doc = New-Object System.Xml.XmlDocument
    $declaration = $doc.CreateXmlDeclaration('1.0','utf-8',$null)
    $null = $doc.AppendChild($declaration)

    $root = $doc.CreateElement('Error')
    $null = $doc.AppendChild($root)

    $timestampValue = $null
    if ($null -ne $Timestamp) {
        if ($Timestamp -is [datetime]) {
            $timestampValue = $Timestamp.ToString('o')
        } elseif ($Timestamp -is [datetimeoffset]) {
            $timestampValue = $Timestamp.ToString('o')
        } else {
            $timestampValue = [string]$Timestamp
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($timestampValue)) {
        $timestampElement = $doc.CreateElement('Timestamp')
        $timestampElement.InnerText = $timestampValue
        $null = $root.AppendChild($timestampElement)
    }

    $errorElement = $doc.CreateElement('ErrorMessage')
    if ($null -ne $ErrorMessage) {
        $errorElement.InnerText = [string]$ErrorMessage
    }
    $null = $root.AppendChild($errorElement)

    $keysElement = $doc.CreateElement('Keys')
    $keysSnapshot = Get-KeysSnapshot -Keys $Keys
    foreach ($entry in $keysSnapshot.GetEnumerator()) {
        $keyElement = $doc.CreateElement('Key')
        $null = $keyElement.SetAttribute('Name', $entry.Key)
        if ($null -ne $entry.Value) {
            $keyElement.InnerText = [string]$entry.Value
        }
        $null = $keysElement.AppendChild($keyElement)
    }
    $null = $root.AppendChild($keysElement)

    $messageElement = $doc.CreateElement('Message')
    if (-not [string]::IsNullOrWhiteSpace($MessageText)) {
        try {
            $messageXml = New-Object System.Xml.XmlDocument
            $messageXml.LoadXml($MessageText)

            $selectedNodes = @()
            if ($MessagePart) {
                [array]$selectedNodes = Get-MessagePartNodes -Document $messageXml -MessagePart $MessagePart
            }

            if ($selectedNodes.Count -gt 0) {
                foreach ($node in $selectedNodes) {
                    if ($node) {
                        $imported = $doc.ImportNode($node, $true)
                        $null = $messageElement.AppendChild($imported)
                    }
                }
            } elseif ($messageXml.DocumentElement) {
                $documentElement = $messageXml.DocumentElement
                $childNodesAdded = $false
                if ($documentElement.LocalName -eq 'Message' -and $documentElement.HasChildNodes) {
                    foreach ($child in $documentElement.ChildNodes) {
                        $importedChild = $doc.ImportNode($child, $true)
                        $null = $messageElement.AppendChild($importedChild)
                        $childNodesAdded = $true
                    }
                }

                if (-not $childNodesAdded) {
                    $importedElement = $doc.ImportNode($documentElement, $true)
                    $null = $messageElement.AppendChild($importedElement)
                }
            } else {
                $messageElement.InnerText = $MessageText
            }
        } catch {
            $messageElement.InnerText = $MessageText
        }
    }
    $null = $root.AppendChild($messageElement)

    return $doc
}

function Save-FormattedXmlDocument {
    param(
        [System.Xml.XmlDocument]$Document,
        [string]$Path
    )

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.IndentChars = '    '
    $settings.NewLineChars = "`n"
    $settings.NewLineHandling = [System.Xml.NewLineHandling]::Replace
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)

    $writer = [System.Xml.XmlWriter]::Create($Path, $settings)
    try {
        $Document.Save($writer)
    } finally {
        if ($writer) { $writer.Dispose() }
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

$sourceFields = @(
    '@timestamp','ScenarioName','Environment','Instance','WorkflowPattern',
    'BK._STATUS_TEXT','BK._ERROR_TEXT','WorkflowMessage1','MessageData1'
) + $effectiveBusinessKeys

$sourceFields = $sourceFields | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

$body = @{
    size = 1000
    query = @{ bool = @{ filter = $filters } }
    _source = $sourceFields
} | ConvertTo-Json -Depth 6

# Retrieve search hits via the shared scroll helper
try {
    $rawHits = Invoke-ElasticScrollSearch -ElasticUrl $ElasticUrl -Headers $headers -Body $body -TimeoutSec 120
} catch {
    Write-Error $_.Exception.Message
    return
}

if ($rawHits.Count -eq 0) {
    Write-Warning 'No errors found for specified criteria.'
    return
}

# Extract error text, apply replacements, and build normalized items
$items = foreach ($r in $rawHits) {
    $src = $r._source
    $err = Get-ElasticSourceValue -Source $src -FieldPath 'BK._STATUS_TEXT'
    if ([string]::IsNullOrWhiteSpace($err)) {
        $err = Get-ElasticSourceValue -Source $src -FieldPath 'BK._ERROR_TEXT'
    }

    $workflowMessage = Get-ElasticSourceValue -Source $src -FieldPath 'WorkflowMessage1'
    if ([string]::IsNullOrWhiteSpace($err) -and $workflowMessage) {
        try {
            [xml]$xml = $workflowMessage
            $node = $xml.SelectSingleNode('//ErrorString')
            if ($node) { $err = $node.InnerText }
        } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($err)) { $err = '(unknown error)' }

    $originalError = $err
    $normalizedError = $originalError

    foreach ($rep in $replacements) {
        try {
            if (-not $rep.Condition -or [regex]::IsMatch($normalizedError, $rep.Condition)) {
                $normalizedError = [regex]::Replace($normalizedError, $rep.Pattern, $rep.Replacement)
            }
        } catch {}
    }

    $message = Get-ElasticSourceValue -Source $src -FieldPath 'MessageData1'

    $keyValues = [ordered]@{}
    foreach ($bk in $effectiveBusinessKeys) {
        $keyValues[$bk] = Get-ElasticSourceValue -Source $src -FieldPath $bk
    }

    $timestamp = Get-ElasticSourceValue -Source $src -FieldPath '@timestamp'

    [pscustomobject]@{
        NormalizedError = $normalizedError
        OriginalError   = $originalError
        Timestamp       = $timestamp
        Message         = $message
        Keys            = $keyValues
    }
}

$groups = $items | Group-Object -Property NormalizedError | Sort-Object Count -Descending

$groups | Select-Object @{Name='Count';Expression={$_.Count}}, @{Name='Error';Expression={$_.Name}} | Format-Table -AutoSize

# Handle output modes
if ($Mode -ne 'Overview') {
    if (-not (Test-Path $OutputDirectory)) {
        $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    }

    $datePrefix = Get-Date -Format 'yyyyMMdd'

    if ($Mode -eq 'All') {
        $counter = 1
        foreach ($it in $items) {
            $fragment = Get-SafeErrorFragment -ErrorText $it.NormalizedError
            $fileName = '{0}_{1:D4}_{2}.xml' -f $datePrefix, $counter, $fragment
            $filePath = Join-Path $OutputDirectory $fileName
            $document = New-ErrorXmlDocument -Keys $it.Keys -Timestamp $it.Timestamp -ErrorMessage $it.OriginalError -MessageText $it.Message -MessagePart $MessagePart
            Save-FormattedXmlDocument -Document $document -Path $filePath
            $counter++
        }
    } elseif ($Mode -eq 'OneOfType') {
        $counter = 1
        foreach ($g in $groups) {
            $fragment = Get-SafeErrorFragment -ErrorText $g.Name
            $fileName = '{0}_{1:D4}_{2}.xml' -f $datePrefix, $counter, $fragment
            $filePath = Join-Path $OutputDirectory $fileName
            $entry = $g.Group | Select-Object -First 1
            if (-not $entry) { continue }
            $document = New-ErrorXmlDocument -Keys $entry.Keys -Timestamp $entry.Timestamp -ErrorMessage $entry.OriginalError -MessageText $entry.Message -MessagePart $MessagePart
            Save-FormattedXmlDocument -Document $document -Path $filePath
            $counter++
        }
    }
}
