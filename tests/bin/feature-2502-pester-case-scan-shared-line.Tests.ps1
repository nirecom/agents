# Tests: bin/lib/test-language-parts/pester-case-scan.ps1
# Tags: TL2, bin, case-markers, test-language-registry, pester, scope:issue-specific, pwsh-required
# A case owns its begin and end lines: Get-CaseScan gives a `grammar` fault at the Describe's begin
# line when another top-level statement (another Describe included) shares its begin or end line,
# so cutting the case range can never cut that statement. A trailing comment is not a statement.
# The file is parsed with the PowerShell parser and never run.

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
    . (Join-Path $PSScriptRoot '..' '..' 'bin' 'lib' 'test-language-parts' 'pester-case-scan.ps1')

    # The scan of the given lines as "<line>|<reason>" faults and "<name>|<begin>|<end>" cases.
    function Get-ScanText {
        param([string]$Label, [string[]]$Line)
        $parseError = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(($Line -join "`n") + "`n", [ref]$null, [ref]$parseError)
        @($parseError).Count | Should -Be 0 -Because "[$Label] the sample parses"
        $scan = Get-CaseScan -Ast $ast
        [pscustomobject]@{
            Fault = (@($scan.Fault | ForEach-Object { "$($_[0])|$($_[1])" }) -join ' ')
            Case  = (@($scan.Case | ForEach-Object { "$($_.Name)|$($_.Begin)|$($_.End)" }) -join ' ')
        }
    }
}

Describe 'pester-case-scan shared line' -Tag 'target:bin/lib/test-language-parts/pester-case-scan.ps1' {
    It 'shared: <Label>' -ForEach @(
        @{ Label = 'a statement after the closing brace'; Fault = '1|grammar'; Case = 'b|4|6'; Line = @(
                "Describe 'a' -Tag 'target:bin/a.sh' {", "    It 'x' { 1 | Should -Be 1 }", '}; $shared = 1',
                "Describe 'b' -Tag 'target:bin/b.sh' {", "    It 'y' { 1 | Should -Be 1 }", '}') }
        @{ Label = 'two Describes on one line'; Fault = '1|grammar 1|grammar'; Case = ''; Line = @(
                "Describe 'a' -Tag 'target:bin/a.sh' { }; Describe 'b' -Tag 'target:bin/b.sh' { }") }
        @{ Label = 'the next Describe opening on the closing line'; Fault = '1|grammar 3|grammar'; Case = ''; Line = @(
                "Describe 'a' -Tag 'target:bin/a.sh' {", "    It 'x' { 1 | Should -Be 1 }",
                "}; Describe 'b' -Tag 'target:bin/b.sh' {", "    It 'y' { 1 | Should -Be 1 }", '}') }
        @{ Label = 'a statement before the Describe on its begin line'; Fault = '1|grammar'; Case = ''; Line = @(
                "`$x = 1; Describe 'a' -Tag 'target:bin/a.sh' {", "    It 'x' { 1 | Should -Be 1 }", '}') }
    ) {
        $r = Get-ScanText -Label "shared: $Label" -Line $Line
        $r.Fault | Should -BeExactly $Fault -Because "[shared: $Label] the faults"
        $r.Case | Should -BeExactly $Case -Because "[shared: $Label] the cases left"
    }

    It 'owned: <Label>' -ForEach @(
        @{ Label = 'a trailing comment on the closing line'; Case = 'a|1|3'; Line = @(
                "Describe 'a' -Tag 'target:bin/a.sh' {", "    It 'x' { 1 | Should -Be 1 }", '} # done') }
        @{ Label = 'a trailing comment on the begin line'; Case = 'a|1|3'; Line = @(
                "Describe 'a' -Tag 'target:bin/a.sh' { # opens", "    It 'x' { 1 | Should -Be 1 }", '}') }
        @{ Label = 'multi-line Describes and statements each on their own lines'; Case = 'a|5|7 b|9|11'; Line = @(
                'BeforeAll {', "    . (Join-Path `$PSScriptRoot '..' 'lib' 'harness.ps1')", '}', '$shared = 1',
                "Describe 'a' -Tag 'target:bin/a.sh' {", "    It 'x' { 1 | Should -Be 1 }", '}',
                '$after = 2',
                "Describe 'b' -Tag 'target:bin/b.sh' {", "    It 'y' { 1 | Should -Be 1 }", '}') }
        @{ Label = 'a one-line Describe alone on its line'; Case = 'a|1|1'; Line = @(
                "Describe 'a' -Tag 'target:bin/a.sh' { It 'x' { 1 | Should -Be 1 } }", '$next = 1') }
    ) {
        $r = Get-ScanText -Label "owned: $Label" -Line $Line
        $r.Fault | Should -BeExactly '' -Because "[owned: $Label] no fault"
        $r.Case | Should -BeExactly $Case -Because "[owned: $Label] every case is kept"
    }
}
