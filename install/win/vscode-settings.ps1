# vscode-settings.ps1 - Merge Copilot/Claude Code settings into VS Code user settings.json
# Usage: called from install.ps1, or directly as .\install\win\vscode-settings.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AgentsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

# Allow override for testing
if ($env:VSCODE_USER_SETTINGS_DIR) {
    $SettingsDir = $env:VSCODE_USER_SETTINGS_DIR
} else {
    $SettingsDir = "$env:APPDATA\Code\User"
}
# Canonicalize to resolve any .. sequences before use (CWE-22)
$SettingsDir = [System.IO.Path]::GetFullPath($SettingsDir)
$SettingsFile = Join-Path $SettingsDir "settings.json"

if (-not (Test-Path $SettingsDir)) {
    Write-Warning "VS Code user settings directory not found: $SettingsDir (skipping)"
    exit 0
}

# Keys to merge (last-write wins for existing keys)
$Patch = [ordered]@{
    "chat.useClaudeMdFile"                                       = $true
    "chat.useAgentsMdFile"                                       = $true
    "chat.useNestedAgentsMdFiles"                                = $false
    "github.copilot.chat.codeGeneration.useInstructionFiles"     = $true
    "chat.includeApplyingInstructions"                           = $true
    "chat.promptFiles"                                           = $true
    "chat.hookFilesLocations"                                    = @{ "$HOME\.claude" = $true }
}

# Read existing settings (treat missing or empty file as {})
$Existing = @{}
if (Test-Path $SettingsFile) {
    $Raw = Get-Content $SettingsFile -Raw -ErrorAction SilentlyContinue
    if ($Raw -and $Raw.Trim()) {
        try {
            $Existing = $Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        } catch {
            Write-Warning "settings.json contains invalid JSON — skipping to avoid corruption: $SettingsFile"
            exit 0
        }
    }
}

# Check if any patch key differs from existing (skip write if already up to date)
$_needsWrite = $false
foreach ($Key in $Patch.Keys) {
    if (-not $Existing.ContainsKey($Key)) { $_needsWrite = $true; break }
    $existingJson = $Existing[$Key] | ConvertTo-Json -Depth 10 -Compress
    $patchJson = $Patch[$Key] | ConvertTo-Json -Depth 10 -Compress
    if ($existingJson -ne $patchJson) { $_needsWrite = $true; break }
}

if (-not $_needsWrite) {
    Write-Host "VS Code settings already up to date: $SettingsFile" -ForegroundColor DarkGray
    exit 0
}

# Merge patch into existing and write
foreach ($Key in $Patch.Keys) {
    $Existing[$Key] = $Patch[$Key]
}
if (Test-Path $SettingsFile) { Copy-Item $SettingsFile "$SettingsFile.bak" -Force }
$Json = $Existing | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($SettingsFile, $Json)
Write-Host "VS Code settings updated: $SettingsFile" -ForegroundColor Green
