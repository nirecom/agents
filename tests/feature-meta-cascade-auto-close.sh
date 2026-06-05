#!/bin/bash
# Tests: bin/github-issues/issue-close-finalize-triage.sh, agents/issue-close-finalize-worker.md, skills/issue-close-finalize/SKILL.md, bin/issue-close-write-outcome.js
# Tags: issue-close, finalize, meta, admin-close-path, cascade

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FINALIZE_TRIAGE_SCRIPT="$AGENTS_DIR/bin/github-issues/issue-close-finalize-triage.sh"
MOCK_DIR="$AGENTS_DIR/tests/fixtures/gh-mock"

PASS=0; FAIL=0

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

for f in gh doc-append git; do
    if [ -f "$MOCK_DIR/$f" ] && [ ! -x "$MOCK_DIR/$f" ]; then
        chmod +x "$MOCK_DIR/$f" 2>/dev/null || true
    fi
done

setup_tmp() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/docs/history"
    : > "$TMP/docs/history.md"
    export AGENTS_CONFIG_DIR="$TMP"
    export PATH="$MOCK_DIR:$PATH"
    export GH_MOCK_COMMENT_LOG="$TMP/comments.log"
    : > "$GH_MOCK_COMMENT_LOG"
}

teardown_tmp() {
    [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP"
    unset AGENTS_CONFIG_DIR GH_MOCK_COMMENT_LOG
}

# MC1: triage returns admin_close_path (distinct from auto_close_path)
# Verifies that meta-cascade routing is its own ACTION, not aliased to the
# closes-#N auto-close path.
setup_tmp
unset STATE SENTINEL ACTION NEXT_STEPS
OUT=$(cd "$TMP" && GH_MOCK_SCENARIO=meta_admin_close_path run_with_timeout 15 bash "$FINALIZE_TRIAGE_SCRIPT" 42 2>/dev/null)
RC=$?
eval "$OUT" 2>/dev/null || true
if [ "$RC" -eq 0 ] && [ "${ACTION:-}" = "admin_close_path" ] && [ "${ACTION:-}" != "auto_close_path" ] && printf '%s' "${NEXT_STEPS:-}" | grep -q "J"; then
    pass "MC1: triage -> admin_close_path (not auto_close_path), J in NEXT_STEPS"
else
    fail "MC1: rc=$RC action=${ACTION:-} next=${NEXT_STEPS:-}"
fi
teardown_tmp

# MC2: SKILL.md has admin_close_path guard on find-pr-by-marker (RED until implementation)
# The G.5 / J step requires PR/SHA lookup, which is skipped on admin_close_path
# because the meta issue is admin-closed without a PR.
SKILL_FILE="$AGENTS_DIR/skills/issue-close-finalize/SKILL.md"
if grep -q "admin_close_path" "$SKILL_FILE" && grep -q "find-pr-by-marker" "$SKILL_FILE"; then
    pass "MC2: SKILL.md has admin_close_path guard near find-pr-by-marker"
else
    fail "MC2: SKILL.md missing admin_close_path guard on find-pr-by-marker (expected RED before impl)"
fi

# MC3: issue-close-write-outcome.js accepts skipped_admin_close historyEntry
# Confirms the outcome JSON writer is value-agnostic for historyEntry, so
# implementation can pass through a new literal without code changes.
TMP_MC3="$(mktemp -d)"
OUT_FILE="$TMP_MC3/out.json"
node "$AGENTS_DIR/bin/issue-close-write-outcome.js" \
    --session-id test123 \
    --out-file "$OUT_FILE" \
    42 succeeded skipped_admin_close succeeded succeeded succeeded 2>/dev/null
RC=$?
if [ "$RC" -eq 0 ] && [ -f "$OUT_FILE" ]; then
    HISTORY_ENTRY=$(OUT_FILE="$OUT_FILE" node -e "const fs=require('fs');const d=JSON.parse(fs.readFileSync(process.env.OUT_FILE,'utf8'));const e=d.issues.find(x=>x.issueNumber===42);console.log(e?e.historyEntry:'')" 2>/dev/null)
    if [ "$HISTORY_ENTRY" = "skipped_admin_close" ]; then
        pass "MC3: issue-close-write-outcome.js -> historyEntry=skipped_admin_close"
    else
        fail "MC3: historyEntry='$HISTORY_ENTRY' (expected skipped_admin_close)"
    fi
else
    fail "MC3: write-outcome exited rc=$RC or no file"
fi
rm -rf "$TMP_MC3"

# MC4: worker.md Step L has skipped_admin_close label (RED until implementation)
# Worker passes triage_action through to Step L's historyEntry decision; the
# admin_close_path branch must map to skipped_admin_close.
WORKER_FILE="$AGENTS_DIR/agents/issue-close-finalize-worker.md"
if grep -q "skipped_admin_close" "$WORKER_FILE"; then
    pass "MC4: worker.md has skipped_admin_close in historyEntry decision"
else
    fail "MC4: worker.md missing skipped_admin_close (expected RED before impl)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
