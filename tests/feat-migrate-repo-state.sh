#!/bin/bash
# Tests for feat/migrate-repo — bin/github-issues/migration/state.sh
#
# state.sh provides the .migration-state.json helpers used by the
# orchestrate / migrate-history / migrate-todo scripts.
#
# RED: fails clean while state.sh is missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_SCRIPT="$AGENTS_DIR/bin/github-issues/migration/state.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# --- Existence gate ---------------------------------------------------------
missing=()
[ -f "$STATE_SCRIPT" ] || missing+=("bin/github-issues/migration/state.sh")
if [ "${#missing[@]}" -gt 0 ]; then
    for f in "${missing[@]}"; do
        echo "FAIL: precondition missing — $f"
    done
    echo ""
    echo "Results: 0 passed, ${#missing[@]} failed"
    exit 1
fi

# shellcheck disable=SC1090
source "$STATE_SCRIPT"

setup_tmp() {
    TMP="$(mktemp -d)"
}

teardown_tmp() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    unset STATE_FILE 2>/dev/null || true
}

# --- T1: state_init creates file with schema_version=2
setup_tmp
state_init "$TMP" >/dev/null 2>&1
if [ -f "$TMP/.migration-state.json" ] && \
   [ "$(jq -r '.schema_version' "$TMP/.migration-state.json" 2>/dev/null)" = "2" ]; then
    pass "T1: state_init creates file with schema_version=2"
else
    fail "T1: state_init did not create valid file"
fi
teardown_tmp

# --- T2: state_init is idempotent
setup_tmp
state_init "$TMP" >/dev/null 2>&1
state_load "$TMP" >/dev/null 2>&1
state_record_migrated history "entry-1" 101 "first" >/dev/null 2>&1
state_init "$TMP" >/dev/null 2>&1
state_load "$TMP" >/dev/null 2>&1
count=$(state_count_migrated history 2>/dev/null)
if [ "$count" = "1" ]; then
    pass "T2: state_init idempotent — existing data preserved"
else
    fail "T2: idempotency lost (count=$count)"
fi
teardown_tmp

# Helper: run state_should_resume and capture rc.
should_resume() {
    local kind="$1" total="$2"
    state_should_resume "$kind" "$total"
}

# --- T3: total=0 → threshold=1, migrated=0 → not resume (rc=1)
setup_tmp
state_init "$TMP" >/dev/null 2>&1
state_load "$TMP" >/dev/null 2>&1
should_resume history 0; RC=$?
if [ "$RC" -ne 0 ]; then
    pass "T3: total=0 migrated=0 → not resume"
else
    fail "T3: rc=$RC (expected non-zero)"
fi
teardown_tmp

# --- T4: total=1 migrated=1 → resume (rc=0)
setup_tmp
state_init "$TMP" >/dev/null 2>&1
state_load "$TMP" >/dev/null 2>&1
state_record_migrated history "h1" 101 "t" >/dev/null 2>&1
should_resume history 1; RC=$?
if [ "$RC" -eq 0 ]; then
    pass "T4: total=1 migrated=1 → resume"
else
    fail "T4: rc=$RC"
fi
teardown_tmp

# --- T5: total=19 migrated=1 → threshold=1 → resume
setup_tmp
state_init "$TMP" >/dev/null 2>&1
state_load "$TMP" >/dev/null 2>&1
state_record_migrated history "h1" 101 "t" >/dev/null 2>&1
should_resume history 19; RC=$?
if [ "$RC" -eq 0 ]; then
    pass "T5: total=19 migrated=1 → resume"
else
    fail "T5: rc=$RC"
fi
teardown_tmp

# --- T6: total=20 migrated=1 → threshold=1 → resume
setup_tmp
state_init "$TMP" >/dev/null 2>&1
state_load "$TMP" >/dev/null 2>&1
state_record_migrated history "h1" 101 "t" >/dev/null 2>&1
should_resume history 20; RC=$?
if [ "$RC" -eq 0 ]; then
    pass "T6: total=20 migrated=1 → resume"
