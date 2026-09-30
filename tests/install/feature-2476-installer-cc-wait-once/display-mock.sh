# Sourced by tests/install/feature-2476-installer-cc-wait-once.sh.
# Always-running counterpart of D-ps-desktop-only: one pwsh session shadows Get-Process
# with a global function returning synthetic processes, then runs the REAL helper via &
# (verified: the function wins over the cmdlet; the helper's exit sets $LASTEXITCODE).
# Pins that the Desktop exclusion drives the wait decision, not only the PID display.

_DM_DESK='C:\Program Files\WindowsApps\Claude_1.2.3.0_x64__abc\app\Claude.exe'
_DM_CLI='C:\Users\u\.local\bin\claude.exe'

cat > "$TMP/disp-mock.ps1" << 'PS1EOF'
param([string]$Helper, [string]$Scenario, [string]$Desk, [string]$Cli)
function New-MockProc([int]$Id, $Path) {
    [pscustomobject]@{ Id = $Id; Path = $Path; Name = 'claude'; ProcessName = 'claude' }
}
switch ($Scenario) {
    'desktop-only' { $global:MockProcs = @(New-MockProc 3131 $Desk) }
    'mixed'        { $global:MockProcs = @((New-MockProc 3131 $Desk), (New-MockProc 4242 $Cli)) }
    'nullpath'     { $global:MockProcs = @(New-MockProc 777 $null) }
}
# Accepts and ignores the helper's call shape (-Name "claude" -ErrorAction SilentlyContinue).
function global:Get-Process { $global:MockProcs }
Remove-Item Env:WAIT_CC_RESULT, Env:WAIT_CC_PROCESS_OVERRIDE -ErrorAction SilentlyContinue
$env:WAIT_CC_POLL_INTERVAL = '1'; $env:WAIT_CC_MAX_POLLS = '1'
$out = & $Helper *>&1 | Out-String
Write-Output "RC=$LASTEXITCODE"
Write-Output $out
PS1EOF

# _dm_run <scenario> -> DM_OUT
_dm_run() {
    DM_OUT="$(bash "$RWT" 60 pwsh -NoProfile -NonInteractive -File "$(np "$TMP/disp-mock.ps1")" \
        -Helper "$(np "$WAIT_PS")" -Scenario "$1" -Desk "$_DM_DESK" -Cli "$_DM_CLI" 2>&1 | tr -d '\r')"
}
_dm_rc()   { printf '%s\n' "$DM_OUT" | grep -qx "RC=$1"; }
_dm_has()  { printf '%s' "$DM_OUT" | grep -qE "$1"; }
_dm_diag() { printf '%s' "$DM_OUT" | grep -E 'RC=|PID|poll' | head -n 5; }

if [ "$HAVE_PWSH" = "0" ]; then
    skip "D-ps-mock: pwsh not on PATH"
elif [ ! -f "$WAIT_PS" ]; then
    fail "D-ps-mock: install/lib/wait-cc-exit.ps1 does not exist"
else
    _dm_run desktop-only
    if _dm_rc 0 && ! _dm_has 'poll [0-9]' && ! _dm_has 'PID '; then
        pass "D-ps-mock-desktop-only: Desktop-shell path only -> rc 0, no poll, no PID line"
    else
        fail "D-ps-mock-desktop-only: want RC=0, no poll, no PID" "$(_dm_diag)"
    fi

    _dm_run mixed
    if _dm_rc 1 && _dm_has 'poll [0-9]' && _dm_has 'PID 4242( |$)' && ! _dm_has 'PID 3131( |$)'; then
        pass "D-ps-mock-mixed: CLI + Desktop -> waits on CLI (rc 1), PID 4242 shown, Desktop PID hidden"
    else
        fail "D-ps-mock-mixed: want RC=1, poll line, 'PID 4242', no 'PID 3131'" "$(_dm_diag)"
    fi

    _dm_run nullpath
    if _dm_rc 1 && _dm_has 'PID 777 .*\(unknown\)'; then
        pass "D-ps-mock-nullpath: Path=\$null counts as a wait target (rc 1), 'PID 777  (unknown)'"
    else
        fail "D-ps-mock-nullpath: want RC=1 and 'PID 777  (unknown)'" "$(_dm_diag)"
    fi
fi
