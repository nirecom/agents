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
  [string]$RepoRoot = "",
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
  # Not $repoRoot: PowerShell variable names are case-insensitive, so that name
  # would clobber the -RepoRoot parameter this script still has to forward.
  $agentsDir = Split-Path (Split-Path $scriptPath -Parent) -Parent
  $loadEnv = ((Join-Path $agentsDir 'hooks/lib/load-env.js') -replace '\\', '/')
}

$kindFile = [System.IO.Path]::GetTempFileName()
try {
  $env:GETCV_NAME    = $Name
  $env:GETCV_DEFAULT = $Default
  $env:GETCV_LOADENV = $loadEnv
  $env:GETCV_KIND_FILE = $kindFile
  $env:GETCV_REPO_ROOT = $RepoRoot
  $nodeScript = @'
const fs = require("fs");
const name = process.env.GETCV_NAME;
const exported = process.env[name];
let mod = null;
try { mod = require(process.env.GETCV_LOADENV); mod.loadDefaultEnv(); fs.writeFileSync(process.env.GETCV_KIND_FILE, "loaded"); } catch (e) { fs.writeFileSync(process.env.GETCV_KIND_FILE, "unloaded"); }
let v;
if (exported && exported.length) { v = exported; }
else if (mod && process.env.GETCV_REPO_ROOT) { v = mod.readEffectiveEnvFile(process.env.GETCV_REPO_ROOT)[name]; }
else { v = process.env[name]; }
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
        # Value withheld — see the bash sibling bin/get-config-var for why.
        Write-Error "get-config-var: unrecognized value for $Name (value withheld; caller-dependent: exit 3 — see usage header for ON vs OFF handling)"
        exit 3
      }
    }
  }
  Write-Output $val
} finally {
  Remove-Item $kindFile -ErrorAction SilentlyContinue
}
