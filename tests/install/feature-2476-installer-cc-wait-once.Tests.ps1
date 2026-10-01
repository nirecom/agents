# Tests: install/lib/wait-cc-exit-target.ps1, install/lib/wait-cc-exit.ps1, install.ps1, install/win/dotfileslink.ps1, install/win/claude-code.ps1
# Tags: installer, wait-cc-exit, TL2, scope:issue-specific, pwsh-required
# #2476: parent waits for Claude Code once, hands the verdict to children via WAIT_CC_RESULT.
# TL2: real .ps1 sources run in a child pwsh (per-process env, .cmd stubs, TestDrive root);
# pwsh-executing half of tests/install/feature-2476-installer-cc-wait-once.sh.
# TL3 gap: real Desktop app (MSIX) beside a CLI claude; install.ps1 end-to-end (fnm,
# winget, network); ping.exe copies may be blocked (Defender/AppLocker).
# Closest-to-action mitigation: bin/check-verification-gate.sh category: installer.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\pester-process-helpers.ps1')
    $script:AgentsDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:WaitPs    = Join-Path $script:AgentsDir 'install\lib\wait-cc-exit.ps1'
    $script:TargetPs  = Join-Path $script:AgentsDir 'install\lib\wait-cc-exit-target.ps1'
    $script:InstallPs = Join-Path $script:AgentsDir 'install.ps1'
    $script:DotPs     = Join-Path $script:AgentsDir 'install\win\dotfileslink.ps1'
    $script:CcPs      = Join-Path $script:AgentsDir 'install\win\claude-code.ps1'

    # Case-sensitive per-line match count (grep -c semantics).
    function Get-LineMatchCount([string]$Text, [string]$Pattern) {
        @($Text -split "`n" | Where-Object { $_ -cmatch $Pattern }).Count
    }
}

Describe 'desktop-shell-excluded-by-path-predicate' {
    # Test-CCWaitTarget -Path: $false only for the drive-rooted Desktop app shell
    # (<Drive>:\[Program Files\]WindowsApps\Claude_*\app\Claude.exe); every other path -
    # a user-writable lookalike included - and null/blank, waits.
    BeforeAll { . $script:TargetPs }

    It 'TP-<Name>: Test-CCWaitTarget -> <Want>' -ForEach @(
        @{ Name = 'std';         Want = $false; Path = 'C:\Program Files\WindowsApps\Claude_1.2.3.0_x64__abc\app\Claude.exe' }
        @{ Name = 'lower';       Want = $false; Path = 'c:\program files\windowsapps\claude_1.2.3.0_x64__abc\app\claude.exe' }
        @{ Name = 'slash';       Want = $false; Path = 'C:/Program Files/WindowsApps/Claude_1.2.3.0_x64__abc/app/Claude.exe' }
        @{ Name = 'ddrive';      Want = $false; Path = 'D:\WindowsApps\Claude_1.2.3.0_x64__abc\app\Claude.exe' }
        @{ Name = 'ddrive2';     Want = $false; Path = 'D:\WindowsApps\Claude_1.2.3_x64__abc\app\Claude.exe' }
        @{ Name = 'userprofile'; Want = $true;  Path = 'C:\Users\u\x\WindowsApps\Claude_1\app\Claude.exe' }
        @{ Name = 'relative';    Want = $true;  Path = 'WindowsApps\Claude_1\app\Claude.exe' }
        @{ Name = 'vscode';      Want = $true;  Path = 'C:\Users\u\.vscode\extensions\anthropic.claude-code-2.0.0-win32-x64\resources\native-binary\claude.exe' }
        @{ Name = 'bundled';     Want = $true;  Path = 'C:\Users\u\AppData\Local\Packages\Claude_x\LocalCache\Roaming\Claude\claude-code\1.0.0\claude.exe' }
        @{ Name = 'cli';         Want = $true;  Path = 'C:\Users\u\.local\bin\claude.exe' }
        @{ Name = 'unknown';     Want = $true;  Path = 'E:\tools\claude\claude.exe' }
        @{ Name = 'null';        Want = $true;  Path = $null }
        @{ Name = 'empty';       Want = $true;  Path = '' }
        @{ Name = 'blank';       Want = $true;  Path = '  ' }
        @{ Name = 'resources';   Want = $true;  Path = 'C:\Program Files\WindowsApps\Claude_x\app\resources\claude.exe' }
        @{ Name = 'notclaude';   Want = $true;  Path = 'C:\Program Files\WindowsApps\NotClaude_x\app\Claude.exe' }
    ) {
        Test-CCWaitTarget -Path $Path | Should -Be $Want
    }
}

