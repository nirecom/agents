<#
.SYNOPSIS
  get-config-var — read a .env config var.
.DESCRIPTION
  --IsOff exit codes: 0 (OFF) | 1 (explicit ON) | 2 (unset, no default) |
  3 (unrecognized value) | 4 (internal failure).
  Usage error (missing Name): exit 64.
  Resolution: $env:AGENTS_CONFIG_DIR first, then $PSScriptRoot/../hooks/lib/load-env.js.
#>
param(
  [switch]$IsOff,
  [Parameter(Position=0)][string]$Name,
  [Parameter(Position=1)][string]$Default = ""
)

if (-not $Name) {
  Write-Error "usage: get-config-var [--IsOff] <Name> [<Default>]"
  exit 64
}

$loadEnv = $null
if ($env:AGENTS_CONFIG_DIR) {
  $candidate = Join-Path $env:AGENTS_CONFIG_DIR 'hooks/lib/load-env.js'
  if (Test-Path $candidate) { $loadEnv = ($candidate -replace '\\', '/') }
}
if (-not $loadEnv) {
  $scriptPath = $MyInvocation.MyCommand.Path
  $item = Get-Item $scriptPath -ErrorAction SilentlyContinue
  if ($item -and $item.Target) { $scriptPath = $item.Target }
  $repoRoot = Split-Path (Split-Path $scriptPath -Parent) -Parent
  $loadEnv = ((Join-Path $repoRoot 'hooks/lib/load-env.js') -replace '\\', '/')
}

$kindFile = [System.IO.Path]::GetTempFileName()
try {
  $env:GETCV_NAME    = $Name
  $env:GETCV_DEFAULT = $Default
  $env:GETCV_LOADENV = $loadEnv
  $env:GETCV_KIND_FILE = $kindFile
  $nodeScript = @'
const fs = require("fs");
try { require(process.env.GETCV_LOADENV).loadDefaultEnv(); fs.writeFileSync(process.env.GETCV_KIND_FILE, "loaded"); } catch (e) { fs.writeFileSync(process.env.GETCV_KIND_FILE, "unloaded"); }
const v = process.env[process.env.GETCV_NAME];
process.stdout.write(v && v.length ? v : (process.env.GETCV_DEFAULT || ""));
'@
  $val = & node -e $nodeScript
  if ($IsOff) {
    $kind = Get-Content $kindFile -Raw -ErrorAction SilentlyContinue
    if ($kind -ne 'loaded') { exit 4 }
    if ([string]::IsNullOrEmpty($val)) { exit 2 }
    switch -CaseSensitive ($val.ToLower()) {
      'off'   { exit 0 }
      'on'    { exit 1 }
      default {
        Write-Error "get-config-var: unrecognized value '$val' for $Name (treated as ON)"
        exit 3
      }
    }
  }
  Write-Host -NoNewline $val
} finally {
  Remove-Item $kindFile -ErrorAction SilentlyContinue
}
