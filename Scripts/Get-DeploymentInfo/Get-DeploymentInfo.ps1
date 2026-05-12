<#
.SYNOPSIS
    Fetches and compares Orchestra deployment scenario information per server.

.DESCRIPTION
    Calls the Orchestra deployment API endpoint `/OrchDyn/deployment/scenarioInfos` using
    HTTP Basic authentication and shows scenario deployment status and version details.
    Credentials are requested per server on first use and stored as user-scoped CLIXML files
    beside this script. Multi-server mode prints one row per scenario with side-by-side
    version indicators for quick comparison.

.PARAMETER Server
    One or more server names (for example prod01-wsk). Server names can be read from
    `Scripts/Resend-FromElastic/targets.csv`.

.PARAMETER OnlyDifferences
    In multi-server mode, omits scenarios where all parsed versions are equal.

.PARAMETER ScenarioName
    Regex filter applied to scenario name. Defaults to SUBFL.

.PARAMETER ResetCredentials
    Prompts again for stored server credentials.

.PARAMETER OutputDirectory
    Optional directory path. When set, writes a UTF-8 text report file instead of console output.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string[]]$Server,

    [Parameter(Mandatory=$false)]
    [switch]$OnlyDifferences,

    [Parameter(Mandatory=$false)]
    [string]$ScenarioName = 'SUBFL',

    [Parameter(Mandatory=$false)]
    [switch]$ResetCredentials,

    [Parameter(Mandatory=$false)]
    [string]$OutputDirectory
)

function Get-CredentialForServer {
    param([string]$ServerName)

    $safeName = ($ServerName -replace '[^A-Za-z0-9_.-]', '_')
    $path = Join-Path $PSScriptRoot "$($safeName).credentials.clixml"
    if ($ResetCredentials -or -not (Test-Path -LiteralPath $path)) {
        $cred = Get-Credential -Message "Credentials for $($ServerName)"
        $cred | Export-Clixml -Path $path
        return $cred
    }
    return Import-Clixml -Path $path
}

function Get-ServerBaseUrl {
    param([string]$ServerName)

    $targetsPath = Join-Path $PSScriptRoot '..\Resend-FromElastic\targets.csv'
    if (-not (Test-Path -LiteralPath $targetsPath)) {
        throw "targets.csv not found at $($targetsPath)."
    }
    $targets = Import-Csv -Path $targetsPath
    $entry = $targets | Where-Object { $_.Name -eq $ServerName } | Select-Object -First 1
    if (-not $entry) {
        throw "Server '$ServerName' not found in $($targetsPath)."
    }
    $uri = [Uri]$entry.URL
    return "$($uri.Scheme)://$($uri.Authority)"
}

function Parse-DeploymentComment {
    param([string]$Comment)

    $result = [ordered]@{ Raw = $Comment; GitVersion = $null; Designer = $null; Mode = $null; Persistence = $null }
    if ([string]::IsNullOrWhiteSpace($Comment)) {
        return [pscustomobject]$result
    }
    $parts = $Comment -split '-'
    if ($parts.Count -ge 1) { $result.GitVersion = $parts[0] }
    if ($parts.Count -ge 2) { $result.Designer = $parts[1] }
    if ($parts.Count -ge 3) { $result.Mode = $parts[2] }
    if ($parts.Count -ge 4) { $result.Persistence = $parts[3] }
    return [pscustomobject]$result
}

function Get-ParsedVersionNumber {
    param([string]$GitVersion)
    if ([string]::IsNullOrWhiteSpace($GitVersion)) { return -1 }
    $normalized = $GitVersion.TrimStart('g','G')
    $number = 0
    if ([int]::TryParse($normalized, [ref]$number)) { return $number }
    return -1
}

function Get-VersionDisplayText {
    param([string]$GitVersion)

    if ([string]::IsNullOrWhiteSpace($GitVersion)) { return '' }
    $display = $GitVersion
    if ($display -match '^[gG](.+)$') { $display = $Matches[1] }
    if ($display -match '^0+(?=\d)') {
        $display = [regex]::Replace($display, '^0+(?=\d)', { param($m) ' ' * $m.Length })
    }
    return $display
}

function Get-StateColorName {
    param([int]$PersistentSubscription,[int]$ServiceState)
    if ($PersistentSubscription -ne 1 -and $ServiceState -eq 1) { return 'DarkGray' }
    if ($PersistentSubscription -ne 1 -and $ServiceState -ne 1) { return 'DarkYellow' }
    if ($ServiceState -eq 1) { return 'White' }
    return 'Yellow'
}

function Get-Indicator {
    return [pscustomobject]@{ Char = '■' }
}

function Get-ShortServerName {
    param([string]$ServerName)
    if ([string]::IsNullOrWhiteSpace($ServerName)) { return $ServerName }
    return ($ServerName -split '[\.-]')[0]
}

