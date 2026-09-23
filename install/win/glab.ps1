# glab.ps1 - Install GitLab CLI and configure authentication
# Sibling: dotfiles/install/win/glab.ps1 (same pattern; kept separate for self-sufficiency)
# Usage: Called by install.ps1 or run independently

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$env:SYSTEM_OPS_APPROVED = "1"

$AgentsRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# GITLAB is opt-in (default off): exit 1 means explicit ON; every other exit
# (off / unset / unrecognized / internal failure) resolves to OFF.
$_glabOn = $false
try {
    $global:LASTEXITCODE = 0
    & "$AgentsRoot\bin\get-config-var.ps1" -IsOff GITLAB off *> $null
    if ($LASTEXITCODE -eq 1) { $_glabOn = $true }
} catch {
    $_glabOn = $false
}

if (-not $_glabOn) {
    Write-Host "GITLAB is off (default); skipping glab installation." -ForegroundColor DarkGray
    exit 0
}

if (Get-Command glab -ErrorAction SilentlyContinue) {
    Write-Host "Updating glab (GitLab CLI)..."
    winget upgrade GLab.GLab --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Host "glab is up to date or upgrade failed (non-fatal)." -ForegroundColor DarkGray
        $global:LASTEXITCODE = 0
    } else {
        Write-Host "glab updated." -ForegroundColor Green
    }
} else {
    Write-Host "Installing glab (GitLab CLI)..."
    winget install GLab.GLab --accept-source-agreements --accept-package-agreements
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

if (-not (Get-Command glab -ErrorAction SilentlyContinue)) {
    Write-Host "glab: not installed, skipping authentication setup." -ForegroundColor Yellow
    exit 0
}

# Read auth config from .env; non-interactive when both GITLAB_HOSTNAME and GITLAB_TOKEN are set.
$_hostname  = (& "$AgentsRoot\bin\get-config-var.ps1" GITLAB_HOSTNAME  2>$null) -join ""
$_token     = (& "$AgentsRoot\bin\get-config-var.ps1" GITLAB_TOKEN     2>$null) -join ""
$_subfolder = (& "$AgentsRoot\bin\get-config-var.ps1" GITLAB_SUBFOLDER 2>$null) -join ""
$_sshHost   = (& "$AgentsRoot\bin\get-config-var.ps1" GITLAB_SSH_HOSTNAME 2>$null) -join ""

if ($_hostname -and $_token) {
    Write-Host "Configuring glab authentication for $_hostname..."
    $_authArgs = @("auth", "login", "--hostname", $_hostname, "--token", $_token, "--api-protocol", "https", "--git-protocol", "ssh")
    if ($_sshHost) { $_authArgs += @("--ssh-hostname", $_sshHost) }
    & glab @_authArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "glab auth login failed (exit code $LASTEXITCODE)."
    } else {
        Write-Host "glab: authenticated." -ForegroundColor Green
        if ($_subfolder) {
            glab config set --host $_hostname subfolder $_subfolder
            Write-Host "glab: subfolder set to '$_subfolder'." -ForegroundColor Green
        }
    }
} else {
    glab auth status 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "glab: already authenticated." -ForegroundColor DarkGray
    } else {
        Write-Host "glab: set GITLAB_HOSTNAME and GITLAB_TOKEN in .env for automated auth," -ForegroundColor Yellow
        Write-Host "      or run 'glab auth login --hostname <host>' manually." -ForegroundColor Yellow
    }
}

exit 0
