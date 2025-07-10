<#
.SYNOPSIS
    Tests TCP connectivity to a list of hosts and ports specified in a CSV file, updating the CSV with connection results and resolved IP addresses.

.DESCRIPTION
    This script reads a CSV file named 'hosts.csv' located in the same directory as the script. The CSV must contain at least a 'Hostname' column and optionally a 'Port' column.
    For each entry, the script attempts to establish a TCP connection to the specified host and port (defaulting to port 80 if not specified).
    The result ("Success" or "Failed") is recorded in a column named after the current computer. The script also resolves and records the IP address of each host.
    If the -All switch is specified, all entries are processed; otherwise, only entries without a "Success" status for this computer are processed.
    The updated results are written back to the CSV file unless -TestOnly is specified.

.PARAMETER All
    If specified, tests all hosts regardless of previous results.

.PARAMETER TestOnly
    Performs the tests without writing any updates back to the CSV file.

.NOTES
    - Requires the CSV file to have a 'Hostname' column.
    - The script must not be run in ConstrainedLanguage mode.
    - The script updates the CSV file in place.
    - Each computer running the script will have its own status column in the CSV.

.EXAMPLE
    .\Test-Connections.ps1
    Tests connectivity for hosts that have not yet succeeded for this computer.

    .\Test-Connections.ps1 -All
    Tests connectivity for all hosts, regardless of previous results.

#>
param(
    [switch]$All,
    [switch]$TestOnly
)

# Prevent running in ConstrainedLanguage mode
if ($ExecutionContext.SessionState.LanguageMode -eq "ConstrainedLanguage")
{
    Write-Host "Cannot execute script in ConstrainedLanguage ($ExecutionContext.SessionState.LanguageMode). Execute with administrative rights." -ForegroundColor Red
    exit
}

# Build path to hosts.csv in the same directory as the script
$csvFilePath = Join-Path -Path (Split-Path -Parent $MyInvocation.MyCommand.Path) -ChildPath "hosts.csv"
$computerName = $env:COMPUTERNAME

# Check if CSV file exists
if (-Not (Test-Path $csvFilePath)) {
    Write-Host "CSV file not found at path: $csvFilePath" -ForegroundColor Red
    exit 1
}

# Import hosts from CSV
$hosts = Import-Csv -Path $csvFilePath -Delimiter ";"
$changesMade = $false

# Ensure CSV has a Hostname column
if (-Not ($hosts | Get-Member -Name Hostname)) {
    Write-Host "CSV file must contain a 'Hostname' column." -ForegroundColor Red
    exit 1
}

foreach ($entry in $hosts) {
    # Only process if -All is specified, or if the column for this machine is missing or empty
    if (-not ($All -or $entry.PSObject.Properties.Name -notcontains $computerName -or $entry.$computerName -ne "Success")) {
        continue
    }

    $hostname = $entry.Hostname
    $port = $entry.Port

    # Skip entry if Hostname is missing
    if (-Not $hostname) {
        continue
    }

    # Default port to 80 if not specified
    if (-Not $port) {
        $port = 80
    }

    # Resolve and update IP address if missing
    if (-not $entry.PSObject.Properties.Name -contains "IPAddress" -or -not $entry.IPAddress) {
        $ipAddress = ""
        try {
            $resolved = [System.Net.Dns]::GetHostAddresses($hostname) | Where-Object { $_.AddressFamily -eq 'InterNetwork' }
            if ($resolved) {
                $ipAddress = $resolved[0].IPAddressToString
            }
        } catch {
            $ipAddress = ""
        }

        if (-not $TestOnly) {
            # Add or update the IPAddress column
            if ($entry.PSObject.Properties.Name -contains "IPAddress") {
                if ($entry.IPAddress -ne $ipAddress) {
                    $entry.IPAddress = $ipAddress
                    $changesMade = $true
                }
            } else {
                $entry | Add-Member -NotePropertyName "IPAddress" -NotePropertyValue $ipAddress
                $changesMade = $true
            }
        }
    }
    
    $status = ""
    try {
        # Attempt TCP connection with 1 second timeout
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $asyncResult = $tcpClient.BeginConnect($hostname, $port, $null, $null)
        if (-not $asyncResult.AsyncWaitHandle.WaitOne(1000, $false)) {
            throw "Connection timed out."
        }
        $tcpClient.EndConnect($asyncResult)
        Write-Host "Connection to $($hostname):$port succeeded." -ForegroundColor Green
        $status = "Success"
        $tcpClient.Close()
    } catch {
        Write-Host "Connection to $($hostname):$port failed." -ForegroundColor Red
        $status = "Failed"
    }

    if (-not $TestOnly) {
        # Add or update the status column for this machine
        if ($entry.PSObject.Properties.Name -contains $computerName) {
            if ($entry.$computerName -ne $status) {
                $entry.$computerName = $status
                $changesMade = $true
            }
        } else {
            $entry | Add-Member -NotePropertyName $computerName -NotePropertyValue $status
            $changesMade = $true
        }
    }
}

# Export or report based on mode
if (-not $TestOnly) {
    if ($changesMade) {
        $hosts | Export-Csv -Path $csvFilePath -NoTypeInformation -Delimiter ";"
        Write-Host "CSV file updated." -ForegroundColor Green
    } else {
        Write-Host "No changes were made to the CSV file." -ForegroundColor Yellow
    }
} else {
    Write-Host "Test completed. CSV file was not updated (-TestOnly)." -ForegroundColor Yellow
}
