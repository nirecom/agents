#!/bin/bash
# Tests: bin/github-issues, bin/github-issues/backfill-commit-comments.sh, bin/github-issues/bootstrap-labels.sh, bin/github-issues/migration/orchestrate.sh, bin/github-issues/migration/state.sh, bin/github-issues/sync-labels.sh
# Tags: backfill, comments, github, issues, labels
# Tests for orchestrate.sh --stage flag (issue #415).
#
# RED: this suite fails until orchestrate.sh introduces a required --stage
# (canary-1|canary-2|full) flag for Step 2/3 with structural process
# separation — each stage runs and exits, no in-process advancement.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCH_SRC="$AGENTS_DIR/bin/github-issues/migration/orchestrate.sh"
STATE_SRC="$AGENTS_DIR/bin/github-issues/migration/state.sh"

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

if [ ! -f "$ORCH_SRC" ] || [ ! -f "$STATE_SRC" ]; then
    echo "FAIL: orchestrate.sh or state.sh not found"
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# ---------------- Harness setup ----------------
HARNESS_DIR="$(mktemp -d)"
GH_MOCK_DIR="$(mktemp -d)"
MOCK_CALLS_LOG="$HARNESS_DIR/mock-calls.log"
export MOCK_CALLS_LOG
: > "$MOCK_CALLS_LOG"

# Copy real orchestrate.sh + state.sh into harness so $SCRIPT_DIR resolves
# to the harness dir and picks up our mocked migrate-*.sh siblings.
cp "$ORCH_SRC" "$HARNESS_DIR/orchestrate.sh"
cp "$STATE_SRC" "$HARNESS_DIR/state.sh"

cat > "$HARNESS_DIR/migrate-history.sh" <<'EOF'
#!/usr/bin/env bash
echo "migrate-history: $*" >> "${MOCK_CALLS_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$HARNESS_DIR/migrate-history.sh"

cat > "$HARNESS_DIR/migrate-todo.sh" <<'EOF'
#!/usr/bin/env bash
echo "migrate-todo: $*" >> "${MOCK_CALLS_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$HARNESS_DIR/migrate-todo.sh"

cat > "$HARNESS_DIR/create-project.sh" <<'EOF'
#!/usr/bin/env bash
echo "create-project: $*" >> "${MOCK_CALLS_LOG:-/dev/null}"
# Populate state.project so the orchestrator's Step 4 jq lookups succeed.
REPO="$1"
SF="$REPO/.migration-state.json"
if [ -f "$SF" ]; then
    tmp="$SF.tmp"
    jq '.project = {number:1, node_id:"PVT_mock", field_ids:{"Content Date":"FLD_mock"}}' "$SF" > "$tmp" && mv "$tmp" "$SF"
fi
exit 0
EOF
chmod +x "$HARNESS_DIR/create-project.sh"

cat > "$HARNESS_DIR/backfill-content-date.sh" <<'EOF'
#!/usr/bin/env bash
echo "backfill-content-date: $*" >> "${MOCK_CALLS_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$HARNESS_DIR/backfill-content-date.sh"

# Mock gh in PATH
cat > "$GH_MOCK_DIR/gh" <<'EOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  "repo view --json url --jq"*)
    echo "https://github.com/mock/repo"
    exit 0
    ;;
  "issue list --state all --limit 1 --json number"*)
    echo "[]"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "$GH_MOCK_DIR/gh"
export PATH="$GH_MOCK_DIR:$PATH"

