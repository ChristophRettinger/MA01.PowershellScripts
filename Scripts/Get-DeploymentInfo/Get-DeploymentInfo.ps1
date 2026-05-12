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

.PARAMETER Mode
    Version (default) keeps current deployment version comparison behaviour.
    Landscape lists and compares relevant landscape values per scenario.

.PARAMETER LandscapeName
    Optional regex filter for landscape entry names when Mode = Landscape.

.PARAMETER LandscapeIgnoreList
    Optional list of regex filters to ignore landscape names. Defaults to ee_orch_instance.

.PARAMETER ResetCredentials
    Prompts again for stored server credentials.

.PARAMETER AutoRename
    Renames scenario names before compare/output using substring rules:
    WIGEV_SUBFL -> ITI_SUBFL and _v01 -> ''.

.PARAMETER OutputDirectory
    Optional directory path. When set, writes a UTF-8 text report file instead of console output.

.PARAMETER IncludeDBUrl
    Controls whether full JDBC URL values are shown in landscape compare output.
    SingleServer (default) shows URL only for single-server calls, Always always shows URL,
    Never hides URL values while still showing parsed Server and Database.
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
    [ValidateSet('Version','Landscape')]
    [string]$Mode = 'Version',

    [Parameter(Mandatory=$false)]
    [string]$LandscapeName,

    [Parameter(Mandatory=$false)]
    [string[]]$LandscapeIgnoreList = @('ee_orch_instance'),

    [Parameter(Mandatory=$false)]
    [switch]$ResetCredentials,

    [Parameter(Mandatory=$false)]
    [switch]$AutoRename,

    [Parameter(Mandatory=$false)]
    [string]$OutputDirectory,

    [Parameter(Mandatory=$false)]
    [ValidateSet('Always','Never','SingleServer')]
    [string]$IncludeDBUrl = 'SingleServer'
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
    param([int]$PersistentSubscription,[bool]$Active)
    if ($PersistentSubscription -ne 1 -and $Active) { return 'DarkGray' }
    if ($PersistentSubscription -ne 1 -and -not $Active) { return 'DarkRed' }
    if ($Active) { return 'White' }
    return 'Red'
}

function Get-Indicator {
    return [pscustomobject]@{ Char = '■' }
}

function Get-ShortServerName {
    param([string]$ServerName)
    if ([string]::IsNullOrWhiteSpace($ServerName)) { return $ServerName }
    return $ServerName
}

function Get-LandscapeTypeIcon {
    param([string]$EntryTypeName)
    switch -Regex ($EntryTypeName) {
        '^Global variable$' { return 'GV' }
        '^database connection$' { return 'DB' }
        '^Proxy server$' { return 'PR' }
        '^SAP client connection$' { return 'SA' }
        '^Uniform resource locator$' { return 'UL' }
        default { return '??' }
    }
}

function Get-NormalizedScenarioName {
    param(
        [string]$Name,
        [switch]$EnableAutoRename
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return $Name }
    if (-not $EnableAutoRename) { return $Name }

    $normalized = $Name -replace 'WIGEV_SUBFL', 'ITI_SUBFL'
    $normalized = $normalized -replace '_v01', ''
    return $normalized
}

function Get-LandscapePropertyMap {
    param([object[]]$Properties)
    $map = @{}
    foreach ($prop in @($Properties)) {
        if ($null -eq $prop.name) { continue }
        $name = [string]$prop.name
        if ($name -in @('VALUE','TYPE','URL','User','Proxy')) {
            $map[$name] = [string]$prop.value
        }
    }
    return $map
}

function Get-DbVirtualProperties {
    param([string]$UrlValue)
    $result = @{}
    if ([string]::IsNullOrWhiteSpace($UrlValue)) { return $result }
    if ($UrlValue -match '^jdbc:[^:]+://([^;]+)') {
        $result['Server'] = $Matches[1]
    }
    if ($UrlValue -match '(?:^|;)DatabaseName=([^;]+)') {
        $result['Database'] = $Matches[1]
    }
    return $result
}

