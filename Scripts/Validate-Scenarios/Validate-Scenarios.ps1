<#
.SYNOPSIS
    Validates Orchestra scenario XML configuration files across scenario subfolders.

.DESCRIPTION
    Scans the provided root folder for ProcessModell_*, Channel_*, and MessageMapping_*
    XML files. Optionally, PSC scenario archives can be opened and inspected for the
    same configuration files. For every scenario (grouped by the top-level folder
    beneath the root path, or by PSC file name), the script checks process model
    settings, business key counts, channel concurrency, and mapping parallel
    execution rules. Results are grouped by scenario name and printed with colored
    headings for the scenario, process models, channels, and mappings. Description
    tags in each XML document can include exception codes (for example: "PM:v; RS:a;
    SC:p75") to allow deviations from the default validation rules.

.NOTES
    Default naming expectations (documented for reference even if not validated):
    - PM (Process Mode): vr (volatile with recovery)
    - RS (Redeployment Strategy): r (restart on redeploy)
    - MR (Manual Restart): e (manual restart enabled)
    - SC (Scheduling): p (parallel unbounded scheduling)
    - BK (Business Keys): MaxBusinessKeyCount (maximum allowed business keys)
    - SI (Input Signal): p (persistent subscription)
    - ST (Resource usage strategy): p (parallel execution) for channels and mappings

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

.PARAMETER Filter
    Optional wildcard filter (or list of filters) applied to scenario folder names
    in Folder mode or PSC file names in PSC mode. Use "all" (default) to include
    every folder or PSC file.

.PARAMETER Mode
    Specifies whether to validate scenario folders ("Folder") or only PSC archives
    in the target directory ("PSC"). Defaults to Folder.

.PARAMETER IncludePsc
    When set in Folder mode, also inspects .psc archive files found beneath the
    selected scenario folders.

.PARAMETER Output
    Optional file path or folder path used to write a text copy of the validation
    results.

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
    [string[]]$ErrorCategories,

    [Parameter(Mandatory = $false)]
    [string[]]$Filter = @('all'),

    [Parameter(Mandatory = $false)]
    [ValidateSet('Folder', 'PSC')]
    [string]$Mode = 'Folder',

    [Parameter(Mandatory = $false)]
    [switch]$IncludePsc,

    [Parameter(Mandatory = $false)]
    [string]$Output
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

$filterProvided = $PSBoundParameters.ContainsKey('Filter')
$effectivePscFilters = $Filter
if ($Mode -eq 'PSC' -and (-not $filterProvided -or ($Filter.Count -eq 1 -and $Filter[0].Equals('all', [System.StringComparison]::OrdinalIgnoreCase)))) {
    $effectivePscFilters = @('*.psc')
}

if ($IncludePsc -or $Mode -eq 'PSC') {
    Add-Type -AssemblyName 'System.IO.Compression.FileSystem' | Out-Null
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

function Test-NameMatchesFilter {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string[]]$Filters
    )

    if (-not $Filters -or ($Filters.Count -eq 1 -and $Filters[0].Equals('all', [System.StringComparison]::OrdinalIgnoreCase))) {
        return $true
    }

    foreach ($pattern in $Filters) {
        if ([string]::IsNullOrWhiteSpace($pattern)) {
            continue
        }

        if ($Name -like $pattern) {
            return $true
        }

        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Name)
        if ($baseName -and $baseName -ne $Name -and $baseName -like $pattern) {
            return $true
        }
    }

    return $false
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

    $lineText = Format-IssueLine -Issue $Issue
    Write-Host -NoNewline '    - '
    Write-Host -NoNewline $Issue.Short -ForegroundColor $issueColor
    if ($Issue.Message) {
        Write-Host " $($Issue.Message)"
    } else {
        Write-Host ''
    }

    Add-OutputLine -Line $lineText
}

$outputLines = New-Object System.Collections.Generic.List[string]

function Add-OutputLine {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Line
    )

    $outputLines.Add($Line)
}

function Format-IssueLine {
    param (
        [Parameter(Mandatory = $true)]
        [object]$Issue
    )

    if ($Issue.Message) {
        return "    - $($Issue.Short) $($Issue.Message)"
    }

    return "    - $($Issue.Short)"
}

