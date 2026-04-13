<#
.SYNOPSIS
    Sends an HL7 message over TLS/MLLP and shows or saves the server response.

.DESCRIPTION
    This script reads an HL7 input file as UTF-8, normalizes line endings to CR, and sends it as an MLLP frame to a TLS endpoint.
    The sending wire encoding can be selected with -Encoding.

    The server response is decoded with the same encoding, extracted from MLLP framing (if present), and either:
    - displayed with syntax coloring for HL7 separator characters, or
    - written as UTF-8 to an output file.

.PARAMETER HostName
    Target host name.

.PARAMETER Port
    Target TCP port.

.PARAMETER Path
    Input HL7 message file path.

.PARAMETER Encoding
    Character encoding used when converting message text to bytes for sending and when decoding the response.

.PARAMETER CACertPath
    Optional CA certificate path used to validate an otherwise untrusted server chain root.

.PARAMETER CertificatePath
    Optional client certificate path for mTLS.

.PARAMETER CertificatePassword
    Optional client certificate password.

.PARAMETER ResponsePath
    Optional output file path for the response. When provided, response text is saved as UTF-8 instead of being colorized in console.

.PARAMETER ReceiveTimeoutMs
    Socket read timeout in milliseconds.

.EXAMPLE
    .\Send-HL7Message.ps1 -HostName stammdatenabfrage-2100.esb.gesundheitsverbund.at -Port 443 -Path .\A19_MAC_Aria.hl7 -Encoding ISO-8859-1

.NOTES
    - Input files are always read as UTF-8.
    - Output files are always written as UTF-8.
#>
param(
    [Parameter(Mandatory)]
    [string]$HostName,

    [Parameter(Mandatory)]
    [int]$Port,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    [ValidateNotNullOrEmpty()]
    [string]$Encoding = 'ISO-8859-1',

    [string]$CACertPath,
    [string]$CertificatePath,
    [string]$CertificatePassword,
    [string]$ResponsePath,

    [ValidateRange(1, 600000)]
    [int]$ReceiveTimeoutMs = 10000
)

$ErrorActionPreference = 'Stop'

# MLLP framing bytes
$SB = [byte]0x0B
$EB = [byte]0x1C
$CR = [byte]0x0D

$script:CaCertificate = $null

function Get-Hl7PayloadFromMllp {
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes,

        [Parameter(Mandatory)]
        [System.Text.Encoding]$TextEncoding,

        [Parameter(Mandatory)]
        [byte]$StartByte,

        [Parameter(Mandatory)]
        [byte]$EndByte
    )

    if ($Bytes.Count -eq 0) {
        return ''
    }

    $startIndex = [Array]::IndexOf($Bytes, $StartByte)
    $endIndex = [Array]::IndexOf($Bytes, $EndByte)

    if ($startIndex -ge 0 -and $endIndex -gt $startIndex) {
        return $TextEncoding.GetString($Bytes, $startIndex + 1, $endIndex - ($startIndex + 1))
    }

    if ($endIndex -gt 0) {
        return $TextEncoding.GetString($Bytes, 0, $endIndex)
    }

    return $TextEncoding.GetString($Bytes)
}

function Write-Hl7Colorized {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    $colorMap = @{
        '|' = 'Cyan'
        '^' = 'Yellow'
        '~' = 'Magenta'
        '\\' = 'DarkYellow'
        '&' = 'Green'
    }

    $segments = $Message -split "`r"
    for ($segmentIndex = 0; $segmentIndex -lt $segments.Count; $segmentIndex++) {
        $segment = $segments[$segmentIndex]

        if ([string]::IsNullOrEmpty($segment)) {
            Write-Host
            continue
        }

        foreach ($char in $segment.ToCharArray()) {
            $token = [string]$char
            if ($colorMap.ContainsKey($token)) {
                Write-Host $token -NoNewline -ForegroundColor $colorMap[$token]
            }
            else {
                Write-Host $token -NoNewline
            }
        }

        if ($segmentIndex -lt ($segments.Count - 1)) {
            Write-Host
        }
    }

    if (-not $Message.EndsWith("`r")) {
        Write-Host
    }
}

