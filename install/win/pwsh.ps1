# pwsh.ps1 - Install or update PowerShell Core
# Install: winget. Update: GitHub Releases API (faster than winget package sync).
# Usage: Called by install.ps1 (default section)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-LatestPwshRelease {
    Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -TimeoutSec 15
}

# --- Install if not present ---
if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warning "winget not found. Install PowerShell Core manually: https://github.com/PowerShell/PowerShell"
        return
    }
    Write-Host "Installing PowerShell Core via winget..."
    winget install --id Microsoft.PowerShell --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -eq 0) {
        Write-Host "PowerShell Core installed." -ForegroundColor Green
        Write-Host "Restart your terminal to use pwsh." -ForegroundColor Yellow
    } else {
        Write-Warning "PowerShell Core installation failed (exit code: $LASTEXITCODE). Re-run install.ps1 to retry."
    }
    return
}

# --- Check for update via GitHub Releases ---
try {
    # Use the installed binary's version, not the running session's ($PSVersionTable.PSVersion
    # reflects the pre-upgrade session and would trigger repeated re-installs until restart).
    $installedPwsh = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
    $currentVersion = if (Test-Path $installedPwsh) {
        [Version]((& $installedPwsh --version) -replace 'PowerShell ', '')
    } else {
        $PSVersionTable.PSVersion
    }
    $release = Get-LatestPwshRelease
} catch {
    Write-Warning "Could not check latest PowerShell version: $($_.Exception.Message)"
    return
}
$latestVersion = [Version]($release.tag_name -replace '^v', '')

if ($latestVersion -le $currentVersion) {
    Write-Host "PowerShell Core is already up to date ($currentVersion)." -ForegroundColor DarkGray
    return
}

Write-Host "Updating PowerShell Core: $currentVersion -> $latestVersion ..."
$arch = if ([Environment]::Is64BitOperatingSystem) { 'win-x64' } else { 'win-x86' }
$msiAsset = $release.assets | Where-Object { $_.name -match "$arch\.msi$" } | Select-Object -First 1
if (-not $msiAsset) {
    Write-Warning "Could not find MSI asset for $latestVersion ($arch)."
    return
}

$msiPath = Join-Path $env:TEMP $msiAsset.name
Write-Host "Downloading $($msiAsset.name)..."
Invoke-WebRequest -Uri $msiAsset.browser_download_url -OutFile $msiPath

$proc = Start-Process msiexec -ArgumentList "/i `"$msiPath`" /quiet /norestart" -Verb RunAs -Wait -PassThru
if ($proc.ExitCode -eq 0) {
    Write-Host "PowerShell Core updated to $latestVersion. Restart your terminal." -ForegroundColor Green
} else {
    Write-Warning "MSI install failed (exit code: $($proc.ExitCode))."
}

# --- Install Pester 5 if not present ---
if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge '5.0' })) {
    Write-Host "Installing Pester 5..."
    try {
        Install-Module Pester -Force -Scope CurrentUser -SkipPublisherCheck
        Write-Host "Pester 5 installed." -ForegroundColor Green
    } catch {
        Write-Warning "Pester installation failed: $($_.Exception.Message). Run manually: Install-Module Pester -Scope CurrentUser"
    }
} else {
    Write-Host "Pester 5 is already installed." -ForegroundColor DarkGray
}
