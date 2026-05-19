<#
.SYNOPSIS
    Query SUBFL records in Elasticsearch and optionally resend them to a target endpoint.

.DESCRIPTION
    Loads Elasticsearch records for a date range and optional filters (ScenarioName,
    ProcessName, case/patient/business IDs, stage/category fields, and environment metadata).

    Action modes:
    - Query: only reports counts and timestamp ranges grouped by ScenarioName.
    - Test: performs full resend preparation but skips HTTP transmission.
    - Send: posts MessageData1 to a target endpoint from ServerConfig.psd1.
    - Curl: writes one curl command per prepared resend record to an output file.

    For resend actions, the script builds SourceInfoMsg and BuKeysString headers,
    supports envelope cleanup, batching, delay handling, single-step mode, and
    keyboard controls (P pause, R resume, S single-step, X exit).

    When multiple records share the same BusinessCaseId/MSGID, only the oldest
    record (lowest @timestamp) is kept for processing.

.EXAMPLE
    .\Invoke-ElasticResend.ps1 -Action Query -BusinessCaseId 021000005865627450708147
    Gets information for a single BusinessCaseId/MSGID. If a result is found, it can be sent later.

.EXAMPLE
    .\Invoke-ElasticResend.ps1 -StartDate "2026-05-01 00:00:00" -EndDate "2026-05-21 00:00:00" -ScenarioName *3287 -WorkflowPattern ERROR
    Searches for errors of a specific scenario in a given time range.

.EXAMPLE
    .\Invoke-ElasticResend.ps1 -Action Send -Target prod01-wsk -BusinessCaseId 011000014048434700509727,011000014048382560508756 -TargetSubId 123
    Sends two specific records to prod01-wsk, but only to subscription 123 (when it is resolved).

.EXAMPLE
    .\Invoke-ElasticResend.ps1 -Action Send -Target prod01-wsk -CaseNo "92134461    26080726" -ScenarioName *HCM_empfangen* -ProcessState Test -Mode Curl -OutputDirectory output
    Creates a text file with curl statements for prod01-wsk. Received HCM messages are replayed with ProcessState set to Test.

.PARAMETER StartDate
    Inclusive start timestamp for Elasticsearch filtering (interpreted as local time unless explicitly marked as UTC). Defaults to now minus 7 days.

.PARAMETER EndDate
    Inclusive end timestamp for Elasticsearch filtering (interpreted as local time unless explicitly marked as UTC). Defaults to now.

.PARAMETER ElasticUrl
    Elasticsearch _search endpoint URL.

.PARAMETER ResetCredentials
    Discard the saved Elasticsearch credential and prompt for a new API key.

.PARAMETER ScenarioName
    ScenarioName wildcard filter. Defaults to '*SUBFL*'. The default value only applies when no explicit filter argument was provided.

.PARAMETER ProcessName
    ProcessName wildcard filter.

.PARAMETER CaseNo
    Array filter for case numbers; accepts repeated or comma-separated values.

.PARAMETER PatientId
    Array filter for patient IDs; accepts repeated or comma-separated values.

.PARAMETER SubId
    Array filter for subscription IDs (BK.SUBFL_subid); accepts repeated or comma-separated values.

.PARAMETER BusinessCaseId
    Array filter for MSGID/BusinessCaseId; accepts repeated or comma-separated values and preserves leading zeros.

.PARAMETER Stage
    BK.SUBFL_stage filter (Input, Map, Resolve, Output).

.PARAMETER WorkflowPattern
    WorkflowPattern filter. Accepts literal values or wildcard expressions.
    Note: WorkflowPattern alone does not satisfy the mandatory filter requirement.

.PARAMETER ErrorOnly
    Convenience switch to filter WorkflowPattern to 'ERROR'. Cannot be combined with WorkflowPattern values other than 'ERROR'.

.PARAMETER Category
    BK.SUBFL_category filter values.

.PARAMETER Subcategory
    BK.SUBFL_subcategory filter values.

.PARAMETER HcmMsgEvent
    BK._HCMMSGEVENT filter values.

.PARAMETER Instance
    Instance filter values. Instance alone does not satisfy the mandatory filter requirement.

.PARAMETER Environment
    Environment filter values. Valid options: development, testing, staging, production.
    Environment alone does not satisfy the mandatory filter requirement.

.PARAMETER Action
    Query, Send, Test, or ShowQuery (prints the Elasticsearch request and exits). Defaults to Query.

.PARAMETER Target
    Target name resolved from ServerConfig.psd1 (OrchestraTargets); supports tab completion from configured server names.

.PARAMETER BatchSize
    Number of records processed per batch. Defaults to 100.

.PARAMETER DelayBetweenBatches
    Delay in seconds between batches for Batch mode. Defaults to 1.

.PARAMETER TargetParty
    Adds SourceInfoMsg SubscriptionFilterParty when specified.

.PARAMETER TargetSubId
    Adds SourceInfoMsg SubscriptionFilterId when specified.

.PARAMETER CleanupEnvelope
    When set, removes Envelope/Data nodes where src != Input before send/test.

.PARAMETER NewBusinessCaseIds
    When set, clears _MSGID header.

.PARAMETER ProcessState
    ProcessState override for SourceInfoMsg when explicitly provided.
    If omitted, ProcessState from SourceInfo is used when available; otherwise 'Original'.

.PARAMETER OutputDirectory
    Optional output directory for logs.

.PARAMETER Replacements
    Optional search/replace list applied to MessageData1 and business-key values before replay.
    Provide an even number of values where each pair is SearchPattern,ReplacementValue.
    Replacements use regular-expression semantics.

