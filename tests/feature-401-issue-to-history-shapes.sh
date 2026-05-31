#!/bin/bash
# Tests: bin/github-issues/issue-to-history.sh, bin/github-issues/lib/extract-field.sh
# Tags: 401, issue-to-history-shapes
set -u
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$AGENTS_DIR/bin/github-issues/lib/extract-field.sh"
if [ ! -f "$LIB" ]; then
    echo "FAIL: precondition missing — $LIB"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi
source "$LIB"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

assert_eq() {
    local field="$1"; local body="$2"; local expected="$3"; local label="$4"
    local got; got="$(BODY="$body" extract_field "$field")"
    if [ "$got" = "$expected" ]; then pass "$label"; else fail "$label (expected='$expected' got='$got')"; fi
}

# S1: inline label
assert_eq Background $'Background: foo bar\nChanges: baz' "foo bar" "S1 inline label"
# S2: H2 header
assert_eq Background $'## Background\n\nfoo bar\n\n## Changes\n\nbaz' "foo bar" "S2 H2 header"
# S3: H3 header multiline
assert_eq Background $'### Background\n\nfoo\nbar\n\n### Changes\n\nbaz' "foo bar" "S3 H3 multiline"
# S4: lowercase inline
assert_eq Background $'background: lower' "lower" "S4 lowercase inline"
# S5: lowercase H2
assert_eq Background $'## background\nfoo' "foo" "S5 lowercase H2"
# S6: wrong field name
assert_eq Background $'Changes: only-changes' "" "S6 wrong field"
# S7: changes field with sub-heading before it
assert_eq Changes $'## Background\nfirst\n## Sub\nirrelevant\n## Changes\nbaz' "baz" "S7 changes with sub-heading"
# S8: inline Cause
assert_eq Cause $'Cause: x\nFix: y' "x" "S8 cause inline"
# S9: H2 Fix
assert_eq Fix $'## Cause\n\nx\n\n## Fix\n\ny' "y" "S9 fix H2"

# === issue-to-history.sh: --history-notes-file / --non-github-mode shapes ===

SCRIPT="$AGENTS_DIR/bin/github-issues/issue-to-history.sh"
MOCK_DIR="$AGENTS_DIR/tests/fixtures/gh-mock"

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout "$1" "${@:2}"; else perl -e 'alarm shift; exec @ARGV' "$@"; fi
}

setup_ith_tmp() {
    ITH_TMP=$(mktemp -d)
    mkdir -p "$ITH_TMP/docs/history"
    touch "$ITH_TMP/docs/history.md"
    export AGENTS_CONFIG_DIR="$ITH_TMP"
    export PATH="$MOCK_DIR:$PATH"
}

teardown_ith_tmp() {
    [ -n "${ITH_TMP:-}" ] && rm -rf "$ITH_TMP"
    unset AGENTS_CONFIG_DIR ITH_TMP
}

if [ -f "$SCRIPT" ]; then

# H1: --history-notes-file with ## History Notes section → "item A" in Changes:
setup_ith_tmp
NOTES_FILE=$(mktemp)
printf '## History Notes\n- item A\n- item B\n' > "$NOTES_FILE"
out=$(GH_MOCK_SCENARIO=issue_task run_with_timeout 15 bash "$SCRIPT" 42 --commit abc1234 \
    --history-notes-file "$NOTES_FILE" 2>/dev/null)
rc=$?
if { [ "$rc" -eq 0 ] && echo "$out" | grep -qE "item A|item B"; } || \
   grep -qE "item A|item B" "$ITH_TMP/docs/history.md" 2>/dev/null; then
    pass "H1: --history-notes-file merges History Notes bullets into history entry"
else
    if grep -qE "item A|item B" "$ITH_TMP/docs/history.md" 2>/dev/null; then
        pass "H1: --history-notes-file merges History Notes bullets into history entry"
    else
        fail "H1: rc=$rc, history.md=$(cat "$ITH_TMP/docs/history.md" 2>/dev/null | head -20)"
    fi
fi
rm -f "$NOTES_FILE"
teardown_ith_tmp

# H2: --history-notes-file with only "- (none)" → no history notes appended
setup_ith_tmp
NOTES_FILE=$(mktemp)
printf '## History Notes\n- (none)\n' > "$NOTES_FILE"
out=$(GH_MOCK_SCENARIO=issue_task run_with_timeout 15 bash "$SCRIPT" 42 --commit abc1234 \
    --history-notes-file "$NOTES_FILE" 2>/dev/null)
rc=$?
history_content=$(cat "$ITH_TMP/docs/history.md" 2>/dev/null)
if [ "$rc" -eq 0 ] && ! echo "$history_content" | grep -qi "History Notes:"; then
    pass "H2: --history-notes-file with only '- (none)' → History Notes: not appended"
else
    fail "H2: rc=$rc, unexpected History Notes: in output"
fi
rm -f "$NOTES_FILE"
teardown_ith_tmp

# NG1: --non-github-mode → doc-append without gh issue view
setup_ith_tmp
BODY_FILE=$(mktemp)
printf '## Background / Motivation\nSome background text\n\n## Changes\nSome changes\n' > "$BODY_FILE"
out=$(run_with_timeout 15 bash "$SCRIPT" 999 --commit abc1234 \
    --non-github-mode --title "Non-GitHub Test" --body-file "$BODY_FILE" \
    --closed-date "2026-01-01" 2>/dev/null)
rc=$?
history_content=$(cat "$ITH_TMP/docs/history.md" 2>/dev/null)
if [ "$rc" -eq 0 ] && echo "$history_content" | grep -q "Non-GitHub Test"; then
    pass "NG1: --non-github-mode creates history entry without gh issue view"
else
    fail "NG1: rc=$rc, history.md='$history_content'"
fi
rm -f "$BODY_FILE"
teardown_ith_tmp

# Sidecar-1: WORKTREE_NOTES.md sidecar handoff (Phase 1 → Phase 2 simulation)
setup_ith_tmp
SIDECAR_DIR=$(mktemp -d)
SIDECAR_FILE="$SIDECAR_DIR/issue-42-worktree-notes.md"
printf '# Worktree Notes\nBranch: fix/test\n\n## History Notes\n- sidecar-note-alpha\n- sidecar-note-beta\n' > "$SIDECAR_FILE"
out=$(GH_MOCK_SCENARIO=issue_task run_with_timeout 15 bash "$SCRIPT" 42 --commit abc1234 \
    --history-notes-file "$SIDECAR_FILE" 2>/dev/null)
rc=$?
history_content=$(cat "$ITH_TMP/docs/history.md" 2>/dev/null)
if [ "$rc" -eq 0 ] && echo "$history_content" | grep -q "sidecar-note-alpha"; then
    pass "Sidecar-1: per-issue sidecar handoff → notes appear in history entry"
else
    fail "Sidecar-1: rc=$rc, history.md='$history_content'"
fi
rm -rf "$SIDECAR_DIR"
teardown_ith_tmp

else
    fail "H1 (precondition): $SCRIPT not found"
    fail "H2 (precondition): $SCRIPT not found"
    fail "NG1 (precondition): $SCRIPT not found"
    fail "Sidecar-1 (precondition): $SCRIPT not found"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
