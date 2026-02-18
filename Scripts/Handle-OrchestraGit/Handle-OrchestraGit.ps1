<#
.SYNOPSIS
    Runs actions against Orchestra git repositories beneath a folder.

.DESCRIPTION
    Detects repository roots by locating `.git` directories beneath the supplied path.
    For the `Status` action, the script ensures required exclude entries exist in each
    repository's `.git/info/exclude` file, evaluates repository state, and prints a
    single-line, colorized status overview per repository.

.PARAMETER Path
    Folder that is either a repository root (contains `.git`) or a parent folder that
    contains one or more repository roots.

.PARAMETER Action
    Action to execute. Currently supports `Status`.

.PARAMETER Output
    Optional output file path or output folder path to additionally write the plain-text
    status lines.

.EXAMPLE
    .\Handle-OrchestraGit.ps1 -Path 'D:\Orchestra' -Action Status

.EXAMPLE
    .\Handle-OrchestraGit.ps1 -Path 'D:\Orchestra' -Action Status -Output '.\Output'
#>

param (
    [Parameter(Mandatory = $false)]
    [string]$Path = '.',

    [Parameter(Mandatory = $false)]
    [ValidateSet('Status')]
    [string]$Action = 'Status',

    [Parameter(Mandatory = $false)]
    [string]$Output
)

$requiredExcludeEntries = @(
    '/orc.cred',
    '/association.map',
    '/lock',
    '/*.local',
    '/TestEnvironment*'
)

function Resolve-RepositoryRoots {
    param (
        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    $resolvedRoot = (Resolve-Path -Path $RootPath -ErrorAction Stop).Path
    $repositories = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

    $rootGitFolder = Join-Path -Path $resolvedRoot -ChildPath '.git'
    if (Test-Path -Path $rootGitFolder -PathType Container) {
        $null = $repositories.Add($resolvedRoot)
    }

    $gitDirectories = Get-ChildItem -Path $resolvedRoot -Directory -Filter '.git' -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($gitDirectory in $gitDirectories) {
        $repositoryRoot = Split-Path -Path $gitDirectory.FullName -Parent
        $null = $repositories.Add($repositoryRoot)
    }

    return $repositories | Sort-Object
}

function Ensure-GitExcludeEntries {
    param (
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [Parameter(Mandatory = $true)]
        [string[]]$Entries
    )

    $infoPath = Join-Path -Path $RepositoryPath -ChildPath '.git/info'
    if (-not (Test-Path -Path $infoPath -PathType Container)) {
        New-Item -Path $infoPath -ItemType Directory -Force | Out-Null
    }

    $excludePath = Join-Path -Path $infoPath -ChildPath 'exclude'
    if (-not (Test-Path -Path $excludePath -PathType Leaf)) {
        New-Item -Path $excludePath -ItemType File -Force | Out-Null
    }

    $existingLines = @()
    if (Test-Path -Path $excludePath -PathType Leaf) {
        $existingLines = @(Get-Content -Path $excludePath -ErrorAction SilentlyContinue)
    }

    $normalizedExisting = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $existingLines) {
        $trimmed = $line.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            $null = $normalizedExisting.Add($trimmed)
        }
    }

    $linesToAppend = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $Entries) {
        if (-not $normalizedExisting.Contains($entry)) {
            $linesToAppend.Add($entry) | Out-Null
        }
    }

    if ($linesToAppend.Count -gt 0) {
        Add-Content -Path $excludePath -Value $linesToAppend -Encoding UTF8
    }
}

