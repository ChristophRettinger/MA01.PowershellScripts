<#
.SYNOPSIS
  Read a CSV of IPs, look up host names, and output an enhanced CSV.

.PARAMETER InputCsv
  Path to the source CSV file.

.PARAMETER OutputCsv
  Path to write the new CSV with the HostName column added.

.PARAMETER IpColumn
  Name of the column in the input CSV that contains the IP/address.  
  Defaults to 'BK.SUBFL_source_host'.

.PARAMETER HostNameColumn
  Name of the column to add containing the resolved hostname.  
  Defaults to 'LookupHostname'.

.EXAMPLE
  .\Add-HostNames.ps1 -InputCsv .\data.csv -OutputCsv .\out.csv `
      -IpColumn "ClientIp" -HostNameColumn "ResolvedName"
#>
param(
    [Parameter(Mandatory=$true)]
    [string] $InputCsv,

    [Parameter(Mandatory=$true)]
    [string] $OutputCsv,

    [Parameter(Mandatory=$false)]
    [string] $IpColumn   = 'BK.SUBFL_source_host',

    [Parameter(Mandatory=$false)]
    [string] $HostNameColumn = 'LookupHostname'
)

# Import the CSV
$data = Import-Csv -Path $InputCsv

# Initialize a cache to store alreadyâ€lookedâ€up hostnames
$lookupCache = @{}

# For each row, attempt DNS resolution of the IP, add HostName field
$enhanced = $data | ForEach-Object {
    $ip = $_.$IpColumn

    if ($ip -and $lookupCache.ContainsKey($ip)) {
        # reuse cached result
        $hostName = $lookupCache[$ip]
    }
    else {
        try {
            $dns = Resolve-DnsName -Name $ip -ErrorAction Stop
            # Pick the first PTR answer
            $hostName = ($dns | Where-Object Type -eq 'PTR' | Select-Object -First 1).NameHost
            if (-not $hostName) {
                # Fallback to Aâ€record reverse if PTR not found
                $hostName = ($dns | Where-Object Type -eq 'A' | Select-Object -First 1).Name
            }
        }
        catch {
            # On any error, mark as N/A
            $hostName = 'N/A'
        }

        # cache the lookup result
        if ($ip) { $lookupCache[$ip] = $hostName }
    }

    # Add the new property using the specified HostNameColumn name
    $_ | Add-Member -NotePropertyName $HostNameColumn -NotePropertyValue $hostName -PassThru
}

# Export the enriched table
$enhanced | Export-Csv -Path $OutputCsv -NoTypeInformation

Write-Host "Wrote enhanced CSV with column '$HostNameColumn' to `"$OutputCsv`""