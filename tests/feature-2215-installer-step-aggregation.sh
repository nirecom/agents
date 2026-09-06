#!/usr/bin/env bash
# tests/feature-2215-installer-step-aggregation.sh
# Tests: install.ps1
# Tags: installer, powershell, step-aggregation, fail-safe, TL2, pwsh-required, scope:issue-specific
# install.ps1 missed a sub-script `exit N` and aborted at the first `throw`;
# Invoke-InstallStep + the summary fix both. Both blocks are extracted from
# install.ps1 at run time (running it for real would mutate the machine).
# TL3 gap: extraction cannot prove every call site routes through the wrapper —
# only a full installer run on a throwaway Windows host covers that.
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_PS1="$AGENTS_DIR/install.ps1"
RUN_WITH_TIMEOUT="$AGENTS_DIR/bin/run-with-timeout.sh"
CASE_TIMEOUT=60

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
assert_contains() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) pass "$name" ;;
        *) fail "$name — want substring $(printf '%q' "$needle") in $(printf '%q' "$hay")" ;;
    esac
}

# Skip gate: this suite drives real PowerShell. No shell, no verdict.
PS_BIN=""
for c in pwsh powershell powershell.exe; do
    if command -v "$c" >/dev/null 2>&1; then PS_BIN="$c"; break; fi
done
if [ -z "$PS_BIN" ]; then
    echo "SKIP-ENV: no pwsh/powershell on PATH — install.ps1's aggregation cannot be exercised"
    exit 77
fi
[ -f "$INSTALL_PS1" ] || { echo "FAIL: install.ps1 is missing"; exit 1; }

win_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
ps_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT

# The failure accumulator plus Invoke-InstallStep, up to the function's closing brace.
FUNC_BLOCK="$(awk '
    /^\$script:FailedSteps = @\(\)/ { on = 1 }
    on { print }
    /^function Invoke-InstallStep/ { infn = 1 }
    infn && /^\}/ { exit }
' "$INSTALL_PS1")"
# The end-of-run summary, up to and including the success line.
SUMMARY_BLOCK="$(awk '
    /^if \(\$script:FailedSteps\.Count -gt 0\) \{/ { on = 1 }
    on { print }
    on && /^Write-Host "=== Done ===/ { exit }
' "$INSTALL_PS1")"

# X1/X2 guard the extraction itself: a renamed block would otherwise leave every
# case below driving an empty harness and passing for free.
case "$FUNC_BLOCK" in
    *"function Invoke-InstallStep"*'$script:FailedSteps += $Name'*)
        pass "X1: Invoke-InstallStep and the failure accumulator were extracted from install.ps1" ;;
    *) fail "X1: could not extract Invoke-InstallStep from install.ps1 — got $(printf '%q' "$FUNC_BLOCK")" ;;
esac
case "$SUMMARY_BLOCK" in
    *"=== Failed ("*"=== Done ==="*)
        pass "X2: the end-of-run summary was extracted from install.ps1" ;;
    *) fail "X2: could not extract the summary block from install.ps1 — got $(printf '%q' "$SUMMARY_BLOCK")" ;;
esac

# write_step <path> <ok|exit1|throw|marker> [marker-path]
write_step() {
    local path="$1" kind="$2" marker="${3:-}"
    case "$kind" in
        ok)     printf 'Write-Host "step ran"\n' > "$path" ;;
        exit1)  printf 'Write-Host "step ran"\nexit 1\n' > "$path" ;;
        throw)  printf 'Write-Host "step ran"\nthrow "boom"\n' > "$path" ;;
        marker) printf 'Write-Host "step ran"\nNew-Item -ItemType File -Path "%s" -Force | Out-Null\n' "$marker" > "$path" ;;
        *)      fail "harness bug: unknown step kind '$kind'"; return 1 ;;
    esac
}

