# Tests: install/win/glab.ps1
# Tags: install, glab-install, gitlab, scope:issue-specific, TL2, pwsh-required
# #2308/#2476: glab.ps1 GITLAB flag gate, non-interactive auth (token on stdin only),
# and the TCP reachability guard. Each case runs the real glab.ps1 in a child pwsh via a
# driver script in TestDrive, with winget/glab replaced by .cmd stubs on PATH (Windows).
# POSIX cases stay in tests/install/feature-2308-install-glab.sh.
# TL3 gap: real winget install/upgrade, real glab auth login + keyring, a real GitLab on 443.
# Closest-to-action mitigation: bin/check-verification-gate.sh category: installer.

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'lib' 'pester-process-helpers.ps1')
    $script:GlabPs1 = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'install' 'win' 'glab.ps1')).Path
    $script:PsTimeout = 30

    # glab.cmd stub: --version answers; `auth status|login` and `config set` run the given
    # cmd fragments (empty fragment = that branch is absent); everything else exits 0.
    function New-GlabStub {
        param([string]$Dir, [string]$Status = '', [string]$Login = '', [string]$Config = '')
        $lines = @('@echo off', 'if "%1"=="--version" (echo glab version 1.0.0 & exit /b 0)')
        $auth = @()
        if ($Status) { $auth += "  if `"%2`"==`"status`" ($Status)" }
        if ($Login) { $auth += "  if `"%2`"==`"login`" ($Login)" }
        if ($auth) { $lines += @('if "%1"=="auth" (') + $auth + @(')') }
        if ($Config) { $lines += $Config }
        $lines += 'exit /b 0'
        New-CmdStub -Directory $Dir -Name 'glab' -Line $lines | Out-Null
    }

    function New-FailingWinget { param([string]$Dir) New-CmdStub -Directory $Dir -Name 'winget' -Line @('@echo off', 'exit /b 1') | Out-Null }

    # Driver for the TCP reachability guard (#2476): Mode open = loopback TcpListener whose
    # port goes to GLAB_PROBE_PORT (LISTENER_PENDING=True proves the probe connected);
    # closed = same port after Stop (refused); none = no listener, default port 443.
    function New-ProbeDriver {
        param([string]$Dir, [string]$HostName, [string]$Token, [string]$Subfolder, [string]$Mode)
        Set-Content -LiteralPath (Join-Path $Dir 'driver.ps1') -Encoding UTF8 -Value @"
`$env:PATH = '$Dir;' + `$env:PATH
`$env:AGENTS_CONFIG_DIR = '$Dir'
Set-Location '$Dir'
`$env:GITLAB = 'on'
`$env:GITLAB_HOSTNAME = '$HostName'
`$env:GITLAB_TOKEN = '$Token'
`$env:GITLAB_SUBFOLDER = '$Subfolder'
if ('$Mode' -ne 'none') {
    `$_l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    `$_l.Start()
    `$env:GLAB_PROBE_PORT = [string]`$_l.LocalEndpoint.Port
    Write-Host "PROBE_PORT=`$env:GLAB_PROBE_PORT"
    if ('$Mode' -eq 'closed') { `$_l.Stop() }
}
try { & '$script:GlabPs1' } finally {
    if ('$Mode' -eq 'open') { Write-Host "LISTENER_PENDING=`$(`$_l.Pending())"; `$_l.Stop() }
}
"@
    }

    # Driver without the probe seam: credentials only (P4-P7).
    function New-PlainDriver {
        param([string]$Dir, [string]$HostName, [string]$Token)
        Set-Content -LiteralPath (Join-Path $Dir 'driver.ps1') -Encoding UTF8 -Value @"
`$env:PATH = '$Dir;' + `$env:PATH
`$env:AGENTS_CONFIG_DIR = '$Dir'
Set-Location '$Dir'
`$env:GITLAB = 'on'
`$env:GITLAB_HOSTNAME = '$HostName'
`$env:GITLAB_TOKEN = '$Token'
& '$script:GlabPs1'
"@
    }

    function Invoke-Driver { param([string]$Dir) Invoke-PwshChild -File (Join-Path $Dir 'driver.ps1') -TimeoutSec $script:PsTimeout }

    function New-CaseDir { param([string]$Name) $d = Join-Path $TestDrive $Name; New-Item -ItemType Directory -Path $d -Force | Out-Null; $d }

    # Stub fragment for `auth login` that records argv (and optionally stdin).
    function Get-LoginFragment {
        param([string]$ArgsFile, [string]$StdinFile)
        if ($StdinFile) { "echo %* >> `"$ArgsFile`" & findstr `"^`" >> `"$StdinFile`" & exit /b 0" }
        else { "echo %* >> `"$ArgsFile`" & exit /b 0" }
    }

    function Get-FileText { param([string]$Path) if (Test-Path -LiteralPath $Path) { [System.IO.File]::ReadAllText($Path) } else { '' } }
}

Describe 'glab-ps1-install-auth-and-reachability' -Skip:(-not $IsWindows) {
    It 'P1: GITLAB=off -> exit 0, winget not called (flag gate)' {
        $d = New-CaseDir 'p1'
        $marker = Join-Path $d 'winget-called.txt'
        New-CmdStub -Directory $d -Name 'winget' -Line @('@echo off', "echo %* >> `"$marker`"", 'exit /b 0') | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'driver.ps1') -Encoding UTF8 -Value @"
`$env:PATH = '$d;' + `$env:PATH
`$env:GITLAB = 'off'
& '$script:GlabPs1'
"@
        $r = Invoke-Driver $d
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $marker | Should -Not -Exist
    }

    It '<Id>: HOSTNAME+TOKEN, open listener -> auth login with --hostname/--stdin, token on stdin only' -ForEach @(
        @{ Id = 'P2'; CheckPending = $false }
        @{ Id = 'PA'; CheckPending = $true }
    ) {
        $d = New-CaseDir $Id.ToLower()
        $auth = Join-Path $d 'auth-args.txt'
        $stdin = Join-Path $d 'auth-stdin.txt'
        New-FailingWinget $d
        New-GlabStub -Dir $d -Status 'exit /b 1' -Login (Get-LoginFragment $auth $stdin) -Config 'if "%1"=="config" (exit /b 0)'
        New-ProbeDriver -Dir $d -HostName '127.0.0.1' -Token 'glpat-test' -Subfolder '' -Mode 'open'
        $r = Invoke-Driver $d
        $authText = Get-FileText $auth
        $stdinText = (Get-FileText $stdin) -replace "`r", ''
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $authText | Should -Match '--hostname'
        $authText | Should -Match '127\.0\.0\.1'
        $authText | Should -Match '--stdin'
        $authText | Should -Not -Match '--token'
        $authText | Should -Not -MatchExactly 'glpat-test'
        $stdinText.TrimEnd("`n") | Should -BeExactly 'glpat-test'
        $r.Output | Should -Not -MatchExactly 'glpat-test'
        if ($CheckPending) { $r.Output | Should -MatchExactly 'LISTENER_PENDING=True' }
    }

    It 'P3: GITLAB_SUBFOLDER -> glab config set subfolder called' {
        $d = New-CaseDir 'p3'
        $auth = Join-Path $d 'auth-args.txt'
        $config = Join-Path $d 'config-args.txt'
        New-FailingWinget $d
        New-GlabStub -Dir $d -Status 'exit /b 1' -Login (Get-LoginFragment $auth) `
            -Config "if `"%1`"==`"config`" (`r`n  if `"%2`"==`"set`" (echo %* >> `"$config`" & exit /b 0)`r`n)"
        New-ProbeDriver -Dir $d -HostName '127.0.0.1' -Token 'glpat-test' -Subfolder 'group1/gitlab' -Mode 'open'
        $r = Invoke-Driver $d
        $configText = Get-FileText $config
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $configText | Should -Match 'subfolder'
        $configText | Should -Match 'group1/gitlab'
    }

    It 'P4: GITLAB=on, no creds -> auth login never called' {
        $d = New-CaseDir 'p4'
        $login = Join-Path $d 'login-called.txt'
        New-FailingWinget $d
        New-GlabStub -Dir $d -Status 'exit /b 1' -Login (Get-LoginFragment $login)
        New-PlainDriver -Dir $d -HostName '' -Token ''
        $r = Invoke-Driver $d
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $login | Should -Not -Exist
    }

    It 'P5: DNS failure -> auth login skipped, warning printed' {
        $d = New-CaseDir 'p5'
        $login = Join-Path $d 'login-called.txt'
        New-FailingWinget $d
        New-GlabStub -Dir $d -Login (Get-LoginFragment $login)
        New-PlainDriver -Dir $d -HostName 'nonexistent.test.invalid' -Token 'glpat-test'
        $r = Invoke-Driver $d
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $login | Should -Not -Exist
        $r.Output | Should -Match 'warning|unreachable|skip'
    }

    It 'P6: no HOSTNAME -> manual auth message, auth status not called' {
        $d = New-CaseDir 'p6'
        $status = Join-Path $d 'auth-status-marker.txt'
        New-FailingWinget $d
        New-GlabStub -Dir $d -Status "echo %* >> `"$status`" & exit /b 0"
        New-PlainDriver -Dir $d -HostName '' -Token ''
        $r = Invoke-Driver $d
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $status | Should -Not -Exist
        $r.Output | Should -Match 'manual|GITLAB_HOSTNAME'
    }

    It '<Id>: partial creds (<What>) -> manual message, auth status + probe not called' -ForEach @(
        @{ Id = 'PB'; What = 'HOSTNAME without TOKEN'; HostName = '127.0.0.1'; Token = '' }
        @{ Id = 'PC'; What = 'TOKEN without HOSTNAME'; HostName = ''; Token = 'glpat-test' }
    ) {
        $d = New-CaseDir $Id.ToLower()
        $status = Join-Path $d 'auth-status-marker.txt'
        New-FailingWinget $d
        New-GlabStub -Dir $d -Status "echo %* >> `"$status`" & exit /b 0"
        New-ProbeDriver -Dir $d -HostName $HostName -Token $Token -Subfolder '' -Mode 'open'
        $r = Invoke-Driver $d
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $status | Should -Not -Exist
        $r.Output | Should -MatchExactly 'LISTENER_PENDING=False'
        $r.Output | Should -Match 'manual|GITLAB_HOSTNAME|GITLAB_TOKEN'
    }

    It 'P7: unresolvable host -> DNS probe bounded under the run timeout, auth login skipped' {
        $d = New-CaseDir 'p7'
        $login = Join-Path $d 'login-called.txt'
        New-FailingWinget $d
        New-GlabStub -Dir $d -Login (Get-LoginFragment $login)
        New-PlainDriver -Dir $d -HostName 'nonexistent.test.invalid' -Token 'glpat-test'
        $r = Invoke-Driver $d
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $login | Should -Not -Exist
        $r.Seconds | Should -BeLessThan $script:PsTimeout
    }

    It 'P8: closed loopback port -> "Cannot connect to 127.0.0.1:PORT", auth login skipped' {
        $d = New-CaseDir 'p8'
        $login = Join-Path $d 'login-called.txt'
        New-FailingWinget $d
        New-GlabStub -Dir $d -Login (Get-LoginFragment $login)
        New-ProbeDriver -Dir $d -HostName '127.0.0.1' -Token 'glpat-test' -Subfolder '' -Mode 'closed'
        $r = Invoke-Driver $d
        $port = (($r.Output -split "`n") | Where-Object { $_ -cmatch '^PROBE_PORT=' } | Select-Object -First 1) -creplace '^PROBE_PORT=', ''
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $login | Should -Not -Exist
        $port | Should -Not -BeNullOrEmpty
        $r.Output.Contains("Cannot connect to 127.0.0.1:$port") | Should -BeTrue -Because $r.Output
        $r.Output | Should -Not -MatchExactly 'glpat-test'
    }

    It 'P9: unanswered connect (192.0.2.1:443) cut in under 8s, warning printed, auth login skipped' {
        $d = New-CaseDir 'p9'
        $login = Join-Path $d 'login-called.txt'
        New-FailingWinget $d
        New-GlabStub -Dir $d -Login (Get-LoginFragment $login)
        New-ProbeDriver -Dir $d -HostName '192.0.2.1' -Token 'glpat-test' -Subfolder '' -Mode 'none'
        $r = Invoke-Driver $d
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $login | Should -Not -Exist
        $r.Seconds | Should -BeLessThan 8
        $r.Output.Contains('Cannot connect to 192.0.2.1:443') | Should -BeTrue -Because $r.Output
        $r.Output | Should -Not -MatchExactly 'glpat-test'
    }
}
