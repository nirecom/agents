# gemini.ps1 - Install Gemini CLI via npm

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

fnm env --shell powershell | Out-String | Invoke-Expression

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    throw "fnm is installed but npm not found. Run: fnm install --lts"
}

if (Get-Command gemini -ErrorAction SilentlyContinue) {
    Write-Host "Gemini CLI is already installed." -ForegroundColor DarkGray
} else {
    Write-Host "Installing Gemini CLI..."
    npm install -g @google/gemini-cli
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Gemini CLI installed. Run: gemini auth" -ForegroundColor Green
    } else {
        Write-Warning "Gemini CLI installation failed (exit code: $LASTEXITCODE). Re-run to retry."
    }
}

if (Get-Command mmdc -ErrorAction SilentlyContinue) {
    Write-Host "Mermaid CLI (mmdc) is already installed." -ForegroundColor DarkGray
} else {
    Write-Host "Installing Mermaid CLI (mmdc)..."
    npm install -g @mermaid-js/mermaid-cli
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Mermaid CLI installed." -ForegroundColor Green
    } else {
        Write-Warning "Mermaid CLI installation failed (exit code: $LASTEXITCODE). Re-run to retry."
    }
}