[hashtable]$allServerData = @{}
foreach ($serverName in $Server) {
    $baseUrl = Get-ServerBaseUrl -ServerName $serverName
    $scenarioInfoUrl = "$($baseUrl)/OrchDyn/deployment/scenarioInfos"
    $cred = Get-CredentialForServer -ServerName $serverName

    Write-Verbose "GET $($scenarioInfoUrl)"
    $response = Invoke-RestMethod -Uri $scenarioInfoUrl -Method Get -Authentication Basic -Credential $cred
    $filtered = $response | Where-Object { $_.name -match $ScenarioName }

    if ($Mode -eq 'Version') {
        $allServerData[$serverName] = @($filtered | ForEach-Object {
            $parsed = Parse-DeploymentComment -Comment $_.comment
            [pscustomobject]@{
                Name = $_.name
                DisplayName = Get-NormalizedScenarioName -Name ([string]$_.name) -EnableAutoRename:$AutoRename
                ServiceState = [int]$_.serviceState
                Active = if ($null -ne $_.active) { [bool]$_.active } else { ([int]$_.serviceState -eq 1) }
                PersistentSubscription = [int]$_.persistentSubcription
                UserName = $_.userName
                ModifiedAt = $_.modifiedAt
                Comment = $_.comment
                Parsed = $parsed
                GitNumeric = Get-ParsedVersionNumber -GitVersion $parsed.GitVersion
            }
        })
        continue
    }

    $landscapeRows = New-Object System.Collections.Generic.List[object]
    foreach ($scenario in @($filtered)) {
        $scenarioId = $scenario.scenarioID
        $landscapeInfosUrl = "$($baseUrl)/OrchDyn/landscape/infos/$($scenarioId)"
        Write-Verbose "GET $($landscapeInfosUrl)"
        $landscapeInfos = Invoke-RestMethod -Uri $landscapeInfosUrl -Method Get -Authentication Basic -Credential $cred
        foreach ($landscape in @($landscapeInfos)) {
            $entryName = [string]$landscape.entryName
            if ($LandscapeName -and ($entryName -notmatch $LandscapeName)) { continue }
            $ignore = $false
            foreach ($ignoreRegex in @($LandscapeIgnoreList)) {
                if ($entryName -match $ignoreRegex) { $ignore = $true; break }
            }
            if ($ignore) { continue }

            if ($landscape.reference -notmatch '\}([0-9]+)$') { continue }
            $landscapeRefId = $Matches[1]
            $propertiesUrl = "$($baseUrl)/OrchDyn/landscape/properties/$($scenarioId)/$($landscapeRefId)"
            Write-Verbose "GET $($propertiesUrl)"
            $properties = Invoke-RestMethod -Uri $propertiesUrl -Method Get -Authentication Basic -Credential $cred
            $propertyMap = Get-LandscapePropertyMap -Properties @($properties)
            $dbVirtual = @{}
            if ([string]$landscape.entryTypeName -eq 'database connection') {
                $dbVirtual = Get-DbVirtualProperties -UrlValue $propertyMap['URL']
            }
            $landscapeRows.Add([pscustomobject]@{
                ScenarioName = [string]$scenario.name
                DisplayScenarioName = Get-NormalizedScenarioName -Name ([string]$scenario.name) -EnableAutoRename:$AutoRename
                EntryTypeName = [string]$landscape.entryTypeName
                TypeIcon = Get-LandscapeTypeIcon -EntryTypeName ([string]$landscape.entryTypeName)
                EntryName = $entryName
                Values = $propertyMap
                DbVirtual = $dbVirtual
            }) | Out-Null
        }
    }
    $allServerData[$serverName] = @($landscapeRows.ToArray())
}

$scenarioNames = $allServerData.Values | ForEach-Object { $_.DisplayName } | Sort-Object -Unique
$lines = New-Object System.Collections.Generic.List[string]

