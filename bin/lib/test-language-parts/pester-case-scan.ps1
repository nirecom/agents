# bin/lib/test-language-parts/pester-case-scan.ps1 — the pester case enumeration, dot-sourced by
# pester-case-reader.ps1 and pester-case-analyzer.ps1 so both see one case order.
# A case is a top-level Describe '<name>' -Tag 'target:<path>' (begin = the Describe line,
# end = its closing brace line). A case owns its begin and end lines: another top-level
# statement on either line reads grammar, so cutting the case never cuts that statement.
# Defines functions only; runs nothing on load.

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

# The "Case target path rule" section of docs/architecture/claude-code/test-language-registry.md owns this rule.
function Test-Target {
    param([string]$Target)
    if ($Target -cnotmatch '^[A-Za-z0-9._/-]+$' -or $Target.StartsWith('/')) { return $false }
    $part = $Target.Split('/')
    $part[0] -ne '.' -and $part -notcontains '..'
}

# The top-level Describe commands of a parsed file, in file order: the case units.
function Get-TopDescribe {
    param([System.Management.Automation.Language.ScriptBlockAst]$Ast)
    foreach ($statement in @($Ast.EndBlock.Statements)) {
        if ($statement -is [System.Management.Automation.Language.PipelineAst] -and $statement.PipelineElements.Count -eq 1 -and
            $statement.PipelineElements[0] -is [System.Management.Automation.Language.CommandAst] -and
            $statement.PipelineElements[0].GetCommandName() -eq 'Describe') { $statement.PipelineElements[0] }
    }
}

# True when a top-level statement other than the Describe's own touches its line span.
function Test-SharedLine {
    param([System.Management.Automation.Language.ScriptBlockAst]$Ast, [System.Management.Automation.Language.CommandAst]$Command)
    $own = $Command.Parent
    $begin = $Command.Extent.StartLineNumber; $end = $Command.Extent.EndLineNumber
    $other = @($Ast.UsingStatements) + @($Ast.ParamBlock)
    foreach ($block in $Ast.DynamicParamBlock, $Ast.BeginBlock, $Ast.ProcessBlock, $Ast.EndBlock) {
        if ($null -ne $block) { $other += @($block.Statements) }
    }
    foreach ($node in $other) {
        if ($null -eq $node -or [object]::ReferenceEquals($node, $own)) { continue }
        if ($node.Extent.StartLineNumber -le $end -and $node.Extent.EndLineNumber -ge $begin) { return $true }
    }
    $false
}

# Every (line, reason) fault and every well-formed case of a parsed file:
# Fault = @(line, reason) items; Case = @{ Name; Target; Begin; End; Command } items, in file order.
function Get-CaseScan {
    param([System.Management.Automation.Language.ScriptBlockAst]$Ast)
    $isBlock = { param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in 'Describe', 'Context' }
    $top = @(Get-TopDescribe -Ast $Ast)
    $fault = [System.Collections.Generic.List[object]]::new()
    foreach ($command in $Ast.FindAll($isBlock, $true)) {
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
        # A TAB, CR or LF would split the record line, so it reads grammar ahead of the target rule.
        elseif ("$($d.Name)$($d.Target[0])" -match "[`t`r`n]") { $fault.Add(@($d.Begin, 'grammar')) }
        elseif (-not (Test-Target -Target $d.Target[0])) { $fault.Add(@($d.Begin, 'target')) }
        elseif (Test-SharedLine -Ast $Ast -Command $command) { $fault.Add(@($d.Begin, 'grammar')) }
        else { $case.Add([pscustomobject]@{ Name = $d.Name; Target = $d.Target[0]; Begin = $d.Begin; End = $d.End; Command = $command }) }
    }
    if ($unmarked.Count -lt $top.Count) { foreach ($line in $unmarked) { $fault.Add(@($line, 'missing-target')) } }
    [pscustomobject]@{ Fault = $fault.ToArray(); Case = $case.ToArray() }
}
