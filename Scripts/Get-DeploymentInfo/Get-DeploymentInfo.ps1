<#
.SYNOPSIS
    Retrieves deployment scenario information from Orchestra servers.

.DESCRIPTION
    Queries Orchestra OrchDyn API endpoints to display scenario versions (Version mode)
    or landscape configuration properties (Landscape mode) across one or more servers.
    Supports column-aligned multi-server comparison with color-coded differences.
    Credentials are stored per server as CLIXML and reused across calls.

.PARAMETER Server
    One or more server names to query. Each name must exist in ServerConfig.psd1 (OrchestraTargets).

.PARAMETER Mode
    Output mode: 'Version' (default) shows scenario versions; 'Landscape' shows landscape properties.

.PARAMETER ScenarioName
    Regex filter for scenario names (applied after name translation). Default: 'SUBFL'.

.PARAMETER LandscapeName
    Regex filter for landscape entry names (Landscape mode only). If omitted, all entries are shown.

.PARAMETER LandscapeIgnoreList
    Regex patterns to exclude landscape entries by name. Default: @('ee_orch_instance').

.PARAMETER IncludeDBUrl
    Controls raw jdbc URL display for database connections: Always, Never, or SingleServer (default).

.PARAMETER OnlyDifferences
    Version mode: show only scenarios where versions differ or a server is missing the scenario.
    Landscape mode: show only entries where property values differ across servers that have the entry.

.PARAMETER FocusServer1
    Limit output to scenarios present on the first server. Scenarios missing from Server[0] are ignored entirely.

.PARAMETER ResetCredentials
    Discard cached credentials and prompt for new ones.

.PARAMETER OutputDirectory
    Write plain-text output to a timestamped .txt file in this directory.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string[]]$Server,

    [Parameter(Mandatory=$false)]
    [ValidateSet('Version','Landscape')]
    [string]$Mode = 'Version',

    [Parameter(Mandatory=$false)]
    [string]$ScenarioName = 'SUBFL',

    [Parameter(Mandatory=$false)]
    [string]$LandscapeName,

    [Parameter(Mandatory=$false)]
    [string[]]$LandscapeIgnoreList = @('ee_orch_instance'),

    [Parameter(Mandatory=$false)]
    [ValidateSet('Always','Never','SingleServer')]
    [string]$IncludeDBUrl = 'SingleServer',

    [Parameter(Mandatory=$false)]
    [switch]$OnlyDifferences,

    [Parameter(Mandatory=$false)]
    [switch]$FocusServer1,

    [Parameter(Mandatory=$false)]
    [switch]$ResetCredentials,

    [Parameter(Mandatory=$false)]
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Set-StrictMode -Off

$sharedDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'Common'
. (Join-Path $sharedDir 'ServerConfig.ps1')

$ScenarioNameTranslations = @(
    @('WIGEV_SUBFL', 'ITI_SUBFL'),
    @('_v01',        '')
)

$PropertyOrder = @('VALUE', 'TYPE', 'Server', 'Database', 'URL', 'User', 'Proxy')

$script:OutputBuilder = $null
if ($OutputDirectory) {
    $script:OutputBuilder = [System.Text.StringBuilder]::new()
}

function Write-PlainText {
    param([string]$Line)
    if ($script:OutputBuilder) {
        [void]$script:OutputBuilder.AppendLine($Line)
    }
}

function Get-ServerBaseUrl {
    param([string]$ServerName)
    $entry = (Get-ServerConfig).OrchestraTargets[$ServerName]
    if (-not $entry) {
        throw "Server '$($ServerName)' not found in ServerConfig.psd1 (OrchestraTargets)"
    }
    return $entry.BaseUrl
}

function Get-OrchCredential {
    param([string]$ServerName)
    $credPath = Join-Path $PSScriptRoot "$($ServerName).credentials.clixml"
    if (-not $ResetCredentials -and (Test-Path $credPath)) {
        return Import-Clixml $credPath
    }
    $cred = Get-Credential -Message "Enter credentials for $($ServerName)"
    $cred | Export-Clixml $credPath
    return $cred
}

function Invoke-OrchApi {
    param([string]$Url, [System.Management.Automation.PSCredential]$Credential)
    try {
        return Invoke-RestMethod -Uri $Url -Method Get -Credential $Credential -SkipCertificateCheck
    } catch {
        throw "API call failed for '$($Url)': $($_)"
    }
}