if ($Mode -eq 'Landscape') {
    $keys = @('VALUE','TYPE','URL','User','Proxy','Server','Database')
    $landscapeKeys = $allServerData.Values | ForEach-Object { $_ | ForEach-Object { "$($_.DisplayScenarioName)|$($_.EntryTypeName)|$($_.EntryName)" } } | Sort-Object -Unique
    $header = "{0,-49} {1,-2} {2,-34} {3,-14}" -f 'Scenario','T','Name','Value-Type'
    foreach ($srv in $Server) { $header += ("  {0,-52}" -f (Get-ShortServerName -ServerName $srv)) }
    if ($OutputDirectory) { $lines.Add($header) | Out-Null } else { Write-Host $header }
    foreach ($lk in $landscapeKeys) {
        $scenarioLabel,$entryTypeName,$entryName = $lk -split '\|',3
        $allRowsForKey = @()
        foreach ($srv in $Server) {
            $allRowsForKey += @($allServerData[$srv] | Where-Object { $_.DisplayScenarioName -eq $scenarioLabel -and $_.EntryTypeName -eq $entryTypeName -and $_.EntryName -eq $entryName } | Select-Object -First 1)
        }
        $icon = (($allRowsForKey | Where-Object { $_ } | Select-Object -First 1).TypeIcon)
        foreach ($valueType in $keys) {
            $values = @()
            foreach ($row in $allRowsForKey) {
                if (-not $row) { $values += $null; continue }
                if ($valueType -in @('Server','Database')) { $values += $row.DbVirtual[$valueType] } else { $values += $row.Values[$valueType] }
            }
            if ($valueType -eq 'TYPE') {
                $entryType = $entryTypeName
                if ($entryType -eq 'Uniform resource locator') { continue }
                if ($entryType -eq 'Global variable') {
                    $existingTypeValues = @($values | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                    $uniqueTypes = @($existingTypeValues | Select-Object -Unique)
                    if ($uniqueTypes.Count -eq 1 -and $uniqueTypes[0] -eq 'Text') { continue }
                }
            }
            if ($valueType -eq 'URL') {
                $showUrl = ($IncludeDBUrl -eq 'Always') -or (($IncludeDBUrl -eq 'SingleServer') -and ($Server.Count -eq 1))
                if (-not $showUrl) { continue }
            }
            $existingValues = @($values | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $hasMissingValue = ($values | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
            if ($existingValues.Count -eq 0) { continue }
            $allEqual = (($existingValues | Select-Object -Unique).Count -eq 1) -and -not $hasMissingValue
            if ($OnlyDifferences) {
                if ($valueType -in @('Server','Database')) {
                    if ($allEqual) { continue }
                } else {
                    continue
                }
            }
            $baseLine = "{0,-49} {1,-2} {2,-34} {3,-14}" -f $scenarioLabel,$icon,$entryName,$valueType
            if ($OutputDirectory) {
                $line = $baseLine
                foreach ($v in $values) { $line += ("  {0,-52}" -f $(if($v){$v}else{'-'})) }
                $lines.Add($line) | Out-Null
            } else {
                Write-Host $baseLine -NoNewline
                foreach ($v in $values) {
                    $display = if ($v) { $v } else { '-' }
                    $color = if ($allEqual) { 'Green' } else { 'Yellow' }
                    Write-Host ("  {0,-52}" -f $display) -NoNewline -ForegroundColor $color
                }
                Write-Host ''
            }
        }
    }
}
elseif ($Server.Count -eq 1) {
    $single = $allServerData[$Server[0]] | Sort-Object Name
    foreach ($item in $single) {
        $versionShort = Get-VersionDisplayText -GitVersion $item.Parsed.GitVersion
        $line = "{0,-62} {1,-8} {2,-12} {3}" -f $item.DisplayName, $versionShort, $item.UserName, $item.ModifiedAt
        if ($OutputDirectory) {
            $lines.Add($line) | Out-Null
        } else {
            $color = Get-StateColorName -PersistentSubscription $item.PersistentSubscription -Active $item.Active
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
        $entries = @(
            for ($idx = 0; $idx -lt $Server.Count; $idx++) {
                $srv = $Server[$idx]
                $entry = $allServerData[$srv] | Where-Object DisplayName -eq $name | Select-Object -First 1
                ,$entry
            }
        )
        if (-not ($entries | Where-Object { $null -ne $_ })) { continue }

        $versions = @($entries | Where-Object { $_ } | ForEach-Object { $_.GitNumeric })
        $allEqual = ($versions.Count -gt 0) -and (($versions | Select-Object -Unique).Count -eq 1)
        $hasMissingDeployment = ($entries | Where-Object { -not $_ }).Count -gt 0
        if ($OnlyDifferences -and $allEqual -and -not $hasMissingDeployment) { continue }

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
                $stateColor = Get-StateColorName -PersistentSubscription $entry.PersistentSubscription -Active $entry.Active
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
