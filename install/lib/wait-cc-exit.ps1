# wait-cc-exit.ps1 — poll for Claude Code process; exit 0=clear, exit 1=timeout.
# Overrides: WAIT_CC_POLL_INTERVAL (default 3), WAIT_CC_MAX_POLLS (default 10).
# Test hook: WAIT_CC_PROCESS_OVERRIDE=none|alive|alive:N

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$interval = 3; if ($env:WAIT_CC_POLL_INTERVAL) { $interval = [int]$env:WAIT_CC_POLL_INTERVAL }
$maxPolls  = 10; if ($env:WAIT_CC_MAX_POLLS)   { $maxPolls  = [int]$env:WAIT_CC_MAX_POLLS     }

function Test-CCRunning {
    param([int]$PollCount = 0)
    $override = $env:WAIT_CC_PROCESS_OVERRIDE
    if ($override) {
        switch -Wildcard ($override) {
            'none'    { return $false }
            'alive'   { return $true  }
            'alive:*' {
                $n = [int]($override -replace '^alive:', '')
                return ($PollCount -lt $n)
            }
        }
    }
    return ($null -ne (Get-Process -Name "claude" -ErrorAction SilentlyContinue))
}

$pollCount = 0
while ($pollCount -lt $maxPolls) {
    if (-not (Test-CCRunning -PollCount $pollCount)) {
        exit 0
    }
    Write-Host "Waiting for Claude Code to exit... (poll $($pollCount + 1)/$maxPolls)" -ForegroundColor DarkGray
    Start-Sleep -Seconds $interval
    $pollCount++
}

if (-not (Test-CCRunning -PollCount $pollCount)) {
    exit 0
}

Write-Warning "Claude Code is still running after $($maxPolls * $interval)s — skipping this operation."
exit 1
