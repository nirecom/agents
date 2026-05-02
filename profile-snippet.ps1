# Sourced from dotfiles' profile.ps1 (sibling-detected) or directly from $PROFILE.
# Idempotent — safe to source twice.
$AgentsRoot = $PSScriptRoot
$env:AGENTS_CONFIG_DIR = $AgentsRoot
$env:AGENTS_DIR        = $AgentsRoot

$_agentSymlinks = @("$HOME\.claude\CLAUDE.md")
$_agentBroken = $_agentSymlinks | Where-Object {
    (Test-Path $_) -and -not ((Get-Item $_ -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
}
if ($_agentBroken) {
    Write-Host "Repairing $($_agentBroken.Count) agents symlink(s)..." -ForegroundColor Yellow
    & "$AgentsRoot\install\win\dotfileslink.ps1"
}
Remove-Variable _agentSymlinks, _agentBroken -ErrorAction SilentlyContinue