else
    fail "T6: rc=$RC"
fi
teardown_tmp

# --- T7: total=100 migrated=4 → threshold=5 → not resume
setup_tmp
state_init "$TMP" >/dev/null 2>&1
state_load "$TMP" >/dev/null 2>&1
for i in 1 2 3 4; do
    state_record_migrated history "h$i" "$((100 + i))" "t$i" >/dev/null 2>&1
done
should_resume history 100; RC=$?
if [ "$RC" -ne 0 ]; then
    pass "T7: total=100 migrated=4 → not resume"
else
    fail "T7: rc=$RC"
fi
teardown_tmp

# --- T8: total=100 migrated=5 → threshold=5 → resume
setup_tmp
state_init "$TMP" >/dev/null 2>&1
state_load "$TMP" >/dev/null 2>&1
for i in 1 2 3 4 5; do
    state_record_migrated history "h$i" "$((100 + i))" "t$i" >/dev/null 2>&1
done
should_resume history 100; RC=$?
if [ "$RC" -eq 0 ]; then
    pass "T8: total=100 migrated=5 → resume"
else
    fail "T8: rc=$RC"
fi
teardown_tmp

# --- T9: state_record_migrated → state_is_migrated returns 0
setup_tmp
state_init "$TMP" >/dev/null 2>&1
state_load "$TMP" >/dev/null 2>&1
state_record_migrated history "entry-A" 101 "title A" >/dev/null 2>&1
if state_is_migrated history "entry-A"; then
    pass "T9: state_is_migrated returns 0 for recorded entry"
else
    fail "T9: state_is_migrated did not find recorded entry"
fi
teardown_tmp

# --- T10: state_is_migrated returns 1 for unknown
setup_tmp
state_init "$TMP" >/dev/null 2>&1
state_load "$TMP" >/dev/null 2>&1
if ! state_is_migrated history "never-recorded"; then
    pass "T10: state_is_migrated returns 1 for unknown entry"
else
    fail "T10: unexpectedly found unknown entry"
fi
teardown_tmp

# --- T11: state_count_migrated
setup_tmp
state_init "$TMP" >/dev/null 2>&1
state_load "$TMP" >/dev/null 2>&1
c0=$(state_count_migrated history 2>/dev/null)
state_record_migrated history "h1" 101 "t" >/dev/null 2>&1
c1=$(state_count_migrated history 2>/dev/null)
if [ "$c0" = "0" ] && [ "$c1" = "1" ]; then
    pass "T11: state_count_migrated 0 → 1"
else
    fail "T11: c0=$c0 c1=$c1"
fi
teardown_tmp

# --- T12: state_set_step
setup_tmp
state_init "$TMP" >/dev/null 2>&1
state_load "$TMP" >/dev/null 2>&1
state_set_step 4 >/dev/null 2>&1
step=$(jq -r '.current_step' "$TMP/.migration-state.json" 2>/dev/null)
if [ "$step" = "4" ]; then
    pass "T12: state_set_step updates current_step"
else
    fail "T12: current_step=$step"
fi
teardown_tmp

# --- T13: state_cleanup
setup_tmp
state_init "$TMP" >/dev/null 2>&1
state_cleanup "$TMP" >/dev/null 2>&1
if [ ! -f "$TMP/.migration-state.json" ]; then
    pass "T13: state_cleanup removes file"
else
    fail "T13: state file still present"
fi
teardown_tmp

# --- T14: state_record_migrated idempotency
setup_tmp
state_init "$TMP" >/dev/null 2>&1
state_load "$TMP" >/dev/null 2>&1
state_record_migrated history "entry-X" 101 "title X" >/dev/null 2>&1
state_record_migrated history "entry-X" 101 "title X" >/dev/null 2>&1
c=$(state_count_migrated history 2>/dev/null)
if [ "$c" = "1" ]; then
    pass "T14: state_record_migrated idempotent (count=1 after dup)"
else
    fail "T14: duplicate recorded (count=$c)"
fi
teardown_tmp

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
