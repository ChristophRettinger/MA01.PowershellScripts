<#
    .SYNOPSIS
        Lightweight HTTP/HTTPS listener that captures inbound POST & PUT requests (optionally all methods)
        and logs request headers + body to timestamped files.

    .DESCRIPTION
        Useful for debugging webhooks, testing integrations, or just seeing what a client is sending.
        Built on [System.Net.HttpListener]. Works on Windows PowerShell 5.1 and PowerShell 7+.

        For HTTPS you must bind a certificate to the chosen port with netsh (see QUICK START below).

    .PARAMETER Prefixes
        One or more HttpListener prefix strings (must end with a slash). Example:
            'http://+:8080/' , 'https://+:8443/'
        If omitted, prefixes are auto-built from -HttpPort and -HttpsPort.

    .PARAMETER HttpPort
        Port for HTTP prefix (default 8080). Ignored if -Prefixes supplied.

    .PARAMETER HttpsPort
        Port for HTTPS prefix (none by default). Ignored if -Prefixes supplied.

    .PARAMETER LogRoot
        Directory where per-request log files will be written. Default: <script folder>\Host-HttpListenerLogs.

    .PARAMETER AllowAllMethods
        By default only POST and PUT requests are logged; others get 405. Use -AllowAllMethods to log all.

    .PARAMETER MaxBodyBytes
        Safety cap when reading request bodies into memory (default 100MB). Bodies larger than this are truncated.

    .PARAMETER Once
        Process a single request then exit (handy for testing).

    .EXAMPLE
        # Listen HTTP 8080 only
        pwsh ./Host-HttpListener.ps1 -HttpPort 8080

    .EXAMPLE
        # Listen HTTP + HTTPS; custom log root
        pwsh ./Host-HttpListener.ps1 -HttpPort 8080 -HttpsPort 8443 -LogRoot C:\Temp\HookLogs

    .EXAMPLE
        # Provide explicit prefixes (Linux-friendly *)
        pwsh ./Host-HttpListener.ps1 -Prefixes 'http://*:5000/'

    .NOTES
        Stop with Ctrl+C.
        Requires appropriate URL ACL reservation if not running elevated (Windows):
            netsh http add urlacl url=http://+:8080/ user=DOMAIN\User
        HTTPS binding (Windows):
            # create or import cert, note thumbprint
            netsh http add sslcert ipport=0.0.0.0:8443 certhash=<THUMBPRINT> appid={<GUID>}
#>

[CmdletBinding()]
param(
    [string[]]$Prefixes,
    [int]$HttpPort = 8080,
    [int]$HttpsPort,
    [string]$LogRoot = (Join-Path $PSScriptRoot 'Host-HttpListenerLogs'),
    [switch]$AllowAllMethods,
    [int]$MaxBodyBytes = 104857600,
    [switch]$Once
)

# Ensure log root exists
[void][IO.Directory]::CreateDirectory($LogRoot)

function Get-SafeFilePart {
    param([string]$Text)
    if (-not $Text) { return 'root' }
    $invalid = [IO.Path]::GetInvalidFileNameChars() -join ''
    $pattern = "[${invalid}\\s/]+"
    $safe = $Text -replace $pattern,'_'
    $safe = $safe.Trim('_')
    if (-not $safe) { $safe = 'root' }
    return $safe
}

function New-RequestBasePath {
    param(
        [System.Net.HttpListenerRequest]$Request,
        [string]$LogRoot
    )
    $now = Get-Date
    $dateFolder = Join-Path $LogRoot ($now.ToString('yyyyMMdd'))
    if (-not (Test-Path $dateFolder)) { [void](New-Item -ItemType Directory -Path $dateFolder) }
    $stamp = $now.ToUniversalTime().ToString('yyyyMMdd_HHmmss_fffZ')
    $method = $Request.HttpMethod
    $urlPart = Get-SafeFilePart -Text $Request.Url.AbsolutePath
    if ($urlPart.Length -gt 40) { $urlPart = $urlPart.Substring(0,40) }
    $baseName = "${stamp}_${method}_${urlPart}"
    return (Join-Path $dateFolder $baseName)
}