Describe 'result-memo-short-circuits-helpers' {
    # WAIT_CC_RESULT memo contract: clear -> exit 0 at once, silent; timeout -> exit 1 at
    # once, silent; unset/empty -> poll as before; any other value (case-sensitive) -> one
    # "Ignoring invalid WAIT_CC_RESULT" diagnostic, then poll. The process override
    # contradicts the memo so only a honored memo passes.
    BeforeAll {
        # $Memo = '-' removes WAIT_CC_RESULT from the child environment.
        function Invoke-Memo([string]$Memo, [string]$Override, [int]$Polls) {
            $memoValue = if ($Memo -eq '-') { $null } else { $Memo }
            $r = Invoke-PwshChild -File $script:WaitPs -TimeoutSec 60 -Environment @{
                WAIT_CC_RESULT           = $memoValue
                WAIT_CC_PROCESS_OVERRIDE = $Override
                WAIT_CC_POLL_INTERVAL    = '1'
                WAIT_CC_MAX_POLLS        = "$Polls"
            }
            # Shell command substitution drops trailing newlines; mirror that for "silent".
            $r | Add-Member -NotePropertyName Text -NotePropertyValue $r.Output.TrimEnd("`n") -PassThru
        }
        $script:PollRe = 'poll [0-9]'
        $script:DiagRe = 'Ignoring invalid WAIT_CC_RESULT'
    }

    It 'M-ps-clear: clear + CC alive -> exit 0 at once, silent' {
        $r = Invoke-Memo 'clear' 'alive' 3
        $r.ExitCode | Should -Be 0
        $r.Text     | Should -Not -Match $script:PollRe
        $r.Text     | Should -BeNullOrEmpty
    }

    It 'M-ps-timeout: timeout + CC absent -> exit 1 at once, silent' {
        $r = Invoke-Memo 'timeout' 'none' 3
        $r.ExitCode | Should -Be 1
        $r.Text     | Should -Not -Match $script:PollRe
        $r.Text     | Should -BeNullOrEmpty
    }

    It 'M-ps-unset: unset + CC absent -> exit 0 (unchanged polling path)' {
        $r = Invoke-Memo '-' 'none' 3
        $r.ExitCode | Should -Be 0
        $r.Text     | Should -Not -Match $script:DiagRe
    }

    It 'M-ps-empty: empty + CC absent -> exit 0, no diagnostic' {
        $r = Invoke-Memo '' 'none' 3
        $r.ExitCode | Should -Be 0
        $r.Text     | Should -Not -Match $script:DiagRe
    }

    It 'M-ps-empty-alive: empty + CC alive -> polls, exit 1, no diagnostic' {
        $r = Invoke-Memo '' 'alive' 1
        $r.ExitCode | Should -Be 1
        (Get-LineMatchCount $r.Text $script:PollRe) | Should -BeGreaterThan 0
        $r.Text     | Should -Not -Match $script:DiagRe
    }

    It 'M-ps-invalid-upper: CLEAR (case-sensitive) + CC alive -> diagnostic, polls, exit 1' {
        $r = Invoke-Memo 'CLEAR' 'alive' 1
        $r.ExitCode | Should -Be 1
        (Get-LineMatchCount $r.Text "$($script:DiagRe).*'CLEAR'") | Should -Be 1
    }

    It 'M-ps-invalid-yes: yes + CC absent -> diagnostic, polls, exit 0' {
        $r = Invoke-Memo 'yes' 'none' 3
        $r.ExitCode | Should -Be 0
        (Get-LineMatchCount $r.Text "$($script:DiagRe).*'yes'") | Should -Be 1
    }
}

