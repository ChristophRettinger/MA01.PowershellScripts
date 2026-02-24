<#
.SYNOPSIS
    Query SUBFL records in Elasticsearch and optionally resend them to a target endpoint.

.DESCRIPTION
    Loads Elasticsearch records for a date range and optional filters (ScenarioName,
    ProcessName, case/patient/business IDs, stage/category fields, and environment metadata).

    Action modes:
    - Query: only reports counts and timestamp ranges grouped by ScenarioName.
    - Test: performs full resend preparation but skips HTTP transmission.
    - Send: posts MessageData1 to a target endpoint from targets.csv.

    For resend actions, the script builds SourceInfoMsg and BuKeysString headers,
    supports envelope cleanup, batching, delay handling, single-step mode, and
    keyboard controls (P pause, R resume/skip wait, S single-step, X exit).

.PARAMETER StartDate
    Inclusive start timestamp for Elasticsearch filtering. Defaults to now minus 7 days.

.PARAMETER EndDate
    Inclusive end timestamp for Elasticsearch filtering. Defaults to now.

.PARAMETER ElasticUrl
    Elasticsearch _search endpoint URL.

.PARAMETER ElasticApiKey
    Elasticsearch API key value.

.PARAMETER ElasticApiKeyPath
    File path containing the Elasticsearch API key.

.PARAMETER ScenarioName
    ScenarioName wildcard filter. Defaults to '*SUBFL*'.

.PARAMETER ProcessName
    ProcessName wildcard filter.

.PARAMETER CaseNo
    Array filter for case numbers.

.PARAMETER PatientId
    Array filter for patient IDs.

.PARAMETER BusinessCaseId
    Array filter for MSGID/BusinessCaseId.

.PARAMETER Stage
    BK.SUBFL_stage filter (Input, Map, Resolve, Output).

.PARAMETER Category
    BK.SUBFL_category filter values.

.PARAMETER Subcategory
    BK.SUBFL_subcategory filter values.

.PARAMETER HcmMsgEvent
    BK._HCMMSGEVENT filter values.

.PARAMETER Instance
    Instance filter values.

.PARAMETER Environment
    Environment filter values.

.PARAMETER Action
    Query, Send, or Test. Defaults to Query.

.PARAMETER Target
    Target name resolved from targets.csv (columns Name,URL); supports tab completion from Name values.

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
    Fallback ProcessState for SourceInfoMsg. Defaults to 'Original'.

.PARAMETER OutputDirectory
    Optional output directory for logs.

.PARAMETER Mode
    Batch, All, or Single processing behavior. Defaults to Batch.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [datetime]$StartDate = (Get-Date).AddDays(-7),

    [Parameter(Mandatory=$false)]
    [datetime]$EndDate = (Get-Date),

    [Parameter(Mandatory=$false)]
    [string]$ElasticUrl = 'https://es-obs.apps.zeus.wien.at/logs-orchestra.journals*/_search',

    [Parameter(Mandatory=$false)]
    [string]$ElasticApiKey,

    [Parameter(Mandatory=$false)]
    [string]$ElasticApiKeyPath = (Join-Path -Path $PSScriptRoot -ChildPath 'elastic.key'),

    [Parameter(Mandatory=$false)]
    [string]$ScenarioName = '*SUBFL*',

    [Parameter(Mandatory=$false)]
    [string]$ProcessName,

    [Parameter(Mandatory=$false)]
    [string[]]$CaseNo,

    [Parameter(Mandatory=$false)]
    [string[]]$PatientId,

    [Alias('MSGID')]
    [Parameter(Mandatory=$false)]
    [string[]]$BusinessCaseId,

    [ValidateSet('Input','Map','Resolve','Output')]
    [Parameter(Mandatory=$false)]
    [string]$Stage,

    [Parameter(Mandatory=$false)]
    [string[]]$Category,

    [Parameter(Mandatory=$false)]
    [string[]]$Subcategory,

    [Parameter(Mandatory=$false)]
    [string[]]$HcmMsgEvent,

    [Parameter(Mandatory=$false)]
    [string[]]$Instance,

    [Parameter(Mandatory=$false)]
    [string[]]$Environment,

    [ValidateSet('Query','Send','Test')]
    [Parameter(Mandatory=$false)]
    [string]$Action = 'Query',

    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

        $targetsPath = Join-Path -Path $PSScriptRoot -ChildPath 'targets.csv'
        if (-not (Test-Path -Path $targetsPath)) {
            return
        }

        Import-Csv -Path $targetsPath |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_.Name) -and
                $_.Name -like "${wordToComplete}*"
            } |
            Select-Object -ExpandProperty Name -Unique |
            ForEach-Object {
                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
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

    [ValidateSet('Batch','All','Single')]
    [Parameter(Mandatory=$false)]
    [string]$Mode = 'Batch'
)

