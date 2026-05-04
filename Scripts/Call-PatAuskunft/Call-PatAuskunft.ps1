<#
.SYNOPSIS
    Calls the PatAuskunft SOAP service and prints the returned XML.

.DESCRIPTION
    Builds a SOAP GetData request for PatAuskunft, sends it with HTTP Basic
    authentication, then prints the decoded GetDataResult XML as formatted text.
    Credentials are stored locally as CLIXML for the current user and can be reset
    with -ResetCredentials.

.PARAMETER Environment
    Target environment. Controls the service URL.

.PARAMETER CASENO
    Case number alias for AID. Has priority for ID1.

.PARAMETER AID
    Alternative name for CASENO. Used for ID1 when CASENO is not set.

.PARAMETER BID
    Business identifier written to ID2.

.PARAMETER LEISTKST
    Leistende Kostenstelle written to ID3.

.PARAMETER Result
    PatAuskunft result type.

.PARAMETER ResultFilter
    Optional explicit result filter. If omitted, defaults depend on Result.

.PARAMETER ID1
    Explicit value for ID1. Overridden by CASENO or AID.

.PARAMETER ID2
    Explicit value for ID2. Overridden by BID.

.PARAMETER ID3
    Explicit value for ID3. Overridden by LEISTKST.

.PARAMETER ID4
    Explicit value for ID4.

.PARAMETER ID5
    Explicit value for ID5.

.PARAMETER ResetCredentials
    Prompts again for credentials and overwrites the locally saved file.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('production','staging','testing','development')]
    [string]$Environment = 'production',

    [Parameter(Mandatory=$false)]
    [string]$CASENO,

    [Parameter(Mandatory=$false)]
    [string]$AID,

    [Parameter(Mandatory=$false)]
    [string]$BID,

    [Parameter(Mandatory=$false)]
    [string]$LEISTKST,

    [Parameter(Mandatory=$false)]
    [ValidateSet('PATIENT_1','PATIENT_2','PATIENT_2L','PATIENT_3','PATIENT_3L','BEWEGUNG_1','AIDKette','DIAGNOSE','EXT_DIAGNOSE','EXT_LEISTUNG')]
    [string]$Result = 'PATIENT_3',

    [Parameter(Mandatory=$false)]
    [string]$ResultFilter,

    [Parameter(Mandatory=$false)]
    [string]$ID1,

    [Parameter(Mandatory=$false)]
    [string]$ID2,

    [Parameter(Mandatory=$false)]
    [string]$ID3,

    [Parameter(Mandatory=$false)]
    [string]$ID4,

    [Parameter(Mandatory=$false)]
    [string]$ID5,

    [Parameter(Mandatory=$false)]
    [switch]$ResetCredentials
)


