<#
.SYNOPSIS
    Creates a Markdown overview for one or more Orchestra process model files.

.DESCRIPTION
    Reads an Orchestra ProcessModel XML file and generates a structured overview that
    includes basic process model metadata, process input/output parameters, variables,
    business keys, and a per-element breakdown of assignments and parameters.

    You can pass a single process model file via -ProcessModelPath or a folder via
    -FolderPath. Folder mode scans for ProcessModell_* files (no extension) and
    writes one Markdown file per input model.

    The script prints a colored summary to the console and always writes a Markdown
    report file into an `Output` folder next to this script (or into -OutputFolder
    if specified).

.PARAMETER ProcessModelPath
    Path to a single process model XML file.

.PARAMETER FolderPath
    Path to a folder that contains process model files.

.PARAMETER OutputFolder
    Optional output folder for generated Markdown files. Defaults to an `Output`
    folder next to this script.

.PARAMETER CheckUnusedVariables
    Adds an "Unused Variables" section by checking declared process properties that are
    not referenced in scripts, assignments, expressions, or shape parameter names.

.EXAMPLE
    .\Create-ProcessModelOverview.ps1 -ProcessModelPath .\ProcessModell_25

.EXAMPLE
    .\Create-ProcessModelOverview.ps1 -FolderPath .\ScenarioA -CheckUnusedVariables
#>

[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'File')]
    [string]$ProcessModelPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'Folder')]
    [string]$FolderPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputFolder,

    [Parameter(Mandatory = $false)]
    [switch]$CheckUnusedVariables
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TypeText {
    param(
        [Parameter(Mandatory = $false)]
        [System.Xml.XmlNode]$TypeNode
    )

    if (-not $TypeNode) {
        return ''
    }

    if (-not [string]::IsNullOrWhiteSpace($TypeNode.InnerText)) {
        return $TypeNode.InnerText.Trim()
    }

    return ''
}

function ConvertTo-MarkdownTable {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Headers,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object[]]$Rows
    )

    if (-not $Rows -or $Rows.Count -eq 0) {
        return @()
    }

    $headerLine = '| ' + ($Headers -join ' | ') + ' |'
    $separatorLine = '| ' + (($Headers | ForEach-Object { '---' }) -join ' | ') + ' |'

    $dataLines = foreach ($row in $Rows) {
        $values = foreach ($header in $Headers) {
            $raw = ''
            if ($row -is [hashtable] -and $row.ContainsKey($header)) {
                $raw = [string]$row[$header]
            } elseif ($row.PSObject.Properties[$header]) {
                $raw = [string]$row.$header
            }

            if ([string]::IsNullOrWhiteSpace($raw)) {
                ''
            } else {
                $raw.Replace('|', '\|').Replace("`r", ' ').Replace("`n", '<br/>').Trim()
            }
        }

        '| ' + ($values -join ' | ') + ' |'
    }

    return @($headerLine, $separatorLine) + $dataLines
}

