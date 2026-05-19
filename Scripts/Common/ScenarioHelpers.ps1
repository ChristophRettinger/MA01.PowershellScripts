# Scripts/Common/ScenarioHelpers.ps1
# Shared helpers for scripts that work with Orchestra scenario folders.

function Get-ScenarioInfo {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    $directoryPath = Split-Path -Path $FilePath -Parent
    $rootPathNormalized = [System.IO.Path]::GetFullPath($RootPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $directoryPathNormalized = [System.IO.Path]::GetFullPath($directoryPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $relativePath = ''

    if ($directoryPathNormalized.Length -ge $rootPathNormalized.Length -and $directoryPathNormalized.StartsWith($rootPathNormalized, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relativePath = $directoryPathNormalized.Substring($rootPathNormalized.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    }

    if ($relativePath) {
        $relativePathSegments = @([regex]::Split($relativePath, '[\\/]+') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $scenarioName = if ($relativePathSegments.Count -gt 0) { [string]$relativePathSegments[0] } else { '' }
        $scenarioPath = Join-Path -Path $RootPath -ChildPath $scenarioName
    } else {
        $scenarioName = Split-Path -Path $directoryPath -Leaf
        $scenarioPath = $directoryPath
    }

    return [PSCustomObject]@{
        Name = $scenarioName
        Path = $scenarioPath
    }
}
