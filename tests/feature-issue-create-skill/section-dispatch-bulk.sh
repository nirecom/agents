# DV-BULK1-5, DV-BULK-EDGE1-3, DV-BULK-DOC1-2, WF-META-DOC1 tests

# ===========================================================================
# DV-BULK series (#1155): verdict=bulk-sub-of — create N children from a TSV
# manifest and attach each under --parent. Multi-URL stdout, manifest order.
#
# These exercise the dispatch arm that does not yet exist on the current code,
# so DV-BULK1/2 are RED until implementation; DV-BULK3/4/5 (usage errors) and
# the DOC cases are RED until the verdict/whitelist/docs land.
# ===========================================================================

# ---------------------------------------------------------------------------
# DV-BULK1: --parent 100 --manifest <2-line TSV> → 2 issue create + 2 sub_issues
#           POST to parent 100, exit 0, stdout has exactly 2 URLs in manifest order
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV-BULK1: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_ISSUE_NUMS="300,301"
    export GH_MOCK_CREATE_CURSOR="$TMP/create-cursor"
    MANIFEST="$TMP/bulk1-manifest.tsv"
    printf 'First child\tBackground: a\\nChanges: a\n' >  "$MANIFEST"
    printf 'Second child\tBackground: b\\nChanges: b\n' >> "$MANIFEST"
    STDOUT_OUT="$TMP/dvbulk1-stdout.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict bulk-sub-of --parent 100 --manifest "$MANIFEST" >"$STDOUT_OUT" 2>/dev/null
    RC=$?
    CREATE_COUNT=$(grep -c "issue create" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
    ATTACH_COUNT=$(grep -c "repos/nirecom/agents/issues/100/sub_issues" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
    URLS=$(grep -E "^https://github.com/.+/issues/[0-9]+$" "$STDOUT_OUT" 2>/dev/null | tr -d '\r')
    URL_COUNT=$(printf '%s\n' "$URLS" | grep -c . )
    ORDER=$(printf '%s\n' "$URLS" | grep -oE '[0-9]+$' | paste -sd, -)
    if [ "$RC" -eq 0 ] \
       && [ "$CREATE_COUNT" -eq 2 ] \
       && [ "$ATTACH_COUNT" -eq 2 ] \
       && [ "$URL_COUNT" -eq 2 ] \
       && [ "$ORDER" = "300,301" ]; then
        pass "DV-BULK1: 2-child manifest → 2 creates + 2 attaches to #100, 2 URLs in order (300,301)"
    else
        fail "DV-BULK1: rc=$RC creates=$CREATE_COUNT attaches=$ATTACH_COUNT urls=$URL_COUNT order='$ORDER' log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV-BULK2: same manifest but 2nd attach fails → exit 1, 1st URL still on stdout,
#           stderr has retry info
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV-BULK2: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_ISSUE_NUMS="400,401"
    export GH_MOCK_CREATE_CURSOR="$TMP/create-cursor"
    export GH_MOCK_SUBISSUE_FAIL_FROM=2
    export GH_MOCK_SUBISSUE_CURSOR="$TMP/subissue-cursor"
    MANIFEST="$TMP/bulk2-manifest.tsv"
    printf 'First child\tBackground: a\\nChanges: a\n' >  "$MANIFEST"
    printf 'Second child\tBackground: b\\nChanges: b\n' >> "$MANIFEST"
    STDOUT_OUT="$TMP/dvbulk2-stdout.txt"
    STDERR_OUT="$TMP/dvbulk2-stderr.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict bulk-sub-of --parent 100 --manifest "$MANIFEST" >"$STDOUT_OUT" 2>"$STDERR_OUT"
    RC=$?
    if [ "$RC" -eq 1 ] \
       && grep -qE "^https://github.com/.+/issues/400$" "$STDOUT_OUT" 2>/dev/null \
       && grep -qiE "retry|sub_issue_id|sub_issues" "$STDERR_OUT" 2>/dev/null; then
        pass "DV-BULK2: 2nd attach fails → exit 1, 1st URL on stdout, retry info on stderr"
    else
        fail "DV-BULK2: rc=$RC stdout=$(cat "$STDOUT_OUT" 2>/dev/null) stderr=$(cat "$STDERR_OUT" 2>/dev/null)"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV-BULK3: --verdict bulk-sub-of without --manifest → exit 2
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV-BULK3: dispatch script missing — RED until implementation"
else
    setup_mock
    run_with_timeout 30 bash "$DISPATCH" --verdict bulk-sub-of --parent 100 >/dev/null 2>/dev/null
    RC=$?
    if [ "$RC" -eq 2 ]; then
        pass "DV-BULK3: bulk-sub-of without --manifest → exit 2"
    else
        fail "DV-BULK3: bulk-sub-of without --manifest should exit 2, got rc=$RC"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV-BULK4: --verdict bulk-sub-of without --parent → exit 2
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV-BULK4: dispatch script missing — RED until implementation"
else
    setup_mock
    MANIFEST="$TMP/bulk4-manifest.tsv"
    printf 'Only child\tBackground: a\\nChanges: a\n' > "$MANIFEST"
    run_with_timeout 30 bash "$DISPATCH" --verdict bulk-sub-of --manifest "$MANIFEST" >/dev/null 2>/dev/null
    RC=$?
    if [ "$RC" -eq 2 ]; then
        pass "DV-BULK4: bulk-sub-of without --parent → exit 2"
    else
        fail "DV-BULK4: bulk-sub-of without --parent should exit 2, got rc=$RC"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV-BULK5: --parent 100 --manifest <empty file> → exit 2
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV-BULK5: dispatch script missing — RED until implementation"
else
    setup_mock
    MANIFEST="$TMP/bulk5-empty.tsv"
    : > "$MANIFEST"
    run_with_timeout 30 bash "$DISPATCH" --verdict bulk-sub-of --parent 100 --manifest "$MANIFEST" >/dev/null 2>/dev/null
    RC=$?
    if [ "$RC" -eq 2 ]; then
        pass "DV-BULK5: bulk-sub-of with empty manifest → exit 2"
    else
        fail "DV-BULK5: bulk-sub-of with empty manifest should exit 2, got rc=$RC"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV-BULK-EDGE1: manifest with empty-title row in the middle → skipped,
#                CREATE_COUNT=2, ATTACH_COUNT=2, 2 URLs on stdout
#
# Note: bash `read` with IFS=$'\t' strips leading IFS chars, so a row of
# "\t<body>" would assign <body> to title. An empty line ("\n") or a
# tab-only line ("\t\n") reliably produces title="" which the [[ -z ]] check
# catches and skips.
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV-BULK-EDGE1: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_ISSUE_NUMS="300,301"
    export GH_MOCK_CREATE_CURSOR="$TMP/create-cursor"
    MANIFEST="$TMP/bulk-edge1-manifest.tsv"
    printf 'First child\tBackground: a\\nChanges: a\n' >  "$MANIFEST"
    printf '\n'                                           >> "$MANIFEST"
    printf 'Third child\tBackground: c\\nChanges: c\n'  >> "$MANIFEST"
    STDOUT_OUT="$TMP/dvbulk-edge1-stdout.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict bulk-sub-of --parent 100 --manifest "$MANIFEST" >"$STDOUT_OUT" 2>/dev/null
    RC=$?
    CREATE_COUNT=$(grep -c "issue create" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
    ATTACH_COUNT=$(grep -c "repos/nirecom/agents/issues/100/sub_issues" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
    URLS=$(grep -E "^https://github.com/.+/issues/[0-9]+$" "$STDOUT_OUT" 2>/dev/null | tr -d '\r')
    URL_COUNT=$(printf '%s\n' "$URLS" | grep -c . )
    if [ "$RC" -eq 0 ] \
       && [ "$CREATE_COUNT" -eq 2 ] \
       && [ "$ATTACH_COUNT" -eq 2 ] \
       && [ "$URL_COUNT" -eq 2 ]; then
        pass "DV-BULK-EDGE1: empty-title row skipped → 2 creates, 2 attaches, 2 URLs"
    else
        fail "DV-BULK-EDGE1: rc=$RC creates=$CREATE_COUNT attaches=$ATTACH_COUNT urls=$URL_COUNT log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV-BULK-EDGE2: manifest with trailing newline → CREATE_COUNT=2 (not 3)
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV-BULK-EDGE2: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_ISSUE_NUMS="300,301"
    export GH_MOCK_CREATE_CURSOR="$TMP/create-cursor"
    MANIFEST="$TMP/bulk-edge2-manifest.tsv"
    printf 'First child\tBackground: a\\nChanges: a\nSecond child\tBackground: b\\nChanges: b\n' > "$MANIFEST"
    STDOUT_OUT="$TMP/dvbulk-edge2-stdout.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict bulk-sub-of --parent 100 --manifest "$MANIFEST" >"$STDOUT_OUT" 2>/dev/null
    RC=$?
    CREATE_COUNT=$(grep -c "issue create" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
    ATTACH_COUNT=$(grep -c "repos/nirecom/agents/issues/100/sub_issues" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
    URLS=$(grep -E "^https://github.com/.+/issues/[0-9]+$" "$STDOUT_OUT" 2>/dev/null | tr -d '\r')
    URL_COUNT=$(printf '%s\n' "$URLS" | grep -c . )
    if [ "$RC" -eq 0 ] \
       && [ "$CREATE_COUNT" -eq 2 ] \
       && [ "$ATTACH_COUNT" -eq 2 ] \
       && [ "$URL_COUNT" -eq 2 ]; then
        pass "DV-BULK-EDGE2: trailing newline not counted as extra row → 2 creates, 2 attaches, 2 URLs"
    else
        fail "DV-BULK-EDGE2: rc=$RC creates=$CREATE_COUNT attaches=$ATTACH_COUNT urls=$URL_COUNT log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV-BULK-EDGE3: title/body with shell metacharacters → passed safely
# ---------------------------------------------------------------------------
if [ ! -x "$DISPATCH" ]; then
    fail "DV-BULK-EDGE3: dispatch script missing — RED until implementation"
else
    setup_mock
    export GH_MOCK_ISSUE_NUMS="300"
    export GH_MOCK_CREATE_CURSOR="$TMP/create-cursor"
    MANIFEST="$TMP/bulk-edge3-manifest.tsv"
    # Title contains $HOME, double-quotes, and backticks; body contains $VAR and quotes
    printf 'Test $HOME "quoted" `backtick` value\tBackground: test with $VAR and "quotes"\\nChanges: done\n' > "$MANIFEST"
    STDOUT_OUT="$TMP/dvbulk-edge3-stdout.txt"
    run_with_timeout 30 bash "$DISPATCH" --verdict bulk-sub-of --parent 100 --manifest "$MANIFEST" >"$STDOUT_OUT" 2>/dev/null
    RC=$?
    CREATE_COUNT=$(grep -c "issue create" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
    ATTACH_COUNT=$(grep -c "repos/nirecom/agents/issues/100/sub_issues" "$GH_MOCK_ARGS_LOG" 2>/dev/null || echo 0)
    URLS=$(grep -E "^https://github.com/.+/issues/[0-9]+$" "$STDOUT_OUT" 2>/dev/null | tr -d '\r')
    URL_COUNT=$(printf '%s\n' "$URLS" | grep -c . )
    if [ "$RC" -eq 0 ] \
       && [ "$CREATE_COUNT" -eq 1 ] \
       && [ "$ATTACH_COUNT" -eq 1 ] \
       && [ "$URL_COUNT" -eq 1 ]; then
        pass "DV-BULK-EDGE3: metacharacters in title/body passed safely → 1 create, 1 attach, 1 URL"
    else
        fail "DV-BULK-EDGE3: rc=$RC creates=$CREATE_COUNT attaches=$ATTACH_COUNT urls=$URL_COUNT log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# DV-BULK-DOC1: skills/issue-create/SKILL.md contains skip-survey reference
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
    fail "DV-BULK-DOC1: skills/issue-create/SKILL.md missing — RED until implementation"
elif grep -q "skip-survey" "$SKILL_MD"; then
    pass "DV-BULK-DOC1: SKILL.md references skip-survey"
else
    fail "DV-BULK-DOC1: SKILL.md does not reference skip-survey — RED until implementation"
fi

# ---------------------------------------------------------------------------
# DV-BULK-DOC2: skills/issue-create/SKILL.md contains bulk-sub-of
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
    fail "DV-BULK-DOC2: skills/issue-create/SKILL.md missing — RED until implementation"
elif grep -q "bulk-sub-of" "$SKILL_MD"; then
    pass "DV-BULK-DOC2: SKILL.md references bulk-sub-of"
else
    fail "DV-BULK-DOC2: SKILL.md does not reference bulk-sub-of — RED until implementation"
fi

# ---------------------------------------------------------------------------
# WF-META-DOC1: skills/workflow-init/SKILL.md PM path contains a sub-issue
#               creation mandate. The mandate must signal sub-issue/bulk creation
#               or "全件" coverage — bare "PM4" already exists for an unrelated
#               outline step, so it alone must NOT satisfy this check.
# ---------------------------------------------------------------------------
if [ ! -f "$WORKFLOW_INIT_MD" ]; then
    fail "WF-META-DOC1: skills/workflow-init/SKILL.md missing"
elif grep -qE "bulk|sub-issue|全件" "$WORKFLOW_INIT_MD"; then
    pass "WF-META-DOC1: workflow-init SKILL.md PM path has sub-issue creation mandate"
else
    fail "WF-META-DOC1: workflow-init SKILL.md missing sub-issue creation mandate — RED until implementation"
fi
