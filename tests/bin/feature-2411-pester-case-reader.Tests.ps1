# Tests: bin/lib/test-language-parts/pester-case-reader.ps1
# Tags: TL2, bin, case-markers, test-language-registry, pester, scope:issue-specific, pwsh-required
# The Pester case reader parses a test file with the PowerShell AST and reports each top-level
# Describe tagged 'target:<path>' as TSV (one FILE line, one CASE line per case). It never runs the file.

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
    . (Join-Path $PSScriptRoot '..' 'lib' 'pester-process-helpers.ps1')
    $script:Reader = Join-Path $PSScriptRoot '..' '..' 'bin' 'lib' 'test-language-parts' 'pester-case-reader.ps1'
    $script:Tab = [string][char]9

    function New-Sample {
        param([string]$Name, [string[]]$Line = @(), [string]$Eol = "`n", [switch]$Bom)
        $path = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        $text = if ($Line.Count -eq 0) { '' } else { ($Line -join $Eol) + $Eol }
        [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new([bool]$Bom))
        $path
    }

    # Every helper takes -Label, the name of the case, and puts it in each failure message.
    function Read-Case {
        param([string]$Label, [string]$Path)
        $child = Invoke-PwshChild -File $script:Reader -ArgumentList @($Path) -TimeoutSec 90
        $rows = @($child.StdOut -split "`n" | Where-Object { $_ -ne '' })
        $stray = @($rows | Where-Object { $_ -notmatch "^(FILE|CASE)$script:Tab" })
        $stray.Count | Should -Be 0 -Because "[$Label] stdout holds only FILE and CASE lines; stderr: $($child.StdErr)"
        [pscustomobject]@{
            ExitCode = $child.ExitCode
            File     = @($rows | Where-Object { $_ -match "^FILE$script:Tab" })
            Case     = @($rows | Where-Object { $_ -match "^CASE$script:Tab" })
        }
    }

    function Assert-Record {
        param([string]$Label, [string]$Path, [string]$State, [string[]]$Case = @())
        $r = Read-Case -Label $Label -Path $Path
        $r.ExitCode | Should -Be 0 -Because "[$Label] the reader exits 0"
        ($r.File -join "`n") | Should -BeExactly (@('FILE', $State, '', '') -join $script:Tab) -Because "[$Label] the FILE line"
        ($r.Case -join "`n") | Should -BeExactly (($Case | ForEach-Object { $_.Replace('|', $script:Tab) }) -join "`n") -Because "[$Label] the CASE lines"
    }

    function Assert-Malformed {
        param([string]$Label, [string]$Path, [string]$Reason, [int]$Line = 0)
        $r = Read-Case -Label $Label -Path $Path
        $r.ExitCode | Should -Be 0 -Because "[$Label] the reader exits 0"
        $r.File.Count | Should -Be 1 -Because "[$Label] exactly one FILE line"
        $field = $r.File[0].Split($script:Tab)
        $field.Count | Should -Be 4 -Because "[$Label] the FILE line has four fields"
        "$($field[1])|$($field[3])" | Should -BeExactly "malformed|$Reason" -Because "[$Label] state and reason"
        if ($Line -gt 0) {
            $field[2] | Should -BeExactly "$Line" -Because "[$Label] the line number"
        } else {
            $field[2] | Should -Match '^[1-9][0-9]*$' -Because "[$Label] the line number"
        }
        $r.Case.Count | Should -Be 0 -Because "[$Label] no CASE line"
    }

    $script:TwoCases = @(
        'BeforeAll {'
        "    . (Join-Path `$PSScriptRoot '..' 'lib' 'harness.ps1')"
        '}'
        ''
        "Describe 'alpha' -Tag 'target:bin/a.sh' {"
        "    It 'one' { 1 | Should -Be 1 }"
        '}'
        ''
        "Describe 'beta' -Tag 'target:bin/lib/b.ps1', 'slow' {"
        "    It 'two' {"
        '        2 | Should -Be 2'
        '    }'
        '}'
    )
    $script:TwoCasesRows = @('CASE|alpha|bin/a.sh|5|7||', 'CASE|beta|bin/lib/b.ps1|9|13||')
}

