<#
.SYNOPSIS
  confirm-off — fail-safe OFF/ON/ERROR resolver for plan-confirm idiom.
.DESCRIPTION
  Reads the config var KEY from $AGENTS_CONFIG_DIR/.env (via load-env.js + node)
  and maps it to stdout tokens: OFF (exit 0), ON (exit 1), ERROR (exit 2).
  'off' is the only OFF value; anything else (on, unset, unrecognized) → ON.
  Exits: 0 OFF | 1 ON | 2 ERROR | 64 usage.

  REQUIRED caller wrapping (PowerShell):
    $out = & pwsh -NoProfile -File "$env:AGENTS_CONFIG_DIR\bin\confirm-off.ps1" CONFIRM_X on
    switch ($out.Trim()) {
      'OFF'   { ... }
      'ON'    { ... }
      'ERROR' { ... }
    }
#>
param(
  [Parameter(Position=0)][string]$Key,
  [Parameter(Position=1)][string]$Default = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Key) {
  [System.Console]::Error.WriteLine("usage: confirm-off <Key> [<Default>]")
  exit 64
}

if (-not $env:AGENTS_CONFIG_DIR) {
  Write-Output "ERROR"
  [System.Console]::Error.WriteLine("confirm-off: AGENTS_CONFIG_DIR not set")
  exit 2
}

# Locate load-env.js — prefer AGENTS_CONFIG_DIR, fall back to script's repo root.
$loadEnv = $null
$candidate = Join-Path $env:AGENTS_CONFIG_DIR 'hooks/lib/load-env.js'
if (Test-Path $candidate) {
  $loadEnv = ($candidate -replace '\\', '/')
} else {
  $scriptPath = $MyInvocation.MyCommand.Path
  $item = Get-Item $scriptPath -ErrorAction SilentlyContinue
  if ($item -and $item.Target) { $scriptPath = $item.Target }
  $repoRoot = Split-Path (Split-Path $scriptPath -Parent) -Parent
  $c2 = Join-Path $repoRoot 'hooks/lib/load-env.js'
  if (Test-Path $c2) { $loadEnv = ($c2 -replace '\\', '/') }
}

if (-not $loadEnv) {
  Write-Output "ERROR"
  [System.Console]::Error.WriteLine("confirm-off: load-env.js not found")
  exit 2
}

# Run node inline — avoids a second pwsh subprocess and env-inheritance chain.
$kindFile = [System.IO.Path]::GetTempFileName()
try {
  $env:GETCV_NAME      = $Key
  $env:GETCV_DEFAULT   = $Default
  $env:GETCV_LOADENV   = $loadEnv
  $env:GETCV_KIND_FILE = $kindFile
  $nodeScript = @'
const fs = require("fs");
try {
  require(process.env.GETCV_LOADENV).loadDefaultEnv();
  fs.writeFileSync(process.env.GETCV_KIND_FILE, "loaded");
} catch (e) {
  fs.writeFileSync(process.env.GETCV_KIND_FILE, "unloaded");
}
const v = process.env[process.env.GETCV_NAME];
process.stdout.write(v && v.length ? v : (process.env.GETCV_DEFAULT || ""));
'@
  $val = & node -e $nodeScript
  $kind = Get-Content $kindFile -Raw -ErrorAction SilentlyContinue
  if ($kind -ne 'loaded') {
    Write-Output "ERROR"
    [System.Console]::Error.WriteLine("confirm-off: load-env internal failure")
    exit 2
  }
  if ([string]::IsNullOrEmpty($val)) {
    Write-Output "ON"
    exit 1
  }
  switch -CaseSensitive ($val.ToLower()) {
    'off' { Write-Output "OFF"; exit 0 }
    default { Write-Output "ON"; exit 1 }
  }
} finally {
  Remove-Item $kindFile -ErrorAction SilentlyContinue
}