.PARAMETER Mode
    Batch, All, Single, or Curl processing behavior. Defaults to Batch.
    Curl mode writes curl commands to a file in OutputDirectory and does not emit
    per-record curl statements to the console.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [datetime]$StartDate = (Get-Date).AddDays(-7),

    [Parameter(Mandatory=$false)]
    [datetime]$EndDate = (Get-Date),

    [Parameter(Mandatory=$false)]
    [string]$ElasticUrl = '',

    [Parameter(Mandatory=$false)]
    [switch]$ResetCredentials,

    [Parameter(Mandatory=$false)]
    [string]$ScenarioName = '*SUBFL*',

    [Parameter(Mandatory=$false)]
    [string]$ProcessName,

    [Parameter(Mandatory=$false)]
    [string[]]$CaseNo,

    [Parameter(Mandatory=$false)]
    [string[]]$PatientId,

    [Parameter(Mandatory=$false)]
    [string[]]$SubId,

    [Alias('MSGID')]
    [Parameter(Mandatory=$false)]
    [string[]]$BusinessCaseId,

    [ValidateSet('Input','Map','Resolve','Output')]
    [Parameter(Mandatory=$false)]
    [string]$Stage,

    [Parameter(Mandatory=$false)]
    [string]$WorkflowPattern,

    [Parameter(Mandatory=$false)]
    [switch]$ErrorOnly,

    [Parameter(Mandatory=$false)]
    [string[]]$Category,

    [Parameter(Mandatory=$false)]
    [string[]]$Subcategory,

    [Parameter(Mandatory=$false)]
    [string[]]$HcmMsgEvent,

    [Parameter(Mandatory=$false)]
    [string[]]$Instance,

    [ValidateSet('development','testing','staging','production', IgnoreCase=$true)]
    [Parameter(Mandatory=$false)]
    [string[]]$Environment,

    [ValidateSet('Query','Send','Test','ShowQuery')]
    [Parameter(Mandatory=$false)]
    [string]$Action = 'Query',

    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

        $sharedDir = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Common'
        $serverConfigPath = Join-Path -Path $sharedDir -ChildPath 'ServerConfig.ps1'
        if (-not (Test-Path -Path $serverConfigPath)) { return }
        . $serverConfigPath
        $cfg = Get-ServerConfig

        $cfg.OrchestraTargets.Keys |
            Where-Object { $_ -like "${wordToComplete}*" } |
            Sort-Object |
            ForEach-Object {
                $env = $cfg.OrchestraTargets[$_].Environment
                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', "$_ ($($env))")
            }
    })]
    [Parameter(Mandatory=$false)]
    [string]$Target,

    [Parameter(Mandatory=$false)]
    [int]$BatchSize = 100,

    [Parameter(Mandatory=$false)]
    [int]$DelayBetweenBatches = 1,

    [Parameter(Mandatory=$false)]
    [string]$TargetParty,

    [Parameter(Mandatory=$false)]
    [string]$TargetSubId,

    [Parameter(Mandatory=$false)]
    [bool]$CleanupEnvelope = $true,

    [Parameter(Mandatory=$false)]
    [switch]$NewBusinessCaseIds,

    [Parameter(Mandatory=$false)]
    [string]$ProcessState = 'Original',

    [Parameter(Mandatory=$false)]
    [string]$OutputDirectory,

    [Parameter(Mandatory=$false)]
    [string[]]$Replacements,

    [ValidateSet('Batch','All','Single','Curl')]
    [Parameter(Mandatory=$false)]
    [string]$Mode = 'Batch'
)

$sharedHelpersDirectory = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Common'
$sharedHelpersPath = Join-Path -Path $sharedHelpersDirectory -ChildPath 'ElasticSearchHelpers.ps1'
if (-not (Test-Path -Path $sharedHelpersPath)) {
    throw "Shared Elastic helper not found at '$sharedHelpersPath'."
}
. $sharedHelpersPath
. (Join-Path $sharedHelpersDirectory 'ServerConfig.ps1')

function Initialize-SystemXmlLinq {
    if ($null -ne ([type]::GetType('System.Xml.Linq.XDocument, System.Xml.Linq', $false))) {
        return
    }

    try {
        Add-Type -AssemblyName 'System.Xml.Linq' -ErrorAction Stop
    } catch {
        $loadedAssembly = [Reflection.Assembly]::LoadWithPartialName('System.Xml.Linq')
        if ($null -eq $loadedAssembly) {
            Write-Warning 'System.Xml.Linq could not be loaded; CleanupEnvelope may be skipped.'
        }
    }
}

function ConvertTo-BashSingleQuotedValue {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return "''"
    }

    $escaped = "$Value" -replace "'", "\'"
    return "'$escaped'"
}

function ConvertTo-CurlCommand {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [Parameter(Mandatory=$true)][hashtable]$Headers,
        [Parameter(Mandatory=$true)][string]$Body
    )

    $headerParts = [System.Collections.Generic.List[string]]::new()
    foreach ($headerName in ($Headers.Keys | Sort-Object)) {
        $headerValue = "$(($Headers[$headerName]))"
        $headerLine = "{0}: {1}" -f $headerName, $headerValue
        $headerParts.Add("--header $(ConvertTo-BashSingleQuotedValue -Value $headerLine)") | Out-Null
    }
    $headerParts.Add("--header $(ConvertTo-BashSingleQuotedValue -Value 'Content-Type: text/xml; charset=utf-8')") | Out-Null

    $commandParts = [System.Collections.Generic.List[string]]::new()
    $commandParts.Add('curl --silent --show-error --location --request POST') | Out-Null
    $commandParts.Add("--url $(ConvertTo-BashSingleQuotedValue -Value $Uri)") | Out-Null
    foreach ($headerPart in $headerParts) {
        $commandParts.Add($headerPart) | Out-Null
    }
    $commandParts.Add("--data-raw $(ConvertTo-BashSingleQuotedValue -Value $Body)") | Out-Null

    return ($commandParts -join ' ')
}

function Write-RunLog {
    param(
        [string]$Level,
        [string]$Message
    )

    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $line = "[$stamp] [$Level] $Message"
    $levelColor = switch ($Level) {
        'ERROR' { 'Red'; break }
        'WARN' { 'Yellow'; break }
        default { 'Gray'; break }
    }

    Write-Host $line -ForegroundColor $levelColor
    if ($script:LogFilePath) {
        Add-Content -Path $script:LogFilePath -Value $line -Encoding UTF8
    }
}

