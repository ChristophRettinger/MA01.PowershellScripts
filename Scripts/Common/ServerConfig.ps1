<#
.SYNOPSIS
    Loads the central server/URL configuration from ServerConfig.psd1.

.DESCRIPTION
    Provides Get-ServerConfig, a cached loader for ServerConfig.psd1. Scripts that need
    server names, URLs, or connection strings dot-source this file independently of
    ElasticSearchHelpers.ps1 — not every script needs Elasticsearch support.

    Usage in a script:
        $sharedDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'Common'
        . (Join-Path $sharedDir 'ServerConfig.ps1')
        $_cfg = Get-ServerConfig

    Compose URLs from config values:
        "$($_cfg.OrchestraTargets['prod01-wsk'].BaseUrl)$($_cfg.OrchestraReinjectPath)"
        "$($_cfg.OrchestraTargets[$srv].BaseUrl)$($_cfg.OrchestraDeploymentApiBase)/deployment/scenarioInfos"
#>

$script:_serverConfigCache = $null

function Get-ServerConfig {
    <#
    .SYNOPSIS
        Returns the parsed ServerConfig.psd1 hashtable, loading it once per session.
    #>
    if (-not $script:_serverConfigCache) {
        $path = Join-Path -Path $PSScriptRoot -ChildPath 'ServerConfig.psd1'
        if (-not (Test-Path -Path $path)) {
            throw "ServerConfig.psd1 not found at '$path'."
        }
        $script:_serverConfigCache = Import-PowerShellDataFile -Path $path
    }
    return $script:_serverConfigCache
}
