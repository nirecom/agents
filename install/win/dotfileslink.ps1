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

function Write-Launcher {
    param([string]$Path, [string]$Content, [string]$Label)
    if ((Test-Path $Path) -and ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::ASCII) -eq $Content)) {
        Write-Host "Already generated: $Label" -ForegroundColor DarkGray
    } else {
        [System.IO.File]::WriteAllText($Path, $Content, [System.Text.Encoding]::ASCII)
        Write-Host "Generated: $Label" -ForegroundColor Green
    }
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
    @{ Source = "skills";      Dest = "$ClaudeDir\skills";      IsDir = $true }
    @{ Source = "rules";       Dest = "$ClaudeDir\rules";       IsDir = $true }
    @{ Source = "agents";      Dest = "$ClaudeDir\agents";      IsDir = $true }
)

foreach ($link in $links) {
    $source = Join-Path $AgentsRoot $link.Source
    $dest = $link.Dest
    if (-not (Test-Path $source)) { Write-Warning "Source not found: $source (skipping)"; continue }
    $item = Get-Item $dest -Force -ErrorAction SilentlyContinue
    if ($item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $target = $item.Target
            if ($target -and [System.IO.Path]::GetFullPath($target) -eq [System.IO.Path]::GetFullPath($source)) { Write-Host "Already linked: $dest" -ForegroundColor DarkGray; continue }
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

# --- Assemble ~/.claude/settings.json from base + extension ---
# Remove stale symlink that used to point settings.json directly into agents/
$staleSettings = "$ClaudeDir\settings.json"
$staleItem = Get-Item $staleSettings -Force -ErrorAction SilentlyContinue
if ($staleItem -and ($staleItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    Remove-Item $staleSettings -Force
    Write-Host "Removed stale symlink: $staleSettings" -ForegroundColor Yellow
}
& node (Join-Path $AgentsRoot "install\assemble-settings.js")
if ($LASTEXITCODE -ne 0) { throw "assemble-settings.js failed (exit $LASTEXITCODE)" }

# --- git core.hooksPath ---
$_hooksPath = "$AgentsRoot\hooks"
$_currentHooksPath = git config --file "$HOME\.gitconfig" core.hooksPath 2>$null
if ($_currentHooksPath -eq $_hooksPath) {
    Write-Host "core.hooksPath already set: $_hooksPath" -ForegroundColor DarkGray
} else {
    git config --file "$HOME\.gitconfig" core.hooksPath $_hooksPath
    Write-Host "core.hooksPath -> $_hooksPath" -ForegroundColor Green
}

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
Write-Launcher "$LocalBin\doc-append.cmd" $cmdContent "doc-append.cmd"

# --- ~/.local/bin/doc-append-plain.cmd launcher ---
$dapCmdContent = "@echo off`r`nuv run `"$AgentsRoot\bin\doc-append-plain.py`" %*`r`n"
Write-Launcher "$LocalBin\doc-append-plain.cmd" $dapCmdContent "doc-append-plain.cmd"

# --- ~/.local/bin/repo-visibility.cmd launcher ---
$rvCmdContent = "@echo off`r`nuv run `"$AgentsRoot\bin\repo-visibility.py`" %*`r`n"
Write-Launcher "$LocalBin\repo-visibility.cmd" $rvCmdContent "repo-visibility.cmd"

# Convert AgentsRoot Windows path to bash-compatible Unix path
$agentsDrive = $AgentsRoot[0].ToString().ToLower()
$agentsUnixPath = "/$agentsDrive" + $AgentsRoot.Substring(2).Replace('\', '/')

# --- ~/.local/bin/review-code-codex launchers (cmd + bash shim) ---
$rcCmdContent = "@echo off`r`nwsl bash -c ""review-code-codex %*""`r`n"
Write-Launcher "$LocalBin\review-code-codex.cmd" $rcCmdContent "review-code-codex.cmd"
$rcShimContent = "#!/usr/bin/env bash`nexec bash `"$agentsUnixPath/bin/review-code-codex`" `"`$@`"`n"
Write-Launcher "$LocalBin\review-code-codex" $rcShimContent "review-code-codex (bash shim)"

# --- ~/.local/bin/review-plan-codex launchers (cmd + bash shim) ---
$rpcCmdContent = "@echo off`r`nwsl bash -c ""review-plan-codex %*""`r`n"
Write-Launcher "$LocalBin\review-plan-codex.cmd" $rpcCmdContent "review-plan-codex.cmd"
$rpcShimContent = "#!/usr/bin/env bash`nexec bash `"$agentsUnixPath/bin/review-plan-codex`" `"`$@`"`n"
Write-Launcher "$LocalBin\review-plan-codex" $rpcShimContent "review-plan-codex (bash shim)"

# --- ~/.local/bin/draw-diagram launchers (cmd + bash shim) ---
$ddCmdContent = "@echo off`r`nwsl bash -c ""draw-diagram %*""`r`n"
Write-Launcher "$LocalBin\draw-diagram.cmd" $ddCmdContent "draw-diagram.cmd"
$ddShimContent = "#!/usr/bin/env bash`nexec bash `"$agentsUnixPath/bin/draw-diagram`" `"`$@`"`n"
Write-Launcher "$LocalBin\draw-diagram" $ddShimContent "draw-diagram (bash shim)"

# --- ~/.local/bin/draw-diagram-gemini launchers (cmd + bash shim) ---
$ddgCmdContent = "@echo off`r`nwsl bash -c ""draw-diagram-gemini %*""`r`n"
Write-Launcher "$LocalBin\draw-diagram-gemini.cmd" $ddgCmdContent "draw-diagram-gemini.cmd"
$ddgShimContent = "#!/usr/bin/env bash`nexec bash `"$agentsUnixPath/bin/draw-diagram-gemini`" `"`$@`"`n"
Write-Launcher "$LocalBin\draw-diagram-gemini" $ddgShimContent "draw-diagram-gemini (bash shim)"
