# Shared process/env helpers for installer Pester suites that execute .ps1 sources.
# Dot-source from a Pester BeforeAll so the functions land in the calling container.
# Invoke-PwshChild runs a script in a child pwsh with a per-call environment overlay
# (the parent environment is never mutated), merged output, exit code, and a timeout.

Set-StrictMode -Version Latest

$script:PwshExe = (Get-Process -Id $PID).Path

function Invoke-PwshChild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$File,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{},
        [int]$TimeoutSec = 60,
        [string]$WorkingDirectory
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:PwshExe
    foreach ($a in @('-NoProfile', '-NonInteractive', '-File', $File) + $ArgumentList) {
        $psi.ArgumentList.Add($a)
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    foreach ($k in $Environment.Keys) {
        if ($null -eq $Environment[$k]) {
            [void]$psi.Environment.Remove($k)
        } else {
            $psi.Environment[$k] = [string]$Environment[$k]
        }
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $timedOut = -not $p.WaitForExit($TimeoutSec * 1000)
    if ($timedOut) { $p.Kill($true) }
    $p.WaitForExit()
    $sw.Stop()
    $stdout = $outTask.Result -replace "`r", ''
    $stderr = $errTask.Result -replace "`r", ''
    [pscustomobject]@{
        ExitCode = if ($timedOut) { 124 } else { $p.ExitCode }
        StdOut   = $stdout
        StdErr   = $stderr
        Output   = $stdout + $stderr
        Seconds  = $sw.Elapsed.TotalSeconds
        TimedOut = $timedOut
    }
}

# New-CmdStub <dir> <name> <body-lines> — writes <dir>\<name>.cmd (CRLF, ASCII).
function New-CmdStub {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Line
    )
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $path = Join-Path $Directory "$Name.cmd"
    [System.IO.File]::WriteAllText($path, (($Line -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
    $path
}

# New-InstallerStubSet — one PATH-first stub directory for the installer .ps1 tests (#2808):
#   <Cli> (claude|codex)  appends "<cli> <args>" to Log, exits CliExit
#   npm                   appends "npm <args>" to Log; `prefix` echoes PrefixOut (own exit code);
#                         `install` exits NpmExit
#   fnm                   appends to Log, prints FnmOutput, exits FnmExit
#   wait helper (ps1)     takes -ProcessName (default claude), appends it to WaitLog, exits
#                         ClaudeWaitExit / CodexWaitExit; hand it over via WAIT_CC_EXIT_SCRIPT_OVERRIDE
# The stub directory doubles as the npm global prefix, so `Get-Command codex` resolves under it.
function New-InstallerStubSet {
    param(
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string]$Cli,
        [int]$CliExit = 0,
        [int]$ClaudeWaitExit = 0,
        [int]$CodexWaitExit = 0,
        [string]$PrefixOut,
        [int]$PrefixExit = 0,
        [int]$NpmExit = 0,
        [int]$FnmExit = 0,
        [string]$FnmOutput = '# noop',
        [switch]$PrefixEmpty,
        [switch]$NoNpm,
        [switch]$NpmStderr
    )
    New-Item -ItemType Directory -Path $Base -Force | Out-Null
    $stub = Join-Path $Base 'bin'
    $log  = Join-Path $Base 'call-log.txt'
    $wlog = Join-Path $Base 'wait-log.txt'
    $wait = Join-Path $Base 'wait-stub.ps1'
    New-Item -ItemType Directory -Path $stub -Force | Out-Null
    if (-not $PrefixOut) { $PrefixOut = $stub }

    [System.IO.File]::WriteAllText($wait, (@(
        'param([string]$ProcessName = ''claude'')'
        "Add-Content -LiteralPath '$($wlog -replace "'", "''")' -Value `$ProcessName"
        "if (`$ProcessName -eq 'codex') { exit $CodexWaitExit }"
        "exit $ClaudeWaitExit"
    ) -join "`n") + "`n")

    if ($IsWindows) {
        New-CmdStub -Directory $stub -Name $Cli -Line @('@echo off', "echo $Cli %* >> `"$log`"", "exit /b $CliExit") | Out-Null
        New-CmdStub -Directory $stub -Name 'fnm' -Line @('@echo off', "echo fnm %* >> `"$log`"", "echo $FnmOutput", "exit /b $FnmExit") | Out-Null
        if (-not $NoNpm) {
            $prefixLine = if ($PrefixEmpty) { 'echo.' } else { "echo $PrefixOut" }
            $lines = @(
                '@echo off'
                "echo npm %* >> `"$log`""
                'if "%1"=="prefix" goto prefix'
                'if "%1"=="install" goto install'
                'exit /b 0'
                ':prefix'
                $prefixLine
                "exit /b $PrefixExit"
                ':install'
            )
            if ($NpmStderr) { $lines += 'echo npm ERR boom 1>&2' }
            $lines += "exit /b $NpmExit"
            New-CmdStub -Directory $stub -Name 'npm' -Line $lines | Out-Null
        }
    } else {
        New-ShStub -Directory $stub -Name $Cli -Line @("echo `"$Cli `$@`" >> '$log'", "exit $CliExit") | Out-Null
        New-ShStub -Directory $stub -Name 'fnm' -Line @("echo `"fnm `$@`" >> '$log'", "echo '$FnmOutput'", "exit $FnmExit") | Out-Null
        if (-not $NoNpm) {
            $prefixCmd = if ($PrefixEmpty) { 'echo' } else { "echo '$PrefixOut'" }
            $lines = @(
                "echo `"npm `$@`" >> '$log'"
                'case "$1" in'
                "  prefix) $prefixCmd; exit $PrefixExit ;;"
                '  install)'
            )
            if ($NpmStderr) { $lines += '    echo "npm ERR boom" >&2' }
            $lines += "    exit $NpmExit ;;"
            $lines += 'esac'
            $lines += 'exit 0'
            New-ShStub -Directory $stub -Name 'npm' -Line $lines | Out-Null
        }
    }
    [pscustomobject]@{
        Stub = $stub; Prefix = $stub; Log = $log; WaitLog = $wlog; Wait = $wait
    }
}

# Invoke-StubbedInstaller — run an installer .ps1 in a child pwsh with the stub set first on PATH.
# -RestrictPath keeps only the stub dir, pwsh's dir and the OS system dir on PATH (no real npm/fnm).
# AGENTS_ROOT and the memo stay unset so the WAIT_CC_EXIT_SCRIPT_OVERRIDE seam alone redirects the helper.
function Invoke-StubbedInstaller {
    param(
        [Parameter(Mandatory)][string]$Installer,
        [Parameter(Mandatory)]$Set,
        [hashtable]$Environment = @{},
        [switch]$RestrictPath,
        [int]$TimeoutSec = 90,
        [string]$WorkingDirectory
    )
    $sep = [IO.Path]::PathSeparator
    $path = if ($RestrictPath) {
        $dirs = @($Set.Stub, (Split-Path -Parent $script:PwshExe))
        if ($IsWindows) { $dirs += (Join-Path $env:SystemRoot 'System32') } else { $dirs += @('/usr/bin', '/bin') }
        $dirs -join $sep
    } else { $Set.Stub + $sep + $env:PATH }
    $envMap = @{
        PATH                         = $path
        AGENTS_ROOT                  = $null
        WAIT_CC_EXIT_SCRIPT_OVERRIDE = $Set.Wait
        WAIT_CC_RESULT               = $null
    }
    foreach ($k in $Environment.Keys) { $envMap[$k] = $Environment[$k] }
    $childArgs = @{ File = $Installer; TimeoutSec = $TimeoutSec; Environment = $envMap }
    if ($WorkingDirectory) { $childArgs['WorkingDirectory'] = $WorkingDirectory }
    $r = Invoke-PwshChild @childArgs
    # Outer @() keeps an empty log an empty array: an `if` statement that emits @() yields $null.
    $calls = @(if (Test-Path -LiteralPath $Set.Log)     { Get-Content -LiteralPath $Set.Log })
    $waits = @(if (Test-Path -LiteralPath $Set.WaitLog) { Get-Content -LiteralPath $Set.WaitLog })
    [pscustomobject]@{
        ExitCode = $r.ExitCode; Output = $r.Output; Calls = $calls; Waits = $waits
        NpmInstalled = [bool]($calls | Where-Object { $_ -match '^npm install -g @openai/codex' })
        CodexUpdated = [bool]($calls | Where-Object { $_ -match '^codex update' })
        Updated = [bool]($calls | Where-Object { $_ -match '^(claude|codex) update' })
    }
}

# New-ShStub <dir> <name> <body-lines> — extensionless bash stub for non-Windows pwsh.
function New-ShStub {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Line
    )
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $path = Join-Path $Directory $Name
    [System.IO.File]::WriteAllText($path, (@('#!/bin/bash') + $Line -join "`n") + "`n")
    if (-not $IsWindows) { & chmod +x $path }
    $path
}
