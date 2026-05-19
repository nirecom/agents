# codex.ps1 - Install Codex CLI via npm

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$env:SYSTEM_OPS_APPROVED = "1"

fnm env --shell powershell | Out-String | Invoke-Expression

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    throw "fnm is installed but npm not found. Run: fnm install --lts"
}

if (Get-Command codex -ErrorAction SilentlyContinue) {
    Write-Host "Codex is already installed." -ForegroundColor DarkGray
} else {
    Write-Host "Installing Codex..."
    npm install -g @openai/codex
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Codex installed." -ForegroundColor Green
    } else {
        Write-Warning "Codex installation failed (exit code: $LASTEXITCODE). Re-run to retry."
    }
}
