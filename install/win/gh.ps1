# gh.ps1 - Install GitHub CLI and configure authentication
# Sibling: dotfiles/install/win/gh.ps1 (same pattern; kept separate for self-sufficiency)
# Usage: Called by install.ps1 or run independently

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$env:SYSTEM_OPS_APPROVED = "1"

if (Get-Command gh -ErrorAction SilentlyContinue) {
    Write-Host "gh is already installed: $(gh --version | Select-Object -First 1)" -ForegroundColor DarkGray
} else {
    Write-Host "Installing gh (GitHub CLI)..."
    winget install GitHub.cli --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        if (Get-Command gh -ErrorAction SilentlyContinue) {
            Write-Host "gh installed." -ForegroundColor Green
        } else {
            Write-Warning "gh installation failed (exit code $LASTEXITCODE). Re-run install.ps1 to retry."
            exit 1
        }
    } else {
        Write-Host "gh installed." -ForegroundColor Green
    }
}

# Auth: check if already authenticated (idempotency — skip login on re-runs)
gh auth status 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "gh: already authenticated — skipping gh auth login." -ForegroundColor DarkGray
} else {
    # Non-interactive guard: only attempt login in interactive sessions to prevent CI hangs.
    # UserInteractive is the primary guard (try/catch only handles exit-code failures, not hangs).
    if ([Environment]::UserInteractive) {
        try {
            gh auth login
        } catch {
            Write-Host "gh auth login did not complete; continuing installation." -ForegroundColor Yellow
        }
    } else {
        Write-Host "gh: non-interactive session — skipping gh auth login. Run 'gh auth login' manually later." -ForegroundColor Yellow
    }
}

# Add project scope (only if not already granted — idempotency)
$authStatusOut = (gh auth status 2>&1) -join "`n"
if ($authStatusOut -match 'project') {
    Write-Host "gh: project scope already granted." -ForegroundColor DarkGray
} else {
    try {
        gh auth refresh -s project
        Write-Host "gh auth project scope ready." -ForegroundColor Green
    } catch {
        Write-Host "gh auth refresh -s project did not complete; continuing installation." -ForegroundColor Yellow
    }
}
