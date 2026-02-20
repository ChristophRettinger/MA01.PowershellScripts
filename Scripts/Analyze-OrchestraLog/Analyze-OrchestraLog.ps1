<#
.SYNOPSIS
    Analyzes Orchestra log files and summarizes recurring warning/error entries.

.DESCRIPTION
    Reads one or more log files (including wildcard paths), parses log entries, and groups relevant entries
    by normalized statement text. The summary includes first/last occurrence, count, severity, flattened statement,
    and the first stacktrace list for each group.

.PARAMETER LogPath
    One or more log file paths. Wildcards are supported.

.PARAMETER OutputDirectory
    Optional directory for writing summary files in addition to console output.

.PARAMETER SettingsFile
    Optional text file with normalization rules for grouping. Each non-empty line must be:
    regex;replacement

.PARAMETER Severity
    Severity levels to include in the result (for example WARNING, SEVERE, ERROR).

.EXAMPLE
    .\Analyze-OrchestraLog.ps1 -LogPath ".\server.log"

.EXAMPLE
    .\Analyze-OrchestraLog.ps1 -LogPath ".\logs\*.log" -OutputDirectory ".\out" -SettingsFile ".\normalize.txt"
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [string[]]$LogPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $false)]
    [string]$SettingsFile,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string[]]$Severity = @('WARNING', 'SEVERE', 'ERROR')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-LogFiles {
    param (
        [string[]]$InputPaths
    )

    $resolvedFiles = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $InputPaths) {
        $matches = Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue
        foreach ($match in $matches) {
            if (-not $resolvedFiles.Contains($match.FullName)) {
                [void]$resolvedFiles.Add($match.FullName)
            }
        }
    }

    return $resolvedFiles
}

function Read-NormalizationRules {
    param (
        [string]$Path
    )

    $rules = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $rules
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Settings file not found: $Path"
    }

    $lineNumber = 0
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $lineNumber++
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }

        $parts = $trimmed -split ';', 2
        if ($parts.Count -ne 2) {
            throw "Invalid settings line $($lineNumber). Expected format: regex;replacement"
        }

        try {
            [void][regex]::new($parts[0])
        } catch {
            throw "Invalid regex on line $($lineNumber): $($parts[0])"
        }

        [void]$rules.Add([PSCustomObject]@{
            Pattern     = $parts[0]
            Replacement = $parts[1]
        })
    }

    return $rules
}

function Get-EntryStatement {
    param (
        [string]$Body
    )

    if ([string]::IsNullOrWhiteSpace($Body)) {
        return ''
    }

    $statementLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Body -split "`r?`n")) {
        if ($line -match '^\s*at\s+') { break }
        if ($line -match '^\s*Caused by:') { break }
        if ($line -match '^\s*\.\.\.\s+\d+\s+more\s*$') { break }

        $trimmed = $line.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            [void]$statementLines.Add($trimmed)
        }
    }

    if ($statementLines.Count -eq 0) {
        return ''
    }

    return (($statementLines -join ' ') -replace '\s+', ' ').Trim()
}

function Get-FirstStacktrace {
    param (
        [string]$Body
    )

    if ([string]::IsNullOrWhiteSpace($Body)) {
        return ''
    }

    foreach ($line in ($Body -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^at\s+') {
            return $trimmed
        }
    }

    return ''
}

function Normalize-Statement {
    param (
        [string]$Statement,
        [System.Collections.Generic.List[object]]$Rules
    )

    $normalized = $Statement
    foreach ($rule in $Rules) {
        $normalized = $normalized -replace $rule.Pattern, $rule.Replacement
    }

    return (($normalized -replace '\s+', ' ').Trim())
}

$files = @(Resolve-LogFiles -InputPaths $LogPath)
if ($files.Count -eq 0) {
    throw 'No log files found for the provided -LogPath values.'
}

$normalizationRules = Read-NormalizationRules -Path $SettingsFile

$entryHeaderRegex = '^\[(?<Timestamp>\d{2}\.\d{2}\.\d{4}/\d{2}:\d{2}:\d{2}\.\d{3})\]\s+\[(?<Severity>[^\]]+)\]\s+\[(?<ProcessId>[^\]]+)\]\s+\[(?<Source>[^\]]+)\]\s*(?<Message>.*)$'
$allowedSeverities = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
foreach ($item in $Severity) {
    if (-not [string]::IsNullOrWhiteSpace($item)) {
        [void]$allowedSeverities.Add($item.Trim())
    }
}
if ($allowedSeverities.Count -eq 0) {
    throw 'At least one severity value must be supplied via -Severity.'
}

$allLines = New-Object System.Collections.Generic.List[psobject]
$totalFiles = $files.Count

for ($fileIndex = 0; $fileIndex -lt $totalFiles; $fileIndex++) {
    $file = $files[$fileIndex]
    Write-Progress -Activity 'Loading log files' -Status "Reading $($file)" -PercentComplete ((($fileIndex + 1) / $totalFiles) * 100)

    $fileLines = @(Get-Content -LiteralPath $file)
    for ($lineIndex = 0; $lineIndex -lt $fileLines.Count; $lineIndex++) {
        [void]$allLines.Add([PSCustomObject]@{
            File = $file
            Text = $fileLines[$lineIndex]
        })
    }
}
Write-Progress -Activity 'Loading log files' -Completed

