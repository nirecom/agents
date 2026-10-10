# glab.ps1 - Install GitLab CLI and configure authentication
# Self-contained installer (no dotfiles sibling; see docs/architecture/gitlab-support.md).
# Usage: Called by install.ps1 or run independently

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$env:SYSTEM_OPS_APPROVED = "1"

$SCRIPT_CHECKOUT_ROOT = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# GITLAB is opt-in (default off): exit 1 means explicit ON; every other exit
# (off / unset / unrecognized / internal failure) resolves to OFF.
$_glabOn = $false
try {
    $global:LASTEXITCODE = 0
    & "$SCRIPT_CHECKOUT_ROOT\bin\get-config-var.ps1" -IsOff GITLAB off *> $null
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
$_hostname  = (& "$SCRIPT_CHECKOUT_ROOT\bin\get-config-var.ps1" GITLAB_HOSTNAME  2>$null) -join ""
$_token     = (& "$SCRIPT_CHECKOUT_ROOT\bin\get-config-var.ps1" GITLAB_TOKEN     2>$null) -join ""
$_subfolder = (& "$SCRIPT_CHECKOUT_ROOT\bin\get-config-var.ps1" GITLAB_SUBFOLDER 2>$null) -join ""
$_sshHost   = (& "$SCRIPT_CHECKOUT_ROOT\bin\get-config-var.ps1" GITLAB_SSH_HOSTNAME 2>$null) -join ""

if ($_hostname -and $_token) {
    # TCP reachability guard: name resolution + connect, 3s hard limit in total.
    # GLAB_PROBE_PORT is a test seam; production always probes 443.
    $_port = 443
    $_candidate = 0
    if ($env:GLAB_PROBE_PORT -match '^\d+$' -and [int]::TryParse($env:GLAB_PROBE_PORT, [ref]$_candidate) `
        -and $_candidate -ge 1 -and $_candidate -le 65535) {
        $_port = $_candidate
    }
    $_reachable = $false
    $_tcp = [System.Net.Sockets.TcpClient]::new()
    try {
        $_task = $_tcp.ConnectAsync($_hostname, $_port)
        if ($_task.Wait(3000)) { $_reachable = $_tcp.Connected }
    } catch {
        $_reachable = $false
    } finally {
        $_tcp.Dispose()
    }
    if (-not $_reachable) {
        Write-Warning "Cannot connect to ${_hostname}:${_port} (TCP connect failed or timed out within 3s). Skipping glab authentication."
    } else {
        Write-Host "Configuring glab authentication for $_hostname..."
        # Token on stdin, not argv: a command line is visible in every process listing.
        $_authArgs = @("auth", "login", "--hostname", $_hostname, "--stdin", "--api-protocol", "https", "--git-protocol", "ssh")
        if ($_sshHost) { $_authArgs += @("--ssh-hostname", $_sshHost) }
        $_token | & glab @_authArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "glab auth login failed (exit code $LASTEXITCODE)."
        } else {
            Write-Host "glab: authenticated." -ForegroundColor Green
            if ($_subfolder) {
                glab config set --host $_hostname subfolder $_subfolder
                Write-Host "glab: subfolder set to '$_subfolder'." -ForegroundColor Green
            }
        }
    }
} else {
    Write-Host "glab: set GITLAB_HOSTNAME and GITLAB_TOKEN in .env for automated auth," -ForegroundColor Yellow
    Write-Host "      or run 'glab auth login --hostname <host>' manually." -ForegroundColor Yellow
}

exit 0