function Convert-DateTimeToUtcWindow {
    param(
        [Parameter(Mandatory=$true)]
        [datetime]$DateTimeValue
    )

    $inputValue = $DateTimeValue
    $effectiveValue = $DateTimeValue
    if ($effectiveValue.Kind -eq [System.DateTimeKind]::Unspecified) {
        $effectiveValue = [System.DateTime]::SpecifyKind($effectiveValue, [System.DateTimeKind]::Local)
    }

    $localValue = if ($effectiveValue.Kind -eq [System.DateTimeKind]::Local) { $effectiveValue } else { $effectiveValue.ToLocalTime() }
    $utcValue = $effectiveValue.ToUniversalTime()

    return [pscustomobject]@{
        Input = $inputValue
        InputIso = $inputValue.ToString('o')
        Local = $localValue
        LocalIso = $localValue.ToString('o')
        Utc = $utcValue
        UtcIso = $utcValue.ToString('o')
    }
}

function ConvertTo-ElasticTermsFilter {
    param(
        [string]$Field,
        [string[]]$Values
    )

    $items = @($Values | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") })
    if ($items.Count -eq 0) {
        return $null
    }

    return @{ terms = @{ $Field = $items } }
}

function Format-FilterValues {
    param(
        [string[]]$Values
    )

    if (-not $Values) {
        return @()
    }

    $normalized = [System.Collections.Generic.List[string]]::new()
    foreach ($value in $Values) {
        if ([string]::IsNullOrWhiteSpace("$value")) {
            continue
        }

        foreach ($part in ("$value" -split ',')) {
            $trimmed = $part.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                $normalized.Add($trimmed)
            }
        }
    }

    return @($normalized | Select-Object -Unique)
}

function Resolve-RawBusinessCaseIdsFromInvocation ($MyInvocation) {
    $invocationLine = "$($MyInvocation.Line)"
    if ([string]::IsNullOrWhiteSpace($invocationLine)) {
        return @()
    }

    $match = [regex]::Match(
        $invocationLine,
        '(?is)-(?:BusinessCaseId|MSGID)\s+(?<values>.+?)(?=\s+-[A-Za-z][A-Za-z0-9]*\b|\s*$)'
    )
    if (-not $match.Success) {
        return @()
    }

    $rawSegment = $match.Groups['values'].Value
    $rawItems = [System.Collections.Generic.List[string]]::new()
    foreach ($rawPart in ($rawSegment -split ',')) {
        $trimmed = $rawPart.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        if (($trimmed.StartsWith("'") -and $trimmed.EndsWith("'")) -or ($trimmed.StartsWith('"') -and $trimmed.EndsWith('"'))) {
            $trimmed = $trimmed.Substring(1, $trimmed.Length - 2)
        }

        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            $rawItems.Add($trimmed)
        }
    }

    return @($rawItems)
}


function Get-RecordBusinessCaseKey {
    param(
        [Parameter(Mandatory=$true)]
        [psobject]$Source
    )

    $businessCaseValue = "$(Get-ElasticSourceValue -Source $Source -FieldPath 'BusinessCaseId')"
    if (-not [string]::IsNullOrWhiteSpace($businessCaseValue)) {
        return $businessCaseValue
    }

    $msgIdValue = "$(Get-ElasticSourceValue -Source $Source -FieldPath 'MSGID')"
    if (-not [string]::IsNullOrWhiteSpace($msgIdValue)) {
        return $msgIdValue
    }

    return $null
}

function Resolve-TargetDefinition {
    param([string]$TargetName)

    $cfg = Get-ServerConfig
    $entry = $cfg.OrchestraTargets[$TargetName]
    if (-not $entry) {
        throw "Target '$TargetName' not found in ServerConfig.psd1 (OrchestraTargets)"
    }

    if ([string]::IsNullOrWhiteSpace($entry.BaseUrl)) {
        throw "Target '$TargetName' has no BaseUrl in ServerConfig.psd1."
    }

    return "$($entry.BaseUrl)$($cfg.OrchestraReinjectPath)"
}