function Get-AssignmentList {
    param(
        [Parameter(Mandatory = $false)]
        [System.Xml.XmlNode]$Parent,

        [Parameter(Mandatory = $true)]
        [string]$AssignmentNodeName
    )

    if (-not $Parent) {
        return @()
    }

    $assignmentContainer = $Parent.SelectSingleNode($AssignmentNodeName)
    if (-not $assignmentContainer) {
        return @()
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($assignment in $assignmentContainer.SelectNodes('Assignment')) {
        $rows.Add([PSCustomObject]@{
            Target = Get-ChildNodeInnerText -ParentNode $assignment -ChildNodeName 'targetPropertyName'
            Expression = Get-ChildNodeInnerText -ParentNode $assignment -ChildNodeName 'sourceExpr/expression'
            Language = Get-ChildNodeInnerText -ParentNode $assignment -ChildNodeName 'sourceExpr/implementingLanguage'
        })
    }

    return $rows
}

function Get-PropertyRows {
    param(
        [Parameter(Mandatory = $false)]
        [System.Xml.XmlNode]$Parent,

        [Parameter(Mandatory = $true)]
        [string]$ContainerName
    )

    if (-not $Parent) {
        return @()
    }

    $container = $Parent.SelectSingleNode($ContainerName)
    if (-not $container) {
        return @()
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($property in $container.SelectNodes('Property')) {
        $rows.Add([PSCustomObject]@{
            Name = Get-ChildNodeInnerText -ParentNode $property -ChildNodeName 'name'
            Type = Get-TypeText -TypeNode ($property.SelectSingleNode('type'))
            Usage = Get-ChildNodeInnerText -ParentNode $property -ChildNodeName 'usagePattern'
            RequiredOnInput = Get-ChildNodeInnerText -ParentNode $property -ChildNodeName 'requiredOnInput'
        })
    }

    return $rows
}

function Get-NodeInnerText {
    param(
        [Parameter(Mandatory = $true)]
        [xml]$XmlDocument,

        [Parameter(Mandatory = $true)]
        [string]$XPath
    )

    $node = $XmlDocument.SelectSingleNode($XPath)
    if (-not $node -or [string]::IsNullOrWhiteSpace($node.InnerText)) {
        return ''
    }

    return [string]$node.InnerText.Trim()
}

function Get-ChildNodeInnerText {
    param(
        [Parameter(Mandatory = $false)]
        [System.Xml.XmlNode]$ParentNode,

        [Parameter(Mandatory = $true)]
        [string]$ChildNodeName
    )

    if (-not $ParentNode) {
        return ''
    }

    $childNode = $ParentNode.SelectSingleNode($ChildNodeName)
    if (-not $childNode -or [string]::IsNullOrWhiteSpace($childNode.InnerText)) {
        return ''
    }

    return [string]$childNode.InnerText.Trim()
}

function Get-ElementTypeName {
    param(
        [Parameter(Mandatory = $true)]
        [System.Xml.XmlNode]$Node
    )

    $rawName = [string]$Node.Name
    if ($rawName -like '*.*') {
        return ($rawName -split '\.')[-1]
    }

    return $rawName
}

function Get-UsedTextFragments {
    param(
        [Parameter(Mandatory = $true)]
        [xml]$XmlDocument
    )

    $fragments = New-Object System.Collections.Generic.List[string]

    foreach ($node in $XmlDocument.SelectNodes('//targetPropertyName|//expression|//script|//imports|//edgeLabel|//displayText')) {
        if (-not [string]::IsNullOrWhiteSpace($node.InnerText)) {
            $fragments.Add($node.InnerText)
        }
    }

    return $fragments
}

function Test-IsVariableUsed {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VariableName,

        [Parameter(Mandatory = $true)]
        [string[]]$TextFragments
    )

    if ([string]::IsNullOrWhiteSpace($VariableName)) {
        return $false
    }

    $escapedName = [regex]::Escape($VariableName)
    $pattern = "(?<![A-Za-z0-9_])$($escapedName)(?![A-Za-z0-9_])"

    foreach ($text in $TextFragments) {
        if ($text -match $pattern) {
            return $true
        }
    }

    return $false
}

function Get-ProcessModelFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResolvedFolderPath
    )

    return @(Get-ChildItem -Path $ResolvedFolderPath -File -Filter 'ProcessModell_*' | Sort-Object -Property FullName -Unique)
}

