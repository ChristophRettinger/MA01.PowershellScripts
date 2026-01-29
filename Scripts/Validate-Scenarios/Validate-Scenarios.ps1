<#!
.SYNOPSIS
    Validates Orchestra scenario XML configuration files across scenario subfolders.

.DESCRIPTION
    Scans the provided root folder for ProcessModell_*, Channel_*, and MessageMapping_*
    XML files. For every scenario (grouped by the top-level folder beneath the root
    path), the script checks process model settings, business key counts, channel
    concurrency, and mapping parallel execution rules. Results are grouped by
    scenario name and printed with colored headings for the scenario, process
    models, channels, and mappings.

.PARAMETER Path
    Root folder that contains scenario subfolders. Defaults to the current directory.

.PARAMETER MaxBusinessKeyCount
    Maximum allowed number of business keys in a process model. Defaults to 6.

.EXAMPLE
    .\Validate-Scenarios.ps1 -Path "D:\Scenarios" -MaxBusinessKeyCount 8
#>

param (
    [Parameter(Mandatory = $false)]
    [string]$Path = '.',

    [Parameter(Mandatory = $false)]
    [int]$MaxBusinessKeyCount = 6
)

$resolvedPath = (Resolve-Path -Path $Path).Path

$processModelPattern = 'ProcessModell_*'
$channelPattern = 'Channel_*'
$mappingPattern = 'MessageMapping_*'

$businessKeysXPath = '/ProcessModel/businessKeys/Property'
$processModelXPaths = [ordered]@{
    isDurable = '/ProcessModel/processObjects/EventStart/trigger/isDurable'
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

    if ($file.Name -like $processModelPattern) {
        $businessKeysCount = ($xmlContent.SelectNodes($businessKeysXPath) | Measure-Object).Count
        $processModelName = Get-NodeValue -XmlDocument $xmlContent -XPath $processModelXPaths.name

        $issues = New-Object System.Collections.Generic.List[string]

        $isDurable = Get-NodeValue -XmlDocument $xmlContent -XPath $processModelXPaths.isDurable
        if ($isDurable -eq 'false') { $issues.Add('Signal subscription not persistent') }

        $manualRestart = Get-NodeValue -XmlDocument $xmlContent -XPath $processModelXPaths.manualRestart
        if ($manualRestart -ne 'true') { $issues.Add('Manual restart disabled') }

        $isPersistent = Get-NodeValue -XmlDocument $xmlContent -XPath $processModelXPaths.isPersistent
        if ($isPersistent -ne 'false') { $issues.Add('Process model is persistent') }

        $redeployPolicy = Get-NodeValue -XmlDocument $xmlContent -XPath $processModelXPaths.redeployPolicy
        if ($redeployPolicy -ne '1') { $issues.Add('Redeployment strategy is set to abort') }

        $volatilePolicy = Get-NodeValue -XmlDocument $xmlContent -XPath $processModelXPaths.volatilePolicy
        if ($volatilePolicy -ne '1') { $issues.Add('Process model is not set to volatile with recovery') }

        if ($businessKeysCount -gt $MaxBusinessKeyCount) {
            $issues.Add("Too many business keys, Count: $($businessKeysCount)")
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
        $channelName = Get-NodeValue -XmlDocument $xmlContent -XPath '/emds.epi.impl.adapter.http.outbound.HttpOutboundGeneralChannel/name'
        $numberOfInstances = Get-NodeValue -XmlDocument $xmlContent -XPath '/emds.epi.impl.adapter.http.outbound.HttpOutboundGeneralChannel/numberOfInstances'

        if ($numberOfInstances -eq '1') {
            $scenarioResults[$scenarioInfo.Name].Channels += [PSCustomObject]@{
                Name = $channelName
                Path = $filePath
                Issues = @("Channel $($channelName) is not concurrent")
            }
        }

        continue
    }

    if ($file.Name -like $mappingPattern) {
        $mappingName = Get-NodeValue -XmlDocument $xmlContent -XPath '/emds.mapping.proc.MappingScript/name'
        $parallelExecution = Get-NodeValue -XmlDocument $xmlContent -XPath '/emds.mapping.proc.MappingScript/parallelExecution'

        if ($parallelExecution -ne 'true') {
            $scenarioResults[$scenarioInfo.Name].Mappings += [PSCustomObject]@{
                Name = $mappingName
                Path = $filePath
                Issues = @("Mapping $($mappingName) is not concurrent")
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
                Write-Host "    - $($issue)"
            }
        }

        foreach ($channel in $scenario.Channels) {
            $channelDisplay = if ($channel.Name -and $channel.Name -ne 'N/A') { $channel.Name } else { '(unnamed channel)' }
            Write-Host -NoNewline '  Channel: '
            Write-Host $channelDisplay -ForegroundColor $channelColor
            foreach ($issue in $channel.Issues) {
                Write-Host "    - $($issue)"
            }
        }

        foreach ($mapping in $scenario.Mappings) {
            $mappingDisplay = if ($mapping.Name -and $mapping.Name -ne 'N/A') { $mapping.Name } else { '(unnamed mapping)' }
            Write-Host -NoNewline '  Mapping: '
            Write-Host $mappingDisplay -ForegroundColor $mappingColor
            foreach ($issue in $mapping.Issues) {
                Write-Host "    - $($issue)"
            }
        }

        Write-Output ''
    }
}

Write-Output "Total number of files processed: $($totalFilesProcessed)"
