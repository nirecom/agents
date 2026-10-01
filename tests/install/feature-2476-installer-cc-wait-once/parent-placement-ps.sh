# Sourced by tests/install/feature-2476-installer-cc-wait-once.sh (needs parent-placement-lib.sh).
# Static: install.ps1 runs the wait helper once, after its Node.js check
# and before the first child (dotfileslink), and publishes the verdict as WAIT_CC_RESULT.

_PP_PS1="$AGENTS_DIR/install.ps1"

# The installer body sits one level deep inside the env-restoring try/finally.
_pp_fnm="$(_pp_line "$_PP_PS1" '^[[:space:]]*Write-Host "--- Checking Node\.js \(fnm\) ---"')"
_pp_fnm_end="$(_pp_line "$_PP_PS1" '^    }[[:space:]]*$' "$_pp_fnm")"
# install.ps1 runs under $ErrorActionPreference='Stop': a bare Remove-Item on an unset
# variable throws on a normal first run, so both clears must carry -ErrorAction.
_PP_RM_RE='^[[:space:]]*Remove-Item Env:WAIT_CC_RESULT.*-ErrorAction[[:space:]]+(SilentlyContinue|Ignore)'
_pp_rm="$(_pp_line "$_PP_PS1" "$_PP_RM_RE" "$_pp_fnm_end")"
_pp_try="$(_pp_line "$_PP_PS1" '^[[:space:]]*try[[:space:]]*\{' "$_pp_rm")"
_pp_pref="$(_pp_line "$_PP_PS1" '^[[:space:]]+\$PSNativeCommandUseErrorActionPreference[[:space:]]*=[[:space:]]*\$false' "$_pp_try")"
_pp_call="$(_pp_line "$_PP_PS1" '^[[:space:]]+&[[:space:]]*pwsh .*wait-cc-exit\.ps1' "$_pp_try")"
_pp_set="$(_pp_line "$_PP_PS1" "^[[:space:]]+\\\$env:WAIT_CC_RESULT[[:space:]]*=.*LASTEXITCODE[[:space:]]+-eq[[:space:]]+0.*'clear'.*'timeout'" "$_pp_call")"
_pp_dot="$(_pp_line "$_PP_PS1" '^[[:space:]]*Invoke-InstallStep "Creating symlinks"')"
_pp_fn="$(_pp_line "$_PP_PS1" '^function Invoke-InstallStep')"
_pp_fn_end="$(_pp_line "$_PP_PS1" '^}' "$_pp_fn")"
_pp_sum="$(_pp_line "$_PP_PS1" '^if \(\$script:FailedSteps\.Count -gt 0\) \{')"
_pp_last_step="$(awk '/^[[:space:]]*Invoke-InstallStep[[:space:]]/ { n = NR } END { print n + 0 }' "$_PP_PS1")"
_pp_finally="$(_pp_line "$_PP_PS1" '^\} finally \{' "$_pp_last_step")"
_pp_clean="$(_pp_line "$_PP_PS1" "$_PP_RM_RE" "$_pp_finally")"

if [ "$_pp_fnm_end" -gt 0 ] && [ "$_pp_rm" -gt "$_pp_fnm_end" ] && [ "$_pp_call" -gt "$_pp_rm" ] \
   && [ "$_pp_set" -gt "$_pp_call" ] && [ "$_pp_dot" -gt "$_pp_set" ]; then
    pass "PP-ps-order: Remove-Item -> helper -> \$env:WAIT_CC_RESULT, after fnm check, before dotfileslink step"
else
    fail "PP-ps-order: want fnm_end < Remove-Item (-ErrorAction SilentlyContinue|Ignore) < helper < memo set < dotfileslink" \
        "fnm_end=$_pp_fnm_end rm=$_pp_rm call=$_pp_call set=$_pp_set dotfileslink=$_pp_dot"
fi

if [ "$_pp_call" -gt 0 ] && { [ "$_pp_call" -lt "$_pp_fn" ] || [ "$_pp_call" -gt "$_pp_fn_end" ]; }; then
    pass "PP-ps-toplevel: helper call sits outside Invoke-InstallStep"
else
    fail "PP-ps-toplevel: helper call missing or inside Invoke-InstallStep" "call=$_pp_call fn=$_pp_fn..$_pp_fn_end"
fi

if [ "$_pp_try" -gt 0 ] && [ "$_pp_pref" -gt "$_pp_try" ] && [ "$_pp_pref" -lt "$_pp_call" ]; then
    pass "PP-ps-native-pref: try block sets \$PSNativeCommandUseErrorActionPreference = \$false before the helper"
else
    fail "PP-ps-native-pref: want try < \$PSNativeCommandUseErrorActionPreference=\$false < helper" \
        "try=$_pp_try pref=$_pp_pref call=$_pp_call"
fi

if [ "$_pp_last_step" -gt 0 ] && [ "$_pp_finally" -gt "$_pp_last_step" ] \
   && [ "$_pp_clean" -gt "$_pp_finally" ] && [ "$_pp_clean" -lt "$_pp_sum" ]; then
    pass "PP-ps-cleanup: Remove-Item Env:WAIT_CC_RESULT in the finally after the last Invoke-InstallStep, before the summary"
else
    fail "PP-ps-cleanup: want last Invoke-InstallStep < '} finally {' < cleanup Remove-Item (-ErrorAction SilentlyContinue|Ignore) < summary if" \
        "last_step=$_pp_last_step finally=$_pp_finally clean=$_pp_clean summary=$_pp_sum"
fi

