<#
.SYNOPSIS
    Validates Orchestra scenario XML configuration files across scenario subfolders.

.DESCRIPTION
    Scans the provided root folder for ProcessModell_*, Channel_*, and MessageMapping_*
    XML files. For every scenario (grouped by the top-level folder beneath the root
    path), the script checks process model settings, business key counts, channel
    concurrency, and mapping parallel execution rules. Results are grouped by
    scenario name and printed with colored headings for the scenario, process
    models, channels, and mappings. Description tags in each XML document can
    include exception codes (for example: "PM:v; RS:a; SC:p75") to allow deviations
    from the default validation rules.

.PARAMETER Path
    Root folder that contains scenario subfolders. Defaults to the current directory.

.PARAMETER MaxBusinessKeyCount
    Maximum allowed number of business keys in a process model. Defaults to 6.

.PARAMETER ShowExceptions
    When set, includes entries that match a configured exception code in the
    output list with an "exception configured" note.

.PARAMETER ErrorCategories
    Optional list of validation categories to check (for example: ST, PM). When
    omitted, all categories are validated.

.EXAMPLE
    .\Validate-Scenarios.ps1 -Path "D:\Scenarios" -MaxBusinessKeyCount 8
#>

param (
    [Parameter(Mandatory = $false)]
    [string]$Path = '.',

    [Parameter(Mandatory = $false)]
    [int]$MaxBusinessKeyCount = 6,

    [Parameter(Mandatory = $false)]
    [switch]$ShowExceptions,

    [Parameter(Mandatory = $false)]
    [string[]]$ErrorCategories
)

$resolvedPath = (Resolve-Path -Path $Path).Path

$processModelPattern = 'ProcessModell_*'
$channelPattern = 'Channel_*'
$mappingPattern = 'MessageMapping_*'

$businessKeysXPath = '/ProcessModel/businessKeys/Property'
$processModelXPaths = [ordered]@{
    isDurable = '/ProcessModel/processObjects/EventStart/trigger[isThrowing="false"]/isDurable'
    isPersistent = '/ProcessModel/isPersistent'
    redeployPolicy = '/ProcessModel/redeployPolicy'
    volatilePolicy = '/ProcessModel/volatilePoicy'
    manualRestart = '/ProcessModel/manualRestart'
    isFifo = '/ProcessModel/isFifo'
    name = '/ProcessModel/name'
}

$scenarioColor = 'Cyan'
$processModelColor = 'Green'
$mappingColor = 'Magenta'
$channelColor = 'Yellow'
$issueColor = 'Red'

$allCategories = @('PM','RS','MR','SI','BK','ST')
$categorySet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
if ($PSBoundParameters.ContainsKey('ErrorCategories') -and $ErrorCategories) {
    foreach ($entry in $ErrorCategories) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        foreach ($token in ($entry -split '[,;]')) {
            $trimmed = $token.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                $null = $categorySet.Add($trimmed.ToUpperInvariant())
            }
        }
    }
}
if ($categorySet.Count -eq 0) {
    foreach ($cat in $allCategories) {
        $null = $categorySet.Add($cat)
    }
}