function New-ProcessModelOverview {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $false)]
        [string]$ReportFolderPath,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeUnusedVariables
    )

    Write-Host "Processing $($FilePath)" -ForegroundColor Cyan

    [xml]$xml = Get-Content -Path $FilePath -Raw
    if ($xml.DocumentElement.LocalName -ne 'ProcessModel') {
        throw "File '$($FilePath)' is not a ProcessModel XML."
    }

    $processName = Get-NodeInnerText -XmlDocument $xml -XPath '/ProcessModel/name'
    if ([string]::IsNullOrWhiteSpace($processName)) {
        $processName = [System.IO.Path]::GetFileName($FilePath)
    }

    $modelId = Get-NodeInnerText -XmlDocument $xml -XPath '/ProcessModel/ID'
    $revisionNumber = Get-NodeInnerText -XmlDocument $xml -XPath '/ProcessModel/revisionNumber'
    $processScenarioId = Get-NodeInnerText -XmlDocument $xml -XPath '/ProcessModel/processSenarioID'

    $processParameters = New-Object System.Collections.Generic.List[object]
    foreach ($property in $xml.SelectNodes('/ProcessModel/properties/Property')) {
        $usage = Get-ChildNodeInnerText -ParentNode $property -ChildNodeName 'usagePattern'
        if ($usage -in @('INPUT', 'OUTPUT', 'IN_OUT')) {
            $processParameters.Add([PSCustomObject]@{
                Name = Get-ChildNodeInnerText -ParentNode $property -ChildNodeName 'name'
                Type = Get-TypeText -TypeNode ($property.SelectSingleNode('type'))
                Usage = $usage
                RequiredOnInput = Get-ChildNodeInnerText -ParentNode $property -ChildNodeName 'requiredOnInput'
            })
        }
    }

    $variables = New-Object System.Collections.Generic.List[object]
    foreach ($property in $xml.SelectNodes('/ProcessModel/properties/Property')) {
        $name = Get-ChildNodeInnerText -ParentNode $property -ChildNodeName 'name'
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $variables.Add([PSCustomObject]@{
            Name = $name
            Type = Get-TypeText -TypeNode ($property.SelectSingleNode('type'))
            Usage = Get-ChildNodeInnerText -ParentNode $property -ChildNodeName 'usagePattern'
        })
    }

    $businessKeys = New-Object System.Collections.Generic.List[object]
    foreach ($key in $xml.SelectNodes('/ProcessModel/businessKeys/Property')) {
        $businessKeys.Add([PSCustomObject]@{
            Name = Get-ChildNodeInnerText -ParentNode $key -ChildNodeName 'name'
            Type = Get-TypeText -TypeNode ($key.SelectSingleNode('type'))
            Usage = Get-ChildNodeInnerText -ParentNode $key -ChildNodeName 'usagePattern'
        })
    }

    $elements = New-Object System.Collections.Generic.List[object]
    foreach ($element in $xml.SelectNodes('/ProcessModel/processObjects/*')) {
        $idNode = $element.SelectSingleNode('id')
        if (-not $idNode) {
            continue
        }

        $elementType = Get-ElementTypeName -Node $element
        $inAssignments = @(Get-AssignmentList -Parent $element -AssignmentNodeName 'inAssignments')
        $outAssignments = @(Get-AssignmentList -Parent $element -AssignmentNodeName 'outAssignments')
        $shapeParameters = @()

        if ($element.SelectSingleNode('parameters')) {
            $shapeParameters = @(Get-PropertyRows -Parent $element -ContainerName 'parameters')
        } elseif ($element.SelectSingleNode('properties')) {
            $shapeParameters = @(Get-PropertyRows -Parent $element -ContainerName 'properties')
        } elseif ($element.SelectSingleNode('trigger/parameters')) {
            $shapeParameters = @(Get-PropertyRows -Parent $element.SelectSingleNode('trigger') -ContainerName 'parameters')
        }

        $elements.Add([PSCustomObject]@{
            ElementId = [string]$idNode.InnerText
            Name = Get-ChildNodeInnerText -ParentNode $element -ChildNodeName 'displayText'
            Type = $elementType
            InAssignments = $inAssignments
            OutAssignments = $outAssignments
            Parameters = $shapeParameters
        })
    }

    $unusedVariables = @()
    if ($IncludeUnusedVariables) {
        $fragments = Get-UsedTextFragments -XmlDocument $xml
        $unusedVariables = @(
            $variables | Where-Object {
                -not (Test-IsVariableUsed -VariableName $_.Name -TextFragments $fragments)
            }
        )
    }

    $baseOutputFolder = $ReportFolderPath
    if ([string]::IsNullOrWhiteSpace($baseOutputFolder)) {
        $baseOutputFolder = Join-Path -Path $PSScriptRoot -ChildPath 'Output'
    }

    if (-not (Test-Path -LiteralPath $baseOutputFolder)) {
        $null = New-Item -Path $baseOutputFolder -ItemType Directory -Force
    }

    $sourceFileName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    if ([string]::IsNullOrWhiteSpace($sourceFileName)) {
        $sourceFileName = [System.IO.Path]::GetFileName($FilePath)
    }

    $outputPath = Join-Path -Path $baseOutputFolder -ChildPath "$($sourceFileName)_Overview.md"

    $md = New-Object System.Collections.Generic.List[string]
    $md.Add("# ProcessModel Overview: $($processName)")
    $md.Add('')
    $md.Add('## Basic Information')
    $md.Add('')
    $md.Add("- Source file: " + [System.IO.Path]::GetFileName($FilePath))
    $md.Add("- Process name: " + $processName)
    $md.Add("- Process model ID: " + $modelId)
    $md.Add("- Scenario ID: " + $processScenarioId)
    $md.Add("- Revision: " + $revisionNumber)
    $md.Add('')
    if ($processParameters.Count -gt 0) {
        $md.Add('### ProcessModel Input/Output Parameters')
        $md.AddRange([string[]](ConvertTo-MarkdownTable -Headers @('Name','Type','Usage','RequiredOnInput') -Rows $processParameters))
        $md.Add('')
    }
    if ($variables.Count -gt 0) {
        $md.Add('## Used Variables')
        $md.Add('')
        $md.AddRange([string[]](ConvertTo-MarkdownTable -Headers @('Name','Type','Usage') -Rows $variables))
        $md.Add('')
    }

    if ($businessKeys.Count -gt 0) {
        $md.Add('## Used BusinessKeys')
        $md.Add('')
        $md.AddRange([string[]](ConvertTo-MarkdownTable -Headers @('Name','Type','Usage') -Rows $businessKeys))
        $md.Add('')
    }

    if ($elements.Count -gt 0) {
        $md.Add('## Used Elements')
        $md.Add('')
    }

    foreach ($element in $elements) {
        $displayName = $element.Name
        if ([string]::IsNullOrWhiteSpace($displayName)) {
            $displayName = '(unnamed element)'
        }

        $md.Add("### $($displayName) [Type: $($element.Type), ElementID: $($element.ElementId)]")

        if ($element.InAssignments.Count -gt 0) {
            $md.Add('')
            $md.Add('#### Input Assignments')
            $md.AddRange([string[]](ConvertTo-MarkdownTable -Headers @('Target','Expression','Language') -Rows $element.InAssignments))
        }

        if ($element.OutAssignments.Count -gt 0) {
            $md.Add('')
            $md.Add('#### Output Assignments')
            $md.AddRange([string[]](ConvertTo-MarkdownTable -Headers @('Target','Expression','Language') -Rows $element.OutAssignments))
        }

        if ($element.Parameters.Count -gt 0) {
            $md.Add('')
            $md.Add('#### Shape Parameters')
            $md.AddRange([string[]](ConvertTo-MarkdownTable -Headers @('Name','Type','Usage','RequiredOnInput') -Rows $element.Parameters))
        }

        $md.Add('')
    }

    if ($IncludeUnusedVariables) {
        if ($unusedVariables.Count -gt 0) {
            $md.Add('## Unused Variables')
            $md.Add('')
            $md.AddRange([string[]](ConvertTo-MarkdownTable -Headers @('Name','Type','Usage') -Rows $unusedVariables))
            $md.Add('')
        }
    }

    Set-Content -Path $outputPath -Value $md -Encoding UTF8

    Write-Host "  Process: $($processName)" -ForegroundColor Green
    Write-Host "  Variables: $($variables.Count), BusinessKeys: $($businessKeys.Count), Elements: $($elements.Count)" -ForegroundColor Yellow
    if ($IncludeUnusedVariables) {
        Write-Host "  Unused Variables: $($unusedVariables.Count)" -ForegroundColor Magenta
    }
    Write-Host "  Overview file: $($outputPath)" -ForegroundColor Cyan

    return [PSCustomObject]@{
        InputFile = $FilePath
        OutputFile = $outputPath
        ProcessName = $processName
        VariableCount = $variables.Count
        BusinessKeyCount = $businessKeys.Count
        ElementCount = $elements.Count
        UnusedVariableCount = if ($IncludeUnusedVariables) { $unusedVariables.Count } else { $null }
    }
}

