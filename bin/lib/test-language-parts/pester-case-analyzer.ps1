# bin/lib/test-language-parts/pester-case-analyzer.ps1 <op> <file> [args] — the pester entry's
# caseEmbedRules analyzer child. Parses the file with the PowerShell parser (never runs it) and prints:
#   deps           ORDER<TAB><idx><TAB><begin><TAB><end> per case, then <idx><TAB><csv> per case
#   leftover-defs  <line><TAB><name> per top-level function no command names
#   self-impl <file> <helper>  <line><TAB><kind><TAB><detail> per counter-init / harness-redef
#   skip-reason    nested-describe when a Describe sits inside another; else nothing
#   syntax-check   nothing; exit 0 when the file parses, 1 with the first parse error otherwise
#   case-count     the number of top-level Describe blocks; exit 1 when there is none
#   all <file> <helper>  OP<TAB><op> blocks for every op but syntax-check (OP<TAB><op><TAB>fail: failed)
# Exit 1: unreadable, a parse error, not conforming (deps) or no unit (case-count); 2: unknown op.
param([string]$Op = '', [string]$Path = '', [string]$Helper = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'pester-case-scan.ps1')

$script:Ops = @('deps', 'self-impl', 'leftover-defs', 'skip-reason', 'case-count')
$script:Lang = 'System.Management.Automation.Language'

function Get-BareName {
    param([string]$Name)
    $Name -replace '^(?i:script|global|local|private|using):', ''
}

# The definitions a case may use: top-level functions and variable assignments, and those at the
# top of a top-level BeforeAll block. Kind is 'function' or 'variable'.
function Get-TopDefinition {
    param([System.Management.Automation.Language.ScriptBlockAst]$Ast)
    $statement = [System.Collections.Generic.List[object]]::new()
    foreach ($s in @($Ast.EndBlock.Statements)) {
        $statement.Add($s)
        if ($s -is "$script:Lang.PipelineAst" -and $s.PipelineElements.Count -eq 1 -and
            $s.PipelineElements[0] -is "$script:Lang.CommandAst" -and $s.PipelineElements[0].GetCommandName() -eq 'BeforeAll') {
            foreach ($e in $s.PipelineElements[0].CommandElements) {
                if ($e -is "$script:Lang.ScriptBlockExpressionAst") { foreach ($t in @($e.ScriptBlock.EndBlock.Statements)) { $statement.Add($t) } }
            }
        }
    }
    foreach ($s in $statement) {
        if ($s -is "$script:Lang.FunctionDefinitionAst") {
            [pscustomobject]@{ Kind = 'function'; Name = $s.Name; Line = $s.Extent.StartLineNumber }
        } elseif ($s -is "$script:Lang.AssignmentStatementAst" -and $s.Left -is "$script:Lang.VariableExpressionAst") {
            [pscustomobject]@{ Kind = 'variable'; Name = Get-BareName -Name $s.Left.VariablePath.UserPath; Line = $s.Extent.StartLineNumber }
        }
    }
}

# The command names and variable names used anywhere under the node.
function Get-Use {
    param([System.Management.Automation.Language.Ast]$Node)
    $command = @{}; $variable = @{}
    foreach ($c in $Node.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $n = $c.GetCommandName()
        if ($n) { $command[$n] = $true }
    }
    foreach ($v in $Node.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $variable[(Get-BareName -Name $v.VariablePath.UserPath)] = $true
    }
    [pscustomobject]@{ Command = $command; Variable = $variable }
}

function Test-Used {
    param([object]$Definition, [object]$Use)
    if ($Definition.Kind -eq 'function') { return $Use.Command.ContainsKey($Definition.Name) }
    $Use.Variable.ContainsKey($Definition.Name)
}

function Get-DepsRow {
    param([System.Management.Automation.Language.ScriptBlockAst]$Ast)
    $scan = Get-CaseScan -Ast $Ast
    if ($scan.Fault.Count -gt 0 -or $scan.Case.Count -eq 0) { throw 'the file is not conforming' }
    $definition = @(Get-TopDefinition -Ast $Ast)
    $i = 0
    foreach ($c in $scan.Case) { "ORDER`t$i`t$($c.Begin)`t$($c.End)"; $i++ }
    $i = 0
    foreach ($c in $scan.Case) {
        $use = Get-Use -Node $c.Command
        $name = [System.Collections.Generic.List[string]]::new()
        foreach ($d in $definition) {
            $shown = if ($d.Kind -eq 'variable') { "`$$($d.Name)" } else { $d.Name }
            if ((Test-Used -Definition $d -Use $use) -and -not $name.Contains($shown)) { $name.Add($shown) }
        }
        "$i`t$($name -join ',')"
        $i++
    }
}

function Get-LeftoverRow {
    param([System.Management.Automation.Language.ScriptBlockAst]$Ast)
    $use = Get-Use -Node $Ast
    foreach ($d in @(Get-TopDefinition -Ast $Ast)) {
        if ($d.Kind -eq 'function' -and -not $use.Command.ContainsKey($d.Name)) { "$($d.Line)`t$($d.Name)" }
    }
}