function Write-RequestLog {
    param(
        [System.Net.HttpListenerContext]$Context,
        [string]$LogRoot,
        [int]$MaxBodyBytes
    )

    $req = $Context.Request
    $resp = $Context.Response

    $base = New-RequestBasePath -Request $req -LogRoot $LogRoot
    $hdrFile  = "$base.headers.txt"
    $bodyFile = "$base.body"
    $metaFile = "$base.meta.json"

    # --- HEADERS ---
    $headersHash = [ordered]@{}
    foreach ($k in $req.Headers.AllKeys) {
        $headersHash[$k] = $req.Headers[$k]
    }

    $remote = $req.RemoteEndPoint

    $hdrOut  = "=== Request Info ===`r`n"
    $hdrOut += "Timestamp (UTC): $(Get-Date -Date (Get-Date).ToUniversalTime() -Format o)`r`n"
    $hdrOut += "Timestamp (Local): $(Get-Date -Format o)`r`n"
    $hdrOut += "Remote: $remote`r`n"
    $hdrOut += "Method: $($req.HttpMethod)`r`n"
    $hdrOut += "Url: $($req.Url.AbsoluteUri)`r`n"
    $hdrOut += "ContentType: $($req.ContentType)`r`n"
    $hdrOut += "ContentLength: $($req.ContentLength64)`r`n"
    $hdrOut += "IsSecureConnection: $($req.IsSecureConnection)`r`n"
    $hdrOut += "KeepAlive: $($req.KeepAlive)`r`n"
    $hdrOut += "UserAgent: $($req.UserAgent)`r`n"
    $hdrOut += "`r`n=== Headers ===`r`n"
    foreach ($k in $headersHash.Keys) { $hdrOut += "$($k): $($headersHash[$k])`r`n" }
    [IO.File]::WriteAllText($hdrFile,$hdrOut)

    # --- BODY ---
    $bodyBytes = $null
    $truncated = $false
    try {
        $buffer = New-Object byte[] 8192
        $ms = New-Object IO.MemoryStream
        $total = 0
        while (($read = $req.InputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
            if (($total + $read) -le $MaxBodyBytes) {
                $ms.Write($buffer,0,$read)
            } else {
                $remain = [math]::Max(0, $MaxBodyBytes - $total)
                if ($remain -gt 0) { $ms.Write($buffer,0,$remain) }
                $truncated = $true
                break
            }
            $total += $read
        }
        $bodyBytes = $ms.ToArray()
        $ms.Dispose()
    } catch {
        Write-Warning "Failed reading request body: $_"
        $bodyBytes = @()
    }

    if ($bodyBytes -and $bodyBytes.Length -gt 0) {
        [IO.File]::WriteAllBytes($bodyFile,$bodyBytes)
    } else {
        # create zero-length file so you know request had no body / read failed
        [IO.File]::WriteAllBytes($bodyFile,[byte[]]@())
    }

    # Determine if body is texty and also write decoded .txt helper (non-authoritative)
    if ($bodyBytes.Length -gt 0) {
        $isText = $false
        if ($req.ContentType -and ($req.ContentType -match '^(text/|application/(json|xml|x-www-form-urlencoded|javascript))')) { $isText = $true }
        if (!$isText -and ($bodyBytes -notmatch "\0")) { $isText = $true }  # crude heuristic: no NUL bytes
        if ($isText) {
            $enc = $req.ContentEncoding
            if (-not $enc) { $enc = [Text.UTF8Encoding]::new($false) }
            try {
                $bodyText = $enc.GetString($bodyBytes)
                [IO.File]::WriteAllText("$bodyFile.txt",$bodyText,$enc)
            } catch {
                Write-Warning "Failed to decode body as text: $_"
            }
        }
    }

    # --- META JSON ---
    $meta = [ordered]@{
        TimestampUtc      = (Get-Date).ToUniversalTime().ToString('o')
        TimestampLocal    = (Get-Date).ToString('o')
        RemoteEndPoint    = $remote.ToString()
        Method            = $req.HttpMethod
        Url               = $req.Url.AbsoluteUri
        RawUrl            = $req.RawUrl
        ContentType       = $req.ContentType
        ContentLength     = [int64]$req.ContentLength64
        IsSecureConnection= $req.IsSecureConnection
        Headers           = $headersHash
        BodyFile          = [IO.Path]::GetFileName($bodyFile)
        BodyTextFile      = if (Test-Path "$bodyFile.txt") { [IO.Path]::GetFileName("$bodyFile.txt") } else { $null }
        Truncated         = $truncated
    }
    $metaJson = $meta | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($metaFile,$metaJson)

    # --- RESPONSE ---
    $resp.StatusCode = 200
    $resp.ContentType = 'text/plain'
    $msg = "OK - logged as $(Split-Path $base -Leaf)"
    if ($truncated) { $msg += " (body truncated at $MaxBodyBytes bytes)" }
    $outBytes = [Text.Encoding]::UTF8.GetBytes($msg)
    $resp.ContentLength64 = $outBytes.Length
    $resp.OutputStream.Write($outBytes,0,$outBytes.Length)
    $resp.Close()

    Write-Host "[$(Get-Date -Format 'u')] $($req.HttpMethod) $($req.Url.AbsoluteUri) -> $base" -ForegroundColor Cyan
    if ($truncated) { Write-Warning "Body truncated for $($req.Url.AbsoluteUri)" }
}

# Build prefixes if not provided
if (-not $Prefixes -or $Prefixes.Count -eq 0) {
    $Prefixes = @()
    if ($HttpPort)  { $Prefixes += "http://+:$HttpPort/" }
    if ($PSBoundParameters.ContainsKey('HttpsPort')) { $Prefixes += "https://+:$HttpsPort/" }
}

if ($Prefixes.Count -eq 0) {
    throw 'No listener prefixes specified. Provide -Prefixes or -HttpPort / -HttpsPort.'
}

$listener = [System.Net.HttpListener]::new()
foreach ($p in $Prefixes) {
    try {
        $listener.Prefixes.Add($p)
    } catch {
        throw "Invalid prefix '$p' : $_"
    }
}
$listener.AuthenticationSchemes = [System.Net.AuthenticationSchemes]::Anonymous

try {
    $listener.Start()
} catch {
    throw "Failed to start HttpListener. Do you need URL ACL / SSL binding? $_"
}

Write-Host "Listening on:" -ForegroundColor Green
$listener.Prefixes | ForEach-Object { Write-Host "  $_" -ForegroundColor Green }
Write-Host "Logging to: $LogRoot" -ForegroundColor Green
if (-not $AllowAllMethods) { Write-Host "Allowed methods: POST, PUT" -ForegroundColor Green }

$stopRequested = $false

# handle Ctrl+C gracefully
$null = Register-ObjectEvent -SourceIdentifier ConsoleBreak -InputObject ([Console]::CancelKeyPress) -EventName CancelKeyPress -Action {
    Write-Host "Ctrl+C detected - stopping listener..." -ForegroundColor Yellow
    $script:stopRequested = $true
    $event.Sender.Cancel = $true  # prevent abrupt kill; we'll exit loop
}

while ($listener.IsListening -and -not $stopRequested) {
    try {
        $ctx = $listener.GetContext()   # blocking
    } catch [System.Net.HttpListenerException] {
        break
    } catch {
        Write-Warning "Listener error: $_"
        continue
    }

    $method = $ctx.Request.HttpMethod
    if (-not $AllowAllMethods -and ($method -notin 'POST','PUT')) {
        # respond 405 without logging
        $ctx.Response.StatusCode = 405
        $ctx.Response.StatusDescription = 'Method Not Allowed'
        $bytes = [Text.Encoding]::UTF8.GetBytes('405 Method Not Allowed - use POST or PUT')
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.OutputStream.Write($bytes,0,$bytes.Length)
        $ctx.Response.Close()
        continue
    }

    Write-RequestLog -Context $ctx -LogRoot $LogRoot -MaxBodyBytes $MaxBodyBytes

    if ($Once) { break }
}

# Cleanup
if ($listener.IsListening) {
    $listener.Stop()
}
$listener.Close()

Unregister-Event -SourceIdentifier ConsoleBreak -ErrorAction SilentlyContinue

Write-Host 'Listener stopped.' -ForegroundColor Yellow

<#
=======================
QUICK START (minimal)
=======================
1. Save this file as Host-HttpListener.ps1.
2. Run (HTTP only):
       pwsh ./Host-HttpListener.ps1 -HttpPort 8080
   Send a test:
       curl -X POST http://localhost:8080/test -H 'X-Example: 123' -d 'hello world'
3. View logs under ./Host-HttpListenerLogs/<date>/...

=======================
HTTPS (Windows) QUICK STEPS
=======================
# Create self-signed cert in LocalMachine\My (admin):
$cert = New-SelfSignedCertificate -DnsName 'localhost' -CertStoreLocation Cert:\LocalMachine\My

# Bind cert to port 8443 (note the cert thumbprint & pick an appid GUID):
netsh http add sslcert ipport=0.0.0.0:8443 certhash=$($cert.Thumbprint) appid='{e3ad0df0-d7f0-47d6-a29a-9b9113946691}'

# Reserve URL ACL (replace USER):
netsh http add urlacl url=https://+:8443/ user=USER

# Run listener:
pwsh ./Host-HttpListener.ps1 -HttpsPort 8443

# Test:
curl -k -X POST https://localhost:8443/test -d '{"ping":1}' -H 'Content-Type: application/json'
#>
