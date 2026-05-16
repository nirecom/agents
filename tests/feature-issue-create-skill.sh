#!/bin/bash
# Tests for the new /issue-create skill:
#   bin/github-issues/issue-create.sh  — bash wrapper around gh issue create
#   skills/issue-create/SKILL.md       — YAML frontmatter skill definition
#   rules/github-issues.md             — ## Issue creation section
#   CLAUDE.md                          — /issue-create mention
#
# RED: this suite fails clean while bin/github-issues/issue-create.sh is missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$AGENTS_DIR/bin/github-issues/issue-create.sh"
SKILL_MD="$AGENTS_DIR/skills/issue-create/SKILL.md"
RULES_GH="$AGENTS_DIR/rules/github-issues.md"
CLAUDE_MD="$AGENTS_DIR/CLAUDE.md"

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

# Early-exit: if the implementation is missing, report cleanly and exit.
if [ ! -f "$TARGET" ]; then
    echo "FAIL: bin/github-issues/issue-create.sh not found (implementation missing)"
    echo ""
    echo "Results: 0 passed, 19 failed"
    exit 1
fi

# ---------------------------------------------------------------------------
# Inline gh mock factory — creates a self-contained mock in $TMP/mock-bin/gh
# per test so each test gets its own args log and env vars.
# ---------------------------------------------------------------------------

TMP=""

setup_mock() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/mock-bin"
    cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${GH_MOCK_ARGS_LOG:-}" ]; then
    printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
fi
case "$ARGS" in
  auth\ status*)
    echo "Token scopes: 'gist', 'project', 'read:org', 'repo'"
    exit 0 ;;
  issue\ create\ *)
    echo "https://github.com/nirecom/agents/issues/9999"
    exit 0 ;;
  project\ item-add\ *)
    if [ "${GH_MOCK_PROJECT_FAIL:-0}" = "1" ]; then
        echo "error: project attach failed" >&2
        exit 1
    fi
    echo "PVTI_mock_item_id_9999"
    exit 0 ;;
  issue\ view\ *createdAt*)
    if [ "${GH_MOCK_CREATEDAT_EMPTY:-0}" = "1" ]; then
        echo ""; exit 0
    fi
    echo "2026-05-15"
    exit 0 ;;
  project\ item-edit\ *)
    if [ "${GH_MOCK_ITEM_EDIT_FAIL:-0}" = "1" ]; then
        echo "error: item-edit failed" >&2; exit 1
    fi
    exit 0 ;;
  *)
    echo "MOCK GH: no match for args=$ARGS" >&2
    exit 2 ;;
esac
MOCK_EOF
    chmod +x "$TMP/mock-bin/gh"
    export PATH="$TMP/mock-bin:$PATH"
    export GH_MOCK_ARGS_LOG="$TMP/gh-args.log"
    : > "$GH_MOCK_ARGS_LOG"
}

teardown_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    TMP=""
    unset GH_MOCK_ARGS_LOG GH_MOCK_PROJECT_FAIL GH_MOCK_CREATEDAT_EMPTY GH_MOCK_ITEM_EDIT_FAIL 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# S1: script exists and is executable
# ---------------------------------------------------------------------------
if [ -x "$TARGET" ]; then
    pass "S1: script exists at expected path and is executable"
else
    fail "S1: script exists but is not executable"
fi

# ---------------------------------------------------------------------------
# S2: type:task always applied to gh issue create invocation
# ---------------------------------------------------------------------------
setup_mock
run_with_timeout 30 bash "$TARGET" --title "Test task" --body "body text" >/dev/null 2>&1
RC=$?
if grep -q -- "type:task" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "S2: type:task label always applied to gh issue create"
else
    fail "S2: type:task label not found in gh invocation (rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S3: --label type:* → exit 2, no gh issue create call
# ---------------------------------------------------------------------------
setup_mock
run_with_timeout 30 bash "$TARGET" --title "Test" --body "body" \
    --label "type:incident" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ] && ! grep -q "issue create" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "S3: --label type:incident → exit 2, no gh issue create call"
else
    fail "S3: --label type:incident handling incorrect (rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S4: --label area:hooks (non-type:*) passes through alongside type:task
# ---------------------------------------------------------------------------
setup_mock
run_with_timeout 30 bash "$TARGET" --title "Hooks task" --body "body" \
    --label "area:hooks" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] && \
   grep -q "type:task" "$GH_MOCK_ARGS_LOG" 2>/dev/null && \
   grep -q "area:hooks" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "S4: non-type:* label passes through alongside type:task"
else
    fail "S4: non-type:* label passthrough incorrect (rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S5: Projects v2 attach non-fatal — gh project item-add fails → exit 0,
