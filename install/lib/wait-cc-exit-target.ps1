# wait-cc-exit-target.ps1 — dot-source only; defines Test-CCWaitTarget, no side effects.
# Test-CCWaitTarget -Path <exe path>: $true = wait for it (Claude Code), $false = skip.
# Only the Desktop app shell is skipped: that Electron shell neither replaces the CLI
# binary nor writes ~\.claude\settings.json. The match is drive-rooted — the MSIX store
# location <Drive>:\Program Files\WindowsApps\Claude_*\app\Claude.exe, or a store moved to
# <Drive>:\WindowsApps\... — because both are admin-owned; a lookalike under a
# user-writable path (e.g. C:\Users\u\x\WindowsApps\Claude_*\...) must not dodge the wait.
# The Claude Code bundled by Desktop (...\Claude\claude-code\<ver>\claude.exe) is a real
# CC session that can rewrite settings.json, so it — like every unknown or unreadable
# path — stays a wait target.

function Test-CCWaitTarget {
    param([AllowNull()][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    return -not ($Path.Trim() -match '(?i)^[a-z]:[\\/]+(Program Files[\\/]+)?WindowsApps[\\/]+Claude_[^\\/]+[\\/]+app[\\/]+Claude\.exe$')
}
