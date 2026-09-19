# claude-code.ps1 - Install Claude Code CLI via npm

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$env:SYSTEM_OPS_APPROVED = "1"

if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Host "Claude Code is already installed." -ForegroundColor DarkGray
    $_ar = if ($env:AGENTS_ROOT) { $env:AGENTS_ROOT } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    & pwsh -NoProfile -File (Join-Path $_ar "install\lib\wait-cc-exit.ps1")
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Claude Code still running — skipping update."
        exit 0
    }
    claude update
    if ($LASTEXITCODE -ne 0) { Write-Warning "claude update failed; retry manually." }
    exit 0
} else {
    fnm env --shell powershell | Out-String | Invoke-Expression
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        Write-Warning "fnm is installed but npm not found. Run: fnm install --lts"
        exit 1
    }
    Write-Host "Installing Claude Code..."
    npm install -g @anthropic-ai/claude-code
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Claude Code installed." -ForegroundColor Green
    } else {
        Write-Warning "Claude Code installation failed (exit code: $LASTEXITCODE). Re-run to retry."
    }
}