function Add-ScenarioResult {
    param (
        [Parameter(Mandatory = $true)]
        [object]$ScenarioInfo,

        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [xml]$XmlContent
    )

    if (-not $script:scenarioResults.ContainsKey($ScenarioInfo.Name)) {
        $script:scenarioResults[$ScenarioInfo.Name] = [ordered]@{
            Name = $ScenarioInfo.Name
            Path = $ScenarioInfo.Path
            ProcessModels = @()
            Channels = @()
            Mappings = @()
        }
    }

    $descriptionTokens = Get-DescriptionTokens -XmlDocument $XmlContent

    if ($FileName -like $script:processModelPattern) {
        $businessKeysCount = ($XmlContent.SelectNodes($script:businessKeysXPath) | Measure-Object).Count
        $processModelName = Get-NodeValue -XmlDocument $XmlContent -XPath $script:processModelXPaths.name

        $issues = New-Object System.Collections.Generic.List[object]

        $isDurable = Get-NodeValue -XmlDocument $XmlContent -XPath $script:processModelXPaths.isDurable
        $manualRestart = Get-NodeValue -XmlDocument $XmlContent -XPath $script:processModelXPaths.manualRestart
        $isPersistent = Get-NodeValue -XmlDocument $XmlContent -XPath $script:processModelXPaths.isPersistent
        $redeployPolicy = Get-NodeValue -XmlDocument $XmlContent -XPath $script:processModelXPaths.redeployPolicy
        $volatilePolicy = Get-NodeValue -XmlDocument $XmlContent -XPath $script:processModelXPaths.volatilePolicy

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
            $script:scenarioResults[$ScenarioInfo.Name].ProcessModels += [PSCustomObject]@{
                Name = $processModelName
                Path = $FilePath
                Issues = $issues
            }
        }

        return
    }

    if ($FileName -like $script:channelPattern) {
        $channelName = Get-NodeValue -XmlDocument $XmlContent -XPath '/*[1]/name'
        $numberOfInstances = Get-NodeValue -XmlDocument $XmlContent -XPath '/*[1]/numberOfInstances'
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
                $script:scenarioResults[$ScenarioInfo.Name].Channels += [PSCustomObject]@{
                    Name = $channelName
                    Path = $FilePath
                    Issues = $issueList
                }
            }
        }

        return
    }

    if ($FileName -like $script:mappingPattern) {
        $mappingName = Get-NodeValue -XmlDocument $XmlContent -XPath '/emds.mapping.proc.MappingScript/name'
        $parallelExecution = Get-NodeValue -XmlDocument $XmlContent -XPath '/emds.mapping.proc.MappingScript/parallelExecution'
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
                $script:scenarioResults[$ScenarioInfo.Name].Mappings += [PSCustomObject]@{
                    Name = $mappingName
                    Path = $FilePath
                    Issues = $issueList
                }
            }
        }
    }
}

$scenarioResults = @{}
$totalFilesProcessed = 0

$scenarioRootPath = $resolvedPath
$files = @()
$pscFiles = @()

if ($Mode -eq 'Folder') {
    $scenarioFolders = Get-ChildItem -Path $resolvedPath -Directory -ErrorAction SilentlyContinue
    if (-not $scenarioFolders) {
        $scenarioFolders = @(Get-Item -Path $resolvedPath)
        $scenarioRootPath = Split-Path -Path $resolvedPath -Parent
        if (-not $scenarioRootPath) {
            $scenarioRootPath = $resolvedPath
        }
    } else {
        $scenarioFolders = $scenarioFolders | Where-Object {
            Test-NameMatchesFilter -Name $_.Name -Filters $Filter
        }
    }

    $scenarioFolderPaths = $scenarioFolders | ForEach-Object { $_.FullName }
    if ($scenarioFolderPaths) {
        $files = Get-ChildItem -Path $scenarioFolderPaths -Recurse -File | Where-Object {
            ($_.Name -like $processModelPattern -or $_.Name -like $channelPattern -or $_.Name -like $mappingPattern) -and $_.Extension -eq ""
        }
    }

    if ($IncludePsc -and $scenarioFolderPaths) {
        $pscFiles = Get-ChildItem -Path $scenarioFolderPaths -Recurse -Filter '*.psc' -File
    }
} else {
    $pscFiles = Get-ChildItem -Path $resolvedPath -File -Filter '*.psc' | Where-Object {
        Test-NameMatchesFilter -Name $_.Name -Filters $effectivePscFilters
    }
}

foreach ($file in $files) {
    $filePath = $file.FullName
    $scenarioInfo = Get-ScenarioInfo -FilePath $filePath -RootPath $scenarioRootPath

    try {
        $xmlContent = Get-XmlDocument -FilePath $filePath
    } catch {
        Write-Warning "Error processing file: $($filePath)"
        Write-Warning $($_.Exception.Message)
        continue
    }

    $totalFilesProcessed += 1
    Add-ScenarioResult -ScenarioInfo $scenarioInfo -FileName $file.Name -FilePath $filePath -XmlContent $xmlContent
}

