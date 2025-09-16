<#
.SYNOPSIS
    Shared helper functions for Elasticsearch queries.

.DESCRIPTION
    Provides reusable logic for executing Elasticsearch scroll queries so that
    scripts can consistently handle paging, error reporting, and header
    management. The primary entry point is Invoke-ElasticScrollSearch, which
    posts the supplied body to an index, follows the scroll cursor until all
    hits are retrieved, and optionally invokes a callback after each page is
    collected. Get-ElasticErrorMessage surfaces response bodies from
    Invoke-RestMethod failures to aid troubleshooting.
#>

function Get-ElasticErrorMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory=$false)]
        [string]$Prefix
    )

    $message = $ErrorRecord.Exception.Message

    try {
        $response = $ErrorRecord.Exception.Response
        if ($response -and $response.GetType().GetMethod('GetResponseStream')) {
            $stream = $response.GetResponseStream()
            if ($stream) {
                $reader = [System.IO.StreamReader]::new($stream)
                $body = $reader.ReadToEnd()
                $reader.Dispose()
                if ($stream -is [System.IDisposable]) { $stream.Dispose() }
                if ($body) {
                    $message = "$message Response: $body"
                }
            }
        }
    } catch {
        # Ignore failures while reading the error response body
    }

    if ($Prefix) {
        return "${Prefix}: $message"
    }

    return $message
}

function Invoke-ElasticScrollSearch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ElasticUrl,

        [Parameter(Mandatory=$true)]
        [object]$Body,

        [Parameter(Mandatory=$false)]
        [hashtable]$Headers = @{},

        [Parameter(Mandatory=$false)]
        [int]$TimeoutSec = 120,

        [Parameter(Mandatory=$false)]
        [string]$ScrollKeepAlive = '1m',

        [Parameter(Mandatory=$false)]
        [ScriptBlock]$OnPage
    )

    if (-not $Headers) {
        $Headers = @{}
    }

    if (-not $Headers.ContainsKey('Content-Type')) {
        $Headers['Content-Type'] = 'application/json'
    }

    if ($Body -isnot [string]) {
        $Body = $Body | ConvertTo-Json -Depth 10
    }

    $searchUri = if ($ElasticUrl -match '\?') {
        "$($ElasticUrl)&scroll=$ScrollKeepAlive"
    } else {
        "$($ElasticUrl)?scroll=$ScrollKeepAlive"
    }

    $uri = [System.Uri]$ElasticUrl
    $scrollUri = "$($uri.Scheme)://$($uri.Authority)/_search/scroll"

    $allHits = [System.Collections.Generic.List[object]]::new()

    try {
        $response = Invoke-RestMethod -Method Post -Uri $searchUri -Headers $Headers -Body $Body -ContentType 'application/json' -TimeoutSec $TimeoutSec
    } catch {
        $message = Get-ElasticErrorMessage -ErrorRecord $_ -Prefix 'Initial Elasticsearch request failed'
        throw [System.Exception]::new($message, $_.Exception)
    }

    if ($response.error) {
        $etype = $response.error.type
        $ereason = $response.error.reason
        throw [System.Exception]::new("Elasticsearch error: $etype - $ereason")
    }

    $hits = @($response.hits.hits)
    $scrollId = $response._scroll_id
    $page = 0

    if ($hits -and $hits.Count -gt 0) {
        foreach ($hit in $hits) { $null = $allHits.Add($hit) }
        $page = 1
        if ($OnPage) {
            & $OnPage $page $hits $allHits.Count
        }
    }

    while ($scrollId -and $hits -and $hits.Count -gt 0) {
        $scrollPayload = @{ scroll = $ScrollKeepAlive; scroll_id = $scrollId } | ConvertTo-Json -Depth 3
        try {
            $scrollResponse = Invoke-RestMethod -Method Post -Uri $scrollUri -Headers $Headers -Body $scrollPayload -ContentType 'application/json' -TimeoutSec $TimeoutSec
        } catch {
            $message = Get-ElasticErrorMessage -ErrorRecord $_ -Prefix 'Elasticsearch scroll request failed'
            throw [System.Exception]::new($message, $_.Exception)
        }

        if ($scrollResponse.error) {
            $stype = $scrollResponse.error.type
            $sreason = $scrollResponse.error.reason
            throw [System.Exception]::new("Elasticsearch scroll error: $stype - $sreason")
        }

        $hits = @($scrollResponse.hits.hits)
        $scrollId = $scrollResponse._scroll_id

        if (-not $hits -or $hits.Count -eq 0) {
            break
        }

        foreach ($hit in $hits) { $null = $allHits.Add($hit) }
        $page++
        if ($OnPage) {
            & $OnPage $page $hits $allHits.Count
        }
    }

    return $allHits
}
