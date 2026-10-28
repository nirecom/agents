#!/bin/bash
# tests/bin/feature-workflow-init-driver-entry-guard.sh
# Tests: tests/bin/feature-workflow-init-driver/_entry-guard.sh
# Tags: workflow-init, driver, timeout-guard, scope:issue-specific
# Pins the re-exec branches of _entry-guard.sh with stub timeout/perl on an isolated PATH:
# wrapped = no re-exec, unwrapped = exactly one re-exec, timeout 600, perl fallback without timeout.
set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

_TMP_ROOT="$(make_tmp)"; readonly _TMP_ROOT
trap 'rm -rf "$_TMP_ROOT"' EXIT
harness_isolate "$_TMP_ROOT/iso"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

GUARD="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-workflow-init-driver/_entry-guard.sh"
REAL_BASH="$(command -v bash)"
STUBS="$_TMP_ROOT/stubs"
PROBE="$_TMP_ROOT/probe.sh"
LOG="$_TMP_ROOT/log.txt"
mkdir -p "$STUBS"

# The stubs record their argv, drop the wrapper arguments and run the real bash on the rest.
printf '%s\n' '#!/bin/bash' 'echo "timeout $*" >>"$STUB_LOG"' 'shift 2' 'exec "$STUB_BASH" "$@"' >"$STUBS/timeout"
printf '%s\n' '#!/bin/bash' 'echo "perl $*" >>"$STUB_LOG"' 'shift 4' 'exec "$STUB_BASH" "$@"' >"$STUBS/perl"
chmod +x "$STUBS/timeout" "$STUBS/perl"
# A PATH holding only perl, so `command -v timeout` finds nothing.
mkdir -p "$_TMP_ROOT/perl-only"
cp "$STUBS/perl" "$_TMP_ROOT/perl-only/perl"
# The probe sources the real guard, then records that it got past it.
printf '%s\n' '#!/bin/bash' ". \"$GUARD\"" 'echo "ran wrapped=${_DRV_EP_WRAPPED:-}" >>"$STUB_LOG"' >"$PROBE"

# run_probe <PATH> [wrapped] — run the probe on the given PATH; the log is reset first.
run_probe() {
    : >"$LOG"
    if [ -n "${2:-}" ]; then
        env PATH="$1" STUB_LOG="$LOG" STUB_BASH="$REAL_BASH" _DRV_EP_WRAPPED=1 "$REAL_BASH" "$PROBE"
    else
        env -u _DRV_EP_WRAPPED PATH="$1" STUB_LOG="$LOG" STUB_BASH="$REAL_BASH" "$REAL_BASH" "$PROBE"
    fi
    LAST_RC=$?
}
count() { grep -c "$1" "$LOG" || true; }

case_begin "entry-guard-wrapped-no-reexec" "tests/bin/feature-workflow-init-driver/_entry-guard.sh"
run_probe "$STUBS:$PATH" wrapped
assert_eq "$(count '^timeout ')" "0"
assert_eq "$(count '^perl ')" "0"
assert_eq "$(count '^ran ')" "1"
assert_eq "$LAST_RC" "0"
case_end

case_begin "entry-guard-unwrapped-reexecs-once" "tests/bin/feature-workflow-init-driver/_entry-guard.sh"
run_probe "$STUBS:$PATH"
assert_eq "$(count '^timeout ')" "1"
assert_eq "$(count '^ran wrapped=1')" "1"
assert_eq "$LAST_RC" "0"
case_end

case_begin "entry-guard-timeout-is-600" "tests/bin/feature-workflow-init-driver/_entry-guard.sh"
run_probe "$STUBS:$PATH"
assert_eq "$(count '^timeout 600 bash ')" "1"
case_end

case_begin "entry-guard-perl-fallback-without-timeout" "tests/bin/feature-workflow-init-driver/_entry-guard.sh"
run_probe "$_TMP_ROOT/perl-only"
assert_eq "$(count '^timeout ')" "0"
assert_eq "$(count '^perl -e alarm 600; exec @ARGV -- bash ')" "1"
assert_eq "$(count '^ran wrapped=1')" "1"
assert_eq "$LAST_RC" "0"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
