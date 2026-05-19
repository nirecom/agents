# claude-code.ps1 - Install Claude Code CLI via npm

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$env:SYSTEM_OPS_APPROVED = "1"

fnm env --shell powershell | Out-String | Invoke-Expression

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    throw "fnm is installed but npm not found. Run: fnm install --lts"
}

if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Host "Claude Code is already installed." -ForegroundColor DarkGray
} else {
    Write-Host "Installing Claude Code..."
    npm install -g @anthropic-ai/claude-code
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Claude Code installed." -ForegroundColor Green
    } else {
        Write-Warning "Claude Code installation failed (exit code: $LASTEXITCODE). Re-run to retry."
    }
}
