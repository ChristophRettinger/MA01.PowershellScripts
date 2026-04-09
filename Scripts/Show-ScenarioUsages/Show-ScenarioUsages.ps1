<#
.SYNOPSIS
    Scans Orchestra scenario folders and reports configured usage feature codes.

.DESCRIPTION
    Iterates over scenario files in a folder (or a direct scenario folder path) and
    evaluates predefined feature codes such as ErrorHandling usage, legacy logging,
    and selected message mappings. Results are grouped per scenario and can be
    filtered by code and/or code type.

.PARAMETER Path
    Root folder that contains scenario folders, or a direct scenario folder path.
    Defaults to the current directory.

.PARAMETER ScenarioFilter
    Optional wildcard filter for scenario folder names. Use "all" to include every
    scenario.

.PARAMETER Codes
    Optional list of feature codes to evaluate. When omitted, all codes are checked.

.PARAMETER CodeTypes
    Optional list of feature code types to evaluate (Desired, Information, Warning).

.PARAMETER Evidence
    Include evidence file paths for each matched code. Disabled by default.

.EXAMPLE
    .\Show-ScenarioUsages.ps1 -Path 'D:\Scenarios' -CodeTypes Desired,Warning

.EXAMPLE
    .\Show-ScenarioUsages.ps1 -Path 'D:\Scenarios' -Evidence
#>

param (
    [Parameter(Mandatory = $false)]
    [string]$Path = '.',

    [Parameter(Mandatory = $false)]
    [string[]]$ScenarioFilter = @('all'),

    [Parameter(Mandatory = $false)]
    [string[]]$Codes,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Desired', 'Information', 'Warning')]
    [string[]]$CodeTypes,

    [Parameter(Mandatory = $false)]
    [switch]$Evidence
)

$resolvedPath = (Resolve-Path -Path $Path).Path

$script:codeDefinitions = @(
    [PSCustomObject]@{
        Code = 'ErrorHandling'
        Type = 'Desired'
        Description = 'Uses the unified ErrorHandling'
        TargetKinds = @('ProcessModel')
        MatchAny = @(
            'orcjava.ErrorHandling.evaluateError',
            'orcjava.ErrorHandling.evaluateUnrecoverableError'
        )
        MatchAll = @()
    },
    [PSCustomObject]@{
        Code = 'ErrorHandling-evaluateError'
        Type = 'Information'
        Description = 'Uses the unified ErrorHandling with evaluateError'
        TargetKinds = @('ProcessModel')
        MatchAny = @('orcjava.ErrorHandling.evaluateError')
        MatchAll = @()
    },
    [PSCustomObject]@{
        Code = 'ErrorHandling-evaluateUnrecoverableError'
        Type = 'Information'
        Description = 'Uses the unified ErrorHandling with evaluateUnrecoverableError'
        TargetKinds = @('ProcessModel')
        MatchAny = @('orcjava.ErrorHandling.evaluateUnrecoverableError')
        MatchAll = @()
    },
    [PSCustomObject]@{
        Code = 'Legacy-Log'
        Type = 'Warning'
        Description = 'Uses the legacy Log class'
        TargetKinds = @('Any')
        MatchAny = @()
        MatchAll = @('SUBFL.Log')
    },
    [PSCustomObject]@{
        Code = 'Elastic-Oneshape'
        Type = 'Desired'
        Description = 'Uses the new one-shape Elastic logging'
        TargetKinds = @('MessageMapping')
        MatchAny = @()
        MatchAll = @('mm_ElasticHandling')
    },
    [PSCustomObject]@{
        Code = 'TransmissionStorage'
        Type = 'Information'
        Description = 'Uses the Transmission Storage concept'
        TargetKinds = @('MessageMapping')
        MatchAny = @()
        MatchAll = @('mm_StoreTransmission')
    }
)

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
        $relativePathSegments = @([regex]::Split($relativePath, '[\\/]+') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $scenarioName = if ($relativePathSegments.Count -gt 0) { [string]$relativePathSegments[0] } else { '' }
        $scenarioPath = Join-Path -Path $RootPath -ChildPath $scenarioName
    }
    else {
        $scenarioName = Split-Path -Path $directoryPath -Leaf
        $scenarioPath = $directoryPath
    }

    [PSCustomObject]@{
        Name = $scenarioName
        Path = $scenarioPath
    }
}

function Get-TargetKind {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    if ($FileName -like 'ProcessModell_*') { return 'ProcessModel' }
    if ($FileName -like 'MessageMapping_*') { return 'MessageMapping' }
    return 'Any'
}

function Test-DefinitionMatch {
    param (
        [Parameter(Mandatory = $true)]
        [object]$Definition,

        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    if ($Definition.MatchAny.Count -gt 0) {
        foreach ($needle in $Definition.MatchAny) {
            if ($Content.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return $true
            }
        }

        return $false
    }

    foreach ($needle in $Definition.MatchAll) {
        if ($Content.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            return $false
        }
    }

    return $Definition.MatchAll.Count -gt 0
}

$requestedCodeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
if ($PSBoundParameters.ContainsKey('Codes') -and $Codes) {
    foreach ($entry in $Codes) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }

        foreach ($token in ($entry -split '[,;]')) {
            $trimmed = $token.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                $null = $requestedCodeSet.Add($trimmed)
            }
        }
    }
}

$requestedTypeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
if ($PSBoundParameters.ContainsKey('CodeTypes') -and $CodeTypes) {
    foreach ($entry in $CodeTypes) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }

        foreach ($token in ($entry -split '[,;]')) {
            $trimmed = $token.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                $null = $requestedTypeSet.Add($trimmed)
            }
        }
    }
}

