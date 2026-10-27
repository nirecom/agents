# wait-cc-exit.ps1 — poll for a running CLI process; exit 0=clear, exit 1=timeout.
# -ProcessName claude (default; no argument = the original Claude Code wait) | codex.
# Overrides: WAIT_CC_POLL_INTERVAL (default 3), WAIT_CC_MAX_POLLS (default 10), shared by both names.
# WAIT_CC_RESULT=clear|timeout (set once by install.ps1) answers at once without polling — claude
# only: the memo measured claude, and reusing it for codex would update over a running codex.
# Desktop app shell exclusion (Test-CCWaitTarget) applies to claude only.
# Test hooks: WAIT_CC_PROCESS_OVERRIDE (claude) / WAIT_CODEX_PROCESS_OVERRIDE (codex) = none|alive|alive:N

param(
    [ValidateSet('claude', 'codex')][string]$ProcessName = 'claude'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$targetConfig = @{
    claude = @{ Display = 'Claude Code'; Seam = 'WAIT_CC_PROCESS_OVERRIDE'; UseMemo = $true; Filter = $true }
    codex  = @{ Display = 'Codex'; Seam = 'WAIT_CODEX_PROCESS_OVERRIDE'; UseMemo = $false; Filter = $false }
}
$target = $targetConfig[$ProcessName]

if ($target.UseMemo) {
    $memo = $env:WAIT_CC_RESULT
    if (-not [string]::IsNullOrEmpty($memo)) {
        if ($memo -ceq 'clear') { exit 0 }
        if ($memo -ceq 'timeout') { exit 1 }
        Write-Host "Ignoring invalid WAIT_CC_RESULT='$memo'; polling." -ForegroundColor DarkGray
    }
}

$interval = 3; if ($env:WAIT_CC_POLL_INTERVAL) { $interval = [int]$env:WAIT_CC_POLL_INTERVAL }
$maxPolls  = 10; if ($env:WAIT_CC_MAX_POLLS)   { $maxPolls  = [int]$env:WAIT_CC_MAX_POLLS     }

. (Join-Path $PSScriptRoot 'wait-cc-exit-target.ps1')

function Get-CCWaitTargets {
    param([int]$PollCount = 0)
    $override = [Environment]::GetEnvironmentVariable($target.Seam)
    if ($override) {
        $synthetic = [pscustomobject]@{ Id = $null; Path = $null }
        switch -Wildcard ($override) {
            'none'    { return }
            'alive'   { return $synthetic }
            'alive:*' {
                $n = [int]($override -replace '^alive:', '')
                if ($PollCount -lt $n) { return $synthetic }
                return
            }
        }
    }
    foreach ($p in @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
        $path = try { $p.Path } catch { $null }
        if (-not $target.Filter -or (Test-CCWaitTarget -Path $path)) {
            [pscustomobject]@{ Id = $p.Id; Path = $path }
        }
    }
}

$lastKey = ''
$pollCount = 0
while ($pollCount -lt $maxPolls) {
    $targets = @(Get-CCWaitTargets -PollCount $pollCount)
    if ($targets.Count -eq 0) {
        exit 0
    }
    $key = (@($targets | ForEach-Object { "$($_.Id)" }) | Sort-Object) -join ','
    if ($key -ne $lastKey) {
        foreach ($t in $targets) {
            if ($null -eq $t.Id) { continue }
            $shown = if ([string]::IsNullOrWhiteSpace($t.Path)) { '(unknown)' } else { $t.Path }
            Write-Host "  PID $($t.Id)  $shown" -ForegroundColor DarkGray
        }
        $lastKey = $key
    }
    Write-Host "Waiting for $($target.Display) to exit... (poll $($pollCount + 1)/$maxPolls)" -ForegroundColor DarkGray
    Start-Sleep -Seconds $interval
    $pollCount++
}

if (@(Get-CCWaitTargets -PollCount $pollCount).Count -eq 0) {
    exit 0
}

Write-Warning "$($target.Display) is still running after $($maxPolls * $interval)s — skipping this operation."
exit 1