# run_harness <case> <kindA> <kindB> <kindC> — a driver made of the extracted
# function, three Invoke-InstallStep calls over dummy sub-scripts, and the
# extracted summary. Publishes $OUT, $RC and $MARKER.
run_harness() {
    local case_id="$1" kind_a="$2" kind_b="$3" kind_c="$4"
    local dir="$BASE/$case_id"
    rm -rf "$dir"; mkdir -p "$dir"
    MARKER="$dir/step-c-ran.txt"
    write_step "$dir/a.ps1" "$kind_a" "$(ps_path "$MARKER")"
    write_step "$dir/b.ps1" "$kind_b" "$(ps_path "$MARKER")"
    write_step "$dir/c.ps1" "$kind_c" "$(ps_path "$MARKER")"
    {
        printf '$ErrorActionPreference = "Stop"\n'
        printf '%s\n' "$FUNC_BLOCK"
        printf 'Invoke-InstallStep "StepA" "%s"\n' "$(ps_path "$dir/a.ps1")"
        printf 'Invoke-InstallStep "StepB" "%s"\n' "$(ps_path "$dir/b.ps1")"
        printf 'Invoke-InstallStep "StepC" "%s"\n' "$(ps_path "$dir/c.ps1")"
        printf '%s\n' "$SUMMARY_BLOCK"
        printf 'exit 0\n'
    } > "$dir/driver.ps1"
    RC=0
    OUT="$(bash "$RUN_WITH_TIMEOUT" "$CASE_TIMEOUT" "$PS_BIN" -NoProfile -NonInteractive \
        -File "$(win_path "$dir/driver.ps1")" 2>&1)" || RC=$?
}

echo "--- I1: a sub-script that exits non-zero is recorded as failed and the installer exits 1 ---"
# `exit N` is not a terminating error: without the $LASTEXITCODE check the run
# would report success over a step that did nothing.
run_harness i1 ok exit1 ok
assert_eq "I1: the installer exits 1" "1" "$RC"
assert_contains "I1: the summary counts exactly one failed step" "=== Failed (1 step(s)) ===" "$OUT"
assert_contains "I1: the summary names the failing step" "  - StepB" "$OUT"

echo "--- I2: a sub-script that throws is recorded AND every later step still runs ---"
# The marker file is StepC's proof that the throw no longer aborts the installer.
run_harness i2 ok throw marker
assert_eq "I2: the installer exits 1" "1" "$RC"
assert_contains "I2: the summary counts exactly one failed step" "=== Failed (1 step(s)) ===" "$OUT"
assert_contains "I2: the summary names the throwing step" "  - StepB" "$OUT"
assert_eq "I2: the step after the throwing one still ran" "ran" \
    "$([ -f "$MARKER" ] && echo ran || echo skipped)"

echo "--- I3: all steps succeed — the success path is not collateral damage ---"
run_harness i3 ok ok ok
assert_eq "I3: the installer exits 0" "0" "$RC"
assert_contains "I3: the run reports success" "=== Done ===" "$OUT"
case "$OUT" in
    *"=== Failed ("*) fail "I3: an all-green run must not print a failure summary — got $(printf '%q' "$OUT")" ;;
    *) pass "I3: no failure summary on an all-green run" ;;
esac

echo "--- I4: the inline \$PROFILE-sourcing block is guarded like every Invoke-InstallStep call ---"
# Static text-scan (not a harness run): the profile-sourcing block runs inline,
# ahead of 5 more Invoke-InstallStep calls, under the global Stop preference —
# an uncaught exception there (e.g. a read-only $PROFILE) would abort the whole
# installer before vscode-settings/global-gitignore/gh/jq/shellcheck/codegraph
# ever ran, the same collateral-failure class Invoke-InstallStep exists to close.
PROFILE_BLOCK="$(awk '
    /Adding profile sourcing/ { on = 1 }
    on { print }
    on && /^Remove-Variable _snippetPath/ { exit }
' "$INSTALL_PS1")"
case "$PROFILE_BLOCK" in
    *"try {"*"catch {"*'$script:FailedSteps += "Adding profile sourcing"'*)
        pass "I4: the profile-sourcing block is wrapped in try/catch and reports into FailedSteps" ;;
    *) fail "I4: the profile-sourcing block is not guarded — an exception here would abort the installer before later steps run — got $(printf '%q' "$PROFILE_BLOCK")" ;;
esac

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
