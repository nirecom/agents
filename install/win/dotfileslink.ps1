# dotfileslink.ps1 - Create ~/.claude/ symlinks, set git hooksPath, write profile snippet
# Usage: Called by install.ps1, or run manually in PowerShell

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AgentsRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))

# Check Developer Mode / Admin for symlink capability
$regKey = Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock -ErrorAction SilentlyContinue
$devMode = if ($regKey -and ($regKey.PSObject.Properties.Name -contains "AllowDevelopmentWithoutDevLicense")) {
    $regKey.AllowDevelopmentWithoutDevLicense
} else { $false }
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$canSymlink = $devMode -or $isAdmin

if (-not $canSymlink) {
    Write-Warning "Cannot create symlinks: Developer Mode not enabled and not running as Administrator."
    exit 1
}

# --- ~/.claude/ symlinks ---
$ClaudeDir = "$HOME\.claude"
if (-not (Test-Path $ClaudeDir)) { New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null }

$oldCommands = "$ClaudeDir\commands"
if ((Test-Path $oldCommands) -and (Get-Item $oldCommands -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    Write-Host "Removing obsolete symlink: $oldCommands" -ForegroundColor Yellow
    Remove-Item $oldCommands -Force
}

$links = @(
    @{ Source = "CLAUDE.md";   Dest = "$ClaudeDir\CLAUDE.md";   IsDir = $false }
    @{ Source = "settings.json"; Dest = "$ClaudeDir\settings.json"; IsDir = $false }
    @{ Source = "skills";      Dest = "$ClaudeDir\skills";      IsDir = $true }
    @{ Source = "rules";       Dest = "$ClaudeDir\rules";       IsDir = $true }
    @{ Source = "agents";      Dest = "$ClaudeDir\agents";      IsDir = $true }
)

foreach ($link in $links) {
    $source = Join-Path $AgentsRoot $link.Source
    $dest = $link.Dest
    if (-not (Test-Path $source)) { Write-Warning "Source not found: $source (skipping)"; continue }
    if (Test-Path $dest -PathType Any) {
        $item = Get-Item $dest -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            if ($item.Target -eq $source) { Write-Host "Already linked: $dest" -ForegroundColor DarkGray; continue }
            Write-Host "Relinking: $dest" -ForegroundColor Yellow
            Remove-Item $dest -Force
        } else {
            $backup = "$dest.bak"
            Write-Host "Backing up: $dest -> $backup" -ForegroundColor Yellow
            if (Test-Path $backup) { Remove-Item -Recurse -Force $backup }
            Rename-Item $dest $backup
        }
    }
    New-Item -ItemType SymbolicLink -Path $dest -Target $source | Out-Null
    Write-Host "Linked: $dest -> $source" -ForegroundColor Green
}

# --- git core.hooksPath ---
git config --file "$HOME\.gitconfig" core.hooksPath "$AgentsRoot\hooks"
Write-Host "core.hooksPath -> $AgentsRoot\hooks" -ForegroundColor Green

# --- ~/.local/bin/doc-append.cmd launcher ---
$LocalBin = "$HOME\.local\bin"
New-Item -ItemType Directory -Force -Path $LocalBin | Out-Null
$cmdContent = @"
@echo off
set "_ARG1=%~1"
if "%~1"=="" goto nopath
if "%_ARG1:~0,1%"=="-" goto nopath
goto haspath
:nopath
uv run "$AgentsRoot\bin\doc-append.py" docs/history.md %*
goto end
:haspath
uv run "$AgentsRoot\bin\doc-append.py" %*
:end
"@
[System.IO.File]::WriteAllText("$LocalBin\doc-append.cmd", $cmdContent, [System.Text.Encoding]::ASCII)
Write-Host "Generated: $LocalBin\doc-append.cmd" -ForegroundColor Green

# Convert AgentsRoot Windows path to bash-compatible Unix path
$agentsDrive = $AgentsRoot[0].ToString().ToLower()
$agentsUnixPath = "/$agentsDrive" + $AgentsRoot.Substring(2).Replace('\', '/')

# --- ~/.local/bin/review-code-codex launchers (cmd + bash shim) ---
$rcCmdContent = "@echo off`r`nwsl bash -c ""review-code-codex %*""`r`n"
[System.IO.File]::WriteAllText("$LocalBin\review-code-codex.cmd", $rcCmdContent, [System.Text.Encoding]::ASCII)
Write-Host "Generated: $LocalBin\review-code-codex.cmd" -ForegroundColor Green
$rcShimContent = "#!/usr/bin/env bash`nexec bash `"$agentsUnixPath/bin/review-code-codex`" `"`$@`"`n"
[System.IO.File]::WriteAllText("$LocalBin\review-code-codex", $rcShimContent, [System.Text.Encoding]::ASCII)
Write-Host "Generated: $LocalBin\review-code-codex (bash shim)" -ForegroundColor Green

# --- ~/.local/bin/review-plan-codex launchers (cmd + bash shim) ---
$rpcCmdContent = "@echo off`r`nwsl bash -c ""review-plan-codex %*""`r`n"
[System.IO.File]::WriteAllText("$LocalBin\review-plan-codex.cmd", $rpcCmdContent, [System.Text.Encoding]::ASCII)
Write-Host "Generated: $LocalBin\review-plan-codex.cmd" -ForegroundColor Green
$rpcShimContent = "#!/usr/bin/env bash`nexec bash `"$agentsUnixPath/bin/review-plan-codex`" `"`$@`"`n"
[System.IO.File]::WriteAllText("$LocalBin\review-plan-codex", $rpcShimContent, [System.Text.Encoding]::ASCII)
Write-Host "Generated: $LocalBin\review-plan-codex (bash shim)" -ForegroundColor Green
