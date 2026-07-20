# jq.ps1 - Install jq (JSON processor)
# jq is required by bin/compose-doc-append-entry, github-contents-write.sh, github-git-data-write.sh

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$env:SYSTEM_OPS_APPROVED = "1"

if (Get-Command jq -ErrorAction SilentlyContinue) {
    Write-Host "jq is already installed: $(jq --version)" -ForegroundColor DarkGray
    return
}

Write-Host "Installing jq..."
winget install jqlang.jq --accept-source-agreements --accept-package-agreements
if ($LASTEXITCODE -ne 0) {
    if (Get-Command jq -ErrorAction SilentlyContinue) {
        Write-Host "jq already present (winget returned $LASTEXITCODE)." -ForegroundColor DarkGray
    } else {
        Write-Warning "jq installation failed (exit code $LASTEXITCODE). Re-run install.ps1 to retry."
        exit 1
    }
} else {
    Write-Host "jq installed: $(jq --version)" -ForegroundColor Green
}