function Write-ColorizedXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [xml]$XmlDocument
    )

    $indentUnit = '  '

    function Write-Indent {
        param([int]$Level)
        if ($Level -gt 0) {
            Write-Host ($indentUnit * $Level) -NoNewline
        }
    }

    function Write-XmlNode {
        param(
            [System.Xml.XmlNode]$Node,
            [int]$Level
        )

        switch ($Node.NodeType) {
            ([System.Xml.XmlNodeType]::Element) {
                Write-Indent -Level $Level
                Write-Host '<' -NoNewline -ForegroundColor DarkGray

                if ($Node.Prefix) {
                    Write-Host ($Node.Prefix + ':') -NoNewline -ForegroundColor Magenta
                }

                Write-Host $Node.LocalName -NoNewline -ForegroundColor Cyan

                if ($Node.Attributes) {
                    foreach ($attribute in $Node.Attributes) {
                        Write-Host ' ' -NoNewline
                        if ($attribute.Prefix) {
                            Write-Host ($attribute.Prefix + ':') -NoNewline -ForegroundColor DarkMagenta
                        }
                        Write-Host $attribute.LocalName -NoNewline -ForegroundColor Yellow
                        Write-Host '=' -NoNewline -ForegroundColor DarkGray
                        Write-Host '"' -NoNewline -ForegroundColor DarkGray
                        Write-Host $attribute.Value -NoNewline -ForegroundColor Green
                        Write-Host '"' -NoNewline -ForegroundColor DarkGray
                    }
                }

                if (-not $Node.HasChildNodes) {
                    Write-Host '/>' -ForegroundColor DarkGray
                    break
                }

                $childNodes = @($Node.ChildNodes)
                $hasElementChildren = $false
                foreach ($childNode in $childNodes) {
                    if ($childNode.NodeType -eq [System.Xml.XmlNodeType]::Element) {
                        $hasElementChildren = $true
                        break
                    }
                }

                if ($hasElementChildren) {
                    Write-Host '>' -ForegroundColor DarkGray
                    foreach ($childNode in $childNodes) {
                        Write-XmlNode -Node $childNode -Level ($Level + 1)
                    }
                    Write-Indent -Level $Level
                    Write-Host '</' -NoNewline -ForegroundColor DarkGray
                    if ($Node.Prefix) {
                        Write-Host ($Node.Prefix + ':') -NoNewline -ForegroundColor Magenta
                    }
                    Write-Host $Node.LocalName -NoNewline -ForegroundColor Cyan
                    Write-Host '>' -ForegroundColor DarkGray
                }
                else {
                    Write-Host '>' -NoNewline -ForegroundColor DarkGray
                    foreach ($childNode in $childNodes) {
                        Write-XmlNode -Node $childNode -Level 0
                    }
                    Write-Host '</' -NoNewline -ForegroundColor DarkGray
                    if ($Node.Prefix) {
                        Write-Host ($Node.Prefix + ':') -NoNewline -ForegroundColor Magenta
                    }
                    Write-Host $Node.LocalName -NoNewline -ForegroundColor Cyan
                    Write-Host '>' -ForegroundColor DarkGray
                }
            }
            ([System.Xml.XmlNodeType]::Text) {
                Write-Host $Node.Value -NoNewline -ForegroundColor White
            }
            ([System.Xml.XmlNodeType]::CData) {
                Write-Host '<![CDATA[' -NoNewline -ForegroundColor DarkGray
                Write-Host $Node.Value -NoNewline -ForegroundColor White
                Write-Host ']]>' -NoNewline -ForegroundColor DarkGray
            }
            ([System.Xml.XmlNodeType]::Comment) {
                Write-Indent -Level $Level
                Write-Host '<!--' -NoNewline -ForegroundColor DarkGray
                Write-Host $Node.Value -NoNewline -ForegroundColor DarkGreen
                Write-Host '-->' -ForegroundColor DarkGray
            }
        }
    }

    Write-Host '<?xml version="1.0"?>' -ForegroundColor DarkGray
    foreach ($node in $XmlDocument.ChildNodes) {
        if ($node.NodeType -ne [System.Xml.XmlNodeType]::XmlDeclaration) {
            Write-XmlNode -Node $node -Level 0
        }
    }
}

function Resolve-PatAuskunftUrl {
    param([string]$TargetEnvironment)

    $urlsByEnvironment = @{
        production  = 'https://dg-patauskunft.wienkav.at/service/'
        staging     = 'https://abndg-patauskunft.wienkav.at/service/'
        testing     = 'https://epadg-patauskunft.wienkav.at/service/'
        development = 'https://epadg-patauskunft.wienkav.at/service/'
    }

    if (-not $urlsByEnvironment.ContainsKey($TargetEnvironment)) {
        throw "Unsupported Environment '$TargetEnvironment'."
    }

    return $urlsByEnvironment[$TargetEnvironment]
}

function Resolve-DefaultResultFilter {
    param([string]$TargetResult)

    switch ($TargetResult) {
        'PATIENT_2' { return '5' }
        'PATIENT_2L' { return '6' }
        'PATIENT_3' { return '3' }
        default { return '' }
    }
}

