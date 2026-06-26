#!/bin/bash
# Tests: skills/workflow-init/scripts/wip-set-resume.sh
# Tags: workflow-init, wip-set-resume, wip-set-single, early-claim, clarify-intent, scope:issue-specific
#
# Feature 1117 — wip-set-resume.sh NEEDS_CLARIFY-branch early WIP claim.
#
# BEFORE the source change, the NEEDS_CLARIFY branch of wip-set-resume.sh emits
# `NEEDS_CLARIFY <N,...>` and exits 1 WITHOUT claiming WIP for any N — the WIP
# fingerprint is only set later, after clarify-intent completes. That leaves an
# OPEN non-meta issue unclaimed during the clarify window, so a concurrent
# session can grab it.
#
# AFTER the source change (Step 1), the NEEDS_CLARIFY branch must claim WIP
# EARLY for each OPEN non-meta N by calling
# `$AGENTS_CONFIG_DIR/bin/github-issues/wip-set-single.sh <N>`, gated on:
#   - state == OPEN   (never claim a CLOSED issue)
#   - label probe succeeded (empty state == probe failed → fail-safe, do NOT claim)
#   - issue is not meta (meta entries never get WIP)
# An RC2 from wip-set-single.sh propagates: emit `RC2 <N>` and exit 2.
#
# WR-1..WR-5 are RED until Step 1 rewrites wip-set-resume.sh — they assert the
# post-change behaviour (early wip-set-single.sh call + OPEN/meta/probe gates).
# WR-REG is GREEN now: it pins the all-clarified Pass-2 path that already exists.
#
# L3 gap (what these tests do NOT catch):
# - Whether the real Projects v2 API accepts the early WIP claim
# - Whether wip-set-single.sh actually flips Status=In Progress in live GitHub
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$AGENTS_DIR/skills/workflow-init/scripts/wip-set-resume.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm '"$secs"'; exec @ARGV' -- "$@"; fi
}

# --- existence gate ---------------------------------------------------------
if [ ! -f "$SUT" ]; then
    echo "FAIL: precondition — $SUT missing"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# --- mock setup -------------------------------------------------------------
# gh mock: `gh issue view <N> --json labels,state ...` returns the per-N JSON
# from GH_MOCK_LABELS_STATE_<N> (a `{"labels":[...],"state":"OPEN"}` object).
# Value "fail" → gh exits 1 (probe failure → empty STATE in the SUT). Also
# tolerates the legacy `--json labels` shape used by the all-clarified Pass-2
# path (selecting only .labels from the same object still works).
#
# wip-set-single.sh mock: records each call (one issue number per line) to
# $WIP_CALLS, then exits WIP_SINGLE_RC (default 0); echoes RC2 on rc=2.
setup_mock() {
    TMP="$(mktemp -d 2>/dev/null || mktemp -d -t wipearly)"
    mkdir -p "$TMP/mock-bin" "$TMP/bin/github-issues"
    WIP_CALLS="$TMP/wip-single-calls.log"
    : > "$WIP_CALLS"

    cat > "$TMP/mock-bin/gh" <<'MOCKGH'
#!/bin/bash
# args: issue view <N> --json labels,state [--jq ...]
N=""
prev=""
for a in "$@"; do
    if [ "$prev" = "view" ]; then N="$a"; break; fi
    prev="$a"
done
VARNAME="GH_MOCK_LABELS_STATE_${N}"
VAL="${!VARNAME:-}"
if [ "$VAL" = "fail" ]; then exit 1; fi
if [ -z "$VAL" ]; then echo '{"labels":[],"state":"OPEN"}'; exit 0; fi
echo "$VAL"
exit 0
MOCKGH
    chmod +x "$TMP/mock-bin/gh"

    cat > "$TMP/bin/github-issues/wip-set-single.sh" <<MOCKWIP
#!/bin/bash
# record the issue number argument (first non-flag positional)
n=""
for a in "\$@"; do
    case "\$a" in --*) ;; *) n="\$a"; break ;; esac
done
echo "\$n" >> "$WIP_CALLS"
rc="\${WIP_SINGLE_RC:-0}"
if [ "\$rc" = "2" ]; then echo "RC2"; fi
if [ "\$rc" = "0" ]; then echo "SET_OK"; fi
exit "\$rc"
MOCKWIP
    chmod +x "$TMP/bin/github-issues/wip-set-single.sh"

    # wip-state.sh mock for the all-clarified Pass-2 path (WR-REG).
    cat > "$TMP/bin/github-issues/wip-state.sh" <<'MOCKSTATE'
#!/bin/bash
exit "${GH_MOCK_WIP_RC:-0}"
MOCKSTATE
    chmod +x "$TMP/bin/github-issues/wip-state.sh"

    export AGENTS_CONFIG_DIR="$TMP"
    export PATH="$TMP/mock-bin:$PATH"
}

teardown_mock() {
    PATH="${PATH#$TMP/mock-bin:}"
    export PATH
    rm -rf "$TMP" 2>/dev/null || true
    for v in $(env | grep -oE '^GH_MOCK_LABELS_STATE_[0-9]+' || true); do unset "$v"; done
    unset WIP_SINGLE_RC GH_MOCK_WIP_RC WIP_CALLS 2>/dev/null || true
}

wip_called_for() {  # arg: N → 0 if recorded, 1 otherwise
    grep -qx "$1" "$WIP_CALLS" 2>/dev/null
}