function Get-SourceInfoXml {
    param(
        [object]$Source,
        [string]$SubscriptionFilterParty,
        [string]$SubscriptionFilterId,
        [string]$FallbackProcessState,
        [bool]$UseProvidedProcessState = $false,
        [string]$TargetName
    )

    $messageData2 = Get-ElasticSourceValue -Source $Source -FieldPath 'MessageData2'
    $sourceInfo = $null

    if (-not [string]::IsNullOrWhiteSpace("$messageData2")) {
        try {
            [xml]$xml = $messageData2
            if ($xml.DocumentElement -and $xml.DocumentElement.LocalName -eq 'SourceInfo') {
                $sourceInfo = $xml
            }
        } catch {
            # Ignore invalid XML content
        }
    }

    $partyValue = if ($sourceInfo) { "$($sourceInfo.SourceInfo.Party)" } else { 'Unknown' }
    $receiveMsgIdValue = if ($sourceInfo) { "$($sourceInfo.SourceInfo.ReceiveMsgId)" } else { '' }
    $receiveTimeValue = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fff')
    $messageTypeValue = if ($sourceInfo -and $sourceInfo.SourceInfo.MessageType) { "$($sourceInfo.SourceInfo.MessageType)" } else { "$(Get-ElasticSourceValue -Source $Source -FieldPath 'BK.SUBFL_messagetype')" }

    $stageValue = if ($Stage) { $Stage } else { "$(Get-ElasticSourceValue -Source $Source -FieldPath 'BK.SUBFL_stage')" }
    $receiveScenarioValue = if ($sourceInfo -and $sourceInfo.SourceInfo.ReceiveScenario) {
        "$($sourceInfo.SourceInfo.ReceiveScenario)"
    } elseif ($stageValue -eq 'Input') {
        "$(Get-ElasticSourceValue -Source $Source -FieldPath 'ScenarioName')"
    } else {
        ''
    }

    $receiveProcessModelValue = if ($sourceInfo -and $sourceInfo.SourceInfo.ReceiveProcessModel) {
        "$($sourceInfo.SourceInfo.ReceiveProcessModel)"
    } elseif ($stageValue -eq 'Input') {
        "$(Get-ElasticSourceValue -Source $Source -FieldPath 'ProcessName')"
    } else {
        ''
    }

    $processStateValue = if ($UseProvidedProcessState) { $FallbackProcessState } elseif ($sourceInfo -and $sourceInfo.SourceInfo.ProcessState) { "$($sourceInfo.SourceInfo.ProcessState)" } else { $FallbackProcessState }
    $instanceValue = if ($TargetName) { $TargetName } elseif ($sourceInfo -and $sourceInfo.SourceInfo.Instance) { "$($sourceInfo.SourceInfo.Instance)" } else { '' }

    $doc = New-Object System.Xml.XmlDocument
    $decl = $doc.CreateXmlDeclaration('1.0', 'UTF-8', $null)
    $null = $doc.AppendChild($decl)

    $root = $doc.CreateElement('SourceInfo')
    $null = $doc.AppendChild($root)

    foreach ($tuple in @(
        @('Party', $partyValue),
        @('ReceiveMsgId', $receiveMsgIdValue),
        @('ReceiveTime', $receiveTimeValue),
        @('MessageType', $messageTypeValue),
        @('MessageFormat', 'XML'),
        @('ReceiveScenario', $receiveScenarioValue),
        @('ReceiveProcessModel', $receiveProcessModelValue),
        @('ProcessState', $processStateValue),
        @('Instance', $instanceValue)
    )) {
        $elem = $doc.CreateElement($tuple[0])
        $elem.InnerText = "$($tuple[1])"
        $null = $root.AppendChild($elem)
    }

    if (-not [string]::IsNullOrWhiteSpace($SubscriptionFilterParty)) {
        $subscriptionFilterPartyElement = $doc.CreateElement('SubscriptionFilterParty')
        $subscriptionFilterPartyElement.InnerText = $SubscriptionFilterParty
        $null = $root.AppendChild($subscriptionFilterPartyElement)
    }

    if (-not [string]::IsNullOrWhiteSpace($SubscriptionFilterId)) {
        $subscriptionFilterIdElement = $doc.CreateElement('SubscriptionFilterId')
        $subscriptionFilterIdElement.InnerText = $SubscriptionFilterId
        $null = $root.AppendChild($subscriptionFilterIdElement)
    }

    $xmlString = $doc.OuterXml
    $base64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($xmlString))
    return [System.Net.WebUtility]::UrlEncode($base64)
}

function ConvertTo-BusinessKeysString {
    param(
        [object]$Source,
        [object[]]$ReplacementPairs
    )

    $excludedKeys = @(
        'SUBFL_stage','SUBFL_party','SUBFL_name','SUBFL_history','SUBFL_subid',
        'SUBFL_subid_list','SUBFL_targetid','SUBFL_workflow','SUBFL_senddate','_INSTITUTION_LONG'
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($prop in $Source.BK.PSObject.Properties) {
        if ($excludedKeys -contains $prop.Name) { continue }

        $value = if ($null -eq $prop.Value) { '' } else { "$($prop.Value)" }
        $value = Invoke-RegexReplacements -InputText $value -ReplacementPairs $ReplacementPairs
        $parts.Add("$($prop.Name):$value") | Out-Null
    }

    $businessKeysRaw = ($parts -join '|').Replace('&colon;', ':').Replace('&pipe;', '|')
	$base64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($businessKeysRaw))
    return [System.Net.WebUtility]::UrlEncode($base64)
}

function Clear-EnvelopeData {
    param([string]$XmlText)

    if ([string]::IsNullOrWhiteSpace($XmlText)) {
        return $XmlText
    }

    try {
        $doc = [System.Xml.Linq.XDocument]::Parse($XmlText)
        if ($doc.Root -and $doc.Root.Name.LocalName -eq 'Envelope') {
            $toRemove = @($doc.Root.Elements() | Where-Object {
                $_.Name.LocalName -eq 'Data' -and "$($_.Attribute('src').Value)" -ne 'Input'
            })
            foreach ($node in $toRemove) {
                $node.Remove()
            }
            return $doc.ToString([System.Xml.Linq.SaveOptions]::DisableFormatting)
        }
    } catch {
        Write-RunLog -Level 'WARN' -Message "CleanupEnvelope skipped due to invalid XML: $($_.Exception.Message)"
    }

    return $XmlText
}

function Get-ControlAction {
    if (-not [Console]::IsInputRedirected) {
        while ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            $char = "$($key.KeyChar)".ToUpperInvariant()
            if ($char -eq 'P') { return 'Pause' }
            if ($char -eq 'R') { return 'Resume' }
            if ($char -eq 'S') { return 'Single' }
            if ($char -eq '+') { return 'DelayIncrease' }
            if ($char -eq '-') { return 'DelayDecrease' }
            if ($key.Key -eq [ConsoleKey]::Add -or $key.Key -eq [ConsoleKey]::OemPlus) { return 'DelayIncrease' }
            if ($key.Key -eq [ConsoleKey]::Subtract -or $key.Key -eq [ConsoleKey]::OemMinus) { return 'DelayDecrease' }
            if ($char -eq 'X' -or $key.Key -eq [ConsoleKey]::C -and $key.Modifiers -band [ConsoleModifiers]::Control) { return 'Exit' }
        }
    }

    return $null
}

function Update-ResendProgressStatus {
    param(
        [int]$IndexDisplay,
        [int]$TotalRecords,
        [bool]$SingleStepMode,
        [bool]$PausedState,
        [int]$BatchSizeValue,
        [int]$DelaySeconds,
        [int]$PercentComplete
    )

    $modeHint = if ($SingleStepMode) { 'single-step' } elseif ($PausedState) { 'paused' } else { 'running' }
    $delayDisplay = "{0}s" -f ([Math]::Max(0, $DelaySeconds))
    $statusLine = "Record $IndexDisplay/$TotalRecords | $modeHint | Bsz:$BatchSizeValue Dly:$delayDisplay | P=pause R=resume S=step +/-=delay±5s X=stop"
    Write-Progress -Id 2 -Activity 'Resend processing' -Status $statusLine -PercentComplete $PercentComplete
}

