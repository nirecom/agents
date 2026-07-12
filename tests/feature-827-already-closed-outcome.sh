#!/usr/bin/env bash
# tests/feature-827-already-closed-outcome.sh
# Tests: bin/github-issues/issue-close-finalize-triage.sh, bin/issue-close-write-outcome.js
# Tags: scope:issue-specific
# Tests for issue #827 (with #1395) — an already-CLOSED issue on the resume_j
# path must reach finalize_terminal and write a new-session-ID outcome entry.
#
# The resume_j path (CLOSED + appended sentinel) only reaches finalize_terminal
# once triage carries Step G (#1395); without G the cascade short-circuits and
# no terminal outcome is recorded for the already-closed issue. This suite is
# RED against current source: triage still emits NEXT_STEPS="J,K" (no G).
#
# L3 gap (what this test does NOT catch):
# - real GitHub API calls and actual issue state transitions
# Closest-to-action mitigation: manual verification at WORKFLOW_USER_VERIFIED preflight

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_SCRIPT="$AGENTS_DIR/bin/github-issues/issue-close-triage-lib.sh"
FINALIZE_TRIAGE_SCRIPT="$AGENTS_DIR/bin/github-issues/issue-close-finalize-triage.sh"
WRITE_OUTCOME="$AGENTS_DIR/bin/issue-close-write-outcome.js"
MOCK_DIR="$AGENTS_DIR/tests/fixtures/gh-mock"

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
[ -f "$LIB_SCRIPT" ]             || missing+=("bin/github-issues/issue-close-triage-lib.sh")
[ -f "$FINALIZE_TRIAGE_SCRIPT" ] || missing+=("bin/github-issues/issue-close-finalize-triage.sh")
[ -f "$WRITE_OUTCOME" ]         || missing+=("bin/issue-close-write-outcome.js")
if [ "${#missing[@]}" -gt 0 ]; then
    for f in "${missing[@]}"; do
        echo "FAIL: precondition missing — $f"
    done
    echo ""
    echo "Results: 0 passed, ${#missing[@]} failed"
    exit 1
fi

for f in gh doc-append git; do
    if [ -f "$MOCK_DIR/$f" ] && [ ! -x "$MOCK_DIR/$f" ]; then
        chmod +x "$MOCK_DIR/$f" 2>/dev/null || true
    fi
done

setup_tmp() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/docs/history"
    : > "$TMP/docs/history.md"
    export AGENTS_CONFIG_DIR="$AGENTS_DIR"
    export PATH="$MOCK_DIR:$PATH"
    OUTCOME="$TMP/session-issue-close-outcome.json"
}

teardown_tmp() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    unset AGENTS_CONFIG_DIR
}

run_triage() {
    local scenario="$1"
    unset STATE SENTINEL ACTION NEXT_STEPS
    local out
    if out=$(cd "$TMP" && AGENTS_CONFIG_DIR="$AGENTS_DIR" GH_MOCK_SCENARIO="$scenario" \
            run_with_timeout 15 bash "$FINALIZE_TRIAGE_SCRIPT" 42 2>/dev/null); then
        T_RC=0
    else
        T_RC=$?
    fi
    # shellcheck disable=SC1090
    eval "$out" 2>/dev/null
    T_ACTION="${ACTION:-}"
    T_NEXT_STEPS="${NEXT_STEPS:-}"
}

# ============================================================================
# T1: resume_j reaches the terminal path only when Step G is present (#1395)
# ============================================================================
# run-initial.sh gates ICF-D/E (and thus the terminal cascade for an
# already-closed meta parent) on `,G,` membership. resume_j must therefore
# carry G. RED today: NEXT_STEPS="J,K".
setup_tmp
run_triage closed_with_appended_sentinel
if [ "$T_RC" -eq 0 ] && [ "$T_ACTION" = "resume_j" ] \
    && [[ ",${T_NEXT_STEPS}," == *",G,"* ]]; then
    pass "T1: resume_j carries Step G → finalize_terminal reachable (#827+#1395)"
else
    fail "T1: rc=$T_RC action=$T_ACTION next=$T_NEXT_STEPS (Step G missing → terminal unreachable)"
fi
teardown_tmp

# ============================================================================
# T2: new-session-ID outcome entry is written for the already-closed issue
# ============================================================================
# The terminal step must persist an outcome entry for the already-closed issue
# under the CURRENT (new) session id, using the --session-id / --out-file form.
setup_tmp
run_with_timeout 15 node "$WRITE_OUTCOME" \
    --session-id newsid827 --out-file "$OUTCOME" \
    42 resume_j appended already_closed posted cleared >/dev/null 2>&1
if [ -f "$OUTCOME" ] \
    && grep -q '"issueNumber": 42' "$OUTCOME" \
    && grep -q '"state": "resume_j"' "$OUTCOME"; then
    pass "T2: already-closed issue #42 recorded under new session id (#827)"
else
    fail "T2: outcome entry for already-closed #42 not written (file=$OUTCOME)"
fi
teardown_tmp

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