function Get-RepositoryStatus {
    param (
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath
    )

    $repoName = Split-Path -Path $RepositoryPath -Leaf
    $tag = (& git -C $RepositoryPath describe --tags --exact-match 2>$null)
    if ([string]::IsNullOrWhiteSpace($tag)) {
        $tag = '-'
    }

    $pendingChanges = (& git -C $RepositoryPath status --porcelain 2>$null)
    $hasPendingChanges = -not [string]::IsNullOrWhiteSpace(($pendingChanges | Out-String).Trim())

    & git -C $RepositoryPath fetch --quiet --all --prune 2>$null

    $upstream = (& git -C $RepositoryPath rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
    $overview = 'Up to date'

    if ($hasPendingChanges) {
        $overview = 'Pending changes'
    } elseif (-not [string]::IsNullOrWhiteSpace($upstream)) {
        $aheadBehind = (& git -C $RepositoryPath rev-list --left-right --count HEAD...@{u} 2>$null)
        if (-not [string]::IsNullOrWhiteSpace($aheadBehind)) {
            $parts = $aheadBehind.Trim() -split '\s+'
            if ($parts.Count -ge 2) {
                $behindCount = 0
                if (-not [int]::TryParse($parts[1], [ref]$behindCount)) {
                    $behindCount = 0
                }

                if ($behindCount -gt 0) {
                    $overview = "Update available ($($upstream))"
                }
            }
        }
    }

    return [PSCustomObject]@{
        Name = $repoName
        Tag = $tag.Trim()
        Overview = $overview
    }
}

function Write-RepositoryStatusLine {
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Status
    )

    $overviewColor = 'Green'
    if ($Status.Overview -like 'Pending changes*') {
        $overviewColor = 'Yellow'
    } elseif ($Status.Overview -like 'Update available*') {
        $overviewColor = 'Red'
    }

    Write-Host -NoNewline 'Repo: ' -ForegroundColor DarkGray
    Write-Host -NoNewline $Status.Name -ForegroundColor Cyan
    Write-Host -NoNewline ' | Tag: ' -ForegroundColor DarkGray
    Write-Host -NoNewline $Status.Tag -ForegroundColor Magenta
    Write-Host -NoNewline ' | Status: ' -ForegroundColor DarkGray
    Write-Host $Status.Overview -ForegroundColor $overviewColor
}

$repositoryRoots = Resolve-RepositoryRoots -RootPath $Path
if (-not $repositoryRoots -or $repositoryRoots.Count -eq 0) {
    Write-Warning "No git repositories found below '$($Path)'."
    return
}

$outputLines = New-Object System.Collections.Generic.List[string]

switch ($Action) {
    'Status' {
        foreach ($repositoryRoot in $repositoryRoots) {
            Ensure-GitExcludeEntries -RepositoryPath $repositoryRoot -Entries $requiredExcludeEntries
            $status = Get-RepositoryStatus -RepositoryPath $repositoryRoot
            Write-RepositoryStatusLine -Status $status
            $outputLines.Add("Repo: $($status.Name) | Tag: $($status.Tag) | Status: $($status.Overview)") | Out-Null
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($Output)) {
    $resolvedOutput = Resolve-Path -Path $Output -ErrorAction SilentlyContinue
    $outputPath = $null

    if ($resolvedOutput -and (Test-Path -Path $resolvedOutput.Path -PathType Container)) {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $outputPath = Join-Path -Path $resolvedOutput.Path -ChildPath "Handle-OrchestraGit-$($timestamp).txt"
    } else {
        $extension = [System.IO.Path]::GetExtension($Output)
        if ([string]::IsNullOrWhiteSpace($extension)) {
            if (-not (Test-Path -Path $Output -PathType Container)) {
                New-Item -Path $Output -ItemType Directory -Force | Out-Null
            }

            $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $outputPath = Join-Path -Path $Output -ChildPath "Handle-OrchestraGit-$($timestamp).txt"
        } else {
            $outputPath = $Output
        }
    }

    $outputFolder = Split-Path -Path $outputPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($outputFolder) -and -not (Test-Path -Path $outputFolder -PathType Container)) {
        New-Item -Path $outputFolder -ItemType Directory -Force | Out-Null
    }

    $outputLines | Out-File -FilePath $outputPath -Encoding utf8
    Write-Host "Results written to '$($outputPath)'" -ForegroundColor Cyan
}