function ConvertTo-ReplacementPairs {
    param([string[]]$Values)

    if (-not $Values -or $Values.Count -eq 0) {
        return @()
    }

    if (($Values.Count % 2) -ne 0) {
        throw 'Replacements requires an even number of values (search/replace pairs).'
    }

    $pairs = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Values.Count; $i += 2) {
        $searchPattern = if ($null -eq $Values[$i]) { '' } else { "$($Values[$i])" }
        $replacementValue = if ($null -eq $Values[$i + 1]) { '' } else { "$($Values[$i + 1])" }
        $pairs.Add([pscustomobject]@{
            SearchPattern = $searchPattern
            ReplacementValue = $replacementValue
        }) | Out-Null
    }

    return @($pairs)
}

function Invoke-RegexReplacements {
    param(
        [AllowNull()][string]$InputText,
        [object[]]$ReplacementPairs
    )

    if ($null -eq $InputText -or -not $ReplacementPairs -or $ReplacementPairs.Count -eq 0) {
        return $InputText
    }

    $updated = $InputText
    foreach ($pair in $ReplacementPairs) {
        try {
            $updated = [regex]::Replace($updated, "$($pair.SearchPattern)", "$($pair.ReplacementValue)")
        } catch {
            throw "Invalid replacement pattern '$($pair.SearchPattern)': $($_.Exception.Message)"
        }
    }

    return $updated
}

<#
════════════════════════════════════════════════════════
  SCRIPT BODY
════════════════════════════════════════════════════════
#>

Initialize-SystemXmlLinq

$script:LogFilePath = $null
$script:CurlOutputFilePath = $null
$script:SuccessLog = [System.Collections.Generic.List[string]]::new()
$script:ErrorLog = [System.Collections.Generic.List[string]]::new()

if ($null -ne $WorkflowPattern) {
    $WorkflowPattern = $WorkflowPattern.Trim()
    if ([string]::IsNullOrWhiteSpace($WorkflowPattern)) {
        $WorkflowPattern = $null
    }
}

