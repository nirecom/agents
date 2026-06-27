# DV1-DV12, DV-graphql-fail, DV7-DV9, D5-D6: dispatch core tests

# ---------------------------------------------------------------------------
# DV1: verdict=none → exactly one `gh issue create`, no extra API calls
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV1: dispatch script missing — RED until implementation"
else
    setup_mock
    STDOUT_OUT="$TMP/dv1-stdout.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict none -- --title "T" --body "$(printf "$CANONICAL_BODY")" >"$STDOUT_OUT" 2>/dev/null
    RC=$?
    CREATE_COUNT=$(grep -c "issue create" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
    LAST_LINE=$(tail -1 "$STDOUT_OUT" 2>/dev/null)
    if [ "$RC" -eq 0 ] \
       && [ "$CREATE_COUNT" -eq 1 ] \
       && ! grep -q "issue reopen" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && ! grep -q "sub_issues" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && echo "$LAST_LINE" | grep -qE "https://github.com/.+/issues/[0-9]+"; then
        pass "DV1: verdict=none → exactly one gh issue create, no extra API calls"
    else
        fail "DV1: verdict=none behavior incorrect (rc=$RC create_count=$CREATE_COUNT stdout='$LAST_LINE' log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV2: verdict=reopen --target 42 → `gh issue reopen 42`, no `gh issue create`
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV2: dispatch script missing — RED until implementation"
else
    setup_mock
    STDOUT_OUT="$TMP/dv2-stdout.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict reopen --target 42 >"$STDOUT_OUT" 2>/dev/null
    RC=$?
    LAST_LINE=$(tail -1 "$STDOUT_OUT" 2>/dev/null)
    if [ "$RC" -eq 0 ] \
       && grep -q "issue reopen 42" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && ! grep -q "issue create" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && [ "$LAST_LINE" = "https://github.com/nirecom/agents/issues/42" ]; then
        pass "DV2: verdict=reopen --target 42 → reopen called, stdout=URL of #42"
    else
        fail "DV2: verdict=reopen behavior incorrect (rc=$RC stdout='$LAST_LINE' log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV3: verdict=sibling --related 42 → body contains `Related to #42`
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV3: dispatch script missing — RED until implementation"
else
    setup_mock
    STDOUT_OUT="$TMP/dv3-stdout.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict sibling --related 42 -- --title "T" --body "$(printf 'Background: Original\nChanges: test')" >"$STDOUT_OUT" 2>/dev/null
    RC=$?
    LAST_LINE=$(tail -1 "$STDOUT_OUT" 2>/dev/null)
    # Body suffix is injected with a real newline, so check the whole args log (multi-line).
    if [ "$RC" -eq 0 ] \
       && grep -q "issue create" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -q "Original" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -q "Related to #42" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && echo "$LAST_LINE" | grep -qE "https://github.com/.+/issues/[0-9]+"; then
        pass "DV3: verdict=sibling --related 42 → body augmented with Related to #42"
    else
        fail "DV3: verdict=sibling behavior incorrect (rc=$RC stdout='$LAST_LINE' log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV4: verdict=sub-of --parent 100 → fetches CHILD id (not parent), attaches via API
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV4: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_NEW_ISSUE_NUM=200
    STDOUT_OUT="$TMP/dv4-stdout.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict sub-of --parent 100 -- --title "T" --body "$(printf "$CANONICAL_BODY")" >"$STDOUT_OUT" 2>/dev/null
    RC=$?
    LAST_LINE=$(tail -1 "$STDOUT_OUT" 2>/dev/null)
    if [ "$RC" -eq 0 ] \
       && grep -q "api graphql" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -q "issue(number: 200)" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -q "repos/nirecom/agents/issues/100/sub_issues" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -q "sub_issue_id=200000" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && echo "$LAST_LINE" | grep -q "/issues/200$"; then
        pass "DV4: verdict=sub-of --parent 100 → child databaseId fetched via GraphQL and attached"
    else
        fail "DV4: verdict=sub-of behavior incorrect (rc=$RC stdout='$LAST_LINE' log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV5: verdict=make-parent --children 42,43 → fetches BOTH child ids and attaches each
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV5: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_NEW_ISSUE_NUM=201
    STDOUT_OUT="$TMP/dv5-stdout.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict make-parent --children 42,43 -- --title "T" --body "$(printf "$CANONICAL_BODY")" >"$STDOUT_OUT" 2>/dev/null
    RC=$?
    LAST_LINE=$(tail -1 "$STDOUT_OUT" 2>/dev/null)
    ATTACH_201_COUNT=$(grep -c "repos/nirecom/agents/issues/201/sub_issues" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
    # Fix #713: make-parent fetches databaseId via GraphQL (api graphql) instead of
    # gh issue view --json databaseId. Mock returns "${NUM}000" for issue(number: N),
    # so child 42 → 42000 and child 43 → 43000.
    if [ "$RC" -eq 0 ] \
       && grep -q "issue(number: 42)" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -q "issue(number: 43)" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -q -- "-F sub_issue_id=42000" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -q -- "-F sub_issue_id=43000" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && [ "$ATTACH_201_COUNT" -ge 2 ] \
       && [ "$LAST_LINE" = "https://github.com/nirecom/agents/issues/201" ]; then
        pass "DV5: verdict=make-parent --children 42,43 → both children attached under new parent 201 with -F sub_issue_id=<integer>"
    else
        fail "DV5: verdict=make-parent behavior incorrect (rc=$RC stdout='$LAST_LINE' attach_201_count=$ATTACH_201_COUNT log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV6: sub-of with sub-issue API failure → non-zero exit (structural failure)
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV6: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_SUBISSUE_API_FAIL=1
    export GH_MOCK_NEW_ISSUE_NUM=202
    run_with_timeout 30 bash "$DISPATCH" --verdict sub-of --parent 100 -- --title "T" --body "$(printf "$CANONICAL_BODY")" >/dev/null 2>/dev/null
    RC=$?
    if [ "$RC" -ne 0 ]; then
        pass "DV6: sub-of + sub-issue API failure → non-zero exit"
    else
        fail "DV6: sub-of + sub-issue API failure should exit non-zero, got rc=$RC"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV-graphql-fail: GH_MOCK_GRAPHQL_DBID_FAIL=1 → gh api graphql returns non-zero → dispatch exits non-zero
# Fix #713: get_child_database_id() uses api graphql; a GraphQL failure must propagate as a non-zero exit.
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV-graphql-fail: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_GRAPHQL_DBID_FAIL=1
    export GH_MOCK_NEW_ISSUE_NUM=200
    run_with_timeout 30 bash "$DISPATCH" --verdict sub-of --parent 100 -- --title "T" --body "$(printf "$CANONICAL_BODY")" >/dev/null 2>/dev/null
    RC=$?
    if [ "$RC" -ne 0 ]; then
        pass "DV-graphql-fail: gh api graphql databaseId failure → dispatch exits non-zero"
    else
        fail "DV-graphql-fail: gh api graphql failure should propagate as non-zero exit, got rc=$RC"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV7: SKILL.md references `is-github-dotcom-remote`
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
    fail "DV7: skills/issue-create/SKILL.md missing — RED until implementation"
elif grep -q "is-github-dotcom-remote" "$SKILL_MD"; then
    pass "DV7: SKILL.md references is-github-dotcom-remote"
else
    fail "DV7: SKILL.md does not reference is-github-dotcom-remote — RED until implementation"
fi

# ---------------------------------------------------------------------------
# DV8: Sub-issue API call shape — `api -X POST` + sub_issues path + -F sub_issue_id=<integer>
# Fix #432: sub_issue_id must be passed via -F (numeric) using the child's
# databaseId integer, not -f (string) with the GraphQL node id.
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV8: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_NEW_ISSUE_NUM=200
    run_with_timeout 30 bash "$DISPATCH" --verdict sub-of --parent 100 -- --title "T" --body "$(printf "$CANONICAL_BODY")" >/dev/null 2>/dev/null
    RC=$?
    if [ "$RC" -eq 0 ] \
       && grep -q "api .*-X POST" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -q "repos/nirecom/agents/issues/100/sub_issues" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -q "api graphql" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -q "issue(number: 200)" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && grep -qE -- "-F sub_issue_id=[0-9]+" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
        pass "DV8: sub-issue API call has correct shape (api graphql databaseId, api -X POST, sub_issues path, -F sub_issue_id=<integer>)"
    else
        fail "DV8: sub-issue API call shape incorrect (rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV9: verdict=reopen without --target → exit 2
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV9: dispatch script missing — RED until implementation"
else
    setup_mock
    run_with_timeout 30 bash "$DISPATCH" --verdict reopen >/dev/null 2>/dev/null
    RC=$?
    if [ "$RC" -eq 2 ]; then
        pass "DV9: verdict=reopen without --target → exit 2"
    else
        fail "DV9: verdict=reopen without --target should exit 2, got rc=$RC"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# D5: SKILL.md references bin/github-issues/issue-create-dispatch.sh
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
    fail "D5: skills/issue-create/SKILL.md missing — RED until implementation"
elif grep -q "issue-create-dispatch.sh" "$SKILL_MD"; then
    pass "D5: SKILL.md references bin/github-issues/issue-create-dispatch.sh"
else
    fail "D5: SKILL.md does not reference issue-create-dispatch.sh — RED until implementation"
fi

# ---------------------------------------------------------------------------
# D6: SKILL.md contains "Survey", "Verdict", AND "Confirm" (case-insensitive)
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
    fail "D6: skills/issue-create/SKILL.md missing — RED until implementation"
elif grep -qi "survey" "$SKILL_MD" && grep -qi "verdict" "$SKILL_MD" && grep -qi "confirm" "$SKILL_MD"; then
    pass "D6: SKILL.md contains Survey, Verdict, and Confirm (case-insensitive)"
else
    fail "D6: SKILL.md missing one of Survey/Verdict/Confirm — RED until implementation"
fi

# ---------------------------------------------------------------------------
# DV10: sub-of + parent CLOSED → ancestor reopen called, stdout last line = URL
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV10: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_NEW_ISSUE_NUM=200
    export GH_MOCK_PARENT_NUM_200=100
    export GH_MOCK_ISSUE_STATE_100=CLOSED
    STDOUT_OUT="$TMP/dv10-stdout.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict sub-of --parent 100 -- --title "T" --body "$(printf "$CANONICAL_BODY")" >"$STDOUT_OUT" 2>/dev/null
    RC=$?
    LAST_LINE=$(tail -1 "$STDOUT_OUT" 2>/dev/null)
    if [ "$RC" -eq 0 ] \
       && grep -q "issue reopen 100" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && echo "$LAST_LINE" | grep -q "/issues/200$"; then
        pass "DV10: sub-of parent CLOSED → ancestor reopen called, stdout last line = URL"
    else
        fail "DV10: sub-of parent CLOSED expected reopen + URL (rc=$RC last='$LAST_LINE' log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV11: sub-of + parent OPEN → reopen NOT called, stdout last line = URL
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV11: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_NEW_ISSUE_NUM=200
    export GH_MOCK_PARENT_NUM_200=100
    export GH_MOCK_ISSUE_STATE_100=OPEN
    STDOUT_OUT="$TMP/dv11-stdout.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict sub-of --parent 100 -- --title "T" --body "$(printf "$CANONICAL_BODY")" >"$STDOUT_OUT" 2>/dev/null
    RC=$?
    LAST_LINE=$(tail -1 "$STDOUT_OUT" 2>/dev/null)
    if [ "$RC" -eq 0 ] \
       && ! grep -q "issue reopen" "$GH_MOCK_ARGS_LOG" 2>/dev/null \
       && echo "$LAST_LINE" | grep -q "/issues/200$"; then
        pass "DV11: sub-of parent OPEN → no reopen, stdout last line = URL"
    else
        fail "DV11: sub-of parent OPEN should skip reopen (rc=$RC last='$LAST_LINE' log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null))"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV12: sub-of + REOPEN_FAIL_100 → dispatch exit 0, WARN to stderr, stdout last line = URL
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV12: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_NEW_ISSUE_NUM=200
    export GH_MOCK_PARENT_NUM_200=100
    export GH_MOCK_ISSUE_STATE_100=CLOSED
    export GH_MOCK_REOPEN_FAIL_100=1
    STDOUT_OUT="$TMP/dv12-stdout.txt"
    STDERR_OUT="$TMP/dv12-stderr.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict sub-of --parent 100 -- --title "T" --body "$(printf "$CANONICAL_BODY")" >"$STDOUT_OUT" 2>"$STDERR_OUT"
    RC=$?
    LAST_LINE=$(tail -1 "$STDOUT_OUT" 2>/dev/null)
    if [ "$RC" -eq 0 ] \
       && grep -qi "warn" "$STDERR_OUT" 2>/dev/null \
       && echo "$LAST_LINE" | grep -q "/issues/200$"; then
        pass "DV12: reopen failure non-fatal → exit 0, WARN to stderr, URL on stdout"
    else
        fail "DV12: reopen failure should be non-fatal (rc=$RC last='$LAST_LINE' stderr=$(cat "$STDERR_OUT" 2>/dev/null))"
    fi
    teardown_mock
fi