# PP-ps-exec: run the real clear lines (loose match, -ErrorAction not required here)
# under StrictMode + Stop with the variable unset; a throw means a first run aborts.
_pp_rm_any="$(_pp_line "$_PP_PS1" '^[[:space:]]*Remove-Item Env:WAIT_CC_RESULT' "$_pp_fnm_end")"
_pp_clean_any="$(_pp_line "$_PP_PS1" '^[[:space:]]*Remove-Item Env:WAIT_CC_RESULT' "$_pp_dot")"
if [ "$HAVE_PWSH" = "0" ]; then
    skip "PP-ps-exec: pwsh not on PATH"
elif [ "$_pp_rm_any" = "0" ] || [ "$_pp_clean_any" = "0" ]; then
    fail "PP-ps-exec: Remove-Item Env:WAIT_CC_RESULT lines not found" "pre=$_pp_rm_any cleanup=$_pp_clean_any"
else
    {
        echo 'Set-StrictMode -Version Latest'
        echo "\$ErrorActionPreference = 'Stop'"
        # No SetEnvironmentVariable($null) prelude: it masks the throw (verified); env -u unsets.
        sed -n "${_pp_rm_any}p;${_pp_clean_any}p" "$_PP_PS1" | tr -d '\r'
        echo "Write-Output 'PP_EXEC_OK'"
    } > "$TMP/pp-exec.ps1"
    _pp_rc=0
    _pp_out="$(env -u WAIT_CC_RESULT bash "$RWT" 60 pwsh -NoProfile -NonInteractive -File "$(np "$TMP/pp-exec.ps1")" 2>&1)" || _pp_rc=$?
    if [ "$_pp_rc" = "0" ] && printf '%s' "$_pp_out" | grep -q 'PP_EXEC_OK'; then
        pass "PP-ps-exec: both clear lines are no-ops on an unset variable under Stop"
    else
        fail "PP-ps-exec: clear line throws when WAIT_CC_RESULT is unset" \
            "rc=$_pp_rc $(printf '%s' "$_pp_out" | tr -d '\r' | head -n 3)"
    fi
fi

# PP-ps-env-restore: .\install.ps1 runs in the caller's session, so SYSTEM_OPS_APPROVED and
# WAIT_CC_RESULT must not outlive it. PATH without fnm/winget takes the fnm-check `exit 1`
# (the earliest exit inside the try); a stub git keeps core.longpaths off the real config.
if [ "$HAVE_PWSH" = "0" ] || [ "$ON_WINDOWS_BASH" = "0" ]; then
    skip "PP-ps-env-restore: install.ps1 runs only under pwsh on a Windows host"
else
    mkdir -p "$TMP/pp-env-bin"
    printf '@echo off\r\nexit /b 0\r\n' > "$TMP/pp-env-bin/git.cmd"
    cat > "$TMP/pp-env.ps1" << 'PS1EOF'
param([string]$Installer, [string]$StubDir)
$env:PATH = "$StubDir;$env:SystemRoot\System32"
foreach ($prior in '<unset>', 'prior') {
    if ($prior -eq '<unset>') { Remove-Item Env:SYSTEM_OPS_APPROVED -ErrorAction SilentlyContinue } else { $env:SYSTEM_OPS_APPROVED = $prior }
    $env:WAIT_CC_RESULT = 'clear'
    try { & $Installer *> $null } catch { Write-Output "THREW $($_.Exception.Message)" }
    $s = if (Test-Path Env:SYSTEM_OPS_APPROVED) { $env:SYSTEM_OPS_APPROVED } else { '<unset>' }
    $w = if (Test-Path Env:WAIT_CC_RESULT) { $env:WAIT_CC_RESULT } else { '<unset>' }
    Write-Output "PRIOR=$prior RC=$LASTEXITCODE SYSOPS=$s WCR=$w"
}
PS1EOF
    _pp_env_out="$(bash "$RWT" 60 pwsh -NoProfile -NonInteractive -File "$(np "$TMP/pp-env.ps1")" \
        -Installer "$(np "$_PP_PS1")" -StubDir "$(cygpath -w "$TMP/pp-env-bin")" 2>&1 | tr -d '\r')"
    if printf '%s\n' "$_pp_env_out" | grep -qx 'PRIOR=<unset> RC=1 SYSOPS=<unset> WCR=<unset>' \
       && printf '%s\n' "$_pp_env_out" | grep -qx 'PRIOR=prior RC=1 SYSOPS=prior WCR=<unset>'; then
        pass "PP-ps-env-restore: exit inside the try restores SYSTEM_OPS_APPROVED (unset/prior) and clears WAIT_CC_RESULT"
    else
        fail "PP-ps-env-restore: want SYSOPS back to its prior value and WCR=<unset> after the fnm-check exit 1" \
            "$(printf '%s' "$_pp_env_out" | head -n 4)"
    fi
fi

# feature-2215 extracts install.ps1 by these column-0 anchors; each must stay unique.
_pp_bad=""
for _pp_re in '^\$script:FailedSteps = @\(\)' '^function Invoke-InstallStep' \
              '^if \(\$script:FailedSteps\.Count -gt 0\) \{' '^Write-Host "=== Done ==='; do
    _pp_n="$(grep -cE "$_pp_re" "$_PP_PS1" || true)"
    [ "$_pp_n" = "1" ] || _pp_bad="$_pp_bad [$_pp_re]=$_pp_n"
done
if [ -z "$_pp_bad" ]; then
    pass "PP-ps-2215-anchors: the 4 feature-2215 awk anchors match exactly once each"
else
    fail "PP-ps-2215-anchors: anchor count drift" "$_pp_bad"
fi
