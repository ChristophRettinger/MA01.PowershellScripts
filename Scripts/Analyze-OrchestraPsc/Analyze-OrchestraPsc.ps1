<#
.SYNOPSIS
    Analyzes Orchestra PSC scenario archives for process model configuration fields.

.DESCRIPTION
    Treats every *.psc file in the specified path as a scenario archive (ZIP file) containing
    one or more process models stored as XML files named "ProcessModell_<number>".
    For each process model, the script extracts the process model name and evaluates all
    configured field element names anywhere in the XML document, reporting their values.
    Results are written to the console and to a single status XML file in the output folder.

.PARAMETER Path
    Root folder that contains the *.psc files to analyze. Defaults to the current directory.

.PARAMETER Filter
    Optional wildcard filter (or list of filters) to match specific PSC files within Path.
    Use "all" (default) to include every PSC file.

.PARAMETER Fields
    List of XML element names to extract from each process model. Defaults to
    isPersistent, useRecovery, isMassData, isFifo, isGroupedFifo, redeployPolicy,
    volatilePoicy, manualRestart, pipelineMode, bestEffortLimit.

.PARAMETER Output
    Folder where the consolidated status XML file is written. Defaults to an "Output"
    sub-folder beneath Path.

.EXAMPLE
    .\Analyze-OrchestraPsc.ps1 -Path "C:\Data\Scenarios" -Filter "*Prod*.psc" \\
        -Fields isPersistent,isFifo -Output "C:\Data\Scenarios\Reports"
#>

param (
    [Parameter(Mandatory = $false)]
    [string]$Path = '.',

    [Parameter(Mandatory = $false)]
    [string[]]$Filter = @('all'),

    [Parameter(Mandatory = $false)]
    [string[]]$Fields = @(
        'isPersistent',
        'useRecovery',
        'isMassData',
        'isFifo',
        'isGroupedFifo',
        'redeployPolicy',
        'volatilePoicy',
        'manualRestart',
        'pipelineMode',
        'bestEffortLimit'
    ),

    [Parameter(Mandatory = $false)]
    [string]$Output
)

$resolvedPath = (Resolve-Path -Path $Path).Path
if (-not $Output) {
    $Output = Join-Path -Path $resolvedPath -ChildPath 'Output'
}

if (-not (Test-Path -Path $Output)) {
    New-Item -Path $Output -ItemType Directory -Force | Out-Null
}

Add-Type -AssemblyName 'System.IO.Compression.FileSystem' | Out-Null

$pscFiles = Get-ChildItem -Path $resolvedPath -Filter '*.psc' -File

if (-not ($Filter.Count -eq 1 -and $Filter[0].Equals('all', [System.StringComparison]::OrdinalIgnoreCase))) {
    $patterns = $Filter
    $pscFiles = $pscFiles | Where-Object {
        $fileName = $_.Name
        foreach ($pattern in $patterns) {
            if ($fileName -like $pattern) { return $true }
        }
        return $false
    }
}

if (-not $pscFiles) {
    Write-Warning "No PSC files found for analysis in '$resolvedPath'."
    return
}

$analysisResults = @()

