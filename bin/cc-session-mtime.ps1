#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$ClaudeDir = (Join-Path $HOME ".claude")
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectsDir = Join-Path $ClaudeDir "projects"
if (-not (Test-Path $ProjectsDir)) {
    Write-Warning "projects dir not found: $ProjectsDir"
    exit 0
}

Get-ChildItem -Path $ProjectsDir -Recurse -Filter "*.jsonl" |
    Where-Object { $_.Name -ne ".history.jsonl" } |
    ForEach-Object {
        $tsLine = Get-Content $_.FullName -ErrorAction SilentlyContinue |
            Where-Object { $_ -match '"timestamp":"([^"]+)"' } | Select-Object -Last 1
        if ($tsLine -match '"timestamp":"([^"]+)"') {
            $ts = $Matches[1]
            if ($DryRun) {
                Write-Host "would set $($_.FullName) mtime to $ts"
            } else {
                try { $_.LastWriteTime = [datetime]::Parse($ts).ToLocalTime() } catch {
                    Write-Warning "failed to set mtime on $($_.FullName): $_"
                }
            }
        } else {
            Write-Warning "no timestamp in $($_.FullName)"
        }
    }
