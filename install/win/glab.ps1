# glab.ps1 - Install GitLab CLI and configure authentication
# Sibling: dotfiles/install/win/glab.ps1 (same pattern; kept separate for self-sufficiency)
# Usage: Called by install.ps1 or run independently

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$env:SYSTEM_OPS_APPROVED = "1"

if (Get-Command glab -ErrorAction SilentlyContinue) {
    Write-Host "glab is already installed: $(glab --version | Select-Object -First 1)" -ForegroundColor DarkGray
} else {
    Write-Host "Installing glab (GitLab CLI)..."
    winget install GitLab.GLab --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        if (Get-Command glab -ErrorAction SilentlyContinue) {
            Write-Host "glab installed." -ForegroundColor Green
        } else {
            Write-Warning "glab installation failed (exit code $LASTEXITCODE). Re-run install.ps1 to retry."
            exit 1
        }
    } else {
        Write-Host "glab installed." -ForegroundColor Green
    }
}

# Auth: skip if glab not installed; check idempotency then prompt only in interactive sessions.
if (-not (Get-Command glab -ErrorAction SilentlyContinue)) {
    Write-Host "glab: not installed, skipping authentication setup." -ForegroundColor Yellow
} else {
    glab auth status 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "glab: already authenticated — skipping glab auth login." -ForegroundColor DarkGray
    } elseif ([Environment]::UserInteractive) {
        # Non-interactive guard: only attempt login in interactive sessions to prevent CI hangs.
        # UserInteractive is the primary guard (try/catch only handles exit-code failures, not hangs).
        try {
            glab auth login
        } catch {
            Write-Host "glab auth login did not complete; continuing installation." -ForegroundColor Yellow
        }
    } else {
        Write-Host "glab: non-interactive session — skipping glab auth login. Run 'glab auth login' manually later." -ForegroundColor Yellow
    }
}

# glab itself is installed at this point; auth login above is intentionally
# best-effort and leaves $LASTEXITCODE non-zero on failure without throwing,
# so the caller's exit-code check must not see its outcome.
exit 0