$serviceUrl = Resolve-PatAuskunftUrl -TargetEnvironment $Environment
$credentialsPath = Join-Path -Path $PSScriptRoot -ChildPath "$($Environment).credentials.clixml"

$credential = $null
if (-not $ResetCredentials -and (Test-Path -Path $credentialsPath)) {
    $credential = Import-Clixml -Path $credentialsPath
}

if ($null -eq $credential) {
    $credential = Get-Credential -Message 'Enter PatAuskunft credentials'
    $credential | Export-Clixml -Path $credentialsPath
}

$effectiveId1 = if ($CASENO) { $CASENO } elseif ($AID) { $AID } else { $ID1 }
$effectiveId2 = if ($BID) { $BID } else { $ID2 }
$effectiveId3 = if ($LEISTKST) { $LEISTKST } else { $ID3 }
$effectiveResultFilter = if ($PSBoundParameters.ContainsKey('ResultFilter')) { $ResultFilter } else { Resolve-DefaultResultFilter -TargetResult $Result }

$xmlCallerInfo = "<?xml version='1.0' encoding='ISO-8859-1'?><kavCallerInfo xmlns='http://www.wienkav.at/kav/igv/XMLSchema'><ApplikationID><IDKey>Orchestra</IDKey><IDType>http://www.wienkav.at/kav</IDType></ApplikationID><AnstaltID><IDKey>MA01</IDKey><IDType>KAV Katalog 27</IDType></AnstaltID><KostenstellenID><IDKey>MA01</IDKey><IDType>KAV Katalog 27</IDType></KostenstellenID></kavCallerInfo>"

$soapEnvelope = @"
<soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
  <soap:Body>
    <GetData xmlns="http://www.wienkav.at/kav/kav.datagate/PatAuskunft">
      <XMLCallerInfo><![CDATA[$xmlCallerInfo]]></XMLCallerInfo>
      <Result>$Result</Result>
      <Resultfilter>$effectiveResultFilter</Resultfilter>
      <ID1>$effectiveId1</ID1>
      <ID2>$effectiveId2</ID2>
      <ID3>$effectiveId3</ID3>
      <ID4>$ID4</ID4>
      <ID5>$ID5</ID5>
    </GetData>
  </soap:Body>
</soap:Envelope>
"@

$response = Invoke-WebRequest -Uri $serviceUrl -Method Post -Credential $credential -ContentType 'text/xml; charset=utf-8' -Body $soapEnvelope

[xml]$responseXml = $response.Content
$ns = New-Object System.Xml.XmlNamespaceManager($responseXml.NameTable)
$ns.AddNamespace('soap', 'http://schemas.xmlsoap.org/soap/envelope/')
$ns.AddNamespace('pa', 'http://www.wienkav.at/kav/kav.datagate/PatAuskunft')
$getDataResultNode = $responseXml.SelectSingleNode('//soap:Body/pa:GetDataResponse/pa:GetDataResult', $ns)

if ($null -eq $getDataResultNode -or [string]::IsNullOrWhiteSpace($getDataResultNode.InnerText)) {
    throw 'GetDataResult was not found in the SOAP response.'
}

$decodedXmlText = [System.Net.WebUtility]::HtmlDecode($getDataResultNode.InnerText)
[xml]$innerXml = $decodedXmlText
$settings = New-Object System.Xml.XmlWriterSettings
$settings.Indent = $true
$settings.OmitXmlDeclaration = $false
$settings.NewLineChars = [Environment]::NewLine
$settings.NewLineHandling = [System.Xml.NewLineHandling]::Replace

$stringBuilder = New-Object System.Text.StringBuilder
$writer = [System.Xml.XmlWriter]::Create($stringBuilder, $settings)
$innerXml.WriteTo($writer)
$writer.Flush()
$writer.Dispose()

Write-Host ("Environment: $($Environment)") -ForegroundColor Cyan
Write-Host ("ServiceUrl: $($serviceUrl)") -ForegroundColor DarkCyan
Write-Host ''
Write-ColorizedXml -XmlDocument $innerXml