function Get-ScenarioInfo {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    $directoryPath = Split-Path -Path $FilePath -Parent
    $rootPathNormalized = [System.IO.Path]::GetFullPath($RootPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $directoryPathNormalized = [System.IO.Path]::GetFullPath($directoryPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $relativePath = ''

    if ($directoryPathNormalized.Length -ge $rootPathNormalized.Length -and $directoryPathNormalized.StartsWith($rootPathNormalized, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relativePath = $directoryPathNormalized.Substring($rootPathNormalized.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    }

    if ($relativePath) {
        $separatorChars = @([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        $scenarioName = $relativePath.Split($separatorChars, [System.StringSplitOptions]::RemoveEmptyEntries)[0]
        $scenarioPath = Join-Path -Path $RootPath -ChildPath $scenarioName
    } else {
        $scenarioName = Split-Path -Path $directoryPath -Leaf
        $scenarioPath = $directoryPath
    }

    return [PSCustomObject]@{
        Name = $scenarioName
        Path = $scenarioPath
    }
}

function Get-XmlDocument {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    return [xml](Get-Content -Path $FilePath -Raw)
}

function Get-NodeValue {
    param (
        [Parameter(Mandatory = $true)]
        [xml]$XmlDocument,

        [Parameter(Mandatory = $true)]
        [string]$XPath
    )

    $node = $XmlDocument.SelectSingleNode($XPath)
    if ($node -and -not [string]::IsNullOrWhiteSpace($node.InnerText)) {
        return $node.InnerText.Trim()
    }

    return 'N/A'
}

function Get-DescriptionTokens {
    param (
        [Parameter(Mandatory = $true)]
        [xml]$XmlDocument
    )

    $descriptionNode = $XmlDocument.SelectSingleNode('/*[1]/description')
    if (-not $descriptionNode -or [string]::IsNullOrWhiteSpace($descriptionNode.InnerText)) {
        return @{}
    }

    $tokens = @{}
    $matches = [regex]::Matches($descriptionNode.InnerText, '\b(?<key>[A-Z]{2})\s*:\s*(?<value>[A-Za-z0-9]+)\b')
    foreach ($match in $matches) {
        $key = $match.Groups['key'].Value
        $value = $match.Groups['value'].Value
        if (-not $tokens.ContainsKey($key)) {
            $tokens[$key] = New-Object System.Collections.Generic.List[string]
        }
        $tokens[$key].Add($value)
    }

    return $tokens
}

function Test-ExceptionMatch {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Tokens,

        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if (-not $Tokens.ContainsKey($Key)) {
        return $false
    }

    return $Tokens[$Key] -contains $Value
}

function Get-BusinessKeyExceptionLimit {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Tokens
    )

    if (-not $Tokens.ContainsKey('BK')) {
        return $null
    }

    $limits = foreach ($entry in $Tokens['BK']) {
        $value = 0
        if ([int]::TryParse($entry, [ref]$value)) {
            $value
        }
    }

    if (-not $limits) {
        return $null
    }

    return ($limits | Measure-Object -Maximum).Maximum
}

function Test-CategoryEnabled {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Category
    )

    return $categorySet.Contains($Category)
}

function New-ValidationIssue {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Category,

        [Parameter(Mandatory = $true)]
        [string]$Code,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    return [PSCustomObject]@{
        Short = "$($Category):$($Code)"
        Message = $Message
    }
}

function Write-IssueLine {
    param (
        [Parameter(Mandatory = $true)]
        [object]$Issue
    )

    Write-Host -NoNewline '    - '
    Write-Host -NoNewline $Issue.Short -ForegroundColor $issueColor
    if ($Issue.Message) {
        Write-Host " $($Issue.Message)"
    } else {
        Write-Host ''
    }
}

$scenarioResults = @{}
$totalFilesProcessed = 0

$files = Get-ChildItem -Path $resolvedPath -Recurse -File | Where-Object {
    ($_.Name -like $processModelPattern -or $_.Name -like $channelPattern -or $_.Name -like $mappingPattern) -and $_.Extension -eq "" 
}

foreach ($file in $files) {
    $totalFilesProcessed += 1
    $filePath = $file.FullName
    $scenarioInfo = Get-ScenarioInfo -FilePath $filePath -RootPath $resolvedPath

    if (-not $scenarioResults.ContainsKey($scenarioInfo.Name)) {
        $scenarioResults[$scenarioInfo.Name] = [ordered]@{
            Name = $scenarioInfo.Name
            Path = $scenarioInfo.Path
            ProcessModels = @()
            Channels = @()
            Mappings = @()
        }
    }

    try {
        $xmlContent = Get-XmlDocument -FilePath $filePath
    } catch {
        Write-Warning "Error processing file: $($filePath)"
        Write-Warning $($_.Exception.Message)
        continue
    }

    $descriptionTokens = Get-DescriptionTokens -XmlDocument $xmlContent

    if ($file.Name -like $processModelPattern) {
        $businessKeysCount = ($xmlContent.SelectNodes($businessKeysXPath) | Measure-Object).Count
        $processModelName = Get-NodeValue -XmlDocument $xmlContent -XPath $processModelXPaths.name

        $issues = New-Object System.Collections.Generic.List[object]

        $isDurable = Get-NodeValue -XmlDocument $xmlContent -XPath $processModelXPaths.isDurable
        $manualRestart = Get-NodeValue -XmlDocument $xmlContent -XPath $processModelXPaths.manualRestart
        $isPersistent = Get-NodeValue -XmlDocument $xmlContent -XPath $processModelXPaths.isPersistent
        $redeployPolicy = Get-NodeValue -XmlDocument $xmlContent -XPath $processModelXPaths.redeployPolicy
        $volatilePolicy = Get-NodeValue -XmlDocument $xmlContent -XPath $processModelXPaths.volatilePolicy

        $processModeCode = if ($isPersistent -eq 'true') {
            'p'
        } elseif ($volatilePolicy -eq '1') {
            'vr'
        } else {
            'v'
        }
        if ((Test-CategoryEnabled -Category 'PM') -and $processModeCode -ne 'vr') {
            $hasException = Test-ExceptionMatch -Tokens $descriptionTokens -Key 'PM' -Value $processModeCode
            $processModeLabel = switch ($processModeCode) {
                'p' { 'persistent' }
                'v' { 'volatile' }
                'vr' { 'volatile with recovery' }
                default { $processModeCode }
            }
            if (-not $hasException) {
                $issues.Add((New-ValidationIssue -Category 'PM' -Code $processModeCode -Message "Process mode is $($processModeLabel) (expected volatile with recovery)."))
            } elseif ($ShowExceptions) {
                $issues.Add((New-ValidationIssue -Category 'PM' -Code $processModeCode -Message 'Exception configured.'))
            }
        }

        $redeployCode = if ($redeployPolicy -eq '1') { 'r' } else { 'a' }
        if ((Test-CategoryEnabled -Category 'RS') -and $redeployCode -ne 'r') {
            $hasException = Test-ExceptionMatch -Tokens $descriptionTokens -Key 'RS' -Value $redeployCode
            $redeployLabel = if ($redeployCode -eq 'r') { 'restart' } else { 'abort' }
            if (-not $hasException) {
                $issues.Add((New-ValidationIssue -Category 'RS' -Code $redeployCode -Message "Redeploy policy is $($redeployLabel) (expected restart)."))
            } elseif ($ShowExceptions) {
                $issues.Add((New-ValidationIssue -Category 'RS' -Code $redeployCode -Message 'Exception configured.'))
            }
        }

        $manualRestartCode = if ($manualRestart -eq 'true') { 'e' } else { 'd' }
        if ((Test-CategoryEnabled -Category 'MR') -and $manualRestartCode -ne 'e') {
            $hasException = Test-ExceptionMatch -Tokens $descriptionTokens -Key 'MR' -Value $manualRestartCode
            $manualRestartLabel = if ($manualRestartCode -eq 'e') { 'enabled' } else { 'disabled' }
            if (-not $hasException) {
                $issues.Add((New-ValidationIssue -Category 'MR' -Code $manualRestartCode -Message "Manual restart is $($manualRestartLabel) (expected enabled)."))
            } elseif ($ShowExceptions) {
                $issues.Add((New-ValidationIssue -Category 'MR' -Code $manualRestartCode -Message 'Exception configured.'))
            }
        }

		if ($isDurable -ne 'N/A') {
			$signalCode = if ($isDurable -eq 'true') { 'p' } else { 't' }
			if ((Test-CategoryEnabled -Category 'SI') -and $signalCode -ne 'p') {
				$hasException = Test-ExceptionMatch -Tokens $descriptionTokens -Key 'SI' -Value $signalCode
				$signalLabel = if ($signalCode -eq 'p') { 'persistent' } else { 'transient' }
				if (-not $hasException) {
					$issues.Add((New-ValidationIssue -Category 'SI' -Code $signalCode -Message "Signal subscription is $($signalLabel) (expected persistent)."))
				} elseif ($ShowExceptions) {
					$issues.Add((New-ValidationIssue -Category 'SI' -Code $signalCode -Message 'Exception configured.'))
				}
			}
		}
		
        if ((Test-CategoryEnabled -Category 'BK') -and $businessKeysCount -gt $MaxBusinessKeyCount) {
            $exceptionLimit = Get-BusinessKeyExceptionLimit -Tokens $descriptionTokens
            $hasException = $null -ne $exceptionLimit -and $businessKeysCount -le $exceptionLimit
            if (-not $hasException) {
                $issues.Add((New-ValidationIssue -Category 'BK' -Code $businessKeysCount -Message "Business key count is $($businessKeysCount) (max $($MaxBusinessKeyCount))."))
            } elseif ($ShowExceptions) {
                $issues.Add((New-ValidationIssue -Category 'BK' -Code $businessKeysCount -Message "Business key count is $($businessKeysCount) (exception BK:$($exceptionLimit))."))
            }
        }

        if ($issues.Count -gt 0) {
            $scenarioResults[$scenarioInfo.Name].ProcessModels += [PSCustomObject]@{
                Name = $processModelName
                Path = $filePath
                Issues = $issues
            }
        }

        continue
    }

    if ($file.Name -like $channelPattern) {
        $channelName = Get-NodeValue -XmlDocument $xmlContent -XPath '/*[1]/name'
        $numberOfInstances = Get-NodeValue -XmlDocument $xmlContent -XPath '/*[1]/numberOfInstances'
        $strategyCode = if ($numberOfInstances -eq '1') { 's' } else { 'p' }

        if ((Test-CategoryEnabled -Category 'ST') -and $strategyCode -ne 'p') {
            $hasException = Test-ExceptionMatch -Tokens $descriptionTokens -Key 'ST' -Value $strategyCode
            $issueList = New-Object System.Collections.Generic.List[object]
            $strategyLabel = if ($strategyCode -eq 'p') { 'parallel' } else { 'sequential' }
            if (-not $hasException) {
                $issueList.Add((New-ValidationIssue -Category 'ST' -Code $strategyCode -Message "Resource usage strategy is $($strategyLabel) (expected parallel)."))
            } elseif ($ShowExceptions) {
                $issueList.Add((New-ValidationIssue -Category 'ST' -Code $strategyCode -Message 'Exception configured.'))
            }

            if ($issueList.Count -gt 0) {
                $scenarioResults[$scenarioInfo.Name].Channels += [PSCustomObject]@{
                    Name = $channelName
                    Path = $filePath
                    Issues = $issueList
                }
            }
        }

        continue
    }

    if ($file.Name -like $mappingPattern) {
        $mappingName = Get-NodeValue -XmlDocument $xmlContent -XPath '/emds.mapping.proc.MappingScript/name'
        $parallelExecution = Get-NodeValue -XmlDocument $xmlContent -XPath '/emds.mapping.proc.MappingScript/parallelExecution'
        $strategyCode = if ($parallelExecution -eq 'true') { 'p' } else { 's' }

        if ((Test-CategoryEnabled -Category 'ST') -and $strategyCode -ne 'p') {
            $hasException = Test-ExceptionMatch -Tokens $descriptionTokens -Key 'ST' -Value $strategyCode
            $issueList = New-Object System.Collections.Generic.List[object]
            $strategyLabel = if ($strategyCode -eq 'p') { 'parallel' } else { 'sequential' }
            if (-not $hasException) {
                $issueList.Add((New-ValidationIssue -Category 'ST' -Code $strategyCode -Message "Resource usage strategy is $($strategyLabel) (expected parallel)."))
            } elseif ($ShowExceptions) {
                $issueList.Add((New-ValidationIssue -Category 'ST' -Code $strategyCode -Message 'Exception configured.'))
            }

            if ($issueList.Count -gt 0) {
                $scenarioResults[$scenarioInfo.Name].Mappings += [PSCustomObject]@{
                    Name = $mappingName
                    Path = $filePath
                    Issues = $issueList
                }
            }
        }
    }
}

$scenariosWithIssues = $scenarioResults.Values | Where-Object {
    $_.ProcessModels.Count -gt 0 -or $_.Channels.Count -gt 0 -or $_.Mappings.Count -gt 0
}

if (-not $scenariosWithIssues) {
    Write-Output 'No incorrect configurations found.'
} else {
    Write-Output "XML Analysis Results (Incorrect Configurations):`n"

    foreach ($scenario in $scenariosWithIssues | Sort-Object Name) {
        Write-Host -NoNewline $scenario.Name -ForegroundColor $scenarioColor
        Write-Host " [$($scenario.Path)]"

        foreach ($processModel in $scenario.ProcessModels) {
            $displayName = if ($processModel.Name -and $processModel.Name -ne 'N/A') { $processModel.Name } else { '(unnamed process model)' }
            Write-Host -NoNewline '  Process Model: '
            Write-Host $displayName -ForegroundColor $processModelColor
            foreach ($issue in $processModel.Issues) {
                Write-IssueLine -Issue $issue
            }
        }

        foreach ($channel in $scenario.Channels) {
            $channelDisplay = if ($channel.Name -and $channel.Name -ne 'N/A') { $channel.Name } else { '(unnamed channel)' }
            Write-Host -NoNewline '  Channel: '
            Write-Host $channelDisplay -ForegroundColor $channelColor
            foreach ($issue in $channel.Issues) {
                Write-IssueLine -Issue $issue
            }
        }

        foreach ($mapping in $scenario.Mappings) {
            $mappingDisplay = if ($mapping.Name -and $mapping.Name -ne 'N/A') { $mapping.Name } else { '(unnamed mapping)' }
            Write-Host -NoNewline '  Mapping: '
            Write-Host $mappingDisplay -ForegroundColor $mappingColor
            foreach ($issue in $mapping.Issues) {
                Write-IssueLine -Issue $issue
            }
        }

        Write-Output ''
    }
}

Write-Output "Total number of files processed: $($totalFilesProcessed)"
