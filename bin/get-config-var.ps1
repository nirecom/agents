param(
  [switch]$IsOff,
  [Parameter(Mandatory=$true, Position=0)][string]$Name,
  [Parameter(Position=1)][string]$Default = ""
)
$loadEnv = (Join-Path $PSScriptRoot "..\hooks\lib\load-env.js") -replace '\\','/'
$env:GETCV_NAME    = $Name
$env:GETCV_DEFAULT = $Default
$env:GETCV_LOADENV = $loadEnv
$nodeScript = @'
try { require(process.env.GETCV_LOADENV).loadDefaultEnv(); } catch (e) {}
const v = process.env[process.env.GETCV_NAME];
process.stdout.write(v && v.length ? v : (process.env.GETCV_DEFAULT || ""));
'@
$val = & node -e $nodeScript
if ($IsOff) {
  switch -CaseSensitive ($val.ToLower()) {
    'off'      { exit 0 }
    '0'        { exit 0 }
    'false'    { exit 0 }
    'no'       { exit 0 }
    'disabled' { exit 0 }
    default    { exit 1 }
  }
}
Write-Host -NoNewline $val