$allServerData = @{}
foreach ($serverName in $Server) {
    $baseUrl = Get-ServerBaseUrl -ServerName $serverName
    $url = "$($baseUrl)/OrchDyn/deployment/scenarioInfos"
    $cred = Get-CredentialForServer -ServerName $serverName

    Write-Verbose "GET $($url)"
    $response = Invoke-RestMethod -Uri $url -Method Get -Authentication Basic -Credential $cred
    $filtered = $response | Where-Object { $_.name -match $ScenarioName }

    $allServerData[$serverName] = @($filtered | ForEach-Object {
        $parsed = Parse-DeploymentComment -Comment $_.comment
        [pscustomobject]@{
            Name = $_.name
            ServiceState = [int]$_.serviceState
            PersistentSubscription = [int]$_.persistentSubcription
            UserName = $_.userName
            ModifiedAt = $_.modifiedAt
            Comment = $_.comment
            Parsed = $parsed
            GitNumeric = Get-ParsedVersionNumber -GitVersion $parsed.GitVersion
        }
    })
}

$scenarioNames = $allServerData.Values | ForEach-Object { $_.Name } | Sort-Object -Unique
$lines = New-Object System.Collections.Generic.List[string]

if ($Server.Count -eq 1) {
    $single = $allServerData[$Server[0]] | Sort-Object Name
    foreach ($item in $single) {
        $versionShort = Get-VersionDisplayText -GitVersion $item.Parsed.GitVersion
        $line = "{0,-62} {1,-8} {2,-12} {3}" -f $item.Name, $versionShort, $item.UserName, $item.ModifiedAt
        if ($OutputDirectory) {
            $lines.Add($line) | Out-Null
        } else {
            $color = Get-StateColorName -PersistentSubscription $item.PersistentSubscription -ServiceState $item.ServiceState
            Write-Host $line -ForegroundColor $color
        }
    }
} else {
    $header = "{0,-62}" -f 'Scenario'
    for ($idx = 0; $idx -lt $Server.Count; $idx++) {
        $shortName = Get-ShortServerName -ServerName $Server[$idx]
        $header += ("  {0,-12}" -f $shortName)
    }
    if ($OutputDirectory) {
        $lines.Add($header) | Out-Null
    } else {
        Write-Host $header
    }

    foreach ($name in $scenarioNames) {
        $entries = foreach ($srv in $Server) {
            $allServerData[$srv] | Where-Object Name -eq $name | Select-Object -First 1
        }
        if (-not ($entries | Where-Object { $_ })) { continue }

        $versions = @($entries | Where-Object { $_ } | ForEach-Object { $_.GitNumeric })
        $allEqual = ($versions.Count -gt 0) -and (($versions | Select-Object -Unique).Count -eq 1)
        if ($OnlyDifferences -and $allEqual) { continue }

        if ($OutputDirectory) {
            $parts = @()
            for ($idx = 0; $idx -lt $Server.Count; $idx++) {
                $entry = $entries[$idx]
                if (-not $entry) { $parts += "-"; continue }
                $v = $entry.Parsed.GitVersion
                $v = Get-VersionDisplayText -GitVersion $v
                $parts += "$($Server[$idx]):$($v)"
            }
            $lines.Add(("{0,-62} {1}" -f $name, ($parts -join ' | '))) | Out-Null
        } else {
            Write-Host ("{0,-62}" -f $name) -NoNewline
            $max = if ($versions.Count -gt 0) { ($versions | Measure-Object -Maximum).Maximum } else { -1 }
            for ($idx = 0; $idx -lt $Server.Count; $idx++) {
                $entry = $entries[$idx]
                $indicator = Get-Indicator
                Write-Host '  ' -NoNewline
                if (-not $entry) {
                    Write-Host ("{0,-12}" -f '-') -NoNewline -ForegroundColor DarkGray
                    continue
                }
                $v = $entry.Parsed.GitVersion
                $v = Get-VersionDisplayText -GitVersion $v
                $stateColor = Get-StateColorName -PersistentSubscription $entry.PersistentSubscription -ServiceState $entry.ServiceState
                $vc = if ($entry.GitNumeric -eq $max) { 'Green' } elseif ($allEqual) { 'White' } else { 'DarkYellow' }
                Write-Host $indicator.Char -NoNewline -ForegroundColor $stateColor
                Write-Host ' ' -NoNewline
                Write-Host ("{0,-10}" -f $v) -NoNewline -ForegroundColor $vc
            }
            Write-Host ''
        }
    }
}

if ($OutputDirectory) {
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $file = Join-Path $OutputDirectory "Get-DeploymentInfo-$($stamp).txt"
    $lines | Set-Content -Path $file -Encoding UTF8
    Write-Host "Wrote $($file)"
}