$sharedHelpersDirectory = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Common'
$sharedHelpersPath = Join-Path -Path $sharedHelpersDirectory -ChildPath 'ElasticSearchHelpers.ps1'
if (-not (Test-Path -Path $sharedHelpersPath)) {
    throw "Shared Elastic helper not found at '$sharedHelpersPath'."
}
. $sharedHelpersPath

$script:LogFilePath = $null
$script:SuccessLog = [System.Collections.Generic.List[string]]::new()
$script:ErrorLog = [System.Collections.Generic.List[string]]::new()

function Write-RunLog {
    param(
        [string]$Level,
        [string]$Message
    )

    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $line = "[$stamp] [$Level] $Message"
    Write-Host $line
    if ($script:LogFilePath) {
        Add-Content -Path $script:LogFilePath -Value $line
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

function Resolve-ApiKey {
    if ($ElasticApiKey) {
        return $ElasticApiKey.Trim()
    }

    if ($ElasticApiKeyPath -and (Test-Path -Path $ElasticApiKeyPath)) {
        return (Get-Content -Path $ElasticApiKeyPath -Raw).Trim()
    }

    throw 'No Elasticsearch API key provided. Use ElasticApiKey or ElasticApiKeyPath.'
}

function Resolve-TargetDefinition {
    param([string]$TargetName)

    $targetsPath = Join-Path -Path $PSScriptRoot -ChildPath 'targets.csv'
    if (-not (Test-Path -Path $targetsPath)) {
        throw "Target file not found: $targetsPath"
    }

    $targets = Import-Csv -Path $targetsPath
    $match = $targets | Where-Object { $_.Name -eq $TargetName } | Select-Object -First 1
    if (-not $match) {
        throw "Target '$TargetName' not found in $targetsPath"
    }

    if ([string]::IsNullOrWhiteSpace($match.URL)) {
        throw "Target '$TargetName' has no URL value."
    }

    $url = $match.URL.Trim()
    return $url
}

function Get-SourceInfoXml {
    param(
        [object]$Source,
        [string]$SubscriptionFilterParty,
        [string]$SubscriptionFilterId,
        [string]$ResolvedProcessState,
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

    $processStateValue = if ($sourceInfo -and $sourceInfo.SourceInfo.ProcessState) { "$($sourceInfo.SourceInfo.ProcessState)" } else { $ResolvedProcessState }
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
    param([object]$Source)

    $excludedKeys = @(
        'SUBFL_stage','SUBFL_party','SUBFL_name','SUBFL_history','SUBFL_subid',
        'SUBFL_subid_list','SUBFL_targetid','SUBFL_workflow','SUBFL_senddate'
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($prop in $Source.BK.PSObject.Properties) {
        if ($excludedKeys -contains $prop.Name) { continue }

        $value = if ($null -eq $prop.Value) { '' } else { "$($prop.Value)" }
        $parts.Add("$($prop.Name):$value") | Out-Null
    }

    $businessKeysRaw = ($parts -join '|').Replace('&colon;', ':').Replace('&pipe;', '|')
	$base64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($businessKeysRaw))
    return [System.Net.WebUtility]::UrlEncode($base64)
}

function Cleanup-EnvelopeData {
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
            if ($char -eq 'X' -or $key.Key -eq [ConsoleKey]::C -and $key.Modifiers -band [ConsoleModifiers]::Control) { return 'Exit' }
        }
    }

    return $null
}

if ($StartDate -gt $EndDate) {
    throw 'StartDate must be less than or equal to EndDate.'
}

if ($BusinessCaseId -and -not $PSBoundParameters.ContainsKey('Stage')) {
    $Stage = 'Input'
}

$effectiveFilterCount = 0
if (-not [string]::IsNullOrWhiteSpace($ScenarioName)) { $effectiveFilterCount++ }
if (-not [string]::IsNullOrWhiteSpace($ProcessName)) { $effectiveFilterCount++ }
foreach ($arr in @($CaseNo,$PatientId,$BusinessCaseId,$Category,$Subcategory,$HcmMsgEvent,$Instance,$Environment)) {
    if ($arr -and @($arr | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") }).Count -gt 0) { $effectiveFilterCount++ }
}
if ($Stage) { $effectiveFilterCount++ }
if ($effectiveFilterCount -eq 0) {
    throw 'At least one filter parameter must be provided.'
}

if ($OutputDirectory) {
    if (-not (Test-Path -Path $OutputDirectory)) {
        $null = New-Item -Path $OutputDirectory -ItemType Directory -Force
    }
    $script:LogFilePath = Join-Path -Path $OutputDirectory -ChildPath ("Resend-FromElastic_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -Path $script:LogFilePath -ItemType File -Force | Out-Null
}

if (($Action -eq 'Send' -or $Action -eq 'Test') -and [string]::IsNullOrWhiteSpace($Target)) {
    throw 'Target is required for Action Send or Test.'
}

$headers = @{ 'Content-Type' = 'application/json'; 'Authorization' = "ApiKey $(Resolve-ApiKey)" }

$mustClauses = @(
    @{ range = @{ '@timestamp' = @{ gte = $StartDate.ToString('o'); lte = $EndDate.ToString('o') } } }
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

$termFilters = @(
    (ConvertTo-ElasticTermsFilter -Field 'BK._CASENO' -Values $CaseNo),
    (ConvertTo-ElasticTermsFilter -Field 'BK._CASENO_BC' -Values $CaseNo),
    (ConvertTo-ElasticTermsFilter -Field 'BK._CASENO_ISH' -Values $CaseNo),
    (ConvertTo-ElasticTermsFilter -Field 'BK._PID' -Values $PatientId),
    (ConvertTo-ElasticTermsFilter -Field 'BK._PID_ISH' -Values $PatientId),
    (ConvertTo-ElasticTermsFilter -Field 'MSGID' -Values $BusinessCaseId),
    (ConvertTo-ElasticTermsFilter -Field 'BusinessCaseId' -Values $BusinessCaseId),
    (ConvertTo-ElasticTermsFilter -Field 'BK.SUBFL_category' -Values $Category),
    (ConvertTo-ElasticTermsFilter -Field 'BK.SUBFL_subcategory' -Values $Subcategory),
    (ConvertTo-ElasticTermsFilter -Field 'BK._HCMMSGEVENT' -Values $HcmMsgEvent),
    (ConvertTo-ElasticTermsFilter -Field 'Instance' -Values $Instance),
    (ConvertTo-ElasticTermsFilter -Field 'Environment' -Values $Environment)
)

foreach ($filter in $termFilters) {
    if ($filter) {
        if ($filter.terms.ContainsKey('BK._CASENO') -or $filter.terms.ContainsKey('BK._CASENO_BC') -or $filter.terms.ContainsKey('BK._CASENO_ISH')) {
            # handled below through should clause
        } elseif ($filter.terms.ContainsKey('BK._PID') -or $filter.terms.ContainsKey('BK._PID_ISH')) {
            # handled below through should clause
        } elseif ($filter.terms.ContainsKey('MSGID') -or $filter.terms.ContainsKey('BusinessCaseId')) {
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
    $shouldClauses += (ConvertTo-ElasticTermsFilter -Field 'MSGID' -Values $BusinessCaseId)
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
        '@timestamp','ScenarioName','ProcessName','BusinessCaseId','MSGID','MessageData1','MessageData2',
        'BK.SUBFL_stage','BK.SUBFL_messagetype','BK.SUBFL_category','BK.SUBFL_subcategory','BK._HCMMSGEVENT','BK.*',
        'Instance','Environment'
    )
}

Write-RunLog -Level 'INFO' -Message "Running Elasticsearch query from $($StartDate.ToString('o')) to $($EndDate.ToString('o'))."
$hits = Invoke-ElasticScrollSearch -ElasticUrl $ElasticUrl -Body $body -Headers $headers -OnPage {
    param($page, $pageHits, $total)
    Write-Progress -Id 1 -Activity 'Elasticsearch query' -Status "Loaded page $page, total records $total" -PercentComplete -1
}
Write-Progress -Id 1 -Activity 'Elasticsearch query' -Completed

$records = @($hits | ForEach-Object { $_._source } | Where-Object { $_ })
Write-RunLog -Level 'INFO' -Message "Found $($records.Count) records."

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

$paused = $false
$singleStep = ($Mode -eq 'Single')
$stopRequested = $false

for ($i = 0; $i -lt $records.Count; $i++) {
    $current = $records[$i]
    $indexDisplay = $i + 1

    $progressPercent = if ($records.Count -gt 0) { [int](($indexDisplay * 100) / $records.Count) } else { 0 }
    Write-Progress -Id 2 -Activity 'Resend processing' -Status "Record $indexDisplay/$($records.Count)" -PercentComplete $progressPercent

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
        } elseif ($control -eq 'Exit') {
            $stopRequested = $true
            Write-RunLog -Level 'WARN' -Message 'Exit requested (X/Ctrl+C).'
            break
        }

        if ($stopRequested -or -not $paused) {
            break
        }

        Start-Sleep -Milliseconds 150
    }

    if ($stopRequested) { break }

    $messageData1 = "$(Get-ElasticSourceValue -Source $current -FieldPath 'MessageData1')"
    if ($CleanupEnvelope) {
        $messageData1 = Cleanup-EnvelopeData -XmlText $messageData1
    }

    $msgId = "$(Get-ElasticSourceValue -Source $current -FieldPath 'MSGID')"
    if ([string]::IsNullOrWhiteSpace($msgId)) {
        $msgId = "$(Get-ElasticSourceValue -Source $current -FieldPath 'BusinessCaseId')"
    }

    $headersOut = @{
        'SourceInfoMsg' = (Get-SourceInfoXml -Source $current -SubscriptionFilterParty $TargetParty -SubscriptionFilterId $TargetSubId -ResolvedProcessState $ProcessState -TargetName $Target)
        'SUBFL_source_host' = 'ElasticReinject'
        'BuKeysString' = (ConvertTo-BusinessKeysString -Source $current)
        '_MSGID' = $(if ($NewBusinessCaseIds.IsPresent) { '' } else { $msgId })
        '_GROUPBY' = ''
        '_SOURCE' = 'ElasticReinject'
    }

    $recordStamp = "$(Get-ElasticSourceValue -Source $current -FieldPath '@timestamp')"
    $scenario = "$(Get-ElasticSourceValue -Source $current -FieldPath 'ScenarioName')"

    try {
        if ($Action -eq 'Send') {
            Invoke-RestMethod -Method Post -Uri $targetUri -Headers $headersOut -Body $messageData1 -ContentType 'text/xml; charset=utf-8' -TimeoutSec 120 | Out-Null
            $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') | OK | #$indexDisplay | MSGID=$msgId | Scenario=$scenario | Timestamp=$recordStamp"
            $script:SuccessLog.Add($line) | Out-Null
            Write-RunLog -Level 'INFO' -Message $line
        } else {
            $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') | TEST | #$indexDisplay | MSGID=$msgId | Scenario=$scenario | Timestamp=$recordStamp"
            $script:SuccessLog.Add($line) | Out-Null
            Write-RunLog -Level 'INFO' -Message $line
        }
    } catch {
        $err = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') | ERROR | #$indexDisplay | MSGID=$msgId | $($_.Exception.Message)"
        $script:ErrorLog.Add($err) | Out-Null
        Write-RunLog -Level 'ERROR' -Message $err
    }

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
                    Write-RunLog -Level 'INFO' -Message 'Next batch started early (R).'
                    break
                }
                if ($control -eq 'Pause') {
                    $paused = $true
                }
                if ($control -eq 'Single') {
                    $singleStep = $true
                }
                if ($control -eq 'Exit') {
                    $stopRequested = $true
                    break
                }
                Start-Sleep -Milliseconds 150
            }
        }
    }

    if ($stopRequested) { break }
}

Write-Progress -Id 2 -Activity 'Resend processing' -Completed
Write-Host ''
Write-Host 'Successes:'
$script:SuccessLog | ForEach-Object { Write-Host $_ }
Write-Host ''
Write-Host 'Errors:'
$script:ErrorLog | ForEach-Object { Write-Host $_ }
Write-Host ''
Write-RunLog -Level 'INFO' -Message "Finished. Successes: $($script:SuccessLog.Count), Errors: $($script:ErrorLog.Count)."
