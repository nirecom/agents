# Sourced by tests/install/feature-2284-install-cc-claude-codex-cli.sh inside a case span.
# Group E (PowerShell): a failed `cli update` must not abort the installer.

if ! command -v pwsh > /dev/null 2>&1; then
    echo "SKIP: E2/E2b require pwsh (not installed)"
else
    # E2: with PSNativeCommandUseErrorActionPreference=$false (pre-7.4 default),
    # $LASTEXITCODE-check soft-fail shape exits 0.
    cat > "$TMP_DIR/caller.ps1" << 'CALLER_PS_EOF'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
& /usr/bin/false
if ($LASTEXITCODE -ne 0) {
    Write-Warning "update failed; continuing"
}
Write-Output "continued"
exit 0
CALLER_PS_EOF
    _e2_rc=0
    _e2_out="$(pwsh -NoProfile -File "$TMP_DIR/caller.ps1" 2>&1)" || _e2_rc=$?
    if [ "$_e2_rc" = "0" ] && printf '%s' "$_e2_out" | grep -q "continued"; then
        pass "E2: PSNativeCommandUseErrorActionPreference=false — LASTEXITCODE soft-fail exits 0"
    else
        fail "E2: LASTEXITCODE soft-fail shape aborts (rc=$_e2_rc, out=$_e2_out)"
    fi

    # E2b: with PSNativeCommandUseErrorActionPreference=$true (pwsh 7.4+ default),
    # the installer must use try/catch so a failed native command is still handled gracefully.
    cat > "$TMP_DIR/caller-trycatch.ps1" << 'CALLER_TC_EOF'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
try {
    & /usr/bin/false
} catch {
    Write-Warning "update failed; continuing"
}
Write-Output "continued"
exit 0
CALLER_TC_EOF
    _e2b_rc=0
    _e2b_out="$(pwsh -NoProfile -File "$TMP_DIR/caller-trycatch.ps1" 2>&1)" || _e2b_rc=$?
    if [ "$_e2b_rc" = "0" ] && printf '%s' "$_e2b_out" | grep -q "continued"; then
        pass "E2b: PSNativeCommandUseErrorActionPreference=true — try/catch soft-fail exits 0"
    else
        fail "E2b: try/catch soft-fail shape aborts under true (rc=$_e2b_rc, out=$_e2b_out)"
    fi
fi