if ($ErrorOnly.IsPresent) {
    $errorPatternValue = 'ERROR'
    if (-not [string]::IsNullOrWhiteSpace($WorkflowPattern) -and -not $WorkflowPattern.Equals($errorPatternValue, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '-ErrorOnly cannot be combined with WorkflowPattern values other than ERROR.'
    }
    $WorkflowPattern = $errorPatternValue
}

if ($StartDate -gt $EndDate) {
    throw 'StartDate must be less than or equal to EndDate.'
}

$startWindow = Convert-DateTimeToUtcWindow -DateTime $StartDate
$endWindow = Convert-DateTimeToUtcWindow -DateTime $EndDate

if ($BusinessCaseId -and -not $PSBoundParameters.ContainsKey('Stage')) {
    $Stage = 'Input'
}

$CaseNo = Format-FilterValues -Values $CaseNo
$PatientId = Format-FilterValues -Values $PatientId
$SubId = Format-FilterValues -Values $SubId
$BusinessCaseId = Format-FilterValues -Values $BusinessCaseId
$rawBusinessCaseIds = Resolve-RawBusinessCaseIdsFromInvocation $MyInvocation
if ($rawBusinessCaseIds.Count -gt 0 -and $rawBusinessCaseIds.Count -eq $BusinessCaseId.Count) {
    $BusinessCaseId = Format-FilterValues -Values $rawBusinessCaseIds
}
$Category = Format-FilterValues -Values $Category
$Subcategory = Format-FilterValues -Values $Subcategory
$HcmMsgEvent = Format-FilterValues -Values $HcmMsgEvent
$Instance = Format-FilterValues -Values $Instance
$EnvironmentFilters = Format-FilterValues -Values $Environment
$ReplacementPairs = ConvertTo-ReplacementPairs -Values $Replacements

$effectiveFilterCount = 0
if (-not [string]::IsNullOrWhiteSpace($ScenarioName)) { $effectiveFilterCount++ }
if (-not [string]::IsNullOrWhiteSpace($ProcessName)) { $effectiveFilterCount++ }
foreach ($arr in @($CaseNo,$PatientId,$SubId,$BusinessCaseId,$Category,$Subcategory,$HcmMsgEvent,$Instance,$EnvironmentFilters)) {
    if ($arr -and @($arr | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") }).Count -gt 0) { $effectiveFilterCount++ }
}
if ($Stage) { $effectiveFilterCount++ }
if (-not [string]::IsNullOrWhiteSpace($WorkflowPattern)) { $effectiveFilterCount++ }
$helpScriptPath = if ([string]::IsNullOrWhiteSpace($PSCommandPath)) { $MyInvocation.MyCommand.Path } else { $PSCommandPath }

$helpScriptPath
if ($PSBoundParameters.Count -eq 0 -or $effectiveFilterCount -eq 0) {
    Get-Help $helpScriptPath
    return
}

$hasRequiredFilter = $false
foreach ($requiredParameterName in @('StartDate','EndDate','ScenarioName','ProcessName','CaseNo','PatientId','SubId','BusinessCaseId','Stage','Category','Subcategory','HcmMsgEvent')) {
    if ($PSBoundParameters.ContainsKey($requiredParameterName)) {
        $hasRequiredFilter = $true
        break
    }
}

if (-not $hasRequiredFilter) {
    Get-Help $helpScriptPath -Detailed
    throw 'At least one filter argument is required (for example StartDate/EndDate, ScenarioName, ProcessName, CaseNo, PatientId, SubId, MSGID/BusinessCaseId, Stage, Category, Subcategory, or HcmMsgEvent). Instance, Environment, and WorkflowPattern are not sufficient by themselves.'
}

if ($Mode -eq 'Curl') {
    if ($Action -in @('Query','ShowQuery')) {
        throw 'Mode Curl requires Action Send or Test.'
    }
    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        throw 'OutputDirectory is required when Mode is Curl.'
    }
}

if ($OutputDirectory) {
    if (-not (Test-Path -Path $OutputDirectory)) {
        $null = New-Item -Path $OutputDirectory -ItemType Directory -Force
    }
    $script:LogFilePath = Join-Path -Path $OutputDirectory -ChildPath ("Invoke-ElasticResend_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -Path $script:LogFilePath -ItemType File -Force | Out-Null

    if ($Mode -eq 'Curl') {
        $script:CurlOutputFilePath = Join-Path -Path $OutputDirectory -ChildPath ("Invoke-ElasticResend_{0}.curl.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        New-Item -Path $script:CurlOutputFilePath -ItemType File -Force | Out-Null
    }
}

if ($ReplacementPairs.Count -gt 0) {
    Write-RunLog -Level 'INFO' -Message "Configured $($ReplacementPairs.Count) replacement pair(s) for payload and business-key value updates."
}

if (($Action -eq 'Send' -or $Action -eq 'Test') -and [string]::IsNullOrWhiteSpace($Target)) {
    throw 'Target is required for Action Send or Test.'
}

if ([string]::IsNullOrWhiteSpace($ElasticUrl)) {
    $ElasticUrl = (Get-ServerConfig).Elasticsearch.OrchestraSearchUrl
}

$credPath = Join-Path -Path $PSScriptRoot -ChildPath 'elastic.credentials.clixml'
$elasticCred = Resolve-ElasticCredential -CredentialPath $credPath -Reset:$ResetCredentials
$headers = @{ 'Content-Type' = 'application/json'; 'Authorization' = "ApiKey $($elasticCred.GetNetworkCredential().Password)" }

$timestampRange = @{ gte = $startWindow.UtcIso; lte = $endWindow.UtcIso }

$mustClauses = @(
    @{ range = @{ '@timestamp' = $timestampRange } }
)

if (-not [string]::IsNullOrWhiteSpace($ScenarioName)) {
    $mustClauses += @{ wildcard = @{ ScenarioName = @{ value = $ScenarioName } } }
}
if (-not [string]::IsNullOrWhiteSpace($ProcessName)) {
    $mustClauses += @{ wildcard = @{ ProcessName = @{ value = $ProcessName } } }
}
if ($Stage) {
    $mustClauses += @{ term = @{ 'BK.SUBFL_stage' = $Stage } }
}
if (-not [string]::IsNullOrWhiteSpace($WorkflowPattern)) {
    if ($WorkflowPattern -match '[*?]') {
        $mustClauses += @{ wildcard = @{ WorkflowPattern = @{ value = $WorkflowPattern } } }
    } else {
        $mustClauses += @{ term = @{ WorkflowPattern = $WorkflowPattern } }
    }
}

$termFilters = @(
    (ConvertTo-ElasticTermsFilter -Field 'BK._CASENO' -Values $CaseNo),
    (ConvertTo-ElasticTermsFilter -Field 'BK._CASENO_BC' -Values $CaseNo),
    (ConvertTo-ElasticTermsFilter -Field 'BK._CASENO_ISH' -Values $CaseNo),
    (ConvertTo-ElasticTermsFilter -Field 'BK._PID' -Values $PatientId),
    (ConvertTo-ElasticTermsFilter -Field 'BK._PID_ISH' -Values $PatientId),
    (ConvertTo-ElasticTermsFilter -Field 'BK.SUBFL_subid' -Values $SubId),
    (ConvertTo-ElasticTermsFilter -Field 'BusinessCaseId' -Values $BusinessCaseId),
    (ConvertTo-ElasticTermsFilter -Field 'BK.SUBFL_category' -Values $Category),
    (ConvertTo-ElasticTermsFilter -Field 'BK.SUBFL_subcategory' -Values $Subcategory),
    (ConvertTo-ElasticTermsFilter -Field 'BK._HCMMSGEVENT' -Values $HcmMsgEvent),
    (ConvertTo-ElasticTermsFilter -Field 'Instance' -Values $Instance),
    (ConvertTo-ElasticTermsFilter -Field 'Environment' -Values $EnvironmentFilters)
)

foreach ($filter in $termFilters) {
    if ($filter) {
        if ($filter.terms.ContainsKey('BK._CASENO') -or $filter.terms.ContainsKey('BK._CASENO_BC') -or $filter.terms.ContainsKey('BK._CASENO_ISH')) {
            # handled below through should clause
        } elseif ($filter.terms.ContainsKey('BK._PID') -or $filter.terms.ContainsKey('BK._PID_ISH')) {
            # handled below through should clause
        } elseif ($filter.terms.ContainsKey('BusinessCaseId')) {
            # handled below through should clause
        } else {
            $mustClauses += $filter
        }
    }
}

$shouldClauses = @()
if ($CaseNo -and $CaseNo.Count -gt 0) {
    $shouldClauses += (ConvertTo-ElasticTermsFilter -Field 'BK._CASENO' -Values $CaseNo)
    $shouldClauses += (ConvertTo-ElasticTermsFilter -Field 'BK._CASENO_BC' -Values $CaseNo)
    $shouldClauses += (ConvertTo-ElasticTermsFilter -Field 'BK._CASENO_ISH' -Values $CaseNo)
}
if ($PatientId -and $PatientId.Count -gt 0) {
    $shouldClauses += (ConvertTo-ElasticTermsFilter -Field 'BK._PID' -Values $PatientId)
    $shouldClauses += (ConvertTo-ElasticTermsFilter -Field 'BK._PID_ISH' -Values $PatientId)
}
if ($BusinessCaseId -and $BusinessCaseId.Count -gt 0) {
    $shouldClauses += (ConvertTo-ElasticTermsFilter -Field 'BusinessCaseId' -Values $BusinessCaseId)
}
$shouldClauses = @($shouldClauses | Where-Object { $_ })

$boolQuery = @{ must = $mustClauses }
if ($shouldClauses.Count -gt 0) {
    $boolQuery.should = $shouldClauses
    $boolQuery.minimum_should_match = 1
}

$body = @{
    size = 500
    sort = @(@{ '@timestamp' = @{ order = 'asc' } })
    query = @{ bool = $boolQuery }
    _source = @(
        '@timestamp','ScenarioName','ProcessName','WorkflowPattern','BusinessCaseId','MSGID','MessageData1','MessageData2',
        'BK.SUBFL_stage','BK.SUBFL_messagetype','BK.SUBFL_category','BK.SUBFL_subcategory','BK._HCMMSGEVENT','BK.*',
        'Instance','Environment'
    )
}

if ($Action -eq 'ShowQuery') {
    $preview = [ordered]@{
        ElasticUrl = $ElasticUrl
        Headers = $headers
        Body = $body
    }
    $json = $preview | ConvertTo-Json -Depth 10
    Write-Host 'ShowQuery selected; request will not be executed.' -ForegroundColor Yellow
    Write-Host $json
    return
}

Write-RunLog -Level 'INFO' -Message ("Running Elasticsearch query from {0} (UTC {1}) to {2} (UTC {3})." -f $startWindow.LocalIso, $startWindow.UtcIso, $endWindow.LocalIso, $endWindow.UtcIso)
$hits = Invoke-ElasticScrollSearch -ElasticUrl $ElasticUrl -Body $body -Headers $headers -OnPage {
    param($page, $pageHits, $total)
    Write-Progress -Id 1 -Activity 'Elasticsearch query' -Status "Loaded page $page, total records $total" -PercentComplete -1
}
Write-Progress -Id 1 -Activity 'Elasticsearch query' -Completed

$records = @($hits | ForEach-Object { $_._source } | Where-Object { $_ })
$totalRecordsFromElastic = $records.Count

$uniqueRecords = [System.Collections.Generic.List[object]]::new()
$seenBusinessCaseIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$duplicateBusinessCaseCount = 0
foreach ($record in $records) {
    $businessCaseKey = Get-RecordBusinessCaseKey -Source $record
    if ([string]::IsNullOrWhiteSpace($businessCaseKey)) {
        $uniqueRecords.Add($record) | Out-Null
        continue
    }

    if ($seenBusinessCaseIds.Add($businessCaseKey)) {
        $uniqueRecords.Add($record) | Out-Null
    } else {
        $duplicateBusinessCaseCount++
    }
}
$records = @($uniqueRecords)

Write-RunLog -Level 'INFO' -Message "Found $($records.Count) records."
if ($duplicateBusinessCaseCount -gt 0) {
    Write-RunLog -Level 'INFO' -Message "Ignored $duplicateBusinessCaseCount newer duplicate records by BusinessCaseId/MSGID (from $totalRecordsFromElastic total hits)."
}

if ($Action -eq 'Query') {
    $grouped = $records | Group-Object -Property ScenarioName | Sort-Object Name
    $summary = foreach ($group in $grouped) {
        $timestamps = @($group.Group | ForEach-Object { [datetime](Get-ElasticSourceValue -Source $_ -FieldPath '@timestamp') })
        [pscustomobject]@{
            ScenarioName = $group.Name
            RecordCount = $group.Count
            MinTimestamp = ($timestamps | Measure-Object -Minimum).Minimum
            MaxTimestamp = ($timestamps | Measure-Object -Maximum).Maximum
        }
    }

    if ($summary.Count -eq 0) {
        Write-RunLog -Level 'INFO' -Message 'No records matched the filter.'
    } else {
        $summary | Format-Table -AutoSize | Out-String | Write-Host
    }
    return
}

$targetUri = Resolve-TargetDefinition -TargetName $Target
Write-RunLog -Level 'INFO' -Message "Resolved target '$Target' to '$targetUri'. Action: $Action."

$singleStep = ($Mode -eq 'Single')
$paused = $singleStep
$stopRequested = $false

for ($i = 0; $i -lt $records.Count; $i++) {
    $current = $records[$i]
    $indexDisplay = $i + 1

    $progressPercent = if ($records.Count -gt 0) { [int](($indexDisplay * 100) / $records.Count) } else { 0 }
    $updateProgress = {
        Update-ResendProgressStatus -IndexDisplay $indexDisplay -TotalRecords $records.Count -SingleStepMode $singleStep -PausedState $paused -BatchSizeValue $BatchSize -DelaySeconds $DelayBetweenBatches -PercentComplete $progressPercent
    }
    & $updateProgress

    while ($true) {
        $control = Get-ControlAction
        if ($control -eq 'Pause') {
            $paused = $true
            Write-RunLog -Level 'INFO' -Message 'Paused by user (P).'
        } elseif ($control -eq 'Resume') {
            $paused = $false
            $singleStep = $false
            Write-RunLog -Level 'INFO' -Message 'Resumed by user (R).'
        } elseif ($control -eq 'Single') {
            $paused = $false
            $singleStep = $true
            Write-RunLog -Level 'INFO' -Message 'Single-step mode activated (S).'
        } elseif ($control -eq 'DelayIncrease') {
            $DelayBetweenBatches += 5
            Write-RunLog -Level 'INFO' -Message "Batch delay updated to $DelayBetweenBatches seconds (+ key)."
        } elseif ($control -eq 'DelayDecrease') {
            $newDelayValue = [Math]::Max(0, $DelayBetweenBatches - 5)
            if ($newDelayValue -ne $DelayBetweenBatches) {
                $DelayBetweenBatches = $newDelayValue
                Write-RunLog -Level 'INFO' -Message "Batch delay updated to $DelayBetweenBatches seconds (- key)."
            } else {
                Write-RunLog -Level 'INFO' -Message 'Batch delay already at 0 seconds (- key).'
            }
        } elseif ($control -eq 'Exit') {
            $stopRequested = $true
            Write-RunLog -Level 'WARN' -Message 'Exit requested (X/Ctrl+C).'
            break
        }

        if ($control) {
            & $updateProgress
        }

        if ($stopRequested -or -not $paused) {
            break
        }

        Start-Sleep -Milliseconds 150
    }

    if ($stopRequested) { break }

    $messageData1 = "$(Get-ElasticSourceValue -Source $current -FieldPath 'MessageData1')"
    $messageData1 = Invoke-RegexReplacements -InputText $messageData1 -ReplacementPairs $ReplacementPairs
    if ($CleanupEnvelope) {
        $messageData1 = Clear-EnvelopeData -XmlText $messageData1
    }

    $msgId = "$(Get-ElasticSourceValue -Source $current -FieldPath 'MSGID')"
    if ([string]::IsNullOrWhiteSpace($msgId)) {
        $msgId = "$(Get-ElasticSourceValue -Source $current -FieldPath 'BusinessCaseId')"
    }

    $headersOut = @{
        'SourceInfoMsg' = (Get-SourceInfoXml -Source $current -SubscriptionFilterParty $TargetParty -SubscriptionFilterId $TargetSubId -FallbackProcessState $(if ($PSBoundParameters.ContainsKey('ProcessState')) { $ProcessState } else { 'Original' }) -UseProvidedProcessState $PSBoundParameters.ContainsKey('ProcessState') -TargetName $Target)
        'SUBFL_source_host' = 'ElasticReinject'
        'BuKeysString' = (ConvertTo-BusinessKeysString -Source $current -ReplacementPairs $ReplacementPairs)
        '_MSGID' = $(if ($NewBusinessCaseIds.IsPresent) { '' } else { $msgId })
        '_GROUPBY' = ''
        '_SOURCE' = 'ElasticReinject'
    }

    $recordStamp = "$(Get-ElasticSourceValue -Source $current -FieldPath '@timestamp')"
    $scenario = "$(Get-ElasticSourceValue -Source $current -FieldPath 'ScenarioName')"

    try {
        if ($Mode -eq 'Curl') {
            $curlCommand = ConvertTo-CurlCommand -Uri $targetUri -Headers $headersOut -Body $messageData1
            Add-Content -Path $script:CurlOutputFilePath -Value $curlCommand -Encoding UTF8

            $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') | CURL  | #$indexDisplay | $msgId | $scenario | TS $recordStamp"
            $script:SuccessLog.Add($line) | Out-Null
            if ($script:LogFilePath) {
                Add-Content -Path $script:LogFilePath -Value $line -Encoding UTF8
            }
        } elseif ($Action -eq 'Send') {
            Invoke-RestMethod -Method Post -Uri $targetUri -Headers $headersOut -Body $messageData1 -ContentType 'text/xml; charset=utf-8' -TimeoutSec 120 | Out-Null
            $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') | OK    | #$indexDisplay | $msgId | $scenario | TS $recordStamp"
            $script:SuccessLog.Add($line) | Out-Null
            Write-RunLog -Level 'INFO' -Message $line
        } else {
            $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') | TEST  | #$indexDisplay | $msgId | $scenario | TS $recordStamp"
            $script:SuccessLog.Add($line) | Out-Null
            Write-RunLog -Level 'INFO' -Message $line
        }
    } catch {
        $err = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') | ERROR | #$indexDisplay | $msgId | $($_.Exception.Message)"
        $script:ErrorLog.Add($err) | Out-Null
        Write-RunLog -Level 'ERROR' -Message $err
    }

    & $updateProgress

    if ($singleStep) {
        $paused = $true
    }

    $isBatchEnd = (($indexDisplay % $BatchSize) -eq 0)
    $isLast = ($indexDisplay -eq $records.Count)

    if (-not $isLast -and $isBatchEnd) {
        if ($Mode -eq 'Batch' -and $DelayBetweenBatches -gt 0) {
            $waitUntil = (Get-Date).AddSeconds($DelayBetweenBatches)
            while ((Get-Date) -lt $waitUntil) {
                $control = Get-ControlAction
                if ($control -eq 'Resume') {
                    $paused = $false
                    $singleStep = $false
                    Write-RunLog -Level 'INFO' -Message 'Next batch started early (R).'
                    & $updateProgress
                    break
                }
                if ($control -eq 'Pause') {
                    $paused = $true
                    & $updateProgress
                }
                if ($control -eq 'Single') {
                    $singleStep = $true
                    $paused = $false
                    & $updateProgress
                }
                if ($control -eq 'Exit') {
                    $stopRequested = $true
                    & $updateProgress
                    break
                }
                if ($control -eq 'DelayIncrease') {
                    $DelayBetweenBatches += 5
                    Write-RunLog -Level 'INFO' -Message "Batch delay updated to $DelayBetweenBatches seconds (+ key)."
                    $waitUntil = (Get-Date).AddSeconds($DelayBetweenBatches)
                    & $updateProgress
                    continue
                }
                if ($control -eq 'DelayDecrease') {
                    $newDelayDuringWait = [Math]::Max(0, $DelayBetweenBatches - 5)
                    if ($newDelayDuringWait -ne $DelayBetweenBatches) {
                        $DelayBetweenBatches = $newDelayDuringWait
                        Write-RunLog -Level 'INFO' -Message "Batch delay updated to $DelayBetweenBatches seconds (- key)."
                    } else {
                        Write-RunLog -Level 'INFO' -Message 'Batch delay already at 0 seconds (- key).'
                    }
                    $waitUntil = (Get-Date).AddSeconds($DelayBetweenBatches)
                    & $updateProgress
                    continue
                }
                Start-Sleep -Milliseconds 150
            }
        }
    }

    if ($stopRequested) { break }
}

Write-Progress -Id 2 -Activity 'Resend processing' -Completed
$stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
$successCount = $script:SuccessLog.Count
$errorCount = $script:ErrorLog.Count
Write-Host "[$stamp] [INFO] Finished. " -ForegroundColor Gray -NoNewline
Write-Host "Successes: $successCount" -ForegroundColor $(if ($successCount -gt 0) { 'Green' } else { 'Gray' }) -NoNewline
Write-Host ", " -ForegroundColor Gray -NoNewline
Write-Host "Errors: $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { 'Red' } else { 'Gray' }) -NoNewline
Write-Host "." -ForegroundColor Gray
if ($script:LogFilePath) {
    Add-Content -Path $script:LogFilePath -Value "[$stamp] [INFO] Finished. Successes: $successCount, Errors: $errorCount." -Encoding UTF8
}
if ($Mode -eq 'Curl' -and $script:CurlOutputFilePath) {
    Write-RunLog -Level 'INFO' -Message "Curl commands written to '$script:CurlOutputFilePath'."
}
