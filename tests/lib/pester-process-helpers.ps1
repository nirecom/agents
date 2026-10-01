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
