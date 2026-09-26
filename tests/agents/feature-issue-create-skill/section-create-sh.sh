# S1-S19: bin/github-issues/issue-create.sh tests

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
run_with_timeout 30 bash "$TARGET" --title "Test task" --body "$(printf "$CANONICAL_BODY")" >/dev/null 2>&1
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
run_with_timeout 30 bash "$TARGET" --title "Hooks task" --body "$(printf "$CANONICAL_BODY")" \
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
run_with_timeout 30 bash "$TARGET" --title "Test" --body "$(printf "$CANONICAL_BODY")" \
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
run_with_timeout 30 bash "$TARGET" --title "URL test" --body "$(printf "$CANONICAL_BODY")" \
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
# S12: inline Background: + Changes: both present → exit 0
# ---------------------------------------------------------------------------
setup_mock
run_with_timeout 30 bash "$TARGET" --title "Schema ok" \
    --body "$(printf 'Background: bg\nChanges: ch')" >/dev/null 2>/dev/null
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "S12: inline Background: + Changes: present → exit 0"
else
    fail "S12: inline Background: + Changes: should exit 0, got rc=$RC"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S13: Background: only (Changes missing) → exit 3, stderr mentions Changes
# ---------------------------------------------------------------------------
setup_mock
STDERR_OUT="$TMP/s13-stderr.txt"
run_with_timeout 30 bash "$TARGET" --title "Missing Changes" \
    --body "Background: bg" >/dev/null 2>"$STDERR_OUT"
RC=$?
if [ "$RC" -eq 3 ] && grep -qF "Changes" "$STDERR_OUT" 2>/dev/null; then
    pass "S13: Background: only → exit 3, stderr mentions Changes"
else
    fail "S13: Background: only handling incorrect (rc=$RC stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S14: ## Background H2 + ## Changes H2 → exit 0
# ---------------------------------------------------------------------------
setup_mock
run_with_timeout 30 bash "$TARGET" --title "H2 schema" \
    --body "$(printf '## Background\nbg\n\n## Changes\nch')" >/dev/null 2>/dev/null
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "S14: ## Background + ## Changes H2 → exit 0"
else
    fail "S14: ## Background + ## Changes H2 should exit 0, got rc=$RC"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S15: ### background + ### changes (H3 lowercase) → exit 0
# ---------------------------------------------------------------------------
setup_mock
run_with_timeout 30 bash "$TARGET" --title "H3 lowercase" \
    --body "$(printf '### background\nbg\n\n### changes\nch')" >/dev/null 2>/dev/null
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "S15: ### background + ### changes (H3 lowercase) → exit 0"
else
    fail "S15: ### background + ### changes H3 lowercase should exit 0, got rc=$RC"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S16: no canonical fields → exit 3, stderr contains "Background, Changes" (IFS join regression)
# ---------------------------------------------------------------------------
setup_mock
STDERR_OUT="$TMP/s16-stderr.txt"
run_with_timeout 30 bash "$TARGET" --title "No fields" \
    --body "no fields at all" >/dev/null 2>"$STDERR_OUT"
RC=$?
if [ "$RC" -eq 3 ] && grep -qF "Background, Changes" "$STDERR_OUT" 2>/dev/null; then
    pass "S16: no canonical fields → exit 3, stderr has 'Background, Changes' (IFS join correct)"
else
    fail "S16: no canonical fields handling incorrect (rc=$RC stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S17: ISSUE_CREATE_SKIP_SCHEMA=1 bypass → exit 0 even with empty body
# ---------------------------------------------------------------------------
setup_mock
export ISSUE_CREATE_SKIP_SCHEMA=1
run_with_timeout 30 bash "$TARGET" --title "Bypass" \
    --body "" >/dev/null 2>/dev/null
unset ISSUE_CREATE_SKIP_SCHEMA
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "S17: ISSUE_CREATE_SKIP_SCHEMA=1 bypass → exit 0 with empty body"
else
    fail "S17: ISSUE_CREATE_SKIP_SCHEMA=1 bypass should exit 0, got rc=$RC"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S18: --body-file with Background only (Changes missing) → exit 3
# ---------------------------------------------------------------------------
setup_mock
BODY_FILE_TMP="$TMP/s18-body.txt"
printf 'Background: bg\n' > "$BODY_FILE_TMP"
STDERR_OUT="$TMP/s18-stderr.txt"
run_with_timeout 30 bash "$TARGET" --title "File missing Changes" \
    --body-file "$BODY_FILE_TMP" >/dev/null 2>"$STDERR_OUT"
RC=$?
if [ "$RC" -eq 3 ] && grep -qF "Changes" "$STDERR_OUT" 2>/dev/null; then
    pass "S18: --body-file with Changes missing → exit 3"
else
    fail "S18: --body-file missing Changes handling incorrect (rc=$RC stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
fi
teardown_mock

# ---------------------------------------------------------------------------
# S19: SKILL.md doc regression — mentions ISSUE_CREATE_SKIP_SCHEMA and exits 3
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
    fail "S19: skills/issue-create/SKILL.md missing"
elif grep -q "ISSUE_CREATE_SKIP_SCHEMA" "$SKILL_MD" && grep -q "exits 3" "$SKILL_MD"; then
    pass "S19: SKILL.md documents ISSUE_CREATE_SKIP_SCHEMA and exits 3"
else
    fail "S19: SKILL.md missing ISSUE_CREATE_SKIP_SCHEMA or 'exits 3' reference"
fi
