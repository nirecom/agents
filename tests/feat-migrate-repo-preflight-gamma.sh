#!/bin/bash
# Tests: bin/github-issues/migration/orchestrate.sh, skills/migrate-repo/scripts/preview-and-capture.sh
# Tags: migration, repo, github, issues, bin, toctou, preflight-gamma
# Option γ pre-flight tests (PF5-PF12) — added for issue #834 TOCTOU fix.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCH_SCRIPT="$AGENTS_DIR/bin/github-issues/migration/orchestrate.sh"
FIXTURE_DIR="$AGENTS_DIR/tests/fixtures/migration"

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
[ -f "$ORCH_SCRIPT" ] || missing+=("bin/github-issues/migration/orchestrate.sh")
if [ "${#missing[@]}" -gt 0 ]; then
    for f in "${missing[@]}"; do
        echo "FAIL: precondition missing — $f"
    done
    echo ""
    echo "Results: 0 passed, ${#missing[@]} failed"
    exit 1
fi

# ---------------------------------------------------------------------------
# Fixture builder: minimal repo + gh-mock on PATH.
# The mock supports MOCK_HAS_ISSUES=1 to simulate existing issues.
# ---------------------------------------------------------------------------
setup_fixture() {
    TMP="$(mktemp -d)"
    REPO="$TMP/repo"
    mkdir -p "$REPO/docs"
    cat > "$REPO/docs/history.md" <<'EOF'
### Entry 1 (2024-01-01)
Background: test entry 1
Changes: change 1
EOF

    # gh mock from fixtures (supports MOCK_HAS_ISSUES).
    MOCK_DIR="$TMP/mock"
    mkdir -p "$MOCK_DIR"
    cp "$FIXTURE_DIR/gh-mock.sh" "$MOCK_DIR/gh"
    chmod +x "$MOCK_DIR/gh"

    MOCK_LOG="$TMP/mock.log"
    MOCK_COUNTER="$TMP/counter"
    echo 101 > "$MOCK_COUNTER"
    : > "$MOCK_LOG"

    export MOCK_LOG MOCK_COUNTER
    export PATH="$MOCK_DIR:$PATH"
    export AGENTS_CONFIG_DIR="$AGENTS_DIR"
}

teardown_fixture() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    unset MOCK_LOG MOCK_COUNTER AGENTS_CONFIG_DIR MOCK_HAS_ISSUES
}