Describe 'pester-case-reader' -Tag 'target:bin/lib/test-language-parts/pester-case-reader.ps1' {
    It 'none: <Label>' -ForEach @(
        @{ Label = 'empty file'; Line = @() }
        @{ Label = 'Describe without a tag'; Line = @("Describe 'alpha' {", "    It 'one' { }", '}') }
        @{ Label = 'Describe with other tags only'; Line = @("Describe 'alpha' -Tag 'slow', 'targeted' {", '}') }
    ) {
        Assert-Record -Label "none: $Label" -Path (New-Sample -Name 'none.Tests.ps1' -Line $Line) -State 'none'
    }

    It 'conforming: two cases, each from its Describe line to its closing brace, deps column empty' {
        Assert-Record -Label 'conforming: two cases' -Path (New-Sample -Name 'two.Tests.ps1' -Line $script:TwoCases) -State 'conforming' -Case $script:TwoCasesRows
    }

    It 'conforming: <Label> gives the same records as the plain file' -ForEach @(
        @{ Label = 'CRLF line endings'; Name = 'crlf.Tests.ps1'; Eol = "`r`n"; Bom = $false }
        @{ Label = 'a UTF-8 BOM'; Name = 'bom.Tests.ps1'; Eol = "`n"; Bom = $true }
        @{ Label = 'a BOM with CRLF'; Name = 'bom-crlf.Tests.ps1'; Eol = "`r`n"; Bom = $true }
        @{ Label = 'a file path holding a space'; Name = 'dir with space/two cases.Tests.ps1'; Eol = "`n"; Bom = $false }
    ) {
        $path = New-Sample -Name $Name -Line $script:TwoCases -Eol $Eol -Bom:$Bom
        Assert-Record -Label "conforming: $Label" -Path $path -State 'conforming' -Case $script:TwoCasesRows
    }

    It 'conforming: double-quoted strings without expansion are constants' {
        $path = New-Sample -Name 'dq.Tests.ps1' -Line @('Describe "alpha" -Tag "target:bin/a.sh" {', '}')
        Assert-Record -Label 'conforming: double-quoted strings' -Path $path -State 'conforming' -Case @('CASE|alpha|bin/a.sh|1|2||')
    }

    It 'constant: <Label>' -ForEach @(
        @{ Label = 'name is a variable'; Head = 'Describe $name -Tag ''target:bin/a.sh'' {' }
        @{ Label = 'tag is a variable'; Head = 'Describe ''alpha'' -Tag $tags {' }
        @{ Label = 'tag is an expanding string'; Head = 'Describe ''alpha'' -Tag "target:$leaf" {' }
        @{ Label = 'tag is an expression'; Head = 'Describe ''alpha'' -Tag (''target:'' + $leaf) {' }
        @{ Label = 'name is an expanding string'; Head = 'Describe "alpha $n" -Tag ''target:bin/a.sh'' {' }
    ) {
        Assert-Malformed -Label "constant: $Label" -Path (New-Sample -Name 'constant.Tests.ps1' -Line @('$leaf = 1', $Head, '}')) -Reason 'constant' -Line 2
    }

    It 'target: invalid path (<Label>)' -ForEach @(
        @{ Label = 'empty'; Target = '' }
        @{ Label = 'absolute'; Target = '/abs/a.sh' }
        @{ Label = 'drive letter'; Target = 'C:/abs/a.sh' }
        @{ Label = 'backslash'; Target = 'bin\a.sh' }
        @{ Label = 'leading dot-dot'; Target = '../a.sh' }
        @{ Label = 'inner dot-dot'; Target = 'bin/../a.sh' }
        @{ Label = 'trailing dot-dot'; Target = 'bin/..' }
        @{ Label = 'semicolon'; Target = 'bin/a.sh;id' }
        @{ Label = 'dollar'; Target = 'bin/$HOME.sh' }
        @{ Label = 'backtick'; Target = 'bin/`id`.sh' }
        @{ Label = 'pipe'; Target = 'bin/a|b.sh' }
        @{ Label = 'ampersand'; Target = 'bin/a&b.sh' }
        @{ Label = 'redirect'; Target = 'bin/a>b.sh' }
        @{ Label = 'parenthesis'; Target = 'bin/a(b).sh' }
        @{ Label = 'space'; Target = 'bin/a b.sh' }
    ) {
        $path = New-Sample -Name 'target.Tests.ps1' -Line @("Describe 'alpha' -Tag 'target:$Target' {", '}')
        Assert-Malformed -Label "target: $Label" -Path $path -Reason 'target' -Line 1
    }

    It 'missing-target: a tagged Describe beside <Label>' -ForEach @(
        @{ Label = 'an untagged one'; Head = "Describe 'beta' {" }
        @{ Label = 'one with other tags only'; Head = "Describe 'beta' -Tag 'slow' {" }
    ) {
        $path = New-Sample -Name 'missing.Tests.ps1' -Line @("Describe 'alpha' -Tag 'target:bin/a.sh' {", '}', $Head, '}')
        Assert-Malformed -Label "missing-target: $Label" -Path $path -Reason 'missing-target' -Line 3
    }

    It 'duplicate-target: two target tags on one Describe' {
        $path = New-Sample -Name 'duplicate.Tests.ps1' -Line @("Describe 'alpha' -Tag 'target:bin/a.sh', 'target:bin/b.sh' {", '}')
        Assert-Malformed -Label 'duplicate-target' -Path $path -Reason 'duplicate-target' -Line 1
    }

    # The parser accepts a repeated tag parameter; only running the file would reject it.
    It 'duplicate-target: one target in each of two tag parameters (<Label>)' -ForEach @(
        @{ Label = '-Tag twice'; Head = "Describe 'alpha' -Tag 'target:bin/a.sh' -Tag 'target:bin/b.sh' {" }
        @{ Label = '-Tag then -Tags'; Head = "Describe 'alpha' -Tag 'target:bin/a.sh' -Tags 'target:bin/b.sh' {" }
    ) {
        $path = New-Sample -Name 'duplicate-param.Tests.ps1' -Line @($Head, '}')
        Assert-Malformed -Label "duplicate-target: $Label" -Path $path -Reason 'duplicate-target' -Line 1
    }

    It 'conforming: a single -Tags parameter holds exactly one target' {
        $path = New-Sample -Name 'tags.Tests.ps1' -Line @("Describe 'alpha' -Tags 'target:bin/a.sh' {", '}')
        Assert-Record -Label 'conforming: single -Tags' -Path $path -State 'conforming' -Case @('CASE|alpha|bin/a.sh|1|2||')
    }

    It 'nested-target: a tagged Describe inside <Label>' -ForEach @(
        @{ Label = 'an untagged Describe'; Open = "Describe 'outer' {" }
        @{ Label = 'a tagged Describe'; Open = "Describe 'outer' -Tag 'target:bin/o.sh' {" }
        @{ Label = 'a function'; Open = 'function Invoke-Group {' }
        @{ Label = 'BeforeAll'; Open = 'BeforeAll {' }
    ) {
        $path = New-Sample -Name 'nested.Tests.ps1' -Line @($Open, "    Describe 'inner' -Tag 'target:bin/a.sh' {", '    }', '}')
        Assert-Malformed -Label "nested-target: $Label" -Path $path -Reason 'nested-target' -Line 2
    }

    It 'nested-target: a tagged Context inside <Label>' -ForEach @(
        @{ Label = 'a tagged Describe'; Open = "Describe 'outer' -Tag 'target:bin/o.sh' {" }
        @{ Label = 'an untagged Describe'; Open = "Describe 'outer' {" }
        @{ Label = 'a function'; Open = 'function Invoke-Group {' }
        @{ Label = 'BeforeAll'; Open = 'BeforeAll {' }
    ) {
        $path = New-Sample -Name 'nested-context.Tests.ps1' -Line @($Open, "    Context 'inner' -Tag 'target:bin/b.ps1' {", '    }', '}')
        Assert-Malformed -Label "nested-target: Context in $Label" -Path $path -Reason 'nested-target' -Line 2
    }

    It 'nested-target: a tagged Context two levels deep' {
        $line = @(
            "Describe 'outer' -Tag 'target:bin/o.sh' {"
            "    Describe 'middle' {"
            "        Context 'deep' -Tag 'target:bin/b.ps1' {"
            '        }'
            '    }'
            '}'
        )
        Assert-Malformed -Label 'nested-target: deep Context' -Path (New-Sample -Name 'deep-context.Tests.ps1' -Line $line) -Reason 'nested-target' -Line 3
    }

    It 'conforming: Contexts without a target tag inside a tagged Describe' {
        $line = @(
            "Describe 'alpha' -Tag 'target:bin/a.sh' {"
            "    Context 'inner' -Tag 'slow' {"
            '    }'
            "    Context 'plain' {"
            '    }'
            '}'
        )
        Assert-Record -Label 'conforming: untargeted Contexts' -Path (New-Sample -Name 'context-plain.Tests.ps1' -Line $line) -State 'conforming' -Case @('CASE|alpha|bin/a.sh|1|6||')
    }

    It 'nested-target: a tagged top-level Context (<Label>)' -ForEach @(
        @{ Label = 'standalone'; Line = @("Context 'alpha' -Tag 'target:bin/a.sh' {", '}'); At = 1 }
        @{ Label = 'beside a tagged Describe'; Line = @("Describe 'alpha' -Tag 'target:bin/a.sh' {", '}', "Context 'beta' -Tag 'target:bin/b.sh' {", '}'); At = 3 }
    ) {
        $path = New-Sample -Name 'top-context.Tests.ps1' -Line $Line
        Assert-Malformed -Label "nested-target: top-level Context $Label" -Path $path -Reason 'nested-target' -Line $At
    }

    It 'conforming: a top-level Context without a target tag beside a tagged Describe' {
        $line = @("Describe 'alpha' -Tag 'target:bin/a.sh' {", '}', "Context 'x' -Tag 'slow' {", '}')
        Assert-Record -Label 'conforming: untargeted top-level Context' -Path (New-Sample -Name 'top-context-plain.Tests.ps1' -Line $line) -State 'conforming' -Case @('CASE|alpha|bin/a.sh|1|2||')
    }

    It 'grammar: a file that does not parse (<Label>)' -ForEach @(
        @{ Label = 'unclosed block'; Line = @("Describe 'alpha' -Tag 'target:bin/a.sh' {", "    It 'one' { }") }
        @{ Label = 'unterminated string'; Line = @("Describe 'alpha -Tag 'target:bin/a.sh' {", '}') }
    ) {
        Assert-Malformed -Label "grammar: $Label" -Path (New-Sample -Name 'broken.Tests.ps1' -Line $Line) -Reason 'grammar'
    }

    It 'grammar: an empty Describe name (<Label>)' -ForEach @(
        @{ Label = 'single-quoted'; Head = "Describe '' -Tag 'target:bin/a.sh' {" }
        @{ Label = 'double-quoted'; Head = 'Describe "" -Tag ''target:bin/a.sh'' {' }
        @{ Label = 'named -Name parameter'; Head = "Describe -Name '' -Tag 'target:bin/a.sh' {" }
    ) {
        Assert-Malformed -Label "grammar: $Label" -Path (New-Sample -Name 'empty-name.Tests.ps1' -Line @($Head, '}')) -Reason 'grammar' -Line 1
    }

    # The reader reports both; rejecting the repeated name is the shared state rule's job (#2673).
    It 'duplicate names pass through the reader (the shared state rule rejects them)' {
        $one = { param($Target) "Describe 'alpha' -Tag 'target:$Target' {"; '}' }
        $line = @(& $one 'bin/a.sh') + @(& $one 'bin/b.sh')
        $path = New-Sample -Name 'dup-name.Tests.ps1' -Line $line
        Assert-Record -Label 'duplicate names' -Path $path -State 'conforming' -Case @('CASE|alpha|bin/a.sh|1|2||', 'CASE|alpha|bin/b.sh|3|4||')
    }

    It 'never executes the file under read' {
        $sentinel = Join-Path $TestDrive 'executed.flag'
        $line = @("Set-Content -LiteralPath '$sentinel' -Value 'ran'", "Describe 'alpha' -Tag 'target:bin/a.sh' {", '}')
        Assert-Record -Label 'never executes' -Path (New-Sample -Name 'side-effect.Tests.ps1' -Line $line) -State 'conforming' -Case @('CASE|alpha|bin/a.sh|2|3||')
        $sentinel | Should -Not -Exist -Because '[never executes] the sentinel must not be written'
    }

    It 'an unreadable path exits non-zero and prints no FILE line' {
        $r = Read-Case -Label 'unreadable path' -Path (Join-Path $TestDrive 'absent.Tests.ps1')
        $r.ExitCode | Should -Not -Be 0 -Because '[unreadable path] the reader fails'
        $r.File.Count | Should -Be 0 -Because '[unreadable path] no FILE line'
    }
}