function Get-VersionNumber {
    param([string]$Comment)
    if ($Comment -match '^g?(\d+)') {
        return [int]$Matches[1]
    }
    return $null
}

function Invoke-TranslateScenarioName {
    param([string]$Name)
    foreach ($t in $ScenarioNameTranslations) {
        $Name = $Name -replace $t[0], $t[1]
    }
    return $Name
}

function Get-ScenarioStateColor {
    param($Scenario)
    if (-not $Scenario.active) { return 'Red' }
    if ($Scenario.persistentSubscription -eq 1) { return 'White' }
    return 'Gray'
}

function Get-CompareColor {
    param([int]$Version, [int[]]$AllVersions)
    if ($AllVersions.Count -le 1) { return 'White' }
    $max = ($AllVersions | Measure-Object -Maximum).Maximum
    $min = ($AllVersions | Measure-Object -Minimum).Minimum
    if ($max -eq $min) { return 'White' }
    if ($Version -eq $max) { return 'Green' }
    if ($Version -eq $min) { return 'Red' }
    return 'Yellow'
}

function Get-EntryTypeIcon {
    param([string]$EntryTypeName)
    switch ($EntryTypeName) {
        'Global variable'          { return 'VAR' }
        'database connection'      { return 'DB ' }
        'Uniform resource locator' { return 'URL' }
        'Proxy server'             { return 'PRX' }
        'SAP client connection'    { return 'SAP' }
        default                    { return '[?]' }
    }
}

function ConvertFrom-JdbcUrl {
    param([string]$Value)
    $result = @{ Server = ''; Database = '' }
    if ($Value -match 'jdbc:sqlserver://([^;]+)') {
        $result.Server = $Matches[1]
    }
    if ($Value -match 'DatabaseName=([^;]+)') {
        $result.Database = $Matches[1]
    }
    return $result
}

function Get-LandscapeEntryProperties {
    param(
        [string]$BaseUrl,
        [System.Management.Automation.PSCredential]$Credential,
        $ScenarioObj,
        $EntryObj
    )

    $scenarioId = $ScenarioObj.scenarioID

    if ($EntryObj.reference -match '\}(\d+)$') {
        $refId = $Matches[1]
    } else {
        return ,@()
    }

    $propsUrl  = "$($BaseUrl)$((Get-ServerConfig).OrchestraDeploymentApiBase)/landscape/properties/$($scenarioId)/$($refId)"
    $rawProps   = Invoke-OrchApi -Url $propsUrl -Credential $Credential

    $entryTypeName = [string]$EntryObj.entryTypeName
    $isDbConn      = $entryTypeName -eq 'database connection'
    $isUrlType     = $entryTypeName -eq 'Uniform resource locator'
    $isGlobalVar   = $entryTypeName -eq 'Global variable'

    $result = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($prop in $rawProps) {
        $propName  = [string]$prop.name
        $propValue = if ($null -ne $prop.value) { [string]$prop.value } else { '' }

        if ($propName -ieq 'Password') { continue }

        if ($propName -ieq 'VALUE') {
            $result.Add(@{ PropName = 'VALUE'; Value = $propValue })
            continue
        }

        if ($propName -ieq 'TYPE') {
            if ($isUrlType)        { continue }
            if (-not $isGlobalVar) { continue }
            if ($propValue -eq 'Text') { continue }
            $result.Add(@{ PropName = 'TYPE'; Value = $propValue })
            continue
        }

        if ($propName -ieq 'URL') {
            if ($isDbConn) {
                $jdbc = ConvertFrom-JdbcUrl -Value $propValue
                $result.Add(@{ PropName = 'Server';   Value = $jdbc.Server   })
                $result.Add(@{ PropName = 'Database'; Value = $jdbc.Database })
                $showUrl = switch ($IncludeDBUrl) {
                    'Always'       { $true }
                    'Never'        { $false }
                    'SingleServer' { $Server.Count -eq 1 }
                }
                if ($showUrl) {
                    $result.Add(@{ PropName = 'URL'; Value = $propValue })
                }
            } else {
                $result.Add(@{ PropName = 'URL'; Value = $propValue })
            }
            continue
        }

        if ($propName -ieq 'User') {
            $result.Add(@{ PropName = 'User'; Value = $propValue })
            continue
        }

        if ($propName -ieq 'Proxy') {
            $result.Add(@{ PropName = 'Proxy'; Value = $propValue })
        }
    }

    return ,$result.ToArray()
}

