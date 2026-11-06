#Requires -Version 5.1
# Restore the mtime of Claude Code session JSONL files from their last timestamp entry.
# The rule lives in `session-sync-engine restore-mtime` (#2658), shared with bin/cc-session-mtime.
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$ClaudeDir = (Join-Path $HOME ".claude")
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$engineArgs = @('restore-mtime', '--claude-dir', $ClaudeDir)
if ($DryRun) { $engineArgs += @('--dry-run', '--dry-run-style', 'set') }
$ErrorActionPreference = 'Continue'
& node (Join-Path $PSScriptRoot 'session-sync-engine') @engineArgs
exit 0
