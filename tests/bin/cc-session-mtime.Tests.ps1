# Tests: bin/cc-session-mtime.ps1
# Tags: bin, mtime, session, session-sync-engine, pwsh-required, scope:issue-specific
#
# #2658: the ps1 entry delegates to `session-sync-engine restore-mtime
# --dry-run-style set`, so it shares the bash entry's rule (one decision table,
# tests/bin/cc-session-mtime.sh pins the bash side; CPR-ORTH). Each run is a
# child pwsh so stdout and stderr are observed separately.
#
# TL3 gap: a real VS Code restart re-reading mtimes, and PS 5.1 hosts, are not
# exercised; see bin/check-verification-gate.sh category pwsh-required.

BeforeDiscovery {
    $script:CanRun = [bool](Get-Command node -ErrorAction SilentlyContinue)
}

Describe 'cc-session-mtime.ps1 delegates to restore-mtime' -Tag 'target:bin/cc-session-mtime.ps1' -Skip:(-not $script:CanRun) {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')
        $script:Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:Ps1 = Join-Path $script:Root 'bin\cc-session-mtime.ps1'
        $script:Bash = Join-Path $script:Root 'bin\cc-session-mtime'
        $script:Tmp = Join-Path $env:TEMP "cc-mtime-ps1-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
        $script:Baseline = [datetime]::Parse('2020-01-01T00:00:00Z').ToUniversalTime()

        function New-ClaudeDir {
            param([string]$Name, [string[]]$Lines)
            $d = Join-Path $script:Tmp "$Name\.claude"
            $proj = Join-Path $d 'projects\test-proj'
            New-Item -ItemType Directory -Path $proj -Force | Out-Null
            $f = Join-Path $proj 'session.jsonl'
            if ($Lines) { [System.IO.File]::WriteAllText($f, (($Lines -join "`n") + "`n")) }
            (Get-Item $f -ErrorAction SilentlyContinue) | ForEach-Object { $_.LastWriteTimeUtc = $script:Baseline }
            @{ Dir = $d; File = $f }
        }

        function Invoke-Ps1 {
            param([string[]]$ArgList)
            $out = Join-Path $script:Tmp "out-$(Get-Random).txt"
            $err = Join-Path $script:Tmp "err-$(Get-Random).txt"
            $p = Start-Process pwsh -ArgumentList (@('-NoProfile', '-NonInteractive', '-File', "`"$script:Ps1`"") + $ArgList) `
                -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
            if (-not $p.WaitForExit(60000)) { $p.Kill(); throw 'cc-session-mtime.ps1 exceeded 60s' }
            @{ Code = $p.ExitCode
               Out = [string](Get-Content $out -Raw -ErrorAction SilentlyContinue)
               Err = [string](Get-Content $err -Raw -ErrorAction SilentlyContinue) }
        }
    }

    AfterAll {
        Remove-Item -Recurse -Force $script:Tmp -ErrorAction SilentlyContinue
    }

    It 'rejects <label> with exit 0, an unchanged mtime and a warn: line on stderr' -ForEach @(
        @{ label = 'long-option-with-value'; value = '--reference=@MARKER@' }
        @{ label = 'short-option-attached';  value = '-r@MARKER@' }
        @{ label = 'short-option-t-form';    value = '-t202001010000' }
        @{ label = 'long-option-date-epoch'; value = '--date=@0' }
        @{ label = 'bare-dash';              value = '-' }
        @{ label = 'double-dash-terminator'; value = '--' }
        @{ label = 'not-a-date';             value = 'not-a-date' }
    ) {
        $marker = Join-Path $script:Tmp "marker-$label"
        Set-Content -Path $marker -Value 'marker'
        (Get-Item $marker).LastWriteTimeUtc = [datetime]::Parse('1999-12-31T00:00:00Z').ToUniversalTime()
        $markerBefore = (Get-Item $marker).LastWriteTimeUtc
        $v = $value.Replace('@MARKER@', ($marker -replace '\\', '/'))
        $c = New-ClaudeDir -Name "dash-$label" -Lines @("{`"timestamp`":`"$v`",`"type`":`"user`"}")
        $r = Invoke-Ps1 -ArgList @('-ClaudeDir', "`"$($c.Dir)`"")
        $r.Code | Should -Be 0 -Because "a rejected value is not fatal (stderr: $($r.Err))"
        (Get-Item $c.File).LastWriteTimeUtc | Should -Be $script:Baseline -Because 'the value must never become the mtime'
        $r.Err | Should -Match 'warn:' -Because 'the engine reports the rejection on stderr as a warn: line'
        (Get-Item $marker).LastWriteTimeUtc | Should -Be $markerBefore -Because 'the file the value names stays untouched'
    }

    It 'dry-run prints "would set <file> mtime to <ts>" and changes nothing' {
        $c = New-ClaudeDir -Name 'dry' -Lines @('{"timestamp":"2024-06-01T10:30:00.000Z","type":"user"}')
        $r = Invoke-Ps1 -ArgList @('-DryRun', '-ClaudeDir', "`"$($c.Dir)`"")
        $r.Code | Should -Be 0
        $r.Out | Should -Match 'would set .*session\.jsonl mtime to 2024-06-01T10:30:00\.000Z'
        (Get-Item $c.File).LastWriteTimeUtc | Should -Be $script:Baseline
    }

    It 'sets the mtime from the last timestamp line' {
        $c = New-ClaudeDir -Name 'normal' -Lines @(
            '{"timestamp":"2024-06-01T08:00:00.000Z","type":"user"}',
            '{"timestamp":"2024-06-01T10:30:00.000Z","type":"assistant"}',
            '{"ai-title":"meta only"}')
        $r = Invoke-Ps1 -ArgList @('-ClaudeDir', "`"$($c.Dir)`"")
        $r.Code | Should -Be 0
        $want = [datetime]::Parse('2024-06-01T10:30:00.000Z').ToUniversalTime()
        [math]::Abs(((Get-Item $c.File).LastWriteTimeUtc - $want).TotalSeconds) | Should -BeLessThan 2
    }

    It 'warns on stderr for a file without a timestamp and keeps its mtime' {
        $c = New-ClaudeDir -Name 'nots' -Lines @('{"sessionId":"no-ts","type":"text"}')
        $r = Invoke-Ps1 -ArgList @('-ClaudeDir', "`"$($c.Dir)`"")
        $r.Code | Should -Be 0
        $r.Err | Should -Match 'warn:'
        (Get-Item $c.File).LastWriteTimeUtc | Should -Be $script:Baseline
    }

    It 'exits 0 when the projects dir is missing' {
        $d = Join-Path $script:Tmp 'noprojects\.claude'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $r = Invoke-Ps1 -ArgList @('-ClaudeDir', "`"$d`"")
        $r.Code | Should -Be 0
        ($r.Out + $r.Err) | Should -Match 'projects dir not found'
    }

    It 'gives the same mtime as the bash entry on the same fixture' -Skip:(-not (Get-Command bash -ErrorAction SilentlyContinue)) {
        $lines = @('{"timestamp":"2024-03-04T05:06:07.000Z","type":"user"}', '{"timestamp":"2024-03-04T06:07:08.000Z","type":"assistant"}')
        $a = New-ClaudeDir -Name 'sym-ps1' -Lines $lines
        $b = New-ClaudeDir -Name 'sym-sh' -Lines $lines
        (Invoke-Ps1 -ArgList @('-ClaudeDir', "`"$($a.Dir)`"")).Code | Should -Be 0
        & bash ($script:Bash -replace '\\', '/') --claude-dir ($b.Dir -replace '\\', '/') 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0
        (Get-Item $a.File).LastWriteTimeUtc | Should -Be (Get-Item $b.File).LastWriteTimeUtc
        (Get-Item $a.File).LastWriteTimeUtc | Should -Not -Be $script:Baseline
    }
}
