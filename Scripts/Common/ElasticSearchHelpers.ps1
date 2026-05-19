<#
.SYNOPSIS
    Shared helper functions for Elasticsearch queries.

.DESCRIPTION
    Provides reusable logic for executing Elasticsearch scroll queries and
    managing API key credentials. Resolve-ElasticCredential stores and loads
    an API key as an encrypted PSCredential (CLIXML/DPAPI) so secrets never
    live in plain-text files or script parameters. Invoke-ElasticScrollSearch
    posts the supplied body to an index, follows the scroll cursor until all
    hits are retrieved, and optionally invokes a callback after each page is
    collected. Get-ElasticErrorMessage surfaces response bodies from
    Invoke-RestMethod failures to aid troubleshooting.
#>

function Resolve-ElasticCredential {
    <#
    .SYNOPSIS
        Load or prompt for an Elasticsearch API key stored as an encrypted CLIXML credential.

    .DESCRIPTION
        Checks for a saved PSCredential at CredentialPath. If found (and Reset is not set),
        imports and returns it. Otherwise prompts via Get-Credential — enter the API key as
        the password field — saves the result, and returns it.
        Extract the key with: $cred.GetNetworkCredential().Password

    .PARAMETER CredentialPath
        Full path to the .credentials.clixml file used to persist the credential.

    .PARAMETER Reset
        When set, discards any saved file and prompts for fresh credentials.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$CredentialPath,

        [Parameter(Mandatory=$false)]
        [switch]$Reset
    )

    if (-not $Reset -and (Test-Path -Path $CredentialPath)) {
        return Import-Clixml -Path $CredentialPath
    }

    $cred = Get-Credential -UserName 'elastic' -Message 'Enter the Elasticsearch API key as the password field'
    $cred | Export-Clixml -Path $CredentialPath
    return $cred
}

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

function Get-ElasticSourceValue {
    <#
    .SYNOPSIS
        Retrieve a nested value from an Elasticsearch _source document using dotted paths.

    .DESCRIPTION
        Traverses PSCustomObjects and dictionary-like structures according to the supplied
        field path segments. Returns $null as soon as a segment cannot be resolved so callers
        can gracefully handle missing fields without throwing.

    .PARAMETER Source
        The _source object (typically a PSCustomObject) to traverse.

    .PARAMETER FieldPath
        Dotted field path (for example "BK._STATUS_TEXT") describing the value to retrieve.
    #>
    param(
        [Parameter(Mandatory=$false)]
        [object]$Source,

        [Parameter(Mandatory=$false)]
        [string]$FieldPath
    )

    if (-not $Source -or [string]::IsNullOrWhiteSpace($FieldPath)) {
        return $null
    }

    $current = $Source
    foreach ($segment in $FieldPath -split '\.') {
        if ($null -eq $current) { return $null }

        $prop = $current.PSObject.Properties[$segment]
        if ($prop) {
            $current = $prop.Value
            continue
        }

        if ($current -is [System.Collections.IDictionary]) {
            if ($current.Contains($segment)) {
                $current = $current[$segment]
                continue
            }

            $foundKey = $false
            foreach ($key in $current.Keys) {
                if ($key -eq $segment) {
                    $current = $current[$key]
                    $foundKey = $true
                    break
                }
            }

            if ($foundKey) { continue }
        }

        return $null
    }

    return $current
}

function Resolve-EffectiveTimespan {
    <#
    .SYNOPSIS
        Resolves a Timespan value from a number (minutes), a TimeSpan, or $null.

    .DESCRIPTION
        Accepts a numeric value (interpreted as minutes), a TimeSpan object, or a
        string that can be parsed as either. Returns a TimeSpan. If Value is null
        or empty, returns a TimeSpan of DefaultMinutes minutes.

    .PARAMETER Value
        A number, TimeSpan, or parseable string. Pass $null to get the default.

    .PARAMETER DefaultMinutes
        Minutes to use when Value is null or empty. Defaults to 15.
    #>
    param(
        [object]$Value,
        [int]$DefaultMinutes = 15
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace("$Value")) {
        return [timespan]::FromMinutes($DefaultMinutes)
    }

    if ($Value -is [timespan]) { return $Value }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        return [timespan]::FromMinutes([double]$Value)
    }

    $minutes = 0.0
    $textValue = "$Value".Trim()
    if ([double]::TryParse($textValue, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$minutes)) {
        return [timespan]::FromMinutes($minutes)
    }

    $parsedTimeSpan = [timespan]::Zero
    if ([timespan]::TryParse($textValue, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedTimeSpan)) {
        return $parsedTimeSpan
    }

    throw "Invalid Timespan '$Value'. Provide a number (minutes) or a TimeSpan value."
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
        $Body = $Body | ConvertTo-Json -Depth 100 -Compress
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

    $responseError = $response.PSObject.Properties['error']
    if ($responseError -and $responseError.Value) {
        throw [System.Exception]::new("Elasticsearch error: $($responseError.Value.type) - $($responseError.Value.reason)")
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

        $scrollError = $scrollResponse.PSObject.Properties['error']
        if ($scrollError -and $scrollError.Value) {
            throw [System.Exception]::new("Elasticsearch scroll error: $($scrollError.Value.type) - $($scrollError.Value.reason)")
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
