# D1-D4 doc checks, T1-T4 content date tests
# Each case is a function; run_case backgrounds it, run_case_sync runs a static check in-process.

# D1: skills/issue-create/SKILL.md exists with name: issue-create and description:
case_d1() {
    if [[ ! -f "$SKILL_MD" ]]; then
        fail "D1: skills/issue-create/SKILL.md missing — RED until implementation"
    elif grep -q "^name: issue-create" "$SKILL_MD" && grep -q "^description:" "$SKILL_MD"; then
        pass "D1: SKILL.md has YAML frontmatter with name: issue-create and description:"
    else
        fail "D1: SKILL.md exists but missing name: issue-create or description: in frontmatter"
    fi
}
run_case_sync case_d1

# D2: SKILL.md mentions the wrapper path bin/github-issues/issue-create.sh
case_d2() {
    if [[ ! -f "$SKILL_MD" ]]; then
        fail "D2: skills/issue-create/SKILL.md missing — RED until implementation"
    elif grep -q "bin/github-issues/issue-create.sh" "$SKILL_MD"; then
        pass "D2: SKILL.md references bin/github-issues/issue-create.sh"
    else
        fail "D2: SKILL.md does not reference bin/github-issues/issue-create.sh"
    fi
}
run_case_sync case_d2

# D3: rules/github-issues.md contains ## Issue creation heading and /issue-create
case_d3() {
    if [[ ! -f "$RULES_GH" ]]; then
        fail "D3: rules/github-issues.md not found"
    elif grep -q "^## Issue creation" "$RULES_GH" && grep -q "/issue-create" "$RULES_GH"; then
        pass "D3: rules/github-issues.md has ## Issue creation heading and /issue-create mention"
    else
        fail "D3: rules/github-issues.md missing ## Issue creation heading or /issue-create mention — RED until implementation"
    fi
}
run_case_sync case_d3

# D4: CLAUDE.md mentions /issue-create
case_d4() {
    if [[ ! -f "$CLAUDE_MD" ]]; then
        fail "D4: CLAUDE.md not found"
    elif grep -q "/issue-create" "$CLAUDE_MD"; then
        pass "D4: CLAUDE.md mentions /issue-create"
    else
        fail "D4: CLAUDE.md does not mention /issue-create — RED until implementation"
    fi
}
run_case_sync case_d4

# T1: Content Date happy path — item-add with --format json, item-edit with right args, no warnings
case_t1() {
    local RC=0 STDERR_OUT
    setup_mock
    STDERR_OUT="$TMP/t1-stderr.txt"
    run_with_timeout 30 bash "$TARGET" --title "Date test" --body "$(printf "$CANONICAL_BODY")" >/dev/null 2>"$STDERR_OUT" || RC=$?
    if [[ "$RC" -eq 0 ]] \
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
}
run_case case_t1

# T2: createdAt fetch fails → item-edit skipped, non-fatal (exit 0)
case_t2() {
    local RC=0 STDERR_OUT
    setup_mock
    export GH_MOCK_CREATEDAT_EMPTY=1
    STDERR_OUT="$TMP/t2-stderr.txt"
    run_with_timeout 30 bash "$TARGET" --title "No createdAt" --body "$(printf "$CANONICAL_BODY")" >/dev/null 2>"$STDERR_OUT" || RC=$?
    if [[ "$RC" -eq 0 ]] \
       && ! grep -q "project item-edit" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -qiE "failed to fetch createdAt|empty createdAt" "$STDERR_OUT" 2>/dev/null; then
        pass "T2: createdAt failure skips item-edit (non-fatal)"
    else
        fail "T2: createdAt failure handling incorrect (rc=$RC stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
    fi
    teardown_mock
}
run_case case_t2

# T3: item-edit fails → non-fatal (exit 0, URL on stdout, warning on stderr)
case_t3() {
    local RC=0 STDOUT_OUT STDERR_OUT
    setup_mock
    export GH_MOCK_ITEM_EDIT_FAIL=1
    STDOUT_OUT="$TMP/t3-stdout.txt"
    STDERR_OUT="$TMP/t3-stderr.txt"
    run_with_timeout 30 bash "$TARGET" --title "Edit fail" --body "$(printf "$CANONICAL_BODY")" >"$STDOUT_OUT" 2>"$STDERR_OUT" || RC=$?
    if [[ "$RC" -eq 0 ]] \
       && grep -qE "https://github.com/.+/issues/[0-9]+" "$STDOUT_OUT" 2>/dev/null \
       && grep -qiE "failed to set Content Date|Content Date set failed" "$STDERR_OUT" 2>/dev/null; then
        pass "T3: item-edit failure is non-fatal (exit 0, URL on stdout, warning on stderr)"
    else
        fail "T3: item-edit non-fatal handling incorrect (rc=$RC stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
    fi
    teardown_mock
}
run_case case_t3

# T4: _ISSUE_CREATE_INTERNAL_* env-var overrides honored (short-circuit path)
case_t4() {
    local RC=0
    setup_mock
    export _ISSUE_CREATE_INTERNAL_OWNER=nirecom
    export _ISSUE_CREATE_INTERNAL_PROJECT_NUM=1
    export _ISSUE_CREATE_INTERNAL_PROJECT_ID=PVT_override_project
    export _ISSUE_CREATE_INTERNAL_FIELD_ID=PVTF_override_field
    run_with_timeout 30 bash "$TARGET" --title "Override" --body "$(printf "$CANONICAL_BODY")" >/dev/null 2>/dev/null || RC=$?
    if [[ "$RC" -eq 0 ]] \
       && grep -q -- "--field-id PVTF_override_field" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -q -- "--project-id PVT_override_project" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
        pass "T4: _ISSUE_CREATE_INTERNAL_* env-var overrides honored (short-circuit path)"
    else
        fail "T4: env-var override not honored (rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
    fi
    teardown_mock
}
run_case case_t4