$groups = @{}
$current = $null
$totalLines = $allLines.Count

for ($index = 0; $index -lt $totalLines; $index++) {
    $line = $allLines[$index].Text
    $headerMatch = [regex]::Match($line, $entryHeaderRegex)

    Write-Progress -Activity 'Analyzing log entries' -Status "Processing line $($index + 1) of $($totalLines)" -PercentComplete ((($index + 1) / [Math]::Max(1, $totalLines)) * 100)

    if ($headerMatch.Success) {
        if ($null -ne $current) {
            $timestamp = [datetime]::ParseExact($current.Timestamp, 'dd.MM.yyyy/HH:mm:ss.fff', [System.Globalization.CultureInfo]::InvariantCulture)
            if ($allowedSeverities.Contains($current.Severity)) {
                $statement = Get-EntryStatement -Body $current.Body
                $normalized = Normalize-Statement -Statement $statement -Rules $normalizationRules
                if (-not [string]::IsNullOrWhiteSpace($normalized)) {
                    $stacktrace = Get-FirstStacktrace -Body $current.Body
                    if (-not $groups.ContainsKey($normalized)) {
                        $groups[$normalized] = [PSCustomObject]@{
                            FirstTime   = $timestamp
                            LastTime    = $timestamp
                            Count       = 0
                            Severity    = $current.Severity
                            Statement   = $normalized
                            FirstStack  = $stacktrace
                        }
                    }

                    $entry = $groups[$normalized]
                    $entry.Count++
                    if ($timestamp -lt $entry.FirstTime) { $entry.FirstTime = $timestamp }
                    if ($timestamp -gt $entry.LastTime) { $entry.LastTime = $timestamp }
                }
            }
        }

        $current = [PSCustomObject]@{
            Timestamp = $headerMatch.Groups['Timestamp'].Value
            Severity  = $headerMatch.Groups['Severity'].Value
            Body      = $headerMatch.Groups['Message'].Value
        }
    } elseif ($null -ne $current) {
        $current.Body += "`n$line"
    }
}

if ($null -ne $current) {
    $timestamp = [datetime]::ParseExact($current.Timestamp, 'dd.MM.yyyy/HH:mm:ss.fff', [System.Globalization.CultureInfo]::InvariantCulture)
    if ($allowedSeverities.Contains($current.Severity)) {
        $statement = Get-EntryStatement -Body $current.Body
        $normalized = Normalize-Statement -Statement $statement -Rules $normalizationRules
        if (-not [string]::IsNullOrWhiteSpace($normalized)) {
            $stacktrace = Get-FirstStacktrace -Body $current.Body
            if (-not $groups.ContainsKey($normalized)) {
                $groups[$normalized] = [PSCustomObject]@{
                    FirstTime   = $timestamp
                    LastTime    = $timestamp
                    Count       = 0
                    Severity    = $current.Severity
                    Statement   = $normalized
                    FirstStack  = $stacktrace
                }
            }

            $entry = $groups[$normalized]
            $entry.Count++
            if ($timestamp -lt $entry.FirstTime) { $entry.FirstTime = $timestamp }
            if ($timestamp -gt $entry.LastTime) { $entry.LastTime = $timestamp }
        }
    }
}
Write-Progress -Activity 'Analyzing log entries' -Completed

$summary = @($groups.Values |
    Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'FirstTime'; Descending = $false } |
    Select-Object @(
        @{ Name = 'FirstTime'; Expression = { $_.FirstTime.ToString('yyyy-MM-dd HH:mm:ss.fff') } },
        @{ Name = 'LastTime'; Expression = { $_.LastTime.ToString('yyyy-MM-dd HH:mm:ss.fff') } },
        'Count',
        'Severity',
        'Statement',
        @{ Name = 'FirstStacktrace'; Expression = { $_.FirstStack } }
    ))

Write-Host "Analyzed $($files.Count) log file(s), found $($summary.Count) grouped issue(s)." -ForegroundColor Cyan

$severityColors = @{
    'SEVERE' = 'Red'
    'ERROR' = 'Magenta'
    'WARNING' = 'Yellow'
}

foreach ($item in $summary) {
    $color = if ($severityColors.ContainsKey($item.Severity)) { $severityColors[$item.Severity] } else { 'White' }
    Write-Host "[$($item.Severity)] Count=$($item.Count) First=$($item.FirstTime) Last=$($item.LastTime)" -ForegroundColor $color
    Write-Host "  Statement: $($item.Statement)" -ForegroundColor Gray
    if (-not [string]::IsNullOrWhiteSpace($item.FirstStacktrace)) {
        Write-Host "  FirstStacktrace: $($item.FirstStacktrace)" -ForegroundColor DarkGray
    }
    Write-Host
}

if (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $csvPath = Join-Path -Path $OutputDirectory -ChildPath "Analyze-OrchestraLog_$($stamp).csv"
    $txtPath = Join-Path -Path $OutputDirectory -ChildPath "Analyze-OrchestraLog_$($stamp).txt"

    $summary | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    $summary | Format-Table -AutoSize | Out-String | Set-Content -Path $txtPath -Encoding UTF8

    Write-Host "Summary written to:" -ForegroundColor Green
    Write-Host "  $($csvPath)" -ForegroundColor Green
    Write-Host "  $($txtPath)" -ForegroundColor Green
}

$summary