$inputFiles = @()
if ($PSCmdlet.ParameterSetName -eq 'File') {
    $resolved = (Resolve-Path -Path $ProcessModelPath).Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "ProcessModelPath is not a file: $($resolved)"
    }
    $inputFiles = @($resolved)
} else {
    $resolvedFolder = (Resolve-Path -Path $FolderPath).Path
    if (-not (Test-Path -LiteralPath $resolvedFolder -PathType Container)) {
        throw "FolderPath is not a folder: $($resolvedFolder)"
    }

    $inputFiles = @(Get-ProcessModelFiles -ResolvedFolderPath $resolvedFolder | ForEach-Object { $_.FullName })
    if ($inputFiles.Count -eq 0) {
        Write-Warning "No ProcessModell_* files found in '$($resolvedFolder)'."
        return
    }
}

$resolvedOutputFolder = $null
if ($PSBoundParameters.ContainsKey('OutputFolder') -and -not [string]::IsNullOrWhiteSpace($OutputFolder)) {
    $resolvedOutputFolder = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFolder)
}

$results = @(foreach ($file in $inputFiles) {
    New-ProcessModelOverview -FilePath $file -ReportFolderPath $resolvedOutputFolder -IncludeUnusedVariables:$CheckUnusedVariables
})

Write-Host ''
Write-Host "Finished. Created $($results.Count) overview file(s)." -ForegroundColor Green
