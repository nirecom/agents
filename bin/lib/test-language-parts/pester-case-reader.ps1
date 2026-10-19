# bin/lib/test-language-parts/pester-case-reader.ps1 <file> — the pester entry's case reader child.
# Parses the file with the PowerShell parser (never runs it) and reports each top-level
# Describe '<name>' -Tag 'target:<path>'. Prints
#   FILE<TAB><state><TAB><line><TAB><reason>   and, when conforming, one
#   CASE<TAB><name><TAB><target><TAB><begin><TAB><end><TAB><TAB>   per Describe, in file order
# (begin = the Describe line, end = its closing brace line). Exit 1: unreadable file.
param([Parameter(Mandatory)][string]$Path)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Write-Record {
    param([object[]]$Row)
    [Console]::Out.Write((($Row | ForEach-Object { $_ -join "`t" }) -join "`n") + "`n")
}

# The name and tag arguments of one Describe command; Constant is false when a tag is not a string constant.
function Read-Describe {
    param([System.Management.Automation.Language.CommandAst]$Command)
    $name = $null; $tagItem = @(); $hasName = $false
    $element = $Command.CommandElements
    for ($i = 1; $i -lt $element.Count; $i++) {
        $item = $element[$i]
        if ($item -is [System.Management.Automation.Language.CommandParameterAst]) {
            if ($item.ParameterName -eq 'Skip') { continue }
            $value = $item.Argument
            if ($null -eq $value -and $i + 1 -lt $element.Count) { $i++; $value = $element[$i] }
            if ($item.ParameterName -in 'Tag', 'Tags') {
                if ($value -is [System.Management.Automation.Language.ArrayLiteralAst]) { $tagItem += @($value.Elements) }
                elseif ($null -ne $value) { $tagItem += @($value) }
            }
            elseif ($item.ParameterName -eq 'Name') { $name = $value; $hasName = $true }
        } elseif (-not $hasName) { $name = $item; $hasName = $true }
    }
    $loose = @($tagItem | Where-Object { $_ -isnot [System.Management.Automation.Language.StringConstantExpressionAst] })
    [pscustomobject]@{
        Name     = if ($name -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $name.Value } else { $null }
        Constant = $loose.Count -eq 0
        Target   = @($tagItem | Where-Object { $loose.Count -eq 0 -and $_.Value -clike 'target:*' } | ForEach-Object { $_.Value.Substring(7) })
        Begin    = $Command.Extent.StartLineNumber
        End      = $Command.Extent.EndLineNumber
    }
}

function Test-Target {
    param([string]$Target)
    if ($Target -cnotmatch '^[A-Za-z0-9._/-]+$' -or $Target.StartsWith('/')) { return $false }
    $part = $Target.Split('/')
    $part[0] -ne '.' -and $part -notcontains '..'
}

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    [Console]::Error.WriteLine("pester-case-reader: cannot read $Path")
    exit 1
}
$token = $null; $parseError = $null
$full = (Resolve-Path -LiteralPath $Path).ProviderPath
$ast = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$token, [ref]$parseError)
if ($parseError.Count -gt 0) {
    Write-Record -Row @(, @('FILE', 'malformed', $parseError[0].Extent.StartLineNumber, 'grammar'))
    exit 0
}

$isBlock = { param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in 'Describe', 'Context' }
$topBlock = @(
    foreach ($statement in @($ast.EndBlock.Statements)) {
        if ($statement -is [System.Management.Automation.Language.PipelineAst] -and $statement.PipelineElements.Count -eq 1 -and
            (& $isBlock $statement.PipelineElements[0])) { $statement.PipelineElements[0] }
    }
)
$top = @($topBlock | Where-Object { $_.GetCommandName() -eq 'Describe' })
$fault = [System.Collections.Generic.List[object]]::new()
foreach ($command in $ast.FindAll($isBlock, $true)) {
    if ($top | Where-Object { [object]::ReferenceEquals($_, $command) }) { continue }
    if ((Read-Describe -Command $command).Target.Count -gt 0) { $fault.Add(@($command.Extent.StartLineNumber, 'nested-target')) }
}
$case = [System.Collections.Generic.List[object]]::new()
$unmarked = [System.Collections.Generic.List[int]]::new()
foreach ($command in $top) {
    $d = Read-Describe -Command $command
    if (-not $d.Constant) { $fault.Add(@($d.Begin, 'constant')) }
    elseif ($d.Target.Count -eq 0) { $unmarked.Add($d.Begin) }
    elseif ($d.Target.Count -gt 1) { $fault.Add(@($d.Begin, 'duplicate-target')) }
    elseif ($null -eq $d.Name) { $fault.Add(@($d.Begin, 'constant')) }
    elseif ($d.Name -eq '') { $fault.Add(@($d.Begin, 'grammar')) }
    elseif (-not (Test-Target -Target $d.Target[0])) { $fault.Add(@($d.Begin, 'target')) }
    else { $case.Add(@($d.Name, $d.Target[0], $d.Begin, $d.End)) }
}
if ($unmarked.Count -lt $top.Count) { foreach ($line in $unmarked) { $fault.Add(@($line, 'missing-target')) } }

if ($fault.Count -gt 0) {
    $first = $fault | Sort-Object -Property { $_[0] } | Select-Object -First 1
    Write-Record -Row @(, @('FILE', 'malformed', $first[0], $first[1]))
    exit 0
}
$row = [System.Collections.Generic.List[object]]::new()
$row.Add(@('FILE', $(if ($case.Count -gt 0) { 'conforming' } else { 'none' }), '', ''))
foreach ($c in $case) { $row.Add(@('CASE') + $c + @('', '')) }
Write-Record -Row $row.ToArray()