#     stderr warning, stdout has issue URL
# ---------------------------------------------------------------------------
setup_mock
export GH_MOCK_PROJECT_FAIL=1
STDOUT_OUT="$TMP/s5-stdout.txt"
STDERR_OUT="$TMP/s5-stderr.txt"
run_with_timeout 30 bash "$TARGET" --title "Test" --body "body" \
    >"$STDOUT_OUT" 2>"$STDERR_OUT"
RC=$?
if [ "$RC" -eq 0 ] && \
   grep -qE "https://github.com/.+/issues/[0-9]+" "$STDOUT_OUT" 2>/dev/null && \
   [ -s "$STDERR_OUT" ]; then
    pass "S5: project item-add failure is non-fatal (exit 0, URL on stdout, warning on stderr)"
else
    fail "S5: project item-add non-fatal handling incorrect (rc=$RC stdout=$(cat "$STDOUT_OUT" 2>/dev/null) stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S6: final stdout line is a parseable GitHub issue URL
# ---------------------------------------------------------------------------
setup_mock
STDOUT_OUT="$TMP/s6-stdout.txt"
run_with_timeout 30 bash "$TARGET" --title "URL test" --body "body" \
    >"$STDOUT_OUT" 2>/dev/null
LAST_LINE=$(tail -1 "$STDOUT_OUT" 2>/dev/null)
if echo "$LAST_LINE" | grep -qE "https://github.com/.+/issues/[0-9]+"; then
    pass "S6: final stdout line is a parseable GitHub issue URL"
else
    fail "S6: final stdout line is not a GitHub URL (got='$LAST_LINE')"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S7: --title missing → exit 2, stderr contains "--title"
# ---------------------------------------------------------------------------
setup_mock
STDERR_OUT="$TMP/s7-stderr.txt"
run_with_timeout 30 bash "$TARGET" --body "body" >/dev/null 2>"$STDERR_OUT"
RC=$?
if [ "$RC" -eq 2 ] && grep -qi -- "--title" "$STDERR_OUT" 2>/dev/null; then
    pass "S7: missing --title → exit 2, stderr mentions --title"
else
    fail "S7: missing --title handling incorrect (rc=$RC stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S8: --body and --body-file both missing → exit 2
# ---------------------------------------------------------------------------
setup_mock
run_with_timeout 30 bash "$TARGET" --title "No body" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "S8: missing --body and --body-file → exit 2"
else
    fail "S8: missing body should exit 2, got rc=$RC"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S9: --body and --body-file both provided → exit 2 (mutually exclusive)
# ---------------------------------------------------------------------------
setup_mock
echo "file body" > "$TMP/body.txt"
run_with_timeout 30 bash "$TARGET" --title "Conflict" --body "inline" \
    --body-file "$TMP/body.txt" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "S9: --body and --body-file together → exit 2"
else
    fail "S9: --body and --body-file together should exit 2, got rc=$RC"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S10: --body-file path does not exist → exit 1
# ---------------------------------------------------------------------------
setup_mock
run_with_timeout 30 bash "$TARGET" --title "Missing file" \
    --body-file "$TMP/nonexistent.txt" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 1 ]; then
    pass "S10: nonexistent --body-file → exit 1"
else
    fail "S10: nonexistent --body-file should exit 1, got rc=$RC"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S11: gh not in PATH → exit 1, stderr contains "gh CLI not found"
# ---------------------------------------------------------------------------
TMPDIR_E5="$(mktemp -d)"
STDERR_OUT="$TMPDIR_E5/s11-stderr.txt"
run_with_timeout 30 env PATH="/bin:/usr/bin" HOME="${HOME:-/root}" \
    bash "$TARGET" --title "No gh" --body "body" >/dev/null 2>"$STDERR_OUT"
RC=$?
if [ "$RC" -eq 1 ] && grep -qiE "gh.*not found|not found.*gh|gh CLI" "$STDERR_OUT" 2>/dev/null; then
    pass "S11: gh not in PATH → exit 1, stderr mentions gh"
else
    fail "S11: gh not in PATH handling incorrect (rc=$RC stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
fi
rm -rf "$TMPDIR_E5"

# ---------------------------------------------------------------------------
# D1: skills/issue-create/SKILL.md exists with name: issue-create and description:
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
    fail "D1: skills/issue-create/SKILL.md missing — RED until implementation"
elif grep -q "^name: issue-create" "$SKILL_MD" && grep -q "^description:" "$SKILL_MD"; then
    pass "D1: SKILL.md has YAML frontmatter with name: issue-create and description:"
else
    fail "D1: SKILL.md exists but missing name: issue-create or description: in frontmatter"
fi

# ---------------------------------------------------------------------------
# D2: SKILL.md mentions the wrapper path bin/github-issues/issue-create.sh
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
    fail "D2: skills/issue-create/SKILL.md missing — RED until implementation"
elif grep -q "bin/github-issues/issue-create.sh" "$SKILL_MD"; then
    pass "D2: SKILL.md references bin/github-issues/issue-create.sh"
else
    fail "D2: SKILL.md does not reference bin/github-issues/issue-create.sh"