Describe 'helpers-list-waited-pids' {
    # PID display contract: "  PID <id>  <path|(unknown)>" on the first poll and whenever the
    # PID set changes (ps: Write-Host); none for the internal override modes.
    BeforeAll {
        $script:HelperEnv = @{
            WAIT_CC_RESULT           = $null
            WAIT_CC_PROCESS_OVERRIDE = $null
            WAIT_CC_POLL_INTERVAL    = '1'
            WAIT_CC_MAX_POLLS        = '1'
        }
        # Copies of PING.EXE named claude.exe: a real long-lived process named "claude".
        function New-ClaudeLookalike([string]$RelPath) {
            $dest = Join-Path $TestDrive $RelPath
            New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
            if (-not (Test-Path -LiteralPath $dest)) {
                Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\PING.EXE') -Destination $dest
            }
            $dest
        }
        function Start-Lookalike([string]$Path) {
            Start-Process -FilePath $Path -ArgumentList '-n', '30', '127.0.0.1' -WindowStyle Hidden -PassThru -ErrorAction Stop
        }
    }

    It 'D-ps-real: CLI claude.exe and user-writable lookalike both listed with path' -Skip:(-not $IsWindows) {
        $cli  = New-ClaudeLookalike 'cli\claude.exe'
        $desk = New-ClaudeLookalike 'WindowsApps\Claude_test\app\Claude.exe'
        $p1 = $null; $p2 = $null
        try {
            try {
                $p1 = Start-Lookalike $cli
                $p2 = Start-Lookalike $desk
            } catch {
                Set-ItResult -Skipped -Because "copied ping.exe could not start ($($_.Exception.Message))"
                return
            }
            Start-Sleep -Milliseconds 500
            $r = Invoke-PwshChild -File $script:WaitPs -TimeoutSec 60 -Environment $script:HelperEnv
            $r.Output | Should -Match "PID $($p1.Id)  .*cli.claude\.exe"
            $r.Output | Should -Match "PID $($p2.Id)  .*WindowsApps.Claude_test.app.Claude\.exe"
        } finally {
            foreach ($p in @($p1, $p2)) { if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
        }
    }

    It 'D-ps-lookalike-only: user-writable Desktop lookalike -> waited (rc 1), PID listed' -Skip:(-not $IsWindows) {
        # A renamed binary cannot dodge the wait; other live claude processes only add PID lines.
        $desk = New-ClaudeLookalike 'WindowsApps\Claude_test\app\Claude.exe'
        $p = $null
        try {
            try { $p = Start-Lookalike $desk } catch {
                Set-ItResult -Skipped -Because "launch failed: $($_.Exception.Message)"
                return
            }
            Start-Sleep -Milliseconds 500
            $procs = @(Get-Process -Name claude -ErrorAction SilentlyContinue)
            if (-not ($procs | Where-Object Id -eq $p.Id)) {
                Set-ItResult -Skipped -Because "copy PID $($p.Id) not visible as Get-Process -Name claude"
                return
            }
            $r = Invoke-PwshChild -File $script:WaitPs -TimeoutSec 60 -Environment $script:HelperEnv
            $r.ExitCode | Should -Be 1
            $r.Output   | Should -Match "PID $($p.Id)  .*WindowsApps.Claude_test.app.Claude\.exe"
        } finally {
            if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
        }
    }

    Context 'Get-Process shadowed by synthetic processes' {
        # One child pwsh shadows Get-Process with a global function returning synthetic
        # processes, then runs the REAL helper via & (the function wins over the cmdlet; the
        # helper's exit sets $LASTEXITCODE). Pins that the Desktop exclusion drives the wait
        # decision, not only the PID display.
        BeforeAll {
            $script:MockDriver = Join-Path $TestDrive 'disp-mock.ps1'
            Set-Content -LiteralPath $script:MockDriver -Value @'
param([string]$Helper, [string]$Scenario, [string]$Desk, [string]$Cli)
function New-MockProc([int]$Id, $Path) {
    [pscustomobject]@{ Id = $Id; Path = $Path; Name = 'claude'; ProcessName = 'claude' }
}
switch ($Scenario) {
    'desktop-only' { $global:MockProcs = @(New-MockProc 3131 $Desk) }
    'mixed'        { $global:MockProcs = @((New-MockProc 3131 $Desk), (New-MockProc 4242 $Cli)) }
    'nullpath'     { $global:MockProcs = @(New-MockProc 777 $null) }
}
# Accepts and ignores the helper's call shape (-Name "claude" -ErrorAction SilentlyContinue).
function global:Get-Process { $global:MockProcs }
Remove-Item Env:WAIT_CC_RESULT, Env:WAIT_CC_PROCESS_OVERRIDE -ErrorAction SilentlyContinue
$env:WAIT_CC_POLL_INTERVAL = '1'; $env:WAIT_CC_MAX_POLLS = '1'
$out = & $Helper *>&1 | Out-String
Write-Output "RC=$LASTEXITCODE"
Write-Output $out
'@
            function Invoke-MockScenario([string]$Scenario) {
                $r = Invoke-PwshChild -File $script:MockDriver -TimeoutSec 60 -ArgumentList @(
                    '-Helper', $script:WaitPs, '-Scenario', $Scenario,
                    '-Desk', 'C:\Program Files\WindowsApps\Claude_1.2.3.0_x64__abc\app\Claude.exe',
                    '-Cli', 'C:\Users\u\.local\bin\claude.exe')
                $r.Output
            }
        }

        It 'D-ps-mock-desktop-only: Desktop-shell path only -> rc 0, no poll, no PID line' {
            $out = Invoke-MockScenario 'desktop-only'
            (Get-LineMatchCount $out '^RC=0$') | Should -Be 1
            $out | Should -Not -Match 'poll [0-9]'
            $out | Should -Not -Match 'PID '
        }

        It 'D-ps-mock-mixed: CLI + Desktop -> waits on CLI (rc 1), PID 4242 shown, Desktop PID hidden' {
            $out = Invoke-MockScenario 'mixed'
            (Get-LineMatchCount $out '^RC=1$') | Should -Be 1
            $out | Should -Match 'poll [0-9]'
            (Get-LineMatchCount $out 'PID 4242( |$)') | Should -BeGreaterThan 0
            (Get-LineMatchCount $out 'PID 3131( |$)') | Should -Be 0
        }

        It 'D-ps-mock-nullpath: Path=$null counts as a wait target (rc 1), PID 777 (unknown)' {
            $out = Invoke-MockScenario 'nullpath'
            (Get-LineMatchCount $out '^RC=1$') | Should -Be 1
            $out | Should -Match 'PID 777 .*\(unknown\)'
        }
    }
}

Describe 'ps-parent-waits-once-before-children' {
    BeforeAll {
        $script:InstallLines = @(Get-Content -LiteralPath $script:InstallPs)
        # First 1-based line number matching $Pattern after line $After, or 0 (awk NR semantics).
        function Get-LineAfter([string]$Pattern, [int]$After = 0) {
            for ($i = $After; $i -lt $script:InstallLines.Count; $i++) {
                if ($script:InstallLines[$i] -cmatch $Pattern) { return $i + 1 }
            }
            0
        }
    }

    It 'PP-ps-exec: both clear lines are no-ops on an unset variable under Stop' {
        # Runs the real clear lines (loose match, -ErrorAction not required here) under
        # StrictMode + Stop with the variable unset; a throw means a first run aborts.
        $fnm    = Get-LineAfter '^\s*Write-Host "--- Checking Node\.js \(fnm\) ---"'
        $fnmEnd = Get-LineAfter '^    }\s*$' $fnm
        $dot    = Get-LineAfter '^\s*Invoke-InstallStep "Creating symlinks"'
        $fnm    | Should -BeGreaterThan 0 -Because 'the fnm-check Write-Host anchor must exist'
        $fnmEnd | Should -BeGreaterThan 0 -Because 'the fnm-check closing brace anchor must exist'
        $dot    | Should -BeGreaterThan 0 -Because 'the Creating symlinks Invoke-InstallStep anchor must exist'
        $rmAny   = Get-LineAfter '^\s*Remove-Item Env:WAIT_CC_RESULT' $fnmEnd
        $cleanAny = Get-LineAfter '^\s*Remove-Item Env:WAIT_CC_RESULT' $dot
        $rmAny    | Should -BeGreaterThan 0 -Because 'the pre-wait Remove-Item Env:WAIT_CC_RESULT line must exist'
        $cleanAny | Should -BeGreaterThan 0 -Because 'the cleanup Remove-Item Env:WAIT_CC_RESULT line must exist'
        $probe = Join-Path $TestDrive 'pp-exec.ps1'
        # No SetEnvironmentVariable($null) prelude: it masks the throw; the child env removes it.
        Set-Content -LiteralPath $probe -Value @(
            'Set-StrictMode -Version Latest'
            "`$ErrorActionPreference = 'Stop'"
            $script:InstallLines[$rmAny - 1]
            $script:InstallLines[$cleanAny - 1]
            "Write-Output 'PP_EXEC_OK'"
        )
        $r = Invoke-PwshChild -File $probe -TimeoutSec 60 -Environment @{ WAIT_CC_RESULT = $null }
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output   | Should -Match 'PP_EXEC_OK'
    }

    It 'PP-ps-env-restore: exit inside the try restores SYSTEM_OPS_APPROVED (unset/prior) and clears WAIT_CC_RESULT' -Skip:(-not $IsWindows) {
        # .\install.ps1 runs in the caller's session, so SYSTEM_OPS_APPROVED and WAIT_CC_RESULT
        # must not outlive it. PATH without fnm/winget takes the fnm-check `exit 1` (the earliest
        # exit inside the try); a stub git keeps core.longpaths off the real config.
        $stubDir = Join-Path $TestDrive 'pp-env-bin'
        New-CmdStub -Directory $stubDir -Name 'git' -Line @('@echo off', 'exit /b 0') | Out-Null
        $driver = Join-Path $TestDrive 'pp-env.ps1'
        Set-Content -LiteralPath $driver -Value @'
param([string]$Installer, [string]$StubDir)
$env:PATH = "$StubDir;$env:SystemRoot\System32"
foreach ($prior in '<unset>', 'prior') {
    if ($prior -eq '<unset>') { Remove-Item Env:SYSTEM_OPS_APPROVED -ErrorAction SilentlyContinue } else { $env:SYSTEM_OPS_APPROVED = $prior }
    $env:WAIT_CC_RESULT = 'clear'
    try { & $Installer *> $null } catch { Write-Output "THREW $($_.Exception.Message)" }
    $s = if (Test-Path Env:SYSTEM_OPS_APPROVED) { $env:SYSTEM_OPS_APPROVED } else { '<unset>' }
    $w = if (Test-Path Env:WAIT_CC_RESULT) { $env:WAIT_CC_RESULT } else { '<unset>' }
    Write-Output "PRIOR=$prior RC=$LASTEXITCODE SYSOPS=$s WCR=$w"
}
'@
        $r = Invoke-PwshChild -File $driver -TimeoutSec 60 -ArgumentList @('-Installer', $script:InstallPs, '-StubDir', $stubDir)
        $lines = $r.Output -split "`n"
        $lines | Should -Contain 'PRIOR=<unset> RC=1 SYSOPS=<unset> WCR=<unset>'
        $lines | Should -Contain 'PRIOR=prior RC=1 SYSOPS=prior WCR=<unset>'
    }
}

Describe 'dotfileslink-ps-skips-only-settings-write' {
    # dotfileslink.ps1 on a wait timeout skips only the settings.json write (node not called)
    # and still sets core.hooksPath and writes the launchers. The override contradicts the
    # memo so only a honored memo passes. Windows only: WindowsIdentity privilege check
    # and the node.cmd stub.
    BeforeAll {
        function Invoke-Dotfileslink([string]$Label, [string]$Memo, [string]$Override) {
            $root = Join-Path $TestDrive "dl-root-$Label"
            $stub = Join-Path $TestDrive "dl-stub-$Label"
            $fakeHome = Join-Path $TestDrive "dl-home-$Label"
            $nodeLog = Join-Path $TestDrive "dl-node-$Label.log"
            foreach ($d in @("$root\install\win", "$root\install\lib", $fakeHome)) {
                New-Item -ItemType Directory -Path $d -Force | Out-Null
            }
            Copy-Item -LiteralPath $script:DotPs -Destination "$root\install\win\"
            Copy-Item -LiteralPath $script:WaitPs, $script:TargetPs -Destination "$root\install\lib\"
            New-CmdStub -Directory $stub -Name 'node' -Line @('@echo off', "echo %* >> `"$nodeLog`"", 'exit /b 0') | Out-Null
            $r = Invoke-PwshChild -File "$root\install\win\dotfileslink.ps1" -TimeoutSec 90 -Environment @{
                PATH                         = "$stub;$env:PATH"
                DOTFILESLINK_HOME_OVERRIDE   = $fakeHome
                DOTFILESLINK_SKIP_PRIV_CHECK = '1'
                WAIT_CC_RESULT               = $Memo
                WAIT_CC_PROCESS_OVERRIDE     = $Override
                WAIT_CC_POLL_INTERVAL        = '1'
                WAIT_CC_MAX_POLLS            = '1'
            }
            [pscustomobject]@{ ExitCode = $r.ExitCode; Output = $r.Output; Home = $fakeHome; NodeLog = $nodeLog }
        }
    }

    It 'DL-ps-timeout: memo timeout -> warning, node skipped, hooksPath set, launcher written, rc 0' -Skip:(-not $IsWindows) {
        $r = Invoke-Dotfileslink 'timeout' 'timeout' 'none'
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output   | Should -Match 'skipping settings\.json write'
        if (Test-Path -LiteralPath $r.NodeLog) {
            (Get-Item -LiteralPath $r.NodeLog).Length | Should -Be 0 -Because 'node must not be called'
        }
        $hooks = & git config --file (Join-Path $r.Home '.gitconfig') core.hooksPath 2>$null
        $hooks | Should -Not -BeNullOrEmpty
        Join-Path $r.Home '.local\bin\doc-append.cmd' | Should -Exist
    }

    It 'DL-ps-clear: memo clear (CC alive) -> node assemble-settings.js called' -Skip:(-not $IsWindows) {
        $r = Invoke-Dotfileslink 'clear' 'clear' 'alive'
        $r.NodeLog | Should -Exist -Because "rc=$($r.ExitCode) $($r.Output)"
        Get-Content -LiteralPath $r.NodeLog -Raw | Should -Match 'assemble-settings\.js'
    }
}

Describe 'children-honor-parent-memo' {
    # Group G: the real claude-code child + the REAL wait helper (copied into a mock root,
    # unlike feature-2284 which mocks the helper) honor the parent memo. The process
    # override contradicts the memo so only a honored memo passes.
    BeforeAll {
        function Invoke-ClaudeCodeChild([string]$Label, [string]$Memo, [string]$Override) {
            $root = Join-Path $TestDrive "g-root-$Label"
            $stub = Join-Path $TestDrive "g-stub-$Label"
            $log  = Join-Path $TestDrive "g-log-$Label.txt"
            foreach ($d in @((Join-Path $root 'install/win'), (Join-Path $root 'install/lib'))) {
                New-Item -ItemType Directory -Path $d -Force | Out-Null
            }
            Copy-Item -LiteralPath $script:CcPs -Destination (Join-Path $root 'install/win/claude-code.ps1')
            Copy-Item -LiteralPath $script:WaitPs, $script:TargetPs -Destination (Join-Path $root 'install/lib')
            # claude.cmd shadows any real claude on Windows; the bash stub serves POSIX pwsh.
            if ($IsWindows) {
                New-CmdStub -Directory $stub -Name 'claude' -Line @('@echo off', "echo %* >> `"$log`"", 'exit /b 0') | Out-Null
            } else {
                New-ShStub -Directory $stub -Name 'claude' -Line @("echo `"`$@`" >> '$log'", 'exit 0') | Out-Null
            }
            $r = Invoke-PwshChild -File (Join-Path $root 'install/win/claude-code.ps1') -TimeoutSec 60 -Environment @{
                PATH                     = $stub + [IO.Path]::PathSeparator + $env:PATH
                AGENTS_ROOT              = $root
                WAIT_CC_RESULT           = $Memo
                WAIT_CC_PROCESS_OVERRIDE = $Override
                WAIT_CC_POLL_INTERVAL    = '1'
                WAIT_CC_MAX_POLLS        = '2'
            }
            $updated = (Test-Path -LiteralPath $log) -and
                [bool](Get-Content -LiteralPath $log | Where-Object { $_ -match '^update' })
            [pscustomobject]@{ ExitCode = $r.ExitCode; Output = $r.Output; Updated = $updated }
        }
    }

    It 'G-ps-clear: memo clear + override alive -> claude update called' {
        $r = Invoke-ClaudeCodeChild 'ps-clear' 'clear' 'alive'
        $r.Updated | Should -BeTrue -Because "rc=$($r.ExitCode) $($r.Output)"
    }

    It 'G-ps-timeout: memo timeout + override none -> update skipped, rc 0' {
        $r = Invoke-ClaudeCodeChild 'ps-timeout' 'timeout' 'none'
        $r.Updated  | Should -BeFalse
        $r.ExitCode | Should -Be 0
    }
}
