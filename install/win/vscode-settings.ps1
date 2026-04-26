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
    # Back up before modifying
    Copy-Item $SettingsFile "$SettingsFile.bak" -Force
}

# Merge patch into existing
foreach ($Key in $Patch.Keys) {
    $Existing[$Key] = $Patch[$Key]
}

$Json = $Existing | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($SettingsFile, $Json)
Write-Host "VS Code settings updated: $SettingsFile" -ForegroundColor Green