function Get-UnionPropNames {
    param([string[]]$Servers, [string]$SName, [string]$EntryName, [hashtable]$LandscapeData)
    $seen = [System.Collections.Generic.List[string]]::new()
    foreach ($srv in $Servers) {
        if ($LandscapeData[$srv][$SName] -and $LandscapeData[$srv][$SName].ContainsKey($EntryName)) {
            foreach ($p in $LandscapeData[$srv][$SName][$EntryName].Properties) {
                if ($seen -notcontains $p.PropName) {
                    $seen.Add($p.PropName)
                }
            }
        }
    }
    $ordered   = @($PropertyOrder | Where-Object { $seen -contains $_ })
    $remaining = @($seen | Where-Object { $PropertyOrder -notcontains $_ })
    return @($ordered + $remaining)
}

<#
════════════════════════════════════════════════════════
  SCRIPT BODY
════════════════════════════════════════════════════════
#>

$credentialMap = @{}
$baseUrlMap    = @{}

foreach ($srv in $Server) {
    $baseUrlMap[$srv]    = Get-ServerBaseUrl -ServerName $srv
    $credentialMap[$srv] = Get-OrchCredential -ServerName $srv
}

# ─── Fetch Scenario Infos ────────────────────────────────────────────────────────

$scenariosByServer = @{}

foreach ($srv in $Server) {
    $url = "$($baseUrlMap[$srv])$((Get-ServerConfig).OrchestraDeploymentApiBase)/deployment/scenarioInfos"
    $raw = Invoke-OrchApi -Url $url -Credential $credentialMap[$srv]

    foreach ($s in $raw) {
        $s | Add-Member -MemberType NoteProperty -Name 'name' -Value (Invoke-TranslateScenarioName ([string]$s.name)) -Force
    }

    $scenariosByServer[$srv] = @($raw | Where-Object { $_.name -match $ScenarioName })
}

# ─── Build Unified Scenario Name List ───────────────────────────────────────────

$allScenarioNames = @(
    $scenariosByServer.Values |
    ForEach-Object { $_ } |
    ForEach-Object { $_.name } |
    Select-Object -Unique |
    Sort-Object
)

if ($FocusServer1) {
    $server1Names = @($scenariosByServer[$Server[0]] | ForEach-Object { $_.name })
    $allScenarioNames = @($allScenarioNames | Where-Object { $server1Names -contains $_ })
}

if ($allScenarioNames.Count -eq 0) {
    Write-Host "No scenarios found matching '$($ScenarioName)'"
    exit
}

# ─── Build Unified Rows ──────────────────────────────────────────────────────────

$unifiedRows = @(foreach ($sName in $allScenarioNames) {
    $entries = @{}
    foreach ($srv in $Server) {
        $entries[$srv] = $scenariosByServer[$srv] |
            Where-Object { $_.name -eq $sName } |
            Select-Object -First 1
    }
    @{ Name = $sName; Entries = $entries }
})

# ═══════════════════════════════════════════════════════════════════════════════════
# MODE = VERSION
# ═══════════════════════════════════════════════════════════════════════════════════

