# codex.ps1 - Install Codex CLI via npm

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (Get-Command codex -ErrorAction SilentlyContinue) {
    Write-Host "Codex is already installed." -ForegroundColor DarkGray
    $_waitScript = if ($env:WAIT_CC_EXIT_SCRIPT_OVERRIDE) { $env:WAIT_CC_EXIT_SCRIPT_OVERRIDE } else { Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "install\lib\wait-cc-exit.ps1" }
    & pwsh -NoProfile -File $_waitScript
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Claude Code still running — skipping update."
        exit 0
    }
    codex update
    if ($LASTEXITCODE -ne 0) { Write-Warning "codex update failed; retry manually." }
    exit 0
} else {
    fnm env --shell powershell | Out-String | Invoke-Expression
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        Write-Warning "fnm is installed but npm not found. Run: fnm install --lts"
        exit 1
    }
    Write-Host "Installing Codex..."
    npm install -g @openai/codex
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Codex installed." -ForegroundColor Green
    } else {
        Write-Warning "Codex installation failed (exit code: $LASTEXITCODE). Re-run to retry."
    }
}