# ============================================================================
# WR-1: OPEN non-meta N lacking intent:clarified → wip-set-single.sh called for
#       N; stdout has NEEDS_CLARIFY N; exit 1.
# ============================================================================
setup_mock
export GH_MOCK_LABELS_STATE_401='{"labels":["type:task"],"state":"OPEN"}'
OUT=$(run_with_timeout 10 bash "$SUT" 401 2>/dev/null)
RC=$?
if [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "NEEDS_CLARIFY" && echo "$OUT" | grep -qw "401" \
   && wip_called_for 401; then
    pass "WR-1: OPEN non-meta unclarified → early wip-set-single.sh claim, NEEDS_CLARIFY, exit 1"
else
    fail "WR-1: expected wip-set-single call + NEEDS_CLARIFY 401 + exit 1; got rc=$RC out='$OUT' calls='$(cat "$WIP_CALLS")'"
fi
teardown_mock

# ============================================================================
# WR-2: CLOSED N lacking intent:clarified → wip-set-single.sh NOT called
#       (OPEN gate blocks the claim); stdout has NEEDS_CLARIFY N; exit 1.
# ============================================================================
setup_mock
export GH_MOCK_LABELS_STATE_402='{"labels":["type:task"],"state":"CLOSED"}'
OUT=$(run_with_timeout 10 bash "$SUT" 402 2>/dev/null)
RC=$?
if [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "NEEDS_CLARIFY" && echo "$OUT" | grep -qw "402" \
   && ! wip_called_for 402; then
    pass "WR-2: CLOSED unclarified → no claim, NEEDS_CLARIFY, exit 1"
else
    fail "WR-2: expected NO wip-set-single call + NEEDS_CLARIFY 402 + exit 1; got rc=$RC out='$OUT' calls='$(cat "$WIP_CALLS")'"
fi
teardown_mock

# ============================================================================
# WR-3: label probe failed (gh returns fail → empty STATE) → wip-set-single.sh
#       NOT called (fail-safe: avoid claiming a possibly-CLOSED issue);
#       stdout has NEEDS_CLARIFY N; exit 1.
# ============================================================================
setup_mock
export GH_MOCK_LABELS_STATE_403=fail
OUT=$(run_with_timeout 10 bash "$SUT" 403 2>/dev/null)
RC=$?
if [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "NEEDS_CLARIFY" && echo "$OUT" | grep -qw "403" \
   && ! wip_called_for 403; then
    pass "WR-3: probe-failed (empty STATE) → fail-safe no claim, NEEDS_CLARIFY, exit 1"
else
    fail "WR-3: expected NO wip-set-single call + NEEDS_CLARIFY 403 + exit 1; got rc=$RC out='$OUT' calls='$(cat "$WIP_CALLS")'"
fi
teardown_mock

# ============================================================================
# WR-4: meta N lacking intent:clarified → wip-set-single.sh NOT called
#       (meta gate blocks the claim); stdout has NEEDS_CLARIFY N; exit 1.
# ============================================================================
setup_mock
export GH_MOCK_LABELS_STATE_404='{"labels":["meta","type:task"],"state":"OPEN"}'
OUT=$(run_with_timeout 10 bash "$SUT" 404 2>/dev/null)
RC=$?
if [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "NEEDS_CLARIFY" && echo "$OUT" | grep -qw "404" \
   && ! wip_called_for 404; then
    pass "WR-4: meta unclarified → no claim, NEEDS_CLARIFY, exit 1"
else
    fail "WR-4: expected NO wip-set-single call + NEEDS_CLARIFY 404 + exit 1; got rc=$RC out='$OUT' calls='$(cat "$WIP_CALLS")'"
fi
teardown_mock

# ============================================================================
# WR-5: wip-set-single.sh exits 2 (RC2) for OPEN non-meta N → wip-set-resume.sh
#       propagates: stdout has RC2 N, exit 2.
# ============================================================================
setup_mock
export GH_MOCK_LABELS_STATE_405='{"labels":["type:task"],"state":"OPEN"}'
export WIP_SINGLE_RC=2
OUT=$(run_with_timeout 10 bash "$SUT" 405 2>/dev/null)
RC=$?
if [ "$RC" -eq 2 ] && echo "$OUT" | grep -q "RC2" && echo "$OUT" | grep -qw "405"; then
    pass "WR-5: wip-set-single rc=2 → RC2 405, exit 2"
else
    fail "WR-5: expected RC2 405 + exit 2; got rc=$RC out='$OUT'"
fi
teardown_mock

# ============================================================================
# WR-REG: all N have intent:clarified → Pass-2 runs, ALL_SET emitted, exit 0.
#         Existing behaviour preserved (GREEN now).
# ============================================================================
setup_mock
export GH_MOCK_LABELS_STATE_501='{"labels":["intent:clarified","type:task"],"state":"OPEN"}'
export GH_MOCK_LABELS_STATE_502='{"labels":["intent:clarified","type:task"],"state":"OPEN"}'
export GH_MOCK_WIP_RC=0
OUT=$(run_with_timeout 10 bash "$SUT" 501 502 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "^ALL_SET$"; then
    pass "WR-REG: all clarified → ALL_SET, exit 0 (existing behaviour preserved)"
else
    fail "WR-REG: expected ALL_SET + exit 0; got rc=$RC out='$OUT'"
fi
teardown_mock

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