foreach ($pscFile in $pscFiles) {
    Write-Host "Processing scenario: $($pscFile.Name)" -ForegroundColor Cyan

    $scenarioResult = [ordered]@{
        ScenarioFile   = $pscFile.Name
        ScenarioPath   = $pscFile.FullName
        ProcessModels  = @()
    }

    try {
        $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($pscFile.FullName)
    } catch {
        Write-Warning "  Failed to open PSC archive: $($_.Exception.Message)"
        continue
    }

    try {
        foreach ($entry in $zipArchive.Entries) {
            if (-not ($entry.FullName -match '^ProcessModell_\d+$')) {
                continue
            }

            $entryContent = $null
            $entryStream = $entry.Open()
            try {
                $reader = New-Object System.IO.StreamReader($entryStream)
                try {
                    $entryContent = $reader.ReadToEnd()
                } finally {
                    $reader.Dispose()
                }
            } finally {
                $entryStream.Dispose()
            }

            if (-not $entryContent) {
                Write-Warning "  Entry '$($entry.FullName)' is empty or unreadable."
                continue
            }

            try {
                [xml]$xmlDoc = $entryContent
            } catch {
                Write-Warning "  Entry '$($entry.FullName)' is not valid XML: $($_.Exception.Message)"
                continue
            }

            $nameNode = $xmlDoc.SelectSingleNode('//*[local-name()="name"][1]')
            $processName = if ($nameNode) { $nameNode.InnerText.Trim() } else { '' }

            $fieldValues = [ordered]@{}
            foreach ($field in $Fields) {
                $xpath = "//*[local-name()='$field']"
                $nodes = $xmlDoc.SelectNodes($xpath)
                if ($nodes) {
                    $values = @()
                    foreach ($node in $nodes) {
                        $value = $node.InnerText.Trim()
                        if (-not [string]::IsNullOrWhiteSpace($value)) {
                            $values += $value
                        }
                    }
                    $values = @($values | Sort-Object -Unique)
                    $fieldValues[$field] = $values
                } else {
                    $fieldValues[$field] = @()
                }
            }

            $processResult = [ordered]@{
                EntryName    = $entry.FullName
                ProcessName  = $processName
                Fields       = $fieldValues
            }

            $scenarioResult.ProcessModels += ,$processResult

            $displayName = if ($processName) { $processName } else { '(unnamed process model)' }
            Write-Host "  Process Model ($($entry.FullName)): $displayName" -ForegroundColor Green
            foreach ($field in $Fields) {
                $values = $fieldValues[$field]
                if ($values.Count -gt 0) {
                    $joined = $values -join ', '
                    Write-Host "    $field: $joined"
                } else {
                    Write-Host "    $field: (not found)"
                }
            }
        }
    } finally {
        $zipArchive.Dispose()
    }

    if ($scenarioResult.ProcessModels.Count -eq 0) {
        Write-Host "  No matching process models found in this scenario." -ForegroundColor Yellow
    }

    $analysisResults += ,$scenarioResult
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outputFileName = "Analyze-OrchestraPsc_Status_$timestamp.xml"
$outputFilePath = Join-Path -Path $Output -ChildPath $outputFileName

$xmlOutput = New-Object System.Xml.XmlDocument
$xmlDeclaration = $xmlOutput.CreateXmlDeclaration('1.0', 'UTF-8', $null)
$xmlOutput.AppendChild($xmlDeclaration) | Out-Null

$root = $xmlOutput.CreateElement('Analysis')
$root.SetAttribute('generatedOn', (Get-Date).ToString('o'))
$xmlOutput.AppendChild($root) | Out-Null

foreach ($scenario in $analysisResults) {
    $scenarioNode = $xmlOutput.CreateElement('Scenario')
    $scenarioNode.SetAttribute('file', $scenario.ScenarioFile)
    $scenarioNode.SetAttribute('path', $scenario.ScenarioPath)
    $root.AppendChild($scenarioNode) | Out-Null

    foreach ($process in $scenario.ProcessModels) {
        $processNode = $xmlOutput.CreateElement('ProcessModel')
        $processNode.SetAttribute('entry', $process.EntryName)
        if (-not [string]::IsNullOrWhiteSpace($process.ProcessName)) {
            $processNode.SetAttribute('name', $process.ProcessName)
        }
        $scenarioNode.AppendChild($processNode) | Out-Null

        foreach ($field in $Fields) {
            $fieldNode = $xmlOutput.CreateElement('Field')
            $fieldNode.SetAttribute('name', $field)
            $values = $process.Fields[$field]
            $hasValues = $values.Count -gt 0
            $fieldNode.SetAttribute('found', $hasValues.ToString().ToLower())
            if ($hasValues) {
                foreach ($value in $values) {
                    $valueNode = $xmlOutput.CreateElement('Value')
                    $valueNode.InnerText = $value
                    $fieldNode.AppendChild($valueNode) | Out-Null
                }
            }
            $processNode.AppendChild($fieldNode) | Out-Null
        }
    }
}

$xmlOutput.Save($outputFilePath)
Write-Host "Results written to '$outputFilePath'" -ForegroundColor Cyan
