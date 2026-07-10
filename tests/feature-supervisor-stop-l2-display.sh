#!/usr/bin/env bash
# tests/feature-supervisor-stop-l2-display.sh
# Tests: hooks/stop-l2-findings-display.js, hooks/lib/supervisor-findings-render.js
# Tags: supervisor, stop-hook, scope:issue-specific, pwsh-not-required, hook-registration
# L3 gap (what this test does NOT catch):
# - hooks/stop-l2-findings-display.js firing as a real Claude Code Stop hook
#   (settings.json Stop hook registration — verified only via live claude -p run)
# - Real transcript JSONL format differences from the minimal crafted input used here
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

# Covers the Stop-hook that surfaces alert-mode findings after session completion:
#  T1 normal (findings surfaced + findings_surfaced_at marked)
#  T2 idempotency (already surfaced → silent)
#  T3 Gate 2 (alert not completed → silent)
#  T4 Gate 3 (no findings → silent)
#  T5 fail-open (invalid JSON input → exit 0, empty stdout)

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK="$AGENTS_DIR/hooks/stop-l2-findings-display.js"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'supvsrl2'; }

if [ ! -f "$HOOK" ]; then
    skip "stop-l2-findings-display.js not present"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi
if ! command -v node >/dev/null 2>&1; then
    skip "node not available"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

node_dir() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

# Seed alert state via writeAlertState. Args: tmp_node sid phase surfaced_at last_run_at findings_json
seed_alert() {
    local tmp_node="$1" sid="$2" phase="$3" surfaced="$4" last_run="$5" findings="$6"
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const patch = { findings: $findings };
if ('$last_run' !== 'null') patch.last_run_at = '$last_run';
if ('$phase' !== 'null') patch.alert_phase = '$phase';
if ('$surfaced' !== 'null') patch.findings_surfaced_at = '$surfaced';
const ok = w.writeAlertState('$sid', patch);
if (!ok) { console.error('seed writeAlertState failed'); process.exit(3); }
" >/dev/null 2>&1
}

read_surfaced() {
    local tmp_node="$1" sid="$2"
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const st = w.readState('$sid');
process.stdout.write(String((st && st.alert && st.alert.findings_surfaced_at) || 'null'));
" 2>/dev/null
}

WARN_FINDING="[{categories:['workflow'],severity:'warning',detail:'test finding',reporter:'test'}]"

# --- T1: alert done + findings + not-yet-surfaced → additionalContext emitted, mark set ---
run_t1_normal() {
    local tmp sid tmp_node out surfaced
    tmp=$(make_tmp); sid="l2t1-sid-$$"
    tmp_node="$(node_dir "$tmp")"

    seed_alert "$tmp_node" "$sid" "done" "null" "null" "$WARN_FINDING"

    local hook_input
    hook_input=$(printf '{"session_id":"%s","transcript_path":""}' "$sid")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$HOOK" <<< "$hook_input" 2>/dev/null)
    local rc=$?

    surfaced=$(read_surfaced "$tmp_node" "$sid")
    rm -rf "$tmp"

    if [ $rc -ne 0 ]; then
        fail "T1: exit code should be 0, got $rc"; return
    fi
    if ! echo "$out" | grep -q "additionalContext"; then
        fail "T1: stdout must contain additionalContext, got: $(printf '%q' "${out:0:80}")"; return
    fi
    if ! echo "$out" | grep -q "\[EM Supervisor\]"; then
        fail "T1: stdout must contain [EM Supervisor], got: $(printf '%q' "${out:0:120}")"; return
    fi
    if [ "$surfaced" = "null" ]; then
        fail "T1: findings_surfaced_at must be set after hook runs, got 'null'"; return
    fi
    pass "T1: done + findings + not-surfaced → additionalContext emitted, findings_surfaced_at marked"
}