fi

# ---------------------------------------------------------------------------
# D3: rules/github-issues.md contains ## Issue creation heading and /issue-create
# ---------------------------------------------------------------------------
if [ ! -f "$RULES_GH" ]; then
    fail "D3: rules/github-issues.md not found"
elif grep -q "^## Issue creation" "$RULES_GH" && grep -q "/issue-create" "$RULES_GH"; then
    pass "D3: rules/github-issues.md has ## Issue creation heading and /issue-create mention"
else
    fail "D3: rules/github-issues.md missing ## Issue creation heading or /issue-create mention — RED until implementation"
fi

# ---------------------------------------------------------------------------
# D4: CLAUDE.md mentions /issue-create
# ---------------------------------------------------------------------------
if [ ! -f "$CLAUDE_MD" ]; then
    fail "D4: CLAUDE.md not found"
elif grep -q "/issue-create" "$CLAUDE_MD"; then
    pass "D4: CLAUDE.md mentions /issue-create"
else
    fail "D4: CLAUDE.md does not mention /issue-create — RED until implementation"
fi

# ---------------------------------------------------------------------------
# T1: Content Date happy path — item-add with --format json, item-edit with right args, no warnings
# ---------------------------------------------------------------------------
setup_mock
STDERR_OUT="$TMP/t1-stderr.txt"
run_with_timeout 30 bash "$TARGET" --title "Date test" --body "body" >/dev/null 2>"$STDERR_OUT"
RC=$?
if [ "$RC" -eq 0 ] \
   && grep -qE "issue view 9999" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
   && grep -qE "project item-add.*--format json.*--jq|project item-add.*--jq.*--format json" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
   && grep -q "project item-edit" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
   && grep -q -- "--date 2026-05-15" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
   && grep -q -- "--field-id PVTF_lAHOAMF_jc4BXf9EzhSsYwA" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
   && grep -q -- "--project-id PVT_kwHOAMF_jc4BXf9E" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
   && ! grep -qi "warn:" "$STDERR_OUT" 2>/dev/null; then
    pass "T1: Content Date set: correct issue#, --format json in item-add, right date/ids, no warnings"
else
    fail "T1: Content Date happy-path incorrect (rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null) stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# T2: createdAt fetch fails → item-edit skipped, non-fatal (exit 0)
# ---------------------------------------------------------------------------
setup_mock
export GH_MOCK_CREATEDAT_EMPTY=1
STDERR_OUT="$TMP/t2-stderr.txt"
run_with_timeout 30 bash "$TARGET" --title "No createdAt" --body "body" >/dev/null 2>"$STDERR_OUT"
RC=$?
if [ "$RC" -eq 0 ] \
   && ! grep -q "project item-edit" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
   && grep -qi "failed to fetch createdAt" "$STDERR_OUT" 2>/dev/null; then
    pass "T2: createdAt failure skips item-edit (non-fatal)"
else
    fail "T2: createdAt failure handling incorrect (rc=$RC stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# T3: item-edit fails → non-fatal (exit 0, URL on stdout, warning on stderr)
# ---------------------------------------------------------------------------
setup_mock
export GH_MOCK_ITEM_EDIT_FAIL=1
STDOUT_OUT="$TMP/t3-stdout.txt"
STDERR_OUT="$TMP/t3-stderr.txt"
run_with_timeout 30 bash "$TARGET" --title "Edit fail" --body "body" >"$STDOUT_OUT" 2>"$STDERR_OUT"
RC=$?
if [ "$RC" -eq 0 ] \
   && grep -qE "https://github.com/.+/issues/[0-9]+" "$STDOUT_OUT" 2>/dev/null \
   && grep -qi "failed to set Content Date" "$STDERR_OUT" 2>/dev/null; then
    pass "T3: item-edit failure is non-fatal (exit 0, URL on stdout, warning on stderr)"
else
    fail "T3: item-edit non-fatal handling incorrect (rc=$RC stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# T4: ISSUE_CREATE_FIELD_ID / ISSUE_CREATE_PROJECT_ID env-var overrides honored
# ---------------------------------------------------------------------------
setup_mock
export ISSUE_CREATE_FIELD_ID=PVTF_override_field
export ISSUE_CREATE_PROJECT_ID=PVT_override_project
run_with_timeout 30 bash "$TARGET" --title "Override" --body "body" >/dev/null 2>/dev/null
RC=$?
if [ "$RC" -eq 0 ] \
   && grep -q -- "--field-id PVTF_override_field" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
   && grep -q -- "--project-id PVT_override_project" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "T4: ISSUE_CREATE_FIELD_ID / ISSUE_CREATE_PROJECT_ID env-var overrides honored"
else
    fail "T4: env-var override not honored (rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
fi
unset ISSUE_CREATE_FIELD_ID ISSUE_CREATE_PROJECT_ID
teardown_mock

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
