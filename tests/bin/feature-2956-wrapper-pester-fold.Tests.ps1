# Tests: bin/lib/test-wrappers/pester.ps1
# Tags: TL2, scope:issue-specific, test-language-wrapper, pester, run-all, result-dir, fail-details, pwsh-required
# #2956 S3: the Pester wrapper writes one fail-details.tsv record (<seq>`t<case>`t<text>) per failed
# test into the result dir, <text> the whole failure message folded by the shared rule; every row of
# tests/fixtures/fail-detail-fold.tsv must come out as its expected text, with the seq cases.tsv
# gives the same case.

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:wrapper = Join-Path $script:root 'bin' 'lib' 'test-wrappers' 'pester.ps1'
    $script:fixture = Join-Path $script:root 'tests' 'fixtures' 'fail-detail-fold.tsv'

    function Expand-FoldRep([string]$s) {
        [regex]::Replace($s, '@@REP:(\d+):([A-Za-z])@@', { param($m) $m.Groups[2].Value * [int]$m.Groups[1].Value })
    }
    function ConvertFrom-FoldEscape([string]$s) {
        $map = @{ '\' = '\'; 't' = "`t"; 'r' = "`r"; 'n' = "`n" }
        [regex]::Replace($s, '\\([\\trn])', { param($m) $map[$m.Groups[1].Value] })
    }
    function Get-FoldRow {
        foreach ($line in [System.IO.File]::ReadAllText($script:fixture).Split("`n")) {
            $line = $line.TrimEnd("`r")
            if ($line -eq '' -or $line.StartsWith('#')) { continue }
            $f = $line.Split("`t")
            [pscustomobject]@{ Name = $f[0]; Input = (Expand-FoldRep (ConvertFrom-FoldEscape $f[1])); Want = (Expand-FoldRep $f[2]) }
        }
    }
    function Read-Tsv([string]$path) {
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        , @([System.IO.File]::ReadAllText($path).Split("`n") | Where-Object { $_ -ne '' } | ForEach-Object { , $_.Split("`t") })
    }
}

Describe 'fail-details fold matches fixture' -Tag 'target:bin/lib/test-wrappers/pester.ps1' {
    BeforeAll {
        $script:rows = @(Get-FoldRow)
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("f2956-pester-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $inDir = Join-Path $script:tmp 'in'
        $script:res = Join-Path $script:tmp 'res'
        New-Item -ItemType Directory -Path $inDir, $script:res -Force | Out-Null
        $src = @("Describe 'fold' {")
        for ($i = 0; $i -lt $script:rows.Count; $i++) {
            $p = Join-Path $inDir "$i.txt"
            [System.IO.File]::WriteAllText($p, $script:rows[$i].Input, [System.Text.UTF8Encoding]::new($false))
            $src += "    It 'row_$($i)_end' { throw [System.Exception]::new([System.IO.File]::ReadAllText('$p')) }"
        }
        $src += '}'
        $script:fx = Join-Path $script:tmp 'fold.Tests.ps1'
        [System.IO.File]::WriteAllText($script:fx, ($src -join "`n") + "`n")
        $saved = @{ Dir = $env:RUN_ALL_RESULT_DIR; Owner = $env:RUN_ALL_RESULT_OWNER }
        try {
            $env:RUN_ALL_RESULT_DIR = $script:res
            $env:RUN_ALL_RESULT_OWNER = $script:fx
            Push-Location $script:tmp
            $script:out = & pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:wrapper -Path $script:fx -MinVersion 5.0 2>&1 | Out-String
            $script:rc = $LASTEXITCODE
        } finally {
            Pop-Location
            $env:RUN_ALL_RESULT_DIR = $saved.Dir
            $env:RUN_ALL_RESULT_OWNER = $saved.Owner
        }
        $script:details = Read-Tsv (Join-Path $script:res 'fail-details.tsv')
        $script:cases = Read-Tsv (Join-Path $script:res 'cases.tsv')
    }
    AfterAll {
        Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'the wrapper exits 1 and writes fail-details.tsv' {
        $script:rc | Should -Be 1 -Because $script:out
        @($script:cases | Where-Object { $_[1] -eq 'FAIL' }).Count | Should -Be $script:rows.Count -Because 'one FAIL case record per fixture row'
        $script:details | Should -Not -BeNullOrEmpty -Because 'fail-details.tsv is written to the result dir'
    }

    It 'every fixture row folds to its expected text, one record with the cases.tsv seq' {
        $script:details | Should -Not -BeNullOrEmpty -Because 'fail-details.tsv is written to the result dir'
        for ($i = 0; $i -lt $script:rows.Count; $i++) {
            $row = $script:rows[$i]
            $key = "row_$($i)_end"
            $got = @($script:details | Where-Object { $_[1].Contains($key) })
            $got.Count | Should -Be 1 -Because "[$($row.Name)] one record for $key"
            $got[0][2] | Should -BeExactly $row.Want -Because "[$($row.Name)] folded text"
            $seqs = @($script:cases | Where-Object { $_.Count -gt 2 -and $_[2].Contains($key) } | ForEach-Object { $_[0] })
            $seqs | Should -Contain $got[0][0] -Because "[$($row.Name)] seq matches cases.tsv"
        }
    }
}