# --- T2: findings_surfaced_at already set → no additionalContext ---
run_t2_idempotency() {
    local tmp sid tmp_node out
    tmp=$(make_tmp); sid="l2t2-sid-$$"
    tmp_node="$(node_dir "$tmp")"

    seed_alert "$tmp_node" "$sid" "done" "2020-01-01T00:00:00.000Z" "null" "$WARN_FINDING"

    local hook_input
    hook_input=$(printf '{"session_id":"%s","transcript_path":""}' "$sid")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$HOOK" <<< "$hook_input" 2>/dev/null)
    local rc=$?
    rm -rf "$tmp"

    if [ $rc -ne 0 ]; then
        fail "T2: exit code should be 0, got $rc"; return
    fi
    if [ -n "$out" ]; then
        fail "T2: stdout must be empty when already surfaced, got: $(printf '%q' "${out:0:80}")"; return
    fi
    pass "T2: findings_surfaced_at already set → silent (idempotent)"
}

# --- T3: alert_phase=pending + last_run_at=null (not completed / not stale-pending) → silent ---
run_t3_not_completed() {
    local tmp sid tmp_node out
    tmp=$(make_tmp); sid="l2t3-sid-$$"
    tmp_node="$(node_dir "$tmp")"

    seed_alert "$tmp_node" "$sid" "pending" "null" "null" "$WARN_FINDING"

    local hook_input
    hook_input=$(printf '{"session_id":"%s","transcript_path":""}' "$sid")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$HOOK" <<< "$hook_input" 2>/dev/null)
    local rc=$?
    rm -rf "$tmp"

    if [ $rc -ne 0 ]; then
        fail "T3: exit code should be 0, got $rc"; return
    fi
    if [ -n "$out" ]; then
        fail "T3: stdout must be empty when alert not completed, got: $(printf '%q' "${out:0:80}")"; return
    fi
    pass "T3: pending + last_run_at=null (not stale-pending) → Gate 2 silent"
}

# --- T4: alert_phase=done but findings=[] → Gate (empty findings) silent ---
run_t4_no_findings() {
    local tmp sid tmp_node out
    tmp=$(make_tmp); sid="l2t4-sid-$$"
    tmp_node="$(node_dir "$tmp")"

    # done with no findings: seed phase only, empty findings array
    seed_alert "$tmp_node" "$sid" "done" "null" "null" "[]"

    local hook_input
    hook_input=$(printf '{"session_id":"%s","transcript_path":""}' "$sid")

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$HOOK" <<< "$hook_input" 2>/dev/null)
    local rc=$?
    rm -rf "$tmp"

    if [ $rc -ne 0 ]; then
        fail "T4: exit code should be 0, got $rc"; return
    fi
    if [ -n "$out" ]; then
        fail "T4: stdout must be empty with no findings, got: $(printf '%q' "${out:0:80}")"; return
    fi
    pass "T4: done + findings=[] → silent (no findings gate)"
}

# --- T5: invalid JSON input → fail-open exit 0, empty stdout ---
run_t5_invalid_json() {
    local tmp tmp_node out
    tmp=$(make_tmp)
    tmp_node="$(node_dir "$tmp")"

    out=$(WORKFLOW_PLANS_DIR="$tmp_node" AGENTS_CONFIG_DIR="$tmp_node" \
        run_with_timeout 10 node "$HOOK" <<< "not json" 2>/dev/null)
    local rc=$?
    rm -rf "$tmp"

    if [ $rc -ne 0 ]; then
        fail "T5: fail-open — exit code should be 0 for invalid JSON, got $rc"; return
    fi
    if [ -n "$out" ]; then
        fail "T5: fail-open — stdout must be empty for invalid JSON, got: $(printf '%q' "${out:0:80}")"; return
    fi
    pass "T5: invalid JSON input → fail-open exit 0, empty stdout"
}

run_t1_normal
run_t2_idempotency
run_t3_not_completed
run_t4_no_findings
run_t5_invalid_json

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