$selectedDefinitions = @(
    $script:codeDefinitions | Where-Object {
        ($requestedCodeSet.Count -eq 0 -or $requestedCodeSet.Contains($_.Code)) -and
        ($requestedTypeSet.Count -eq 0 -or $requestedTypeSet.Contains($_.Type))
    }
)

if (-not $selectedDefinitions -or $selectedDefinitions.Count -eq 0) {
    Write-Warning 'No feature codes selected. Adjust -Codes and/or -CodeTypes.'
    return
}

$unknownCodes = @()
if ($requestedCodeSet.Count -gt 0) {
    $knownCodeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($definition in $script:codeDefinitions) {
        $null = $knownCodeSet.Add($definition.Code)
    }

    foreach ($candidate in $requestedCodeSet) {
        if (-not $knownCodeSet.Contains($candidate)) {
            $unknownCodes += $candidate
        }
    }
}

if ($unknownCodes.Count -gt 0) {
    Write-Warning ("Unknown code filter(s): $($unknownCodes -join ', ')")
}

$filterMatchers = @($ScenarioFilter | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($filterMatchers.Count -eq 0) {
    $filterMatchers = @('all')
}

$includeAllScenarios = $false
foreach ($matcher in $filterMatchers) {
    if ($matcher.Equals('all', [System.StringComparison]::OrdinalIgnoreCase)) {
        $includeAllScenarios = $true
        break
    }
}

$files = Get-ChildItem -Path $resolvedPath -File -Recurse | Where-Object {
    $_.Name -like 'ProcessModell_*' -or $_.Name -like 'MessageMapping_*' -or $_.Name -like 'Channel_*'
}

if (-not $files -or $files.Count -eq 0) {
    Write-Warning "No scenario files found below $($resolvedPath)."
    return
}

$scenarioUsageMap = [ordered]@{}

foreach ($file in $files) {
    $scenarioInfo = Get-ScenarioInfo -FilePath $file.FullName -RootPath $resolvedPath
    if ([string]::IsNullOrWhiteSpace($scenarioInfo.Name)) { continue }

    if (-not $includeAllScenarios) {
        $matchesFilter = $false
        foreach ($matcher in $filterMatchers) {
            if ($scenarioInfo.Name -like $matcher) {
                $matchesFilter = $true
                break
            }
        }

        if (-not $matchesFilter) {
            continue
        }
    }

    if (-not $scenarioUsageMap.Contains($scenarioInfo.Name)) {
        $scenarioUsageMap[$scenarioInfo.Name] = [ordered]@{
            Name = $scenarioInfo.Name
            Path = $scenarioInfo.Path
            Hits = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        }
    }

    $content = Get-Content -Path $file.FullName -Raw
    $targetKind = Get-TargetKind -FileName $file.Name

    foreach ($definition in $selectedDefinitions) {
        if ($scenarioUsageMap[$scenarioInfo.Name].Hits.ContainsKey($definition.Code)) {
            continue
        }

        $supportsTarget = $definition.TargetKinds -contains 'Any' -or $definition.TargetKinds -contains $targetKind
        if (-not $supportsTarget) {
            continue
        }

        if (Test-DefinitionMatch -Definition $definition -Content $content) {
            $scenarioUsageMap[$scenarioInfo.Name].Hits[$definition.Code] = [PSCustomObject]@{
                Code = $definition.Code
                Type = $definition.Type
                Description = $definition.Description
                Evidence = $file.FullName
            }
        }
    }
}

$scenarioItems = @($scenarioUsageMap.Values | Sort-Object -Property Name)
if (-not $scenarioItems -or $scenarioItems.Count -eq 0) {
    Write-Warning 'No scenarios matched the provided filters.'
    return
}

$colorByType = @{
    Desired = 'Green'
    Information = 'Cyan'
    Warning = 'Yellow'
}

$codeTotals = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($definition in $selectedDefinitions) {
    $codeTotals[$definition.Code] = 0
}

Write-Host ''
Write-Host 'Scenario usage report' -ForegroundColor White
Write-Host ('Root: {0}' -f $resolvedPath) -ForegroundColor DarkGray
Write-Host ('Selected codes: {0}' -f (($selectedDefinitions | Select-Object -ExpandProperty Code) -join ', ')) -ForegroundColor DarkGray
Write-Host ''

foreach ($scenario in $scenarioItems) {
    Write-Host $scenario.Name -ForegroundColor Magenta
    Write-Host ('  Path: {0}' -f $scenario.Path) -ForegroundColor DarkGray

    $hits = @($scenario.Hits.Values | Sort-Object -Property Code)
    if ($hits.Count -eq 0) {
        Write-Host '  (no matching usages)' -ForegroundColor DarkGray
        Write-Host ''
        continue
    }

    foreach ($hit in $hits) {
        $codeTotals[$hit.Code] = $codeTotals[$hit.Code] + 1
        $typeColor = if ($colorByType.ContainsKey($hit.Type)) { $colorByType[$hit.Type] } else { 'Gray' }
        Write-Host ("  [$($hit.Code)] [$($hit.Type)] $($hit.Description)") -ForegroundColor $typeColor
        if ($Evidence) {
            Write-Host ("    Evidence: $($hit.Evidence)") -ForegroundColor DarkGray
        }
    }

    Write-Host ''
}

Write-Host 'Code summary' -ForegroundColor White
foreach ($definition in ($selectedDefinitions | Sort-Object -Property Code)) {
    $typeColor = if ($colorByType.ContainsKey($definition.Type)) { $colorByType[$definition.Type] } else { 'Gray' }
    Write-Host ("  [$($definition.Code)] [$($definition.Type)] scenarios: $($codeTotals[$definition.Code])") -ForegroundColor $typeColor
}
