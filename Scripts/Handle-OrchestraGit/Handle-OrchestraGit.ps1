<#
.SYNOPSIS
    Runs actions against Orchestra git repositories beneath a folder.

.DESCRIPTION
    Detects repository roots by locating `.git` directories beneath the supplied path.
    For every action, the script ensures required exclude entries exist in each
    repository's `.git/info/exclude` file, evaluates repository state (including short
    pending-change counts), optionally applies the selected action, and prints a
    fixed-width, colorized status overview per repository.

.PARAMETER Path
    Folder that is either a repository root (contains `.git`) or a parent folder that
    contains one or more repository roots.

.PARAMETER Action
    Action to execute. Supports `Status`, `Update`, `Pull`, `Reset`, and `Clean`.
    `Reset` also removes untracked files. `Clean` untracks files that are currently
    tracked but match `.git/info/exclude` rules.

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
    [ValidateSet('Status', 'Update', 'Pull', 'Reset', 'Clean')]
    [string]$Action = 'Status',

    [Parameter(Mandatory = $false)]
    [string]$Output
)

$requiredExcludeEntries = @(
    '/.orc.cred',
    '/association.map',
    '/lock',
    '/*.local',
    '/TestEnvironment*'
)

function Get-NormalizedPath {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    return $fullPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

function Resolve-RepositoryRoots {
    param (
        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    $resolvedRoot = Get-NormalizedPath -Path ((Resolve-Path -Path $RootPath -ErrorAction Stop).Path)
    $repositories = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

    $rootGitFolder = Join-Path -Path $resolvedRoot -ChildPath '.git'
    if ((Test-Path -Path $rootGitFolder -PathType Container) -or (Test-Path -Path $rootGitFolder -PathType Leaf)) {
        $null = $repositories.Add($resolvedRoot)
    }

    $gitDirectories = Get-ChildItem -Path $resolvedRoot -Directory -Filter '.git' -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($gitDirectory in $gitDirectories) {
        if ((Get-NormalizedPath -Path $gitDirectory.FullName) -eq (Get-NormalizedPath -Path $rootGitFolder)) {
            continue
        }

        $repositoryRoot = Split-Path -Path $gitDirectory.FullName -Parent
        $null = $repositories.Add((Get-NormalizedPath -Path $repositoryRoot))
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

    $pendingChanges = @(& git -C $RepositoryPath status --porcelain 2>$null)
    $hasPendingChanges = -not [string]::IsNullOrWhiteSpace(($pendingChanges | Out-String).Trim())
    $untrackedFiles = 0
    $changedFiles = 0

    foreach ($pendingLine in $pendingChanges) {
        if ([string]::IsNullOrWhiteSpace($pendingLine)) {
            continue
        }

        if ($pendingLine.StartsWith('??')) {
            $untrackedFiles++
            continue
        }

        $changedFiles++
    }

    & git -C $RepositoryPath fetch --quiet --all --prune 2>$null

    $upstream = (& git -C $RepositoryPath rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
    $overview = 'Up to date'

    if ($hasPendingChanges) {
        $overview = "Pending c:$($changedFiles) u:$($untrackedFiles)"
    } elseif (-not [string]::IsNullOrWhiteSpace($upstream)) {
        $aheadBehind = (& git -C $RepositoryPath rev-list --left-right --count 'HEAD...@{u}' 2>$null)
        if (-not [string]::IsNullOrWhiteSpace($aheadBehind)) {
            $parts = $aheadBehind.Trim() -split '\s+'
            if ($parts.Count -ge 2) {
                $behindCount = 0
                if (-not [int]::TryParse($parts[1], [ref]$behindCount)) {
                    $behindCount = 0
                }

                if ($behindCount -gt 0) {
                    $overview = "Update available ($(Get-UpstreamVersionLabel -RepositoryPath $RepositoryPath -Reference $upstream))"
                }
            }
        }
    }

    return [PSCustomObject]@{
        Name = $repoName
        Tag = $tag.Trim()
        Overview = $overview
        HasPendingChanges = $hasPendingChanges
        ChangedFiles = $changedFiles
        UntrackedFiles = $untrackedFiles
        Upstream = if ([string]::IsNullOrWhiteSpace($upstream)) { '' } else { $upstream.Trim() }
    }
}

function Get-UpstreamVersionLabel {
    param (
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [Parameter(Mandatory = $true)]
        [string]$Reference
    )

    $shortHash = (& git -C $RepositoryPath rev-parse --short $Reference 2>$null)
    $shortHash = $shortHash.Trim()
    if ([string]::IsNullOrWhiteSpace($shortHash)) {
        return 'unknown'
    }

    $tag = (& git -C $RepositoryPath describe --tags --exact-match $Reference 2>$null)
    $tag = $tag.Trim()

    if ([string]::IsNullOrWhiteSpace($tag)) {
        return $shortHash
    }

    return "$($tag) $($shortHash)"
}

function Invoke-RepositoryAction {
    param (
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [Parameter(Mandatory = $true)]
        [string]$ActionName,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Status
    )

    if ($ActionName -in @('Update', 'Pull')) {
        if ($Status.HasPendingChanges) {
            return
        }

        if ([string]::IsNullOrWhiteSpace($Status.Upstream)) {
            return
        }

        & git -C $RepositoryPath pull --ff-only --quiet 2>$null
        return
    }

    if ($ActionName -eq 'Reset') {
        if ([string]::IsNullOrWhiteSpace($Status.Upstream)) {
            return
        }

        & git -C $RepositoryPath reset --hard $Status.Upstream 2>$null
        & git -C $RepositoryPath clean -fd 2>$null
        return
    }

    if ($ActionName -eq 'Clean') {
        $excludePath = Join-Path -Path $RepositoryPath -ChildPath '.git/info/exclude'
        if (-not (Test-Path -Path $excludePath -PathType Leaf)) {
            return
        }

        $trackedIgnoredFiles = @(& git -C $RepositoryPath ls-files -ci --exclude-from=$excludePath 2>$null)

        foreach ($trackedIgnoredFile in $trackedIgnoredFiles) {
            if ([string]::IsNullOrWhiteSpace($trackedIgnoredFile)) {
                continue
            }

            & git -C $RepositoryPath rm --cached --quiet -- $trackedIgnoredFile 2>$null
        }
    }
}

function Write-RepositoryStatusLine {
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Status
    )

    $overviewColor = 'Green'
    if ($Status.Overview -like 'Pending*') {
        $overviewColor = 'Yellow'
    } elseif ($Status.Overview -like 'Update available*') {
        $overviewColor = 'Red'
    }

    $repoDisplay = '{0,-60}' -f $Status.Name
    $tagDisplay = '{0,-20}' -f $Status.Tag

    Write-Host -NoNewline $repoDisplay -ForegroundColor Cyan
    Write-Host -NoNewline ' | ' -ForegroundColor DarkGray
    Write-Host -NoNewline $tagDisplay -ForegroundColor Magenta
    Write-Host -NoNewline ' | ' -ForegroundColor DarkGray
    Write-Host $Status.Overview -ForegroundColor $overviewColor
}

function Get-OutputStatusLine {
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Status
    )

    $repoDisplay = '{0,-60}' -f $Status.Name
    $tagDisplay = '{0,-20}' -f $Status.Tag
    return "$($repoDisplay) | $($tagDisplay) | $($Status.Overview)"
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
            $outputLines.Add((Get-OutputStatusLine -Status $status)) | Out-Null
        }
    }
    'Update' {
        foreach ($repositoryRoot in $repositoryRoots) {
            Ensure-GitExcludeEntries -RepositoryPath $repositoryRoot -Entries $requiredExcludeEntries
            $statusBefore = Get-RepositoryStatus -RepositoryPath $repositoryRoot
            Invoke-RepositoryAction -RepositoryPath $repositoryRoot -ActionName $Action -Status $statusBefore
            $status = Get-RepositoryStatus -RepositoryPath $repositoryRoot
            Write-RepositoryStatusLine -Status $status
            $outputLines.Add((Get-OutputStatusLine -Status $status)) | Out-Null
        }
    }
    'Pull' {
        foreach ($repositoryRoot in $repositoryRoots) {
            Ensure-GitExcludeEntries -RepositoryPath $repositoryRoot -Entries $requiredExcludeEntries
            $statusBefore = Get-RepositoryStatus -RepositoryPath $repositoryRoot
            Invoke-RepositoryAction -RepositoryPath $repositoryRoot -ActionName $Action -Status $statusBefore
            $status = Get-RepositoryStatus -RepositoryPath $repositoryRoot
            Write-RepositoryStatusLine -Status $status
            $outputLines.Add((Get-OutputStatusLine -Status $status)) | Out-Null
        }
    }
    'Reset' {
        foreach ($repositoryRoot in $repositoryRoots) {
            Ensure-GitExcludeEntries -RepositoryPath $repositoryRoot -Entries $requiredExcludeEntries
            $statusBefore = Get-RepositoryStatus -RepositoryPath $repositoryRoot
            Invoke-RepositoryAction -RepositoryPath $repositoryRoot -ActionName $Action -Status $statusBefore
            $status = Get-RepositoryStatus -RepositoryPath $repositoryRoot
            Write-RepositoryStatusLine -Status $status
            $outputLines.Add((Get-OutputStatusLine -Status $status)) | Out-Null
        }
    }
    'Clean' {
        foreach ($repositoryRoot in $repositoryRoots) {
            Ensure-GitExcludeEntries -RepositoryPath $repositoryRoot -Entries $requiredExcludeEntries
            $statusBefore = Get-RepositoryStatus -RepositoryPath $repositoryRoot
            Invoke-RepositoryAction -RepositoryPath $repositoryRoot -ActionName $Action -Status $statusBefore
            $status = Get-RepositoryStatus -RepositoryPath $repositoryRoot
            Write-RepositoryStatusLine -Status $status
            $outputLines.Add((Get-OutputStatusLine -Status $status)) | Out-Null
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