# The helper library's function names; none when it is missing or does not parse.
function Get-HelperName {
    param([string]$Helper)
    $name = @{}
    if ($Helper -eq '' -or -not (Test-Path -LiteralPath $Helper -PathType Leaf)) { return $name }
    $t = $null; $e = $null
    $h = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $Helper).ProviderPath, [ref]$t, [ref]$e)
    if ($e.Count -gt 0) { return $name }
    foreach ($f in $h.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $name[$f.Name] = $true }
    $name
}

function Test-ZeroAssignment {
    param([System.Management.Automation.Language.AssignmentStatementAst]$Node)
    $r = $Node.Right
    $Node.Operator -eq 'Equals' -and $r -is "$script:Lang.CommandExpressionAst" -and
        $r.Expression -is "$script:Lang.ConstantExpressionAst" -and $r.Expression.Value -is [int] -and $r.Expression.Value -eq 0
}

# counter-init: a `$script:` counter set to 0 anywhere, or a bare one at the top (Get-TopDefinition's
# statements); harness-redef: a top function named like a helper function.
function Get-SelfImplRow {
    param([System.Management.Automation.Language.ScriptBlockAst]$Ast, [string]$Helper)
    $counter = '^(?i:PASS|FAIL|Passed|Failed)$'
    $top = @{}
    foreach ($d in @(Get-TopDefinition -Ast $Ast)) { $top["$($d.Kind):$($d.Line)"] = $d }
    $row = [System.Collections.Generic.List[object]]::new()
    foreach ($a in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        if ($a.Left -isnot "$script:Lang.VariableExpressionAst" -or -not (Test-ZeroAssignment -Node $a)) { continue }
        $bare = Get-BareName -Name $a.Left.VariablePath.UserPath
        $line = $a.Extent.StartLineNumber
        if ($bare -match $counter -and ($a.Left.VariablePath.IsScript -or $top.ContainsKey("variable:$line"))) {
            $row.Add([pscustomobject]@{ Line = $line; Text = "$line`tcounter-init`t$bare=0" })
        }
    }
    $own = Get-HelperName -Helper $Helper
    foreach ($d in $top.Values) {
        if ($d.Kind -eq 'function' -and $own.ContainsKey($d.Name)) {
            $row.Add([pscustomobject]@{ Line = $d.Line; Text = "$($d.Line)`tharness-redef`t$($d.Name)" })
        }
    }
    foreach ($r in @($row | Sort-Object -Property Line)) { $r.Text }
}

# nested-describe: an inner Describe is a case the case reader does not split, so the file
# cannot be embedded case by case.
function Get-SkipReasonRow {
    param([System.Management.Automation.Language.ScriptBlockAst]$Ast)
    $describe = { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Describe' }
    foreach ($d in $Ast.FindAll($describe, $true)) {
        for ($p = $d.Parent; $null -ne $p; $p = $p.Parent) {
            if (& $describe $p) { return 'nested-describe' }
        }
    }
}

function Get-CaseCountRow {
    param([System.Management.Automation.Language.ScriptBlockAst]$Ast)
    $count = @(Get-TopDescribe -Ast $Ast).Count
    if ($count -eq 0) { throw 'no case unit' }
    "$count"
}

function Get-OpRow {
    param([string]$Name, [System.Management.Automation.Language.ScriptBlockAst]$Ast, [string]$Helper = '')
    switch ($Name) {
        'case-count' { Get-CaseCountRow -Ast $Ast }
        'deps' { Get-DepsRow -Ast $Ast }
        'self-impl' { Get-SelfImplRow -Ast $Ast -Helper $Helper }
        'leftover-defs' { Get-LeftoverRow -Ast $Ast }
        'skip-reason' { Get-SkipReasonRow -Ast $Ast }
        default { }
    }
}

function Write-Row {
    param([string[]]$Row)
    if ($Row.Count -gt 0) { [Console]::Out.Write(($Row -join "`n") + "`n") }
}

# syntax-check stays out of `all`: it answers by exit code alone, after the parse below.
if ($Op -notin ($script:Ops + 'all', 'syntax-check')) {
    [Console]::Error.WriteLine("[pester-case-analyzer] unknown op: $Op")
    exit 2
}
if ($Path -eq '' -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    [Console]::Error.WriteLine("pester-case-analyzer: cannot read $Path")
    exit 1
}
$token = $null; $parseError = $null
$full = (Resolve-Path -LiteralPath $Path).ProviderPath
$ast = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$token, [ref]$parseError)
if ($parseError.Count -gt 0) {
    [Console]::Error.WriteLine("pester-case-analyzer: ${Path}:$($parseError[0].Extent.StartLineNumber): $($parseError[0].Message)")
    exit 1
}
if ($Op -ne 'all') {
    try { Write-Row -Row @(Get-OpRow -Name $Op -Ast $ast -Helper $Helper) }
    catch { [Console]::Error.WriteLine("pester-case-analyzer: $Op ${Path}: $($_.Exception.Message)"); exit 1 }
    exit 0
}
$out = [System.Collections.Generic.List[string]]::new()
foreach ($name in $script:Ops) {
    try { $row = @(Get-OpRow -Name $name -Ast $ast -Helper $Helper); $out.Add("OP`t$name"); foreach ($r in $row) { $out.Add($r) } }
    catch { $out.Add("OP`t$name`tfail") }
}
Write-Row -Row $out.ToArray()
exit 0