# AGENTS_CONFIG_DIR: build a fake one with mocked sub-scripts so Step 1/5
# don't run real gh/git operations when tests fall through past Step 2/3.
FAKE_AGENTS_DIR="$(mktemp -d)"
mkdir -p "$FAKE_AGENTS_DIR/bin/github-issues" "$FAKE_AGENTS_DIR/.github/ISSUE_TEMPLATE" "$FAKE_AGENTS_DIR/.github/workflows"
cat > "$FAKE_AGENTS_DIR/bin/github-issues/sync-labels.sh" <<'EOF'
#!/usr/bin/env bash
echo "sync-labels: $*" >> "${MOCK_CALLS_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$FAKE_AGENTS_DIR/bin/github-issues/sync-labels.sh"
cat > "$FAKE_AGENTS_DIR/bin/github-issues/backfill-commit-comments.sh" <<'EOF'
#!/usr/bin/env bash
echo "backfill-commit-comments: $*" >> "${MOCK_CALLS_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$FAKE_AGENTS_DIR/bin/github-issues/backfill-commit-comments.sh"
# bootstrap-labels.sh stub — referenced by /migrate-repo Step 1.3 (issue #283).
cat > "$FAKE_AGENTS_DIR/bin/github-issues/bootstrap-labels.sh" <<'EOF'
#!/usr/bin/env bash
echo "bootstrap-labels stub"
exit 0
EOF
chmod +x "$FAKE_AGENTS_DIR/bin/github-issues/bootstrap-labels.sh"
: > "$FAKE_AGENTS_DIR/.github/labels.yml"
# sync-labels.yml workflow placeholder — copied by bootstrap-labels.sh (issue #283).
echo "# stub" > "$FAKE_AGENTS_DIR/.github/workflows/sync-labels.yml"
export AGENTS_CONFIG_DIR="$FAKE_AGENTS_DIR"

# Helper: create a clean repo dir with optional history/todo.
make_repo() {
    local dir; dir="$(mktemp -d)"
    mkdir -p "$dir/docs"
    echo "$dir"
}

# Helper: init state file (schema_version:1 today, v2 post-impl)
init_state() {
    local repo="$1"
    # shellcheck disable=SC1090
    ( source "$HARNESS_DIR/state.sh"; state_init "$repo" >/dev/null 2>&1 )
}

# Helper: write state with N history.migrated entries and given current_step.
write_state_with_history_migrated() {
    local repo="$1" n_migrated="$2" current_step="$3"
    local entries="[]"
    if [ "$n_migrated" -gt 0 ]; then
        entries=$(jq -n --argjson n "$n_migrated" \
            '[range(0; $n) | {entry_id: ("e" + (. | tostring)), issue_number: (. + 1), title: ("T" + (. | tostring))}]')
    fi
    jq -n \
        --argjson migrated "$entries" \
        --argjson step "$current_step" \
        '{schema_version:1,repo_dir:"/fake",started_at:"2026-05-01T00:00:00Z",
          current_step:$step,
          history:{total_entries:0,migrated:$migrated},
          todo:{total_entries:0,migrated:[],todo_md_rewritten:false},
          project:{number:null,node_id:null,field_ids:{}}}' \
        > "$repo/.migration-state.json"
}

# Helper: write state with N history.migrated and M todo.migrated
write_state_full() {
    local repo="$1" n_hist="$2" n_todo="$3" current_step="$4"
    local hist_entries todo_entries
    if [ "$n_hist" -gt 0 ]; then
        hist_entries=$(jq -n --argjson n "$n_hist" \
            '[range(0;$n)|{entry_id:("h"+(.|tostring)),issue_number:(.+1),title:("H"+(.|tostring))}]')
    else
        hist_entries="[]"
    fi
    if [ "$n_todo" -gt 0 ]; then
        todo_entries=$(jq -n --argjson n "$n_todo" \
            '[range(0;$n)|{entry_id:("t"+(.|tostring)),issue_number:(.+100),title:("T"+(.|tostring))}]')
    else
        todo_entries="[]"
    fi
    jq -n \
        --argjson hist "$hist_entries" \
        --argjson todo "$todo_entries" \
        --argjson step "$current_step" \
        '{schema_version:1,repo_dir:"/fake",started_at:"2026-05-01T00:00:00Z",
          current_step:$step,
          history:{total_entries:0,migrated:$hist},
          todo:{total_entries:0,migrated:$todo,todo_md_rewritten:false},
          project:{number:null,node_id:null,field_ids:{}}}' \
        > "$repo/.migration-state.json"
}

run_orch() {
    run_with_timeout 30 bash "$HARNESS_DIR/orchestrate.sh" "$@"
}

# ============================================================
# d. --from-step 4 does not require --stage (resume-compat)
# ============================================================
REPO_D=$(make_repo)
write_state_with_history_migrated "$REPO_D" 0 3
OUT=$(run_orch "$REPO_D" --from-step 4 --dry-run 2>&1 || true)
if echo "$OUT" | grep -qiE "requires --stage"; then
    fail "d: --from-step 4 should NOT require --stage (saw 'requires --stage')"
