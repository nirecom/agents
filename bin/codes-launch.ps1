# Launch VS Code with session sync (push on window close via title polling).
# Invoked via `&` from profile-snippet.ps1's `codes` wrapper — every call re-reads this
# file from disk, so edits here (unlike edits to a dot-sourced function) take effect in
# already-open shells immediately, with no need to re-source $PROFILE or open a new window.
$AgentsRoot = Split-Path -Parent $PSScriptRoot

# $cmd (built below) is a command STRING executed by a child pwsh, so every value
# interpolated into it is wrapped in single quotes with embedded quotes doubled ('' is
# the PowerShell single-quote escape). Without this, a directory name or a caller
# argument containing a quote or ';' would break out of its quoting and run arbitrary
# code in the hidden window.
function _codesQuote([string]$s) { "'" + ($s -replace "'", "''") + "'" }

# Re-apply the VS Code extension's worktree-visibility patch (every extension
# auto-upgrade overwrites it) and prune stale stub sessions before the extension
# host loads — best-effort: a repair failure must never block a `codes` launch.
$_repairScript = Join-Path $AgentsRoot 'bin\vscode-cc-repair'
if (Test-Path $_repairScript) {
    try { & node $_repairScript --prune-stub-sessions } catch {}
}
$syncScript = "$AgentsRoot\bin\session-sync.ps1"
$waitScript = "$AgentsRoot\bin\wait-vscode-window.ps1"
$target = if ($args.Count -gt 0) { $args[0] } else { '.' }
if ($target -match '\.code-workspace$') {
    $name = [IO.Path]::GetFileNameWithoutExtension((Resolve-Path $target).Path)
} else {
    $name = Split-Path -Leaf (Resolve-Path $target).Path
}
$_ssOn = $false
$_getCfg = Join-Path $AgentsRoot 'bin\get-config-var.ps1'
# Save the pre-existing $LASTEXITCODE so it can be restored once the gate is finalized —
# `codes` must not leave 0/1 behind for a caller inspecting $LASTEXITCODE for an
# unrelated prior command.
$_preLastExitCode = $global:LASTEXITCODE
if (Test-Path $_getCfg) {
    try {
        # Reset first so a stale exit code cannot read as "on". *> (all streams)
        # keeps a resolver diagnostic from leaking on every `codes` invocation,
        # matching the bash sibling's stderr suppression at this call site.
        $global:LASTEXITCODE = 0
        & $_getCfg -IsOff SESSION_SYNC off *> $null
        if ($LASTEXITCODE -eq 1) { $_ssOn = $true }
    } catch { $_ssOn = $false }
}
$global:LASTEXITCODE = $_preLastExitCode
# Read CC_NATIVE_* pinned model versions from .env and resolve CLAUDE_MODEL / CLAUDE_SMALL_MODEL
# for the child window. Tier detection reads ~/.claude/settings.json so each tier var applies only
# when CC is configured for that tier, letting all four be set simultaneously without conflict.
$_prevEc = $global:LASTEXITCODE
$_pinnedModel = ""
$_pinnedSubagent = ""
if (Test-Path $_getCfg) {
    try {
        $_ccModel = ""
        $_ccSettings = Join-Path $env:USERPROFILE ".claude\settings.json"
        if (Test-Path $_ccSettings) {
            try { $_ccModel = (Get-Content $_ccSettings -Raw | ConvertFrom-Json).model } catch {}
            if (-not $_ccModel) { $_ccModel = "" }
        }
        $_tierVar = if ($_ccModel -match "fable")  { "CC_NATIVE_FABLE"  }
                    elseif ($_ccModel -match "sonnet") { "CC_NATIVE_SONNET" }
                    elseif ($_ccModel -match "haiku")  { "CC_NATIVE_HAIKU"  }
                    else                               { "CC_NATIVE_OPUS"   }
        $_pinnedModel    = & $_getCfg $_tierVar
        $_pinnedSubagent = & $_getCfg CC_NATIVE_SUBAGENT
    } catch {}
}
$global:LASTEXITCODE = $_prevEc
if ($_pinnedModel)    { Write-Host "[CC_NATIVE] CLAUDE_MODEL=$_pinnedModel" }
if ($_pinnedSubagent) { Write-Host "[CC_NATIVE] CLAUDE_SMALL_MODEL=$_pinnedSubagent" }
$codeArgs = ($args | ForEach-Object { _codesQuote "$_" }) -join ' '
# Clear gateway env vars in the CHILD pwsh only (not $env: here, which would also wipe
# the caller's shell) — prevents a leftover code-ccgw.ps1 session from misrouting a
# native `codes` launch. #2083
$_envClear = 'Remove-Item Env:ANTHROPIC_* -ErrorAction SilentlyContinue; Remove-Item Env:NODE_EXTRA_CA_CERTS -ErrorAction SilentlyContinue; '
if ($_pinnedModel)    { $_envClear += '$env:CLAUDE_MODEL = '       + (_codesQuote $_pinnedModel)   + '; ' }
if ($_pinnedSubagent) { $_envClear += '$env:CLAUDE_SMALL_MODEL = ' + (_codesQuote $_pinnedSubagent) + '; ' }
$cmd = "$_envClear" + "code.cmd --new-window $codeArgs"
if ($_ssOn) { $cmd += "; & $(_codesQuote $waitScript) $(_codesQuote $name); & $(_codesQuote $syncScript) push -Quiet" }
Start-Process pwsh -ArgumentList "-NoProfile", "-WindowStyle", "Hidden", "-Command", $cmd -WindowStyle Hidden
