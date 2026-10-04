# Tests: bin/test-language-registry
# Tags: bin, pwsh, test-language-registry, TL2, scope:common, pwsh-required
# PowerShell reads the test language registry through the CLI only:
# `node <CLI> --format json | ConvertFrom-Json` (no .ps1 wrapper exists).

Set-StrictMode -Version Latest

Describe 'test-language-registry CLI read from PowerShell' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:cli = Join-Path $script:repoRoot 'bin\test-language-registry'
        $script:tablePath = Join-Path $script:repoRoot 'hooks\lib\test-language-registry.json'
        # The expected entry set is read from the table itself, so a new entry needs no edit here.
        $script:tableIds = @((Get-Content -LiteralPath $script:tablePath -Raw | ConvertFrom-Json).entries | ForEach-Object { $_.id })
        $script:fixtureDir = Join-Path $script:repoRoot 'tests\bin\test-language-registry\fixtures'
    }

    It 'the CLI file exists' {
        Test-Path -LiteralPath $script:cli -PathType Leaf | Should -BeTrue
    }

    It 'json output parses with ConvertFrom-Json and exits 0' {
        $raw = & node $script:cli --format json
        $LASTEXITCODE | Should -Be 0
        $table = ($raw -join "`n") | ConvertFrom-Json
        $table | Should -Not -BeNullOrEmpty
    }

    It 'exposes the entry count and headerMaxLines' {
        $table = ((& node $script:cli --format json) -join "`n") | ConvertFrom-Json
        $script:tableIds.Count | Should -BeGreaterThan 0
        @($table.entries).Count | Should -Be $script:tableIds.Count
        $table.headerMaxLines | Should -Be 10
    }

    It 'entries carry the table ids in table order and converted globs' {
        $table = ((& node $script:cli --format json) -join "`n") | ConvertFrom-Json
        (@($table.entries) | ForEach-Object { $_.id }) -join ',' | Should -Be ($script:tableIds -join ',')
        $script:tableIds | Should -Contain 'bash'
        $bash = @($table.entries) | Where-Object { $_.id -eq 'bash' }
        $bash.status | Should -Be 'supported'
        @($bash.globs) -join ',' | Should -Be '?*.sh'
        $pester = @($table.entries) | Where-Object { $_.id -eq 'pester' }
        @($pester.globs) -join ',' | Should -Be '?*.Tests.ps1'
        $pester.launch.requires | Should -Be 'pwsh'
    }

    It 'a table with an extra valid entry reads back without any test-side id list' {
        $real = Get-Content -LiteralPath $script:tablePath -Raw | ConvertFrom-Json
        $jt = Get-Content -LiteralPath (Join-Path $script:fixtureDir 'java-terraform.json') -Raw | ConvertFrom-Json
        $real.entries = @($real.entries) + @(@($jt.entries) | Where-Object { $_.id -eq 'java-junit' })
        $extraPath = Join-Path $TestDrive 'extra-entry.json'
        $real | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $extraPath -Encoding utf8NoBOM
        $wantIds = @((Get-Content -LiteralPath $extraPath -Raw | ConvertFrom-Json).entries | ForEach-Object { $_.id })
        $wantIds.Count | Should -Be ($script:tableIds.Count + 1)
        $raw = & node $script:cli --format json --file $extraPath
        $LASTEXITCODE | Should -Be 0
        $table = ($raw -join "`n") | ConvertFrom-Json
        (@($table.entries) | ForEach-Object { $_.id }) -join ',' | Should -Be ($wantIds -join ',')
    }

    It 'an argument error exits 2' {
        & node $script:cli --format xml 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 2
    }
}