else
    pass "d: --from-step 4 does not require --stage"
fi

# ============================================================
# e. --from-step 2 without --stage WITH docs/history.md -> non-zero + guidance
# ============================================================
REPO_E=$(make_repo)
echo "### Entry1" > "$REPO_E/docs/history.md"
init_state "$REPO_E"
OUT=$(run_orch "$REPO_E" --from-step 2 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qiE "(requires --stage|--stage)"; then
    pass "e: --from-step 2 without --stage exits non-zero with stage guidance"
else
    fail "e: --from-step 2 without --stage expected non-zero+guidance (rc=$RC out=$(echo "$OUT" | head -3))"
fi

# ============================================================
# f. --from-step 2 without --stage and WITHOUT docs/history.md -> exit 0 skip
# ============================================================
REPO_F=$(make_repo)
init_state "$REPO_F"
OUT=$(run_orch "$REPO_F" --from-step 2 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -qi "skipping"; then
    pass "f: --from-step 2 without history skips cleanly (exit 0)"
else
    fail "f: --from-step 2 without history expected exit 0 + 'skipping' (rc=$RC)"
fi

# ============================================================
# g. --from-step 2 --stage canary-1 -> exit 0 + next-command hint
# ============================================================
REPO_G=$(make_repo)
printf '### Entry1\n### Entry2\n' > "$REPO_G/docs/history.md"
init_state "$REPO_G"
: > "$MOCK_CALLS_LOG"
OUT=$(run_orch "$REPO_G" --from-step 2 --stage canary-1 2>&1)
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "g1: --stage canary-1 exits 0"
else
    fail "g1: --stage canary-1 expected exit 0 (rc=$RC)"
fi
if echo "$OUT" | grep -qi "canary-2"; then
    pass "g2: output contains next-stage hint 'canary-2'"
else
    fail "g2: missing next-stage hint 'canary-2' in output"
fi
if grep -q "migrate-history:" "$MOCK_CALLS_LOG"; then
    pass "g3: migrate-history.sh was invoked"
else
    fail "g3: migrate-history.sh was NOT invoked"
fi
if grep -q "migrate-history:.*--canary 1" "$MOCK_CALLS_LOG"; then
    pass "g4: migrate-history.sh called with --canary 1"
else
    fail "g4: migrate-history.sh missing '--canary 1' (log: $(cat "$MOCK_CALLS_LOG"))"
fi

# ============================================================
# h. yes y | --stage canary-1 -> only runs canary-1 (no advancement)
# ============================================================
REPO_H=$(make_repo)
printf '### Entry1\n### Entry2\n' > "$REPO_H/docs/history.md"
init_state "$REPO_H"
: > "$MOCK_CALLS_LOG"
OUT=$(yes y | run_with_timeout 30 bash "$HARNESS_DIR/orchestrate.sh" "$REPO_H" --from-step 2 --stage canary-1 2>&1)
RC=$?
N_CALLS=$(grep -c "^migrate-history:" "$MOCK_CALLS_LOG" 2>/dev/null || echo 0)
if [ "$RC" -eq 0 ] && [ "$N_CALLS" -eq 1 ]; then
    pass "h1: --stage canary-1 with 'yes y' invokes migrate-history exactly once"
else
    fail "h1: expected exit 0 + 1 call (rc=$RC calls=$N_CALLS)"
fi
if ! grep -q "migrate-history:.*--canary 2" "$MOCK_CALLS_LOG"; then
    pass "h2: --stage canary-1 did NOT advance to canary 2"
else
    fail "h2: --stage canary-1 leaked into canary 2 (log: $(cat "$MOCK_CALLS_LOG"))"
fi

# ============================================================
# i. --dry-run behavior unchanged
# ============================================================
REPO_I=$(make_repo)
echo "### Entry1" > "$REPO_I/docs/history.md"
OUT=$(run_orch "$REPO_I" --dry-run 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -qiE "(dry.?run|DRY RUN)"; then
    pass "i: --dry-run exits 0 and announces dry-run mode"
else
    fail "i: --dry-run expected exit 0 + announcement (rc=$RC)"
fi

# ============================================================
# j. History idempotency-skip: all --stage values exit 0 when already complete;
#    --stage full advances current_step
# ============================================================
REPO_J=$(make_repo)
printf '### E1\n### E2\n' > "$REPO_J/docs/history.md"
write_state_with_history_migrated "$REPO_J" 2 1

# j1: canary-1
: > "$MOCK_CALLS_LOG"
OUT=$(run_orch "$REPO_J" --from-step 2 --stage canary-1 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -qiE "(already|skipping)"; then
    pass "j1: --stage canary-1 with complete history exits 0 with 'already/skipping'"
else
    fail "j1: rc=$RC out=$(echo "$OUT" | head -3)"
fi

# j2: canary-2
OUT=$(run_orch "$REPO_J" --from-step 2 --stage canary-2 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -qiE "(already|skipping)"; then
    pass "j2: --stage canary-2 with complete history exits 0 with 'already/skipping'"
else
    fail "j2: rc=$RC out=$(echo "$OUT" | head -3)"
fi

# j3: full advances current_step
write_state_with_history_migrated "$REPO_J" 2 1
OUT=$(run_orch "$REPO_J" --from-step 2 --stage full 2>&1)
RC=$?
STEP=$(jq -r '.current_step' "$REPO_J/.migration-state.json" 2>/dev/null || echo "?")
if [ "$RC" -eq 0 ] && [ "$STEP" = "2" ]; then
    pass "j3: --stage full sets current_step=2"
else
    fail "j3: expected rc=0 + current_step=2 (rc=$RC step=$STEP)"
fi

# ============================================================
# k. Todo idempotency-skip: --stage full invokes migrate-todo; canary-1/2 no-ops
# ============================================================
REPO_K=$(make_repo)
printf '### H1\n### H2\n' > "$REPO_K/docs/history.md"
printf '## Section1\n## Section2\n' > "$REPO_K/docs/todo.md"

# k1: canary-1 -> no migrate-todo calls
write_state_full "$REPO_K" 2 2 2
: > "$MOCK_CALLS_LOG"
OUT=$(run_orch "$REPO_K" --from-step 3 --stage canary-1 2>&1)
RC=$?
N=$(grep -c "^migrate-todo:" "$MOCK_CALLS_LOG" 2>/dev/null || true); N=${N:-0}
if [ "$RC" -eq 0 ] && [ "$N" -eq 0 ]; then
    pass "k1: --stage canary-1 with complete todo invokes migrate-todo 0 times"
else
    fail "k1: rc=$RC todo-calls=$N"
fi

# k2: canary-2 -> no migrate-todo calls
write_state_full "$REPO_K" 2 2 2
: > "$MOCK_CALLS_LOG"
OUT=$(run_orch "$REPO_K" --from-step 3 --stage canary-2 2>&1)
RC=$?
N=$(grep -c "^migrate-todo:" "$MOCK_CALLS_LOG" 2>/dev/null || true); N=${N:-0}
if [ "$RC" -eq 0 ] && [ "$N" -eq 0 ]; then
    pass "k2: --stage canary-2 with complete todo invokes migrate-todo 0 times"
else
    fail "k2: rc=$RC todo-calls=$N"
fi

# k3: full -> 1 migrate-todo call without --canary; current_step=3
write_state_full "$REPO_K" 2 2 2
: > "$MOCK_CALLS_LOG"
OUT=$(run_orch "$REPO_K" --from-step 3 --stage full 2>&1)
RC=$?
N=$(grep -c "^migrate-todo:" "$MOCK_CALLS_LOG" 2>/dev/null || true); N=${N:-0}
STEP=$(jq -r '.current_step' "$REPO_K/.migration-state.json" 2>/dev/null || echo "?")
HAS_CANARY=$(grep "^migrate-todo:" "$MOCK_CALLS_LOG" | grep -c -- "--canary" || true)
if [ "$RC" -eq 0 ] && [ "$N" -eq 1 ] && [ "$STEP" = "3" ] && [ "$HAS_CANARY" -eq 0 ]; then
    pass "k3: --stage full invokes migrate-todo once (no --canary) and sets current_step=3"
else
    fail "k3: rc=$RC todo-calls=$N step=$STEP has-canary=$HAS_CANARY"
fi

# Cleanup harness
rm -rf "$HARNESS_DIR" "$GH_MOCK_DIR"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
