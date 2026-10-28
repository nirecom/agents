# Tests: bin/lib/test-language-parts/pester-case-analyzer.ps1
# Tags: TL2, bin, case-markers, test-language-registry, sweep-tests, pester, scope:issue-specific, pwsh-required
# The Pester analyzer answers each caseEmbedRules op as TSV for one test file, called as
# `<op> <file> [args]`: deps (ORDER lines matching the test case reader's ranges, then
# idx<TAB>csv), leftover-defs (line<TAB>name), self-impl <file> <helper> (line<TAB>kind<TAB>
# detail), skip-reason (one word or nothing), syntax-check (no stdout; rc 0 / 1) and the
# internal `all <file> <helper>` (OP<TAB><name> blocks equal to the single ops). It parses
# with the PowerShell AST and never runs the file.

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
    . (Join-Path $PSScriptRoot '..' 'lib' 'pester-process-helpers.ps1')
    $parts = Join-Path $PSScriptRoot '..' '..' 'bin' 'lib' 'test-language-parts'
    $script:Analyzer = Join-Path $parts 'pester-case-analyzer.ps1'
    $script:Reader = Join-Path $parts 'pester-case-reader.ps1'
    $script:Helper = Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1'
    $script:Tab = [string][char]9

    function New-Sample {
        param([string]$Name, [string[]]$Line)
        $path = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [System.IO.File]::WriteAllText($path, (($Line -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
        $path
    }

    # Every helper takes -Label, the case's name, and puts it in each failure message.
    function Invoke-Analyzer {
        param([string]$Label, [string[]]$Argument, [string]$Script = $script:Analyzer)
        Test-Path -LiteralPath $script:Analyzer | Should -BeTrue -Because "[$Label] the analyzer exists"
        $child = Invoke-PwshChild -File $Script -ArgumentList $Argument -TimeoutSec 90
        [pscustomobject]@{
            ExitCode = $child.ExitCode
            StdOut   = [string]$child.StdOut
            StdErr   = [string]$child.StdErr
            Row      = @(([string]$child.StdOut) -split "`r?`n" | Where-Object { $_ -ne '' })
        }
    }

    function Get-OpRow {
        param([string]$Label, [string]$Op, [string]$Path, [string[]]$Extra = @())
        $r = Invoke-Analyzer -Label $Label -Argument (@($Op, $Path) + $Extra)
        $r.ExitCode | Should -Be 0 -Because "[$Label] $Op exits 0; stderr: $($r.StdErr)"
        , $r.Row
    }

    # Three cases: case 0 uses Get-Alpha; case 1 uses Get-Alpha, Get-Beta (BeforeAll) and
    # $Shared; case 2 uses none; Get-Unused (line 8) is used by no case.
    $script:SampleLine = @(
        'BeforeAll {'
        "    . (Join-Path `$PSScriptRoot '..' 'lib' 'harness.ps1')"
        '    function Get-Beta { return 2 }'
        '}'
        ''
        'function Get-Alpha { return 1 }'
        ''
        'function Get-Unused { return 3 }'
        ''
        '$Shared = 3'
        ''
        "Describe 'alpha' -Tag 'target:bin/a.sh' {"
        "    It 'uses alpha' {"
        '        Get-Alpha | Should -Be 1'
        '    }'
        '}'
        ''
        "Describe 'beta' -Tag 'target:bin/b.sh' {"
        "    It 'uses alpha and beta' {"
        '        (Get-Alpha) + (Get-Beta) | Should -Be $Shared'
        '    }'
        '}'
        ''
        "Describe 'plain' -Tag 'target:bin/c.sh' {"
        "    It 'uses nothing' {"
        '        1 | Should -Be 1'
        '    }'
        '}'
    )

    # self-impl: counter-init on 4 ($script:PASS) and 5 ($Failed); harness-redef on 6.
    $script:SelfLine = @(
        'BeforeAll {'
        "    . (Join-Path `$PSScriptRoot '..' 'lib' 'harness.ps1')"
        '}'
        '$script:PASS = 0'
        '$Failed = 0'
        'function Enter-HarnessIsolation { return 1 }'
        "Describe 'x' -Tag 'target:bin/a.sh' {"
        "    It 'y' { 1 | Should -Be 1 }"
        '}'
    )

    # Look-alikes: a renamed counter and helper (the accepted limit), a counter inside It.
    $script:CleanLine = @(
        'BeforeAll {'
        "    . (Join-Path `$PSScriptRoot '..' 'lib' 'harness.ps1')"
        '}'
        '$count = 0'
        'function Enter-MyIsolation { return 1 }'
        "Describe 'x' -Tag 'target:bin/a.sh' {"
        "    It 'y' {"
        '        $Passed = 0'
        '        $Passed | Should -Be 0'
        '    }'
        '}'
    )
}

Describe 'pester-case-analyzer' -Tag 'target:bin/lib/test-language-parts/pester-case-analyzer.ps1' {
    It 'deps: ORDER lines match the test case reader''s ranges and come first' {
        $path = New-Sample -Name 'order/sample.Tests.ps1' -Line $script:SampleLine
        $row = Get-OpRow -Label 'deps order' -Op 'deps' -Path $path
        $reader = Invoke-Analyzer -Label 'deps order' -Script $script:Reader -Argument @($path)
        $i = 0
        $ranges = @($reader.Row | Where-Object { $_ -match "^CASE$script:Tab" } | ForEach-Object { $f = $_.Split($script:Tab); "$i|$($f[3])|$($f[4])"; $i++ })
        ($ranges -join ' ') | Should -BeExactly '0|12|16 1|18|22 2|24|28' -Because '[deps order] the reader ranges'
        $order = @($row | Where-Object { $_ -match "^ORDER$script:Tab" } | ForEach-Object { $_.Substring(6).Replace($script:Tab, '|') })
        ($order -join ' ') | Should -BeExactly ($ranges -join ' ') -Because '[deps order] ORDER lines equal the reader ranges'
        $last = [array]::FindLastIndex([string[]]$row, [Predicate[string]] { param($x) $x -match "^ORDER$script:Tab" })
        $first = [array]::FindIndex([string[]]$row, [Predicate[string]] { param($x) $x -notmatch "^ORDER$script:Tab" })
        ($first -lt 0 -or $last -lt $first) | Should -BeTrue -Because '[deps order] ORDER lines come first'
    }

    It 'deps: each case names the definitions it uses' {
        $row = Get-OpRow -Label 'deps names' -Op 'deps' -Path (New-Sample -Name 'deps/sample.Tests.ps1' -Line $script:SampleLine)
        $deps = @{}
        foreach ($r in ($row | Where-Object { $_ -notmatch "^ORDER$script:Tab" })) {
            $f = $r.Split($script:Tab)
            $deps[$f[0]] = @(if ($f.Count -gt 1) { $f[1].Split(',') | Where-Object { $_ } | ForEach-Object { $_.TrimStart('$') } })
        }
        (@($deps.Keys) | Sort-Object) -join ' ' | Should -BeExactly '0 1 2' -Because '[deps names] one idx row per case'
        $deps['0'] | Should -Contain 'Get-Alpha' -Because '[deps names] case 0 uses Get-Alpha'
        foreach ($x in 'Get-Beta', 'Shared', 'Get-Unused') { $deps['0'] | Should -Not -Contain $x -Because "[deps names] case 0 lacks $x" }
        foreach ($x in 'Get-Alpha', 'Get-Beta', 'Shared') { $deps['1'] | Should -Contain $x -Because "[deps names] case 1 has $x" }
        $deps['1'] | Should -Not -Contain 'Get-Unused' -Because '[deps names] case 1 lacks Get-Unused'
        @($deps['2']).Count | Should -Be 0 -Because '[deps names] case 2 depends on nothing'
    }

    It 'leftover-defs: names the top-level function no case uses' {
        $row = Get-OpRow -Label 'leftover-defs' -Op 'leftover-defs' -Path (New-Sample -Name 'left/sample.Tests.ps1' -Line $script:SampleLine)
        ($row -join '/') | Should -BeExactly "8${script:Tab}Get-Unused" -Because '[leftover-defs] the one unused definition'
    }

    It 'self-impl: reports counters and redefinitions of the helper library''s functions' {
        $row = Get-OpRow -Label 'self-impl' -Op 'self-impl' -Path (New-Sample -Name 'self/self.Tests.ps1' -Line $script:SelfLine) -Extra @($script:Helper)
        $pair = @($row | ForEach-Object { $f = $_.Split($script:Tab); "$($f[0]):$($f[1])" })
        ($pair -join ' ') | Should -BeExactly '4:counter-init 5:counter-init 6:harness-redef' -Because '[self-impl] the detections'
        $detail = @($row | ForEach-Object { $_.Split($script:Tab)[2] })
        $detail[0] | Should -Match 'PASS' -Because '[self-impl] the counter on line 4'
        $detail[1] | Should -Match 'Failed' -Because '[self-impl] the counter on line 5'
        $detail[2] | Should -BeExactly 'Enter-HarnessIsolation' -Because '[self-impl] the redefined helper'
    }

    It 'self-impl: does not report renamed look-alikes or a counter inside It' {
        $row = Get-OpRow -Label 'self-impl clean' -Op 'self-impl' -Path (New-Sample -Name 'self/clean.Tests.ps1' -Line $script:CleanLine) -Extra @($script:Helper)
        $row.Count | Should -Be 0 -Because "[self-impl clean] no detection; got $($row -join ' / ')"
    }

    It 'skip-reason: <Label>' -ForEach @(
        @{ Label = 'a nested Describe is nested-describe'; Want = 'nested-describe'; Line = @("Describe 'outer' -Tag 'target:bin/a.sh' {", "    Describe 'inner' {", "        It 'y' { 1 | Should -Be 1 }", '    }', '}') }
        @{ Label = 'flat Describes give nothing'; Want = ''; Line = $null }
    ) {
        $line = if ($null -eq $Line) { $script:SampleLine } else { $Line }
        $row = Get-OpRow -Label "skip-reason: $Label" -Op 'skip-reason' -Path (New-Sample -Name 'skip/s.Tests.ps1' -Line $line)
        ($row -join '/') | Should -BeExactly $Want -Because "[skip-reason: $Label] the word"
    }

    It 'syntax-check: <Label>' -ForEach @(
        @{ Label = 'a valid file passes'; Code = 0; Line = $null }
        @{ Label = 'an unclosed block fails'; Code = 1; Line = @("Describe 'x' {", "    It 'y' { 1 | Should -Be 1") }
        @{ Label = 'an unterminated string fails'; Code = 1; Line = @("Describe 'x -Tag 'target:bin/a.sh' {", '}') }
    ) {
        $line = if ($null -eq $Line) { $script:SampleLine } else { $Line }
        $r = Invoke-Analyzer -Label "syntax-check: $Label" -Argument @('syntax-check', (New-Sample -Name 'syn/s.Tests.ps1' -Line $line))
        $r.ExitCode | Should -Be $Code -Because "[syntax-check: $Label] exit code; stderr: $($r.StdErr)"
        $r.StdOut.Trim() | Should -BeExactly '' -Because "[syntax-check: $Label] no stdout"
        ($r.StdErr.Trim() -ne '') | Should -Be ($Code -eq 1) -Because "[syntax-check: $Label] stderr carries the reason only on failure"
    }

    It 'all: one launch answers every cached op with the single-op rows' {
        $path = New-Sample -Name 'all/sample.Tests.ps1' -Line ($script:SampleLine + @('function Enter-HarnessIsolation { return 1 }'))
        $all = Get-OpRow -Label 'all' -Op 'all' -Path $path -Extra @($script:Helper)
        $block = @{}
        $name = $null
        foreach ($r in $all) {
            if ($r -match "^OP$script:Tab(.+)$") { $name = $Matches[1]; $block[$name] = [System.Collections.Generic.List[string]]::new() }
            elseif ($null -ne $name) { $block[$name].Add($r) }
        }
        foreach ($op in 'deps', 'self-impl', 'leftover-defs', 'skip-reason') {
            $block.ContainsKey($op) | Should -BeTrue -Because "[all] an OP block for $op"
            $extra = if ($op -eq 'self-impl') { @($script:Helper) } else { @() }
            $single = Get-OpRow -Label "all $op" -Op $op -Path $path -Extra $extra
            (@($block[$op]) -join "`n") | Should -BeExactly ($single -join "`n") -Because "[all] the $op block equals the single op"
        }
    }

    # case-count (#2502 S4-4b): the top-level Describe blocks are the units; nested Describe /
    # Context and It are not, and the -Tag markers do not change the count.
    It 'case-count: <Label>' -ForEach @(
        @{ Label = 'three top-level Describe blocks'; Code = 0; Want = '3'; Line = $null }
        @{ Label = 'nested Describe, Context and It are not units'; Code = 0; Want = '2'; Line = @(
                "Describe 'outer' {", "    Describe 'inner' {", "        It 'a' { 1 | Should -Be 1 }", '    }',
                "    Context 'ctx' {", "        It 'b' { 1 | Should -Be 1 }", '    }', '}',
                "Describe 'second' {", "    It 'c' { 1 | Should -Be 1 }", '}') }
        @{ Label = 'unmarked Describe blocks count the same'; Code = 0; Want = '2'; Line = @(
                "Describe 'a' {", "    It 'x' { 1 | Should -Be 1 }", '}', "Describe 'b' {", "    It 'y' { 1 | Should -Be 1 }", '}') }
        @{ Label = 'a parse error fails'; Code = 1; Want = ''; Line = @("Describe 'x' {", "    It 'y' { 1 | Should -Be 1") }
    ) {
        $line = if ($null -eq $Line) { $script:SampleLine } else { $Line }
        $r = Invoke-Analyzer -Label "case-count: $Label" -Argument @('case-count', (New-Sample -Name 'count/c.Tests.ps1' -Line $line))
        $r.ExitCode | Should -Be $Code -Because "[case-count: $Label] exit code; stderr: $($r.StdErr)"
        $r.StdOut.Trim() | Should -BeExactly $Want -Because "[case-count: $Label] the count"
    }

    It 'never runs the file under analysis' {
        $sentinel = Join-Path $TestDrive 'executed.flag'
        $path = New-Sample -Name 'side/side.Tests.ps1' -Line (@("Set-Content -LiteralPath '$sentinel' -Value 'ran'") + $script:SampleLine)
        foreach ($op in 'deps', 'leftover-defs', 'skip-reason', 'syntax-check') { $null = Get-OpRow -Label "never runs $op" -Op $op -Path $path }
        $null = Get-OpRow -Label 'never runs self-impl' -Op 'self-impl' -Path $path -Extra @($script:Helper)
        $sentinel | Should -Not -Exist -Because '[never runs] the sentinel must not be written'
    }
}
