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

# Executing cases PP-ps-exec / PP-ps-env-restore live in
# tests/install/feature-2476-installer-cc-wait-once.Tests.ps1.

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
