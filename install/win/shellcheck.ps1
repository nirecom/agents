# shellcheck.ps1 - Install ShellCheck (shell script linter)
# shellcheck is required by skills/write-code/SKILL.md's bash-file lint step

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$env:SYSTEM_OPS_APPROVED = "1"

if (Get-Command shellcheck -ErrorAction SilentlyContinue) {
    Write-Host "shellcheck is already installed: $(shellcheck --version | Select-String 'version:')" -ForegroundColor DarkGray
    return
}

Write-Host "Installing shellcheck..."
winget install koalaman.shellcheck --accept-source-agreements --accept-package-agreements
if ($LASTEXITCODE -ne 0) {
    if (Get-Command shellcheck -ErrorAction SilentlyContinue) {
        Write-Host "shellcheck already present (winget returned $LASTEXITCODE)." -ForegroundColor DarkGray
    } else {
        Write-Warning "shellcheck installation failed (exit code $LASTEXITCODE). Re-run install.ps1 to retry."
        exit 1
    }
} else {
    Write-Host "shellcheck installed." -ForegroundColor Green
}
