# session-sync.ps1 - Sync Claude Code session history across machines
# Usage:
#   .\session-sync.ps1 push    # Integrate local session data and publish it
#   .\session-sync.ps1 pull    # Integrate remote session data into this machine
#   .\session-sync.ps1 status  # Show sync status
#   .\session-sync.ps1 reset   # Integrate onto the remote state without pushing (setup / recovery)
# Integration lives in bin/session-sync-engine (#2658); this entry warns about a running
# Claude Code and turns a -Quiet push result into a toast instead of a throw.

param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet("push", "pull", "status", "reset")]
    [string]$Action,

    [string]$ClaudeDir = (Join-Path $env:USERPROFILE ".claude"),

    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectsDir = Join-Path $ClaudeDir "projects"
$engine = Join-Path $PSScriptRoot "session-sync-engine"
$helperJs = Join-Path $PSScriptRoot "../hooks/lib/workflow-plans-dir.js"
$PlansDir = if (Test-Path $helperJs) {
    & node -e "process.stdout.write(require('$($helperJs -replace '\\','/')').getWorkflowPlansDir())" 2>$null
} else { $null }
if (-not $PlansDir) { $PlansDir = Join-Path $env:USERPROFILE ".workflow-plans" }

if (-not (Test-Path (Join-Path $ProjectsDir ".git"))) {
    Write-Error "Session sync not initialized. Run install.ps1 or install\win\session-sync-init.ps1 first."
    return
}

function Show-SessionToast([string]$Message) {
    # WinRT type loading requires Windows PowerShell 5.1 — invoke via powershell.exe so this works from both pwsh 7+ and PS 5.1.
    # Tag+Group: consecutive pushes replace the previous toast in Action Center instead of accumulating.
    $escaped = $Message -replace "'", "''"
    $script = @"
[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
`$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
`$text = `$xml.GetElementsByTagName('text')
[void]`$text.Item(0).AppendChild(`$xml.CreateTextNode('session-sync'))
[void]`$text.Item(1).AppendChild(`$xml.CreateTextNode('$escaped'))
`$toast = [Windows.UI.Notifications.ToastNotification]::new(`$xml)
`$toast.Tag = 'session-sync'
`$toast.Group = 'session-sync'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('PowerShell').Show(`$toast)
"@
    powershell.exe -NoProfile -Command $script 2>&1 | Out-Null
}

if ($Action -eq "push" -and -not $Quiet) {
    # Transcripts still being written by a live session may be pushed half-flushed.
    if (Get-Process -Name "claude" -ErrorAction SilentlyContinue) {
        Write-Warning "Claude Code is running. Close all sessions before push to ensure latest data is saved."
    }
}

$engineArgs = @($Action, "--claude-dir", $ClaudeDir, "--plans-dir", $PlansDir)
if ($Quiet) { $engineArgs += "--quiet" }
# The engine reports on stderr; judge it by its exit code only (#1757).
$prevEap = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    & node $engine @engineArgs
    $rc = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prevEap
}

if ($Quiet) {
    if ($Action -eq "push") {
        if ($rc -eq 0) { Show-SessionToast "push complete" }
        else { Show-SessionToast "push failed (exit code $rc)" }
    }
    return
}
if ($rc -ne 0) { throw "session-sync $Action failed with exit code $rc" }
