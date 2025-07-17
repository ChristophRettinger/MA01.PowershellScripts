<#
.SYNOPSIS
    Extracts selected properties from a JSON array of chat metadata and writes a simplified JSON output.

.DESCRIPTION
    This script reads a JSON file with chat analysis objects (such as those containing summaries, topics, etc.),
    selects only the properties specified (default: Summary, KeyTopics, WorkflowIdeas),
    and writes the result to a new JSON file.

.PARAMETER InputFile
    Path to the input JSON file.

.PARAMETER OutputFile
    Path where the simplified JSON will be written.

.PARAMETER Properties
    Optional array of property names to keep. If not specified, defaults to Summary, KeyTopics, and WorkflowIdeas.

.EXAMPLE
    .\Extract-ChatProperties.ps1 -InputFile "input.json" -OutputFile "output.json"

.EXAMPLE
    .\Extract-ChatProperties.ps1 -InputFile "input.json" -OutputFile "output.json" -Properties "Summary", "ConfidenceScore"

#>

param (
    [Parameter(Mandatory = $true)]
    [string]$InputFile,

    [Parameter(Mandatory = $true)]
    [string]$OutputFile,

    [string[]]$Properties = @("Summary", "KeyTopics", "WorkflowIdeas")
)

# Check if input file exists
if (-not (Test-Path -Path $InputFile)) {
    Write-Error "Input file '$InputFile' does not exist."
    exit 1
}

try {
    # Read the input JSON content
    $jsonContent = Get-Content -Raw -Path $InputFile | ConvertFrom-Json

    # Ensure the root is an array
    if (-not ($jsonContent -is [System.Collections.IEnumerable])) {
        Write-Error "Input JSON must be an array of objects."
        exit 1
    }

    # Select only the desired properties
    $simplified = $jsonContent | ForEach-Object {
        $obj = @{}
        foreach ($prop in $Properties) {
            if ($_.PSObject.Properties[$prop]) {
                $obj[$prop] = $_.$prop
            }
        }
        [PSCustomObject]$obj
    }

    # Write output as JSON
    $simplified | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputFile -Encoding UTF8

    Write-Host "Simplified JSON written to '$OutputFile'"
}
catch {
    Write-Error "An error occurred: $_"
}