if ($Mode -eq 'Version') {

    if ($OnlyDifferences) {
        $unifiedRows = @($unifiedRows | Where-Object {
            $row = $_
            $hasAbsent = @($Server | Where-Object { $null -eq $row.Entries[$_] }).Count -gt 0
            if ($hasAbsent) { return $true }
            $versions = @(
                $Server |
                Where-Object { $null -ne $row.Entries[$_] } |
                ForEach-Object { Get-VersionNumber $row.Entries[$_].comment } |
                Where-Object { $null -ne $_ }
            )
            if ($versions.Count -lt 2) { return $false }
            ($versions | Select-Object -Unique).Count -gt 1
        })

        if ($unifiedRows.Count -eq 0) {
            Write-Host 'No differences found.'
            exit
        }
    }

    if ($Server.Count -eq 1) {
        # ── Single-server ──────────────────────────────────────────────────────────
        $header = "{0,-63}  Version     User         ModifiedAt" -f 'Scenario'
        Write-Host $header
        Write-PlainText $header

        foreach ($row in $unifiedRows) {
            $srv      = $Server[0]
            $scenario = $row.Entries[$srv]
            if ($null -eq $scenario) { continue }

            $stateColor = Get-ScenarioStateColor -Scenario $scenario
            $version    = Get-VersionNumber $scenario.comment
            $versionStr = if ($null -ne $version) { $version.ToString().PadLeft(3) } else { '  ?' }
            $userName   = if ($scenario.userName) { [string]$scenario.userName } else { '' }
            $modifiedAt = ''
            if ($scenario.modifiedAt) {
                try   { $modifiedAt = ([datetime]$scenario.modifiedAt).ToString('yyyy-MM-dd') }
                catch { $modifiedAt = [string]$scenario.modifiedAt }
            }

            $nameStr = "{0,-63}" -f $row.Name
            Write-Host $nameStr          -NoNewline
            Write-Host '  '              -NoNewline
            Write-Host '■'               -NoNewline -ForegroundColor $stateColor
            Write-Host " $($versionStr)   " -NoNewline
            Write-Host ("{0,-12}" -f $userName) -NoNewline
            Write-Host " $($modifiedAt)"

            Write-PlainText "$($nameStr)  ■ $($versionStr)   $("{0,-12}" -f $userName) $($modifiedAt)"
        }

    } else {
        # ── Multi-server ───────────────────────────────────────────────────────────
        $header = "{0,-63}  " -f 'Scenario'
        foreach ($srv in $Server) { $header += "{0,-13}" -f $srv }
        Write-Host $header
        Write-PlainText $header

        foreach ($row in $unifiedRows) {
            $presentVersions = @(
                $Server |
                Where-Object { $null -ne $row.Entries[$_] } |
                ForEach-Object { Get-VersionNumber $row.Entries[$_].comment } |
                Where-Object { $null -ne $_ }
            )

            $nameStr   = "{0,-63}" -f $row.Name
            $plainLine = "$($nameStr)  "
            Write-Host $nameStr -NoNewline
            Write-Host '  '    -NoNewline

            foreach ($srv in $Server) {
                $scenario = $row.Entries[$srv]
                if ($null -eq $scenario) {
                    $col = "{0,-13}" -f '-'
                    Write-Host $col -NoNewline -ForegroundColor DarkGray
                    $plainLine += $col
                } else {
                    $stateColor = Get-ScenarioStateColor -Scenario $scenario
                    $version    = Get-VersionNumber $scenario.comment
                    $versionStr = if ($null -ne $version) { $version.ToString().PadLeft(3) } else { '  ?' }
                    $cmpColor   = if ($null -ne $version -and $presentVersions.Count -gt 0) {
                        Get-CompareColor -Version $version -AllVersions $presentVersions
                    } else { 'White' }

                    # Column = 13 chars: "■ VVV        " (1+1+3+8)
                    Write-Host '■'            -NoNewline -ForegroundColor $stateColor
                    Write-Host ' '            -NoNewline
                    Write-Host $versionStr    -NoNewline -ForegroundColor $cmpColor
                    Write-Host '        '     -NoNewline
                    $plainLine += "■ $($versionStr)        "
                }
            }

            Write-Host ''
            Write-PlainText $plainLine
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════════
# MODE = LANDSCAPE
# ═══════════════════════════════════════════════════════════════════════════════════

elseif ($Mode -eq 'Landscape') {

    # ── Fetch landscape data ─────────────────────────────────────────────────────
    # $landscapeData[$serverName][$scenarioName][$entryName] = @{ EntryType; Properties }

    $landscapeData = @{}
    foreach ($srv in $Server) { $landscapeData[$srv] = @{} }

    foreach ($sName in $allScenarioNames) {
        foreach ($srv in $Server) {
            $scenario = $scenariosByServer[$srv] |
                Where-Object { $_.name -eq $sName } |
                Select-Object -First 1
            if ($null -eq $scenario) { continue }

            $infosUrl   = "$($baseUrlMap[$srv])$((Get-ServerConfig).OrchestraDeploymentApiBase)/landscape/infos/$($scenario.scenarioID)"
            $rawEntries = Invoke-OrchApi -Url $infosUrl -Credential $credentialMap[$srv]

            $landscapeData[$srv][$sName] = @{}

            foreach ($entry in $rawEntries) {
                $entryName = [string]$entry.entryName

                $ignored = $false
                foreach ($pattern in $LandscapeIgnoreList) {
                    if ($entryName -match $pattern) { $ignored = $true; break }
                }
                if ($ignored) { continue }

                if ($LandscapeName -and $entryName -notmatch $LandscapeName) { continue }

                $props = Get-LandscapeEntryProperties `
                    -BaseUrl     $baseUrlMap[$srv] `
                    -Credential  $credentialMap[$srv] `
                    -ScenarioObj $scenario `
                    -EntryObj    $entry

                $landscapeData[$srv][$sName][$entryName] = @{
                    EntryType  = [string]$entry.entryTypeName
                    Properties = $props
                }
            }
        }
    }

    # ── Pre-compute valueWidth ───────────────────────────────────────────────────
    $maxValueLen = 0
    foreach ($srv in $Server) {
        if ($srv.Length -gt $maxValueLen) { $maxValueLen = $srv.Length }
        foreach ($sName in $allScenarioNames) {
            if (-not $landscapeData[$srv][$sName]) { continue }
            foreach ($entryName in $landscapeData[$srv][$sName].Keys) {
                foreach ($p in $landscapeData[$srv][$sName][$entryName].Properties) {
                    if ($p.Value.Length -gt $maxValueLen) { $maxValueLen = $p.Value.Length }
                }
            }
        }
    }
    $valueWidth = $maxValueLen + 20

    if ($Host) {
        $maxLengthDueToScreen = [int](($Host.UI.RawUI.WindowSize.Width - 60)/$Server.Count)-3
        if ($valueWidth -gt $maxLengthDueToScreen) {$valueWidth=$maxLengthDueToScreen}
    }
    else {
        if ($valueWidth -gt 40) {$valueWidth=40}
    }
    

    # ── Build show-entry sets (applying OnlyDifferences) ────────────────────────
    $showEntries = @{}
    foreach ($sName in $allScenarioNames) {
        $allEntryNames = @(
            $Server |
            Where-Object { $landscapeData[$_][$sName] } |
            ForEach-Object { $landscapeData[$_][$sName].Keys } |
            Select-Object -Unique |
            Sort-Object
        )

        $entriesToShow = [System.Collections.Generic.List[string]]::new()

        foreach ($entryName in $allEntryNames) {
            if ($OnlyDifferences) {
                $serversWithEntry = @(
                    $Server | Where-Object {
                        $landscapeData[$_][$sName] -and
                        $landscapeData[$_][$sName].ContainsKey($entryName)
                    }
                )

                if ($serversWithEntry.Count -lt 2) { continue }

                $firstSrv  = $serversWithEntry[0]
                $entryType = $landscapeData[$firstSrv][$sName][$entryName].EntryType
                $propNames = Get-UnionPropNames -Servers $serversWithEntry -SName $sName -EntryName $entryName -LandscapeData $landscapeData

                $isDifferent = $false
                foreach ($propName in $propNames) {
                    if ($entryType -eq 'database connection' -and $propName -notin @('Server', 'Database')) {
                        continue
                    }
                    $vals = @(
                        $serversWithEntry | ForEach-Object {
                            $p = $landscapeData[$_][$sName][$entryName].Properties |
                                Where-Object { $_.PropName -eq $propName } |
                                Select-Object -First 1
                            if ($p) { $p.Value } else { $null }
                        } | Where-Object { $null -ne $_ }
                    )
                    if (($vals | Select-Object -Unique).Count -gt 1) {
                        $isDifferent = $true
                        break
                    }
                }

                if (-not $isDifferent) { continue }
            }

            $entriesToShow.Add($entryName)
        }

        $showEntries[$sName] = $entriesToShow
    }

    # ── Render ───────────────────────────────────────────────────────────────────

    $firstSceanario = $true
    foreach ($sName in $allScenarioNames) {
        $entriesToShow = $showEntries[$sName]
        if ($entriesToShow.Count -eq 0) { continue }

        Write-Host $sName -ForegroundColor Cyan
        Write-PlainText $sName

        if ($Server.Count -eq 1) {
            # ── Single-server landscape ──────────────────────────────────────────
            $srv = $Server[0]
            foreach ($entryName in $entriesToShow) {
                if (-not ($landscapeData[$srv][$sName] -and $landscapeData[$srv][$sName].ContainsKey($entryName))) { continue }
                $entryData = $landscapeData[$srv][$sName][$entryName]
                $icon      = Get-EntryTypeIcon -EntryTypeName $entryData.EntryType

                foreach ($p in $entryData.Properties) {
                    $line = "  $($icon) $("{0,-40}" -f $entryName)  $("{0,-10}" -f $p.PropName)  $($p.Value)"
                    Write-Host $line
                    Write-PlainText $line
                }
            }

        } else {
            # ── Multi-server landscape ───────────────────────────────────────────
            $blankLeft  = "  " + " " * 3 + " " + ("{0,-40}" -f '') + "  " + ("{0,-10}" -f '') + "  "
            $headerLine = $blankLeft
            foreach ($srv in $Server) {
                $headerLine += ("{0,-$valueWidth}" -f $srv) + "  "
            }
            if ($firstSceanario) { Write-Host $headerLine }
            Write-PlainText $headerLine

            foreach ($entryName in $entriesToShow) {
                $firstSrv = $Server | Where-Object {
                    $landscapeData[$_][$sName] -and
                    $landscapeData[$_][$sName].ContainsKey($entryName)
                } | Select-Object -First 1

                $icon      = if ($firstSrv) {
                    Get-EntryTypeIcon -EntryTypeName $landscapeData[$firstSrv][$sName][$entryName].EntryType
                } else { '[?]' }

                $serversWithEntry = @(
                    $Server | Where-Object {
                        $landscapeData[$_][$sName] -and
                        $landscapeData[$_][$sName].ContainsKey($entryName)
                    }
                )
                $allPropNames = Get-UnionPropNames -Servers $serversWithEntry -SName $sName -EntryName $entryName -LandscapeData $landscapeData

                foreach ($propName in $allPropNames) {
                    $perServerValues = @{}
                    foreach ($srv in $Server) {
                        $hasEntry = $landscapeData[$srv][$sName] -and
                                    $landscapeData[$srv][$sName].ContainsKey($entryName)
                        if ($hasEntry) {
                            $p = $landscapeData[$srv][$sName][$entryName].Properties |
                                Where-Object { $_.PropName -eq $propName } |
                                Select-Object -First 1
                            $perServerValues[$srv] = if ($p) { $p.Value } else { $null }
                        } else {
                            $perServerValues[$srv] = $null
                        }
                    }

                    $presentVals  = @($Server | Where-Object { $null -ne $perServerValues[$_] -and "" -ne $perServerValues[$_]  } | ForEach-Object { $perServerValues[$_] })
                    $allSameValue = ($presentVals | Select-Object -Unique).Count -le 1

                    $leftPart = "  $($icon) $("{0,-40}" -f $entryName)  $("{0,-10}" -f $propName)  "
                    Write-Host $leftPart -NoNewline
                    $plainLine = $leftPart

                    foreach ($srv in $Server) {
                        $val = $perServerValues[$srv]

                        if ($null -eq $val) {
                            $col = ("{0,-$valueWidth}" -f '-') + "  "
                            Write-Host $col -NoNewline -ForegroundColor DarkGray
                            $plainLine += $col
                        } else {
                            $val = if ($val.Length -gt $valueWidth) { $val.Substring(0,$valueWidth-1) + "…" } else { $val }
                            $color = if ($allSameValue) { 'White' } else { 'Yellow' }
                            $col   = ("{0,-$valueWidth}" -f $val) + "  "
                            Write-Host $col -NoNewline -ForegroundColor $color
                            $plainLine += $col
                        }
                    }

                    Write-Host ''
                    Write-PlainText $plainLine
                }
            }
        }

        $firstSceanario = $false
    }
}

# ─── Write Output File ────────────────────────────────────────────────────────────

if ($OutputDirectory -and $script:OutputBuilder) {
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $serverStr = $Server -join '_'
    $fileName  = "Get-DeploymentInfo_${serverStr}_${timestamp}.txt"
    $filePath  = Join-Path $OutputDirectory $fileName
    $script:OutputBuilder.ToString() | Set-Content -Path $filePath -Encoding UTF8
    Write-Host "Output written to: $($filePath)"
}