foreach ($pscFile in $pscFiles) {
    $scenarioInfo = [PSCustomObject]@{
        Name = [System.IO.Path]::GetFileNameWithoutExtension($pscFile.Name)
        Path = $pscFile.FullName
    }

    try {
        $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($pscFile.FullName)
    } catch {
        Write-Warning "Error opening PSC archive: $($pscFile.FullName)"
        Write-Warning $($_.Exception.Message)
        continue
    }

    try {
        foreach ($entry in $zipArchive.Entries) {
            $entryName = [System.IO.Path]::GetFileName($entry.FullName)
            if (-not $entryName) {
                continue
            }

            if (-not [string]::IsNullOrWhiteSpace([System.IO.Path]::GetExtension($entryName))) {
                continue
            }

            if (-not ($entryName -like $processModelPattern -or $entryName -like $channelPattern -or $entryName -like $mappingPattern)) {
                continue
            }

            $entryPath = Join-Path -Path $pscFile.FullName -ChildPath $entry.FullName

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
                Write-Warning "Entry '$($entry.FullName)' in archive '$($pscFile.Name)' is empty or unreadable."
                continue
            }

            try {
                [xml]$xmlContent = $entryContent
            } catch {
                Write-Warning "Entry '$($entry.FullName)' in archive '$($pscFile.Name)' is not valid XML: $($_.Exception.Message)"
                continue
            }

            $totalFilesProcessed += 1
            Add-ScenarioResult -ScenarioInfo $scenarioInfo -FileName $entryName -FilePath $entryPath -XmlContent $xmlContent
        }
    } finally {
        $zipArchive.Dispose()
    }
}

$scenariosWithIssues = $scenarioResults.Values | Where-Object {
    $_.ProcessModels.Count -gt 0 -or $_.Channels.Count -gt 0 -or $_.Mappings.Count -gt 0
}

if (-not $scenariosWithIssues) {
    Write-Output 'No incorrect configurations found.'
    Add-OutputLine -Line 'No incorrect configurations found.'
} else {
    Write-Output "Scenario Validation Results (Incorrect Configurations):`n"
    Add-OutputLine -Line 'Scenario Validation Results (Incorrect Configurations):'
    Add-OutputLine -Line ''

    foreach ($scenario in $scenariosWithIssues | Sort-Object Name) {
        Write-Host -NoNewline $scenario.Name -ForegroundColor $scenarioColor
        Write-Host " [$($scenario.Path)]"
        Add-OutputLine -Line "$($scenario.Name) [$($scenario.Path)]"

        foreach ($processModel in $scenario.ProcessModels) {
            $displayName = if ($processModel.Name -and $processModel.Name -ne 'N/A') { $processModel.Name } else { '(unnamed process model)' }
            Write-Host -NoNewline '  Process Model: '
            Write-Host $displayName -ForegroundColor $processModelColor
            Add-OutputLine -Line "  Process Model: $($displayName)"
            foreach ($issue in $processModel.Issues) {
                Write-IssueLine -Issue $issue
            }
        }

        foreach ($channel in $scenario.Channels) {
            $channelDisplay = if ($channel.Name -and $channel.Name -ne 'N/A') { $channel.Name } else { '(unnamed channel)' }
            Write-Host -NoNewline '  Channel: '
            Write-Host $channelDisplay -ForegroundColor $channelColor
            Add-OutputLine -Line "  Channel: $($channelDisplay)"
            foreach ($issue in $channel.Issues) {
                Write-IssueLine -Issue $issue
            }
        }

        foreach ($mapping in $scenario.Mappings) {
            $mappingDisplay = if ($mapping.Name -and $mapping.Name -ne 'N/A') { $mapping.Name } else { '(unnamed mapping)' }
            Write-Host -NoNewline '  Mapping: '
            Write-Host $mappingDisplay -ForegroundColor $mappingColor
            Add-OutputLine -Line "  Mapping: $($mappingDisplay)"
            foreach ($issue in $mapping.Issues) {
                Write-IssueLine -Issue $issue
            }
        }

        Write-Output ''
        Add-OutputLine -Line ''
    }
}

Write-Output "Total number of files processed: $($totalFilesProcessed)"
Add-OutputLine -Line "Total number of files processed: $($totalFilesProcessed)"

if ($PSBoundParameters.ContainsKey('Output') -and -not [string]::IsNullOrWhiteSpace($Output)) {
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $outputFilePath = $null

    if (Test-Path -Path $Output) {
        $outputItem = Get-Item -Path $Output
        if ($outputItem.PSIsContainer) {
            $outputFilePath = Join-Path -Path $Output -ChildPath "Validate-Scenarios_$timestamp.txt"
        } else {
            $outputFilePath = $Output
        }
    } else {
        $extension = [System.IO.Path]::GetExtension($Output)
        if ([string]::IsNullOrWhiteSpace($extension)) {
            New-Item -Path $Output -ItemType Directory -Force | Out-Null
            $outputFilePath = Join-Path -Path $Output -ChildPath "Validate-Scenarios_$timestamp.txt"
        } else {
            $parentPath = Split-Path -Path $Output -Parent
            if ($parentPath -and -not (Test-Path -Path $parentPath)) {
                New-Item -Path $parentPath -ItemType Directory -Force | Out-Null
            }
            $outputFilePath = $Output
        }
    }

    if ($outputFilePath) {
        $outputLines | Out-File -FilePath $outputFilePath -Encoding utf8
        Write-Host "Results written to '$($outputFilePath)'" -ForegroundColor Cyan
    }
}