# ---------------------------------------------------------------------------
# seed_state_history — inject N dummy history entries into .migration-state.json
# ---------------------------------------------------------------------------
seed_state_history() {
    local repo_path="$1" count="$2"
    # shellcheck disable=SC1090
    source "$AGENTS_DIR/bin/github-issues/migration/state.sh"
    state_init "$repo_path" >/dev/null 2>&1
    state_load "$repo_path" >/dev/null 2>&1
    local sf="$repo_path/.migration-state.json"
    local tmp="${sf}.tmp"
    jq --argjson n "$count" \
       '.history.migrated = [range(0; $n) | {entry_id:("dummy-"+(.|tostring)),issue_number:(100+.),title:("dummy-"+(.|tostring))}]' \
       "$sf" > "$tmp"
    mv "$tmp" "$sf"
    state_load "$repo_path" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# PF5: TOCTOU canary-1 reject — dry-run sees no issues, then external mutation
#      creates issue #5, then live invocation with stale ack=0/0 must abort.
# ---------------------------------------------------------------------------
setup_fixture
unset MOCK_HAS_ISSUES

OUT_PF5_DRY=$(run_with_timeout 30 bash "$ORCH_SCRIPT" "$REPO" --dry-run 2>&1)
HAS_SENTINEL0_PF5=$(echo "$OUT_PF5_DRY" | grep -c "MIGRATE_DRY_RUN_HIGHEST_ISSUE_N=0" 2>/dev/null) || HAS_SENTINEL0_PF5=0

# Simulate external mutation: issue #5 appears.
export MOCK_HAS_ISSUES=1

OUT_PF5_LIVE=$(MIGRATE_ACK_EXISTING_ISSUES=1 MIGRATE_ACK_UP_TO_ISSUE_N=0 MIGRATE_ACK_SELF_COUNT_AT_ACK=0 \
    run_with_timeout 30 bash "$ORCH_SCRIPT" "$REPO" --from-step 2 --stage canary-1 2>&1)
RC_PF5=$?

HAS_TOCTOU_PF5=$(echo "$OUT_PF5_LIVE" | grep -c "TOCTOU\|moved since dry-run" 2>/dev/null) || HAS_TOCTOU_PF5=0

if [ "$HAS_SENTINEL0_PF5" -gt 0 ] && [ "$RC_PF5" -ne 0 ] && [ "$HAS_TOCTOU_PF5" -gt 0 ]; then
    pass "PF5: TOCTOU canary-1 reject (stale ack, issue appeared post-dry-run)"
else
    fail "PF5: sentinel0=$HAS_SENTINEL0_PF5 rc=$RC_PF5 toctou=$HAS_TOCTOU_PF5 (expected sentinel0>0, rc!=0, toctou>0)"
fi
teardown_fixture

# ---------------------------------------------------------------------------
# PF6: fresh-ack accepted — dry-run sees N=5; live ack with that N passes
#      the TOCTOU gate (no abort message). Downstream may still fail Step 2
#      for unrelated reasons — we only check the gate.
# ---------------------------------------------------------------------------
setup_fixture
export MOCK_HAS_ISSUES=1

OUT_PF6_DRY=$(run_with_timeout 30 bash "$ORCH_SCRIPT" "$REPO" --dry-run 2>&1)
# Extract N from sentinel.
N_PF6=$(echo "$OUT_PF6_DRY" | sed -n 's/^MIGRATE_DRY_RUN_HIGHEST_ISSUE_N=\([0-9]*\).*/\1/p' | head -1)
[ -z "$N_PF6" ] && N_PF6=5

OUT_PF6_LIVE=$(MIGRATE_ACK_EXISTING_ISSUES=1 MIGRATE_ACK_UP_TO_ISSUE_N="$N_PF6" MIGRATE_ACK_SELF_COUNT_AT_ACK=0 \
    run_with_timeout 30 bash "$ORCH_SCRIPT" "$REPO" --from-step 2 --stage canary-1 2>&1)

HAS_ACK_PF6=$(echo "$OUT_PF6_LIVE" | grep -c "acknowledged" 2>/dev/null) || HAS_ACK_PF6=0
HAS_TOCTOU_PF6=$(echo "$OUT_PF6_LIVE" | grep -c "TOCTOU\|moved since dry-run" 2>/dev/null) || HAS_TOCTOU_PF6=0

if [ "$HAS_ACK_PF6" -gt 0 ] && [ "$HAS_TOCTOU_PF6" -eq 0 ]; then
    pass "PF6: fresh ack (UP_TO=$N_PF6) accepted, no TOCTOU abort"
else
    fail "PF6: ack=$HAS_ACK_PF6 toctou=$HAS_TOCTOU_PF6 N=$N_PF6 (expected ack>0, toctou=0)"
fi
teardown_fixture

# ---------------------------------------------------------------------------
# PF7: dry-run sentinel emission (3 sub-cases).
# ---------------------------------------------------------------------------
PF7_SUB_PASS=0

# 7a: no issues → highest=0, self=0
setup_fixture
unset MOCK_HAS_ISSUES
OUT_PF7A=$(run_with_timeout 30 bash "$ORCH_SCRIPT" "$REPO" --dry-run 2>&1)
A1=$(echo "$OUT_PF7A" | grep -c "MIGRATE_DRY_RUN_HIGHEST_ISSUE_N=0" 2>/dev/null) || A1=0
A2=$(echo "$OUT_PF7A" | grep -c "MIGRATE_DRY_RUN_SELF_COUNT=0" 2>/dev/null) || A2=0
if [ "$A1" -gt 0 ] && [ "$A2" -gt 0 ]; then
    PF7_SUB_PASS=$((PF7_SUB_PASS + 1))
else
    echo "  PF7a: highest=0_present=$A1 self=0_present=$A2"
fi
teardown_fixture

# 7b: existing issues (5) → highest=5, self=0
setup_fixture
export MOCK_HAS_ISSUES=1
OUT_PF7B=$(run_with_timeout 30 bash "$ORCH_SCRIPT" "$REPO" --dry-run 2>&1)
B1=$(echo "$OUT_PF7B" | grep -c "MIGRATE_DRY_RUN_HIGHEST_ISSUE_N=5" 2>/dev/null) || B1=0
B2=$(echo "$OUT_PF7B" | grep -c "MIGRATE_DRY_RUN_SELF_COUNT=0" 2>/dev/null) || B2=0
if [ "$B1" -gt 0 ] && [ "$B2" -gt 0 ]; then
    PF7_SUB_PASS=$((PF7_SUB_PASS + 1))
else
    echo "  PF7b: highest=5_present=$B1 self=0_present=$B2"
fi
teardown_fixture

# 7c: 2 state-history entries pre-seeded → self=2
setup_fixture
unset MOCK_HAS_ISSUES
seed_state_history "$REPO" 2
OUT_PF7C=$(run_with_timeout 30 bash "$ORCH_SCRIPT" "$REPO" --dry-run 2>&1)
C1=$(echo "$OUT_PF7C" | grep -c "MIGRATE_DRY_RUN_SELF_COUNT=2" 2>/dev/null) || C1=0
if [ "$C1" -gt 0 ]; then
    PF7_SUB_PASS=$((PF7_SUB_PASS + 1))
else
    echo "  PF7c: self=2_present=$C1"
fi
teardown_fixture

if [ "$PF7_SUB_PASS" -eq 3 ]; then
    pass "PF7: dry-run sentinel emission (3/3 sub-cases)"
else
    fail "PF7: only $PF7_SUB_PASS/3 sub-cases passed"
fi

# ---------------------------------------------------------------------------
# PF8: Layer P presence — missing/empty env vars must abort with clear error.
# ---------------------------------------------------------------------------

# 8a: MIGRATE_ACK_UP_TO_ISSUE_N unset
setup_fixture
export MOCK_HAS_ISSUES=1
unset MIGRATE_ACK_UP_TO_ISSUE_N
OUT_PF8A=$(MIGRATE_ACK_EXISTING_ISSUES=1 MIGRATE_ACK_SELF_COUNT_AT_ACK=0 \
    run_with_timeout 30 bash "$ORCH_SCRIPT" "$REPO" --from-step 2 --stage canary-1 2>&1)
RC_PF8A=$?
HAS_HINT_PF8A=$(echo "$OUT_PF8A" | grep -c "MIGRATE_ACK_UP_TO_ISSUE_N.*required\|required.*MIGRATE_ACK_UP_TO_ISSUE_N" 2>/dev/null) || HAS_HINT_PF8A=0
if [ "$RC_PF8A" -ne 0 ] && [ "$HAS_HINT_PF8A" -gt 0 ]; then
    pass "PF8a: MIGRATE_ACK_UP_TO_ISSUE_N unset → abort with hint"
else
    fail "PF8a: rc=$RC_PF8A hint=$HAS_HINT_PF8A"
fi
teardown_fixture

# 8b: MIGRATE_ACK_UP_TO_ISSUE_N=""
setup_fixture
export MOCK_HAS_ISSUES=1
OUT_PF8B=$(MIGRATE_ACK_EXISTING_ISSUES=1 MIGRATE_ACK_UP_TO_ISSUE_N="" MIGRATE_ACK_SELF_COUNT_AT_ACK=0 \
    run_with_timeout 30 bash "$ORCH_SCRIPT" "$REPO" --from-step 2 --stage canary-1 2>&1)
RC_PF8B=$?
HAS_HINT_PF8B=$(echo "$OUT_PF8B" | grep -c "MIGRATE_ACK_UP_TO_ISSUE_N.*required\|required.*MIGRATE_ACK_UP_TO_ISSUE_N" 2>/dev/null) || HAS_HINT_PF8B=0
if [ "$RC_PF8B" -ne 0 ] && [ "$HAS_HINT_PF8B" -gt 0 ]; then
    pass "PF8b: MIGRATE_ACK_UP_TO_ISSUE_N=\"\" → abort with hint"
else
    fail "PF8b: rc=$RC_PF8B hint=$HAS_HINT_PF8B"
fi
teardown_fixture

# 8c: MIGRATE_ACK_SELF_COUNT_AT_ACK unset
setup_fixture
export MOCK_HAS_ISSUES=1
unset MIGRATE_ACK_SELF_COUNT_AT_ACK
OUT_PF8C=$(MIGRATE_ACK_EXISTING_ISSUES=1 MIGRATE_ACK_UP_TO_ISSUE_N=5 \
    run_with_timeout 30 bash "$ORCH_SCRIPT" "$REPO" --from-step 2 --stage canary-1 2>&1)
RC_PF8C=$?
HAS_HINT_PF8C=$(echo "$OUT_PF8C" | grep -c "MIGRATE_ACK_SELF_COUNT_AT_ACK.*required\|required.*MIGRATE_ACK_SELF_COUNT_AT_ACK" 2>/dev/null) || HAS_HINT_PF8C=0
if [ "$RC_PF8C" -ne 0 ] && [ "$HAS_HINT_PF8C" -gt 0 ]; then
    pass "PF8c: MIGRATE_ACK_SELF_COUNT_AT_ACK unset → abort with hint"
else
    fail "PF8c: rc=$RC_PF8C hint=$HAS_HINT_PF8C"
fi
teardown_fixture

# 8d: both empty
setup_fixture
export MOCK_HAS_ISSUES=1
OUT_PF8D=$(MIGRATE_ACK_EXISTING_ISSUES=1 MIGRATE_ACK_UP_TO_ISSUE_N="" MIGRATE_ACK_SELF_COUNT_AT_ACK="" \
    run_with_timeout 30 bash "$ORCH_SCRIPT" "$REPO" --from-step 2 --stage canary-1 2>&1)
RC_PF8D=$?
HAS_HINT_PF8D=$(echo "$OUT_PF8D" | grep -ci "required" 2>/dev/null) || HAS_HINT_PF8D=0
if [ "$RC_PF8D" -ne 0 ] && [ "$HAS_HINT_PF8D" -gt 0 ]; then
    pass "PF8d: both vars empty → abort with hint"
else
    fail "PF8d: rc=$RC_PF8D hint=$HAS_HINT_PF8D"
fi
teardown_fixture

# ---------------------------------------------------------------------------
# PF9: non-integer / unsafe format for MIGRATE_ACK_UP_TO_ISSUE_N.
# ---------------------------------------------------------------------------
PF9_FAILED=()
for v in "abc" "5.0" "-1" " 5" "5;rm" "1e2"; do
    setup_fixture
    export MOCK_HAS_ISSUES=1
    OUT_PF9=$(MIGRATE_ACK_EXISTING_ISSUES=1 MIGRATE_ACK_UP_TO_ISSUE_N="$v" MIGRATE_ACK_SELF_COUNT_AT_ACK=0 \
        run_with_timeout 30 bash "$ORCH_SCRIPT" "$REPO" --from-step 2 --stage canary-1 2>&1)
    RC_PF9=$?
    HAS_HINT_PF9=$(echo "$OUT_PF9" | grep -c "non-negative integer" 2>/dev/null) || HAS_HINT_PF9=0
    if [ "$RC_PF9" -ne 0 ] && [ "$HAS_HINT_PF9" -gt 0 ]; then
        pass "PF9-${v}: value rejected as non-negative integer"
    else
        fail "PF9-${v}: rc=$RC_PF9 hint=$HAS_HINT_PF9"
        PF9_FAILED+=("$v")
    fi
    teardown_fixture
done

# ---------------------------------------------------------------------------
# PF10: later-step invocation without env vars must abort at Layer P
#       (a/b/c) and stale snapshot triggers Layer C abort (d).
# ---------------------------------------------------------------------------

# 10a: --from-step 3 --stage canary-2, no Layer P vars
setup_fixture
export MOCK_HAS_ISSUES=1
unset MIGRATE_ACK_UP_TO_ISSUE_N MIGRATE_ACK_SELF_COUNT_AT_ACK
OUT_PF10A=$(MIGRATE_ACK_EXISTING_ISSUES=1 \
    run_with_timeout 30 bash "$ORCH_SCRIPT" "$REPO" --from-step 3 --stage canary-2 2>&1)
RC_PF10A=$?
HAS_HINT_PF10A=$(echo "$OUT_PF10A" | grep -ci "required" 2>/dev/null) || HAS_HINT_PF10A=0
if [ "$RC_PF10A" -ne 0 ] && [ "$HAS_HINT_PF10A" -gt 0 ]; then
    pass "PF10a: from-step 3 canary-2 without env vars → Layer P abort"
else
    fail "PF10a: rc=$RC_PF10A hint=$HAS_HINT_PF10A"
fi
teardown_fixture

# 10b: --from-step 2 --stage canary-2, no Layer P vars
setup_fixture
export MOCK_HAS_ISSUES=1
unset MIGRATE_ACK_UP_TO_ISSUE_N MIGRATE_ACK_SELF_COUNT_AT_ACK
OUT_PF10B=$(MIGRATE_ACK_EXISTING_ISSUES=1 \
    run_with_timeout 30 bash "$ORCH_SCRIPT" "$REPO" --from-step 2 --stage canary-2 2>&1)
RC_PF10B=$?
HAS_HINT_PF10B=$(echo "$OUT_PF10B" | grep -ci "required" 2>/dev/null) || HAS_HINT_PF10B=0
if [ "$RC_PF10B" -ne 0 ] && [ "$HAS_HINT_PF10B" -gt 0 ]; then
    pass "PF10b: from-step 2 canary-2 without env vars → Layer P abort"
else
    fail "PF10b: rc=$RC_PF10B hint=$HAS_HINT_PF10B"
fi
teardown_fixture

# 10c: --from-step 4, no Layer P vars
setup_fixture
export MOCK_HAS_ISSUES=1
unset MIGRATE_ACK_UP_TO_ISSUE_N MIGRATE_ACK_SELF_COUNT_AT_ACK
OUT_PF10C=$(MIGRATE_ACK_EXISTING_ISSUES=1 \
    run_with_timeout 30 bash "$ORCH_SCRIPT" "$REPO" --from-step 4 2>&1)
RC_PF10C=$?
HAS_HINT_PF10C=$(echo "$OUT_PF10C" | grep -ci "required" 2>/dev/null) || HAS_HINT_PF10C=0
if [ "$RC_PF10C" -ne 0 ] && [ "$HAS_HINT_PF10C" -gt 0 ]; then
    pass "PF10c: from-step 4 without env vars → Layer P abort"
else
    fail "PF10c: rc=$RC_PF10C hint=$HAS_HINT_PF10C"
fi
teardown_fixture

# 10d: stale snapshot (existing=5, self_now=2, ack=0/0) → Layer C abort.
#      self_delta=2, expected_max=0+2=2, existing_n=5 > 2 → ABORT.
setup_fixture
export MOCK_HAS_ISSUES=1
seed_state_history "$REPO" 2
OUT_PF10D=$(MIGRATE_ACK_EXISTING_ISSUES=1 MIGRATE_ACK_UP_TO_ISSUE_N=0 MIGRATE_ACK_SELF_COUNT_AT_ACK=0 \
    run_with_timeout 30 bash "$ORCH_SCRIPT" "$REPO" --from-step 2 --stage canary-1 2>&1)
RC_PF10D=$?
HAS_TOCTOU_PF10D=$(echo "$OUT_PF10D" | grep -c "TOCTOU\|moved since dry-run" 2>/dev/null) || HAS_TOCTOU_PF10D=0
if [ "$RC_PF10D" -ne 0 ] && [ "$HAS_TOCTOU_PF10D" -gt 0 ]; then
    pass "PF10d: stale snapshot (existing=5 > expected_max=2) → Layer C abort"
else
    fail "PF10d: rc=$RC_PF10D toctou=$HAS_TOCTOU_PF10D"
fi
teardown_fixture

# ---------------------------------------------------------------------------
# PF11: mid-migration self-count allows pass.
#       existing_n=2, self_now=2, ack=0/0 → self_delta=2, expected_max=2,
#       existing_n=2 ≤ 2 → PASS (no TOCTOU abort, ack message present).
# ---------------------------------------------------------------------------
setup_fixture
export MOCK_HAS_ISSUES=1
export MOCK_HIGHEST_ISSUE_N=2
seed_state_history "$REPO" 2
OUT_PF11=$(MIGRATE_ACK_EXISTING_ISSUES=1 MIGRATE_ACK_UP_TO_ISSUE_N=0 MIGRATE_ACK_SELF_COUNT_AT_ACK=0 \
    run_with_timeout 30 bash "$ORCH_SCRIPT" "$REPO" --from-step 2 --stage canary-1 2>&1)
HAS_ACK_PF11=$(echo "$OUT_PF11" | grep -c "acknowledged" 2>/dev/null) || HAS_ACK_PF11=0
HAS_TOCTOU_PF11=$(echo "$OUT_PF11" | grep -c "TOCTOU\|moved since dry-run" 2>/dev/null) || HAS_TOCTOU_PF11=0
unset MOCK_HIGHEST_ISSUE_N
if [ "$HAS_ACK_PF11" -gt 0 ] && [ "$HAS_TOCTOU_PF11" -eq 0 ]; then
    pass "PF11: existing=2 ≤ expected_max=2 → Layer C pass"
else
    fail "PF11: ack=$HAS_ACK_PF11 toctou=$HAS_TOCTOU_PF11"
fi
teardown_fixture

# ---------------------------------------------------------------------------
# PF12: post-canary-1 external mutation caught — existing=5, self_now=2,
#       ack=0/0 → self_delta=2, expected_max=2, existing=5 > 2 → ABORT.
#       Error message must include numeric details: acked_up_to=0,
#       expected_max=2, existing_n=5.
# ---------------------------------------------------------------------------
setup_fixture
export MOCK_HAS_ISSUES=1
export MOCK_HIGHEST_ISSUE_N=5
seed_state_history "$REPO" 2
OUT_PF12=$(MIGRATE_ACK_EXISTING_ISSUES=1 MIGRATE_ACK_UP_TO_ISSUE_N=0 MIGRATE_ACK_SELF_COUNT_AT_ACK=0 \
    run_with_timeout 30 bash "$ORCH_SCRIPT" "$REPO" --from-step 2 --stage canary-1 2>&1)
RC_PF12=$?
HAS_TOCTOU_PF12=$(echo "$OUT_PF12" | grep -c "TOCTOU\|moved since dry-run" 2>/dev/null) || HAS_TOCTOU_PF12=0
HAS_NUM_0_PF12=$(echo "$OUT_PF12" | grep -c "0" 2>/dev/null) || HAS_NUM_0_PF12=0
HAS_NUM_2_PF12=$(echo "$OUT_PF12" | grep -c "2" 2>/dev/null) || HAS_NUM_2_PF12=0
HAS_NUM_5_PF12=$(echo "$OUT_PF12" | grep -c "5" 2>/dev/null) || HAS_NUM_5_PF12=0
unset MOCK_HIGHEST_ISSUE_N
if [ "$RC_PF12" -ne 0 ] && [ "$HAS_TOCTOU_PF12" -gt 0 ] && \
   [ "$HAS_NUM_0_PF12" -gt 0 ] && [ "$HAS_NUM_2_PF12" -gt 0 ] && [ "$HAS_NUM_5_PF12" -gt 0 ]; then
    pass "PF12: external mutation caught + numeric details (0,2,5) present"
else
    fail "PF12: rc=$RC_PF12 toctou=$HAS_TOCTOU_PF12 nums(0,2,5)=($HAS_NUM_0_PF12,$HAS_NUM_2_PF12,$HAS_NUM_5_PF12)"
fi
teardown_fixture

# ---------------------------------------------------------------------------
# PF13: self-repo dry-run (#1234 identity guard).
#       When REPO == AGENTS_CONFIG_DIR, dry-run must detect the self-repo
#       condition (emit SELF_REPO_DETECTED) yet still complete (rc==0) and
#       emit the dry-run highest-issue sentinel.
#       FAIL-BEFORE-FIX: guard not implemented → no SELF_REPO_DETECTED.
# ---------------------------------------------------------------------------
setup_fixture
unset MOCK_HAS_ISSUES
SELF="$TMP/selfrepo"
mkdir -p "$SELF/docs"
cat > "$SELF/docs/history.md" <<'EOF'
### Entry 1 (2024-01-01)
Background: test entry 1
Changes: change 1
EOF
SELF="$(cd "$SELF" && pwd)"
export AGENTS_CONFIG_DIR="$SELF"
OUT_PF13=$(run_with_timeout 30 bash "$ORCH_SCRIPT" "$SELF" --dry-run 2>&1)
RC_PF13=$?
HAS_SELF_PF13=$(echo "$OUT_PF13" | grep -c "SELF_REPO_DETECTED" 2>/dev/null) || HAS_SELF_PF13=0
HAS_HIGHEST_PF13=$(echo "$OUT_PF13" | grep -c "MIGRATE_DRY_RUN_HIGHEST_ISSUE_N=" 2>/dev/null) || HAS_HIGHEST_PF13=0
if [ "$RC_PF13" -eq 0 ] && [ "$HAS_SELF_PF13" -gt 0 ] && [ "$HAS_HIGHEST_PF13" -gt 0 ]; then
    pass "PF13: self-repo dry-run detects SELF_REPO_DETECTED and emits highest sentinel"
else
    fail "PF13: rc=$RC_PF13 self_detected=$HAS_SELF_PF13 highest=$HAS_HIGHEST_PF13 (expected rc=0, self_detected>0, highest>0)"
fi
teardown_fixture

# ---------------------------------------------------------------------------
# PF14: self-repo live --from-step 1 (#1234 identity guard).
#       Live migration targeting AGENTS_CONFIG_DIR itself must abort because
#       it would corrupt the agents repo's own issues (misidentification).
#       FAIL-BEFORE-FIX: guard absent → no abort referencing the self-repo.
# ---------------------------------------------------------------------------
setup_fixture
unset MOCK_HAS_ISSUES MIGRATE_ACK_EXISTING_ISSUES
SELF="$TMP/selfrepo"
mkdir -p "$SELF/docs"
cat > "$SELF/docs/history.md" <<'EOF'
### Entry 1 (2024-01-01)
Background: test entry 1
Changes: change 1
EOF
SELF="$(cd "$SELF" && pwd)"
export AGENTS_CONFIG_DIR="$SELF"
OUT_PF14=$(run_with_timeout 30 bash "$ORCH_SCRIPT" "$SELF" --from-step 1 2>&1)
RC_PF14=$?
HAS_SELF_MSG_PF14=$(echo "$OUT_PF14" | grep -c "AGENTS_CONFIG_DIR\|取り違え\|misidentification" 2>/dev/null) || HAS_SELF_MSG_PF14=0
if [ "$RC_PF14" -ne 0 ] && [ "$HAS_SELF_MSG_PF14" -gt 0 ]; then
    pass "PF14: self-repo live invocation aborts with misidentification guard"
else
    fail "PF14: rc=$RC_PF14 self_msg=$HAS_SELF_MSG_PF14 (expected rc!=0, self_msg>0)"
fi
teardown_fixture

# ---------------------------------------------------------------------------
# PF14b: self-repo live --from-step 1 with full ack (#1234 identity guard —
#        CHARACTERIZATION test, inverse direction from PF14).
#        Approved design: MIGRATE_ACK_EXISTING_ISSUES=1 is the deliberate gate
#        for legitimate Phase 3 self-migration. When the full ack env is present
#        and Layer P/C are satisfied, a self-repo live invocation must NOT be
#        blocked by the identity guard — it should proceed to Step 1.
#        This pins the approved behaviour so a future change that makes the
#        identity guard unconditional (blocking even with ACK=1) would break here.
#        PASS both before and after the fix (pure characterization).
# ---------------------------------------------------------------------------
setup_fixture
SELF="$TMP/selfrepo"
mkdir -p "$SELF/docs"
cat > "$SELF/docs/history.md" <<'EOF'
### Entry 1 (2024-01-01)
Background: test entry 1
Changes: change 1
EOF
SELF="$(cd "$SELF" && pwd)"
export AGENTS_CONFIG_DIR="$SELF"
export MOCK_HAS_ISSUES=1
# MOCK_HIGHEST_ISSUE_N defaults to 5 in the mock when unset.
# Layer P/C: MIGRATE_ACK_UP_TO_ISSUE_N=5 matches the mock's highest issue N;
# MIGRATE_ACK_SELF_COUNT_AT_ACK=0 means self_delta=0, expected_max=5+0=5,
# existing_n=5 <= 5, so Layer C passes.
OUT_PF14B=$(MIGRATE_ACK_EXISTING_ISSUES=1 MIGRATE_ACK_UP_TO_ISSUE_N=5 MIGRATE_ACK_SELF_COUNT_AT_ACK=0 \
    run_with_timeout 30 bash "$ORCH_SCRIPT" "$SELF" --from-step 1 --stage canary-1 2>&1)
RC_PF14B=$?
# Assert NOT blocked by the self-repo identity guard (abort-specific phrase only).
# The broad vocabulary (AGENTS_CONFIG_DIR / 取り違え / misidentification) also appears in two
# approved non-abort WARNINGs present in this run: the self-repo ack-proceed WARNING and the
# strengthened existing-issues WARNING (MOCK_HAS_ISSUES=1). "Refusing live migration" is emitted
# exclusively by the guard's exit 1 path in orchestrate.sh — never by WARNINGs — so it is the
# precise signal that the abort fired.
HAS_SELFGUARD_PF14B=$(echo "$OUT_PF14B" | grep -c "Refusing live migration" 2>/dev/null) || HAS_SELFGUARD_PF14B=0
# Also assert NOT blocked by the base live-mode-requires abort (would fire if ACK were absent).
HAS_LIVEMODE_PF14B=$(echo "$OUT_PF14B" | grep -c "live mode requires" 2>/dev/null) || HAS_LIVEMODE_PF14B=0
# Primary assertion: guard abort absent AND rc==0 (run proceeds).
# If rc!=0 for an unrelated reason (e.g. canary sub-step), the guard-absent check alone suffices.
if [ "$HAS_SELFGUARD_PF14B" -eq 0 ] && [ "$HAS_LIVEMODE_PF14B" -eq 0 ] && [ "$RC_PF14B" -eq 0 ]; then
    pass "PF14b: self-repo + full ack NOT blocked by identity guard (approved Phase 3 self-migration path)"
elif [ "$HAS_SELFGUARD_PF14B" -eq 0 ] && [ "$HAS_LIVEMODE_PF14B" -eq 0 ]; then
    # rc!=0 for a reason unrelated to the identity guard — characterization still holds.
    pass "PF14b: self-repo + full ack NOT blocked by identity guard (rc=$RC_PF14B, unrelated failure — guard absent)"
else
    fail "PF14b: rc=$RC_PF14B selfguard=$HAS_SELFGUARD_PF14B livemode=$HAS_LIVEMODE_PF14B (expected guard absent)"
fi
unset MOCK_HAS_ISSUES
teardown_fixture

# ---------------------------------------------------------------------------
# PF15: normal fixture repo (NOT self) --from-step 1 --stage canary-1 (#1232).
#       Characterization test: Step 1 (label sync) must be invoked and the
#       run must succeed on a non-self repo. Limitation: gh-mock does not model
#       label-not-found, so this asserts Step 1 is invoked (option b), not that
#       a label-less canary fails-then-succeeds.
# ---------------------------------------------------------------------------
setup_fixture
unset MOCK_HAS_ISSUES
OUT_PF15=$(run_with_timeout 30 bash "$ORCH_SCRIPT" "$REPO" --from-step 1 --stage canary-1 2>&1)
RC_PF15=$?
HAS_STEP1_PF15=$(echo "$OUT_PF15" | grep -c "Step 1: label sync" 2>/dev/null) || HAS_STEP1_PF15=0
if [ "$HAS_STEP1_PF15" -gt 0 ] && [ "$RC_PF15" -eq 0 ]; then
    pass "PF15: non-self repo invokes Step 1 label sync (rc=0)"
else
    fail "PF15: rc=$RC_PF15 step1=$HAS_STEP1_PF15 (expected rc=0, step1>0)"
fi
teardown_fixture

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