function Test-ServerCertificate {
    param($sender, $serverCertificate, $chain, $sslPolicyErrors)

    if ($sslPolicyErrors -eq [System.Net.Security.SslPolicyErrors]::None) {
        return $true
    }

    if ($sslPolicyErrors -eq [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors -and $script:CaCertificate) {
        foreach ($status in $chain.ChainStatus) {
            if ($status.Status -eq [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags]::UntrustedRoot) {
                $chainRoot = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
                if ($chainRoot.Thumbprint -eq $script:CaCertificate.Thumbprint) {
                    Write-Host 'Certificate successfully validated against custom CA.'
                    return $true
                }
            }
        }
    }

    Write-Warning "Certificate validation error: $($sslPolicyErrors)"
    foreach ($status in $chain.ChainStatus) {
        Write-Warning "  Chain status: $($status.StatusInformation.Trim())"
    }

    return $false
}

if (-not (Test-Path -Path $Path -PathType Leaf)) {
    throw "Input HL7 file not found: $($Path)"
}

try {
    $wireEncoding = [System.Text.Encoding]::GetEncoding($Encoding)
}
catch {
    throw "Unsupported encoding '$($Encoding)'."
}

if ($CACertPath) {
    $script:CaCertificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CACertPath)
    Write-Host "Loaded CA certificate: $($script:CaCertificate.Subject)"
}

$hl7Message = Get-Content -Path $Path -Raw -Encoding UTF8
$hl7Message = $hl7Message -replace "`r`n", "`r"
$hl7Message = $hl7Message -replace "`n", "`r"
$hl7Message = $hl7Message.TrimEnd("`r")

$tcpClient = $null
$sslStream = $null

try {
    $tcpClient = New-Object System.Net.Sockets.TcpClient
    $tcpClient.ReceiveTimeout = $ReceiveTimeoutMs
    $tcpClient.Connect($HostName, $Port)

    Write-Host "Connected TCP socket to $($HostName):$($Port)."

    $sslStream = New-Object System.Net.Security.SslStream(
        $tcpClient.GetStream(),
        $false,
        { param($sender, $serverCertificate, $chain, $sslPolicyErrors) Test-ServerCertificate $sender $serverCertificate $chain $sslPolicyErrors }
    )

    $clientCertificates = New-Object System.Security.Cryptography.X509Certificates.X509CertificateCollection
    if ($CertificatePath) {
        $clientCertificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertificatePath, $CertificatePassword)
        $clientCertificates.Add($clientCertificate) | Out-Null
        Write-Host "Loaded client certificate: $($clientCertificate.Subject)"
    }

    $sslStream.AuthenticateAsClient(
        $HostName,
        $clientCertificates,
        [System.Security.Authentication.SslProtocols]::Tls12,
        $true
    )

    Write-Host "TLS established. Protocol: $($sslStream.SslProtocol), Cipher: $($sslStream.CipherAlgorithm)."

    $payloadBytes = $wireEncoding.GetBytes($hl7Message)
    $frameBytes = [byte[]](@($SB) + $payloadBytes + @($EB, $CR))

    $sslStream.Write($frameBytes, 0, $frameBytes.Length)
    $sslStream.Flush()

    Write-Host "Message sent ($($frameBytes.Length) bytes including MLLP frame)."

    $buffer = New-Object byte[] 4096
    $responseBytes = New-Object System.Collections.Generic.List[byte]
    $foundEndByte = $false

    do {
        try {
            $bytesRead = $sslStream.Read($buffer, 0, $buffer.Length)
        }
        catch [System.IO.IOException] {
            Write-Warning "Timeout while reading server response."
            break
        }

        if ($bytesRead -gt 0) {
            $responseBytes.AddRange($buffer[0..($bytesRead - 1)])
            if ($responseBytes.Contains($EB)) {
                $foundEndByte = $true
            }
        }
    } while ($bytesRead -gt 0 -and -not $foundEndByte)

    if ($responseBytes.Count -eq 0) {
        Write-Warning 'No response received from server.'
        return
    }

    $responseMessage = Get-Hl7PayloadFromMllp -Bytes $responseBytes.ToArray() -TextEncoding $wireEncoding -StartByte $SB -EndByte $EB

    if ($ResponsePath) {
        $responseDirectory = Split-Path -Path $ResponsePath -Parent
        if ($responseDirectory -and -not (Test-Path -Path $responseDirectory -PathType Container)) {
            New-Item -Path $responseDirectory -ItemType Directory -Force | Out-Null
        }

        Set-Content -Path $ResponsePath -Value $responseMessage -Encoding UTF8
        Write-Host "Response saved to UTF-8 file: $($ResponsePath)"
    }
    else {
        Write-Host 'Server response:'
        Write-Hl7Colorized -Message $responseMessage
    }
}
catch {
    Write-Error "Failed to send HL7 message: $($_.Exception.Message)"
    if ($_.Exception.InnerException) {
        Write-Error "Inner exception: $($_.Exception.InnerException.Message)"
    }
    throw
}
finally {
    if ($sslStream) {
        $sslStream.Dispose()
    }

    if ($tcpClient) {
        $tcpClient.Dispose()
    }

    Write-Host 'Connection closed.'
}
