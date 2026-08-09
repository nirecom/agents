# tests/feat-1699-meta-parent-guard/make-parent.sh
# Tests: bin/github-issues/issue-create-dispatch.sh, bin/github-issues/lib/meta-parent-body.sh
# Tags: issue-create, dispatch, meta-parent, make-parent, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - Real `gh issue create` rendering of the generated parent body / label acceptance.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# Group B — make-parent creates TWO issues, no longer promoting the proposal into the
# parent slot: (1) a meta-labeled `Group: `-titled parent with a dispatcher-generated body,
# and (2) the proposal unmodified as a child. Siblings named by --children plus the new
# child all attach under the new parent. stdout is two lines, parent FIRST and child LAST,
# so callers doing `| tail -n 1` keep receiving the proposal's URL.

# arg_lines_after <call-file> <flag> <n> → the n argv LINES following <flag>.
# `arg_after` stops at one line — right for a title, wrong for a body: the mock writes one
# argv element per line, so a one-line read would compare half a body and call it verbatim.
arg_lines_after() {
    awk -v flag="$2" -v n="$3" '
      found { if (c < n) { print; c++ } ; next }
      $0 == flag { found = 1 }' "$1"
}

mp_run() {  # runs the standard 2-child make-parent scenario; caller sets mock env first
    run_dispatch --verdict make-parent --children "42,43" -- \
        --title "improve retry backoff" \
        --body "$(printf "$CANONICAL_BODY")" \
        --label "severity:high"
}

# --- B1/B2/B3: creation count and per-issue argv ---------------------------------------
setup_mock
export GH_MOCK_ISSUE_NUMS="201,202"
mp_run
if [ "$RC" -eq 0 ]; then
    pass "B0-make-parent-rc0"
else
    fail "B0-make-parent-rc0" "want rc 0 (got: $RC); stderr: $ERR"
fi

n=$(count_creates)
if [ "${n:-0}" -eq 2 ]; then
    pass "B1-make-parent-creates-two-issues"
else
    fail "B1-make-parent-creates-two-issues" "want 2 gh issue create calls (got: ${n:-0})"
fi

P="$(nth_create_file 1)"
C="$(nth_create_file 2)"

if [ -n "$P" ] && has_label "$P" "meta"; then
    pass "B2-parent-carries-meta-label"
else
    fail "B2-parent-carries-meta-label" "first create has no '--label meta' (args: $( [ -n "$P" ] && tr '\n' ' ' < "$P"))"
fi

ptitle="$( [ -n "$P" ] && arg_after "$P" "--title")"
case "$ptitle" in
    "Group: "*) pass "B2b-parent-title-has-group-prefix" ;;
    *) fail "B2b-parent-title-has-group-prefix" "want a 'Group: ' prefixed title (got: '$ptitle')" ;;
esac
# B2b passes for `Group: ` + anything, so the whole normalised result is pinned: a title
# with the subject dropped, truncated, or re-worded would satisfy B2b.
if [ "$ptitle" = "Group: improve retry backoff" ]; then
    pass "B2c-parent-title-is-exactly-the-normalised-proposal-title"
else
    fail "B2c-parent-title-is-exactly-the-normalised-proposal-title" "want 'Group: improve retry backoff' (got: '$ptitle')"
fi

ctitle="$( [ -n "$C" ] && arg_after "$C" "--title")"
if [ "$ctitle" = "improve retry backoff" ]; then
    pass "B3-child-title-unmodified"
else
    fail "B3-child-title-unmodified" "want the proposal title verbatim (got: '$ctitle')"
fi
if [ -n "$C" ] && has_label "$C" "severity:high"; then
    pass "B3b-child-keeps-passthrough-labels"
else
    fail "B3b-child-keeps-passthrough-labels" "child create lost '--label severity:high'"
fi
# Whole-body comparison: the dispatcher rewrites bodies elsewhere
# (inject_related_into_body for `sibling`), so B4 does not rule out a rewritten child body.
EXPECTED_BODY="$(printf "$CANONICAL_BODY")"
BODY_NLINES=$(printf '%s\n' "$EXPECTED_BODY" | grep -c '')
GOT_CBODY="$( [ -n "$C" ] && arg_lines_after "$C" "--body" "$BODY_NLINES")"
if [ -n "$C" ] && [ "$GOT_CBODY" = "$EXPECTED_BODY" ]; then
    pass "B3c-child-body-is-the-proposal-verbatim"
else
    fail "B3c-child-body-is-the-proposal-verbatim" "want the proposal body unchanged (want: '$EXPECTED_BODY', got: '$GOT_CBODY')"
fi
# A child carrying `meta` would satisfy require-meta-parent.sh's first condition.
if [ -n "$C" ] && has_label "$C" "meta"; then
    fail "B3d-child-does-not-carry-the-meta-label" "the proposal child was created with '--label meta'"
else
    pass "B3d-child-does-not-carry-the-meta-label"
fi

# --- B4: parent body is generated, not the proposal's ---------------------------------
pbody="$( [ -n "$P" ] && arg_after "$P" "--body")"
cbody="$( [ -n "$C" ] && arg_after "$C" "--body")"
# cbody must be non-empty: with one create call there is no child file, and an empty
# $cbody makes the inequality trivially true.
if [ -n "$pbody" ] && [ -n "$cbody" ] && [ "$pbody" != "$cbody" ]; then
    pass "B4-parent-body-differs-from-proposal"
else
    fail "B4-parent-body-differs-from-proposal" "parent body is empty or identical to the child body (parent: '$pbody')"
fi
# Body-schema validation in issue-create.sh applies to the generated body too.
if printf '%s' "$pbody" | grep -qi 'background' && printf '%s' "$pbody" | grep -qi 'changes'; then
    pass "B4b-parent-body-has-background-and-changes"
else
    fail "B4b-parent-body-has-background-and-changes" "generated parent body lacks Background/Changes: '$pbody'"
fi
# Saying so in the body is what stops a future reader implementing against the container.
if printf '%s' "$pbody" | grep -qi 'sub-issue'; then
    pass "B4c-parent-body-points-at-sub-issues"
else
    fail "B4c-parent-body-points-at-sub-issues" "generated parent body never mentions sub-issues: '$pbody'"
fi

# --- B5: severity is a property of work, and the parent holds none ---------------------
if [ -n "$P" ] && grep -q '^severity:' "$P"; then
    fail "B5-parent-has-no-severity-label" "parent create carries a severity:* label"
else
    pass "B5-parent-has-no-severity-label"
fi

# --- B7: attach fan-out ----------------------------------------------------------------
a=$(count_attaches)
if [ "${a:-0}" -eq 3 ]; then
    pass "B7-attaches-children-plus-new-child"
else
    fail "B7-attaches-children-plus-new-child" "want 3 sub_issues POSTs (2 named children + the new proposal), got ${a:-0}"
fi
off=$(grep 'sub_issues' "$GH_MOCK_ARGS_LOG" | grep -c -v 'issues/201/sub_issues') || true
if [ "${off:-0}" -eq 0 ]; then
    pass "B7b-all-attaches-target-the-new-parent"
else
    fail "B7b-all-attaches-target-the-new-parent" "${off} attach call(s) targeted an issue other than the new parent #201"
fi
# WHICH ids, not how many: the count alone passes if #42 was attached three times, or the
# parent to itself. The mock's databaseId is the issue number + "000", so the expected set
# is exact — children 42, 43 plus the new proposal 202, never the parent 201.
ATTACHED_IDS=$(grep 'sub_issues' "$GH_MOCK_ARGS_LOG" \
    | grep -oE 'sub_issue_id=[0-9]+' | sed 's/sub_issue_id=//' | LC_ALL=C sort -u | tr '\n' ',')
if [ "$ATTACHED_IDS" = "202000,42000,43000," ]; then
    pass "B7c-attached-database-ids-are-exactly-the-children-plus-the-proposal"
else
    fail "B7c-attached-database-ids-are-exactly-the-children-plus-the-proposal" "want the databaseIds of #42,#43,#202 (42000,43000,202000) (got: '${ATTACHED_IDS:-<none>}')"
fi
# Separate, because a self-attach reads as "3 attaches under #201" to every count-based
# assertion.
if printf '%s' "$ATTACHED_IDS" | grep -q '201000'; then
    fail "B7d-parent-is-not-attached-to-itself" "the parent's own databaseId (201000) appears in a sub_issues POST"
else
    pass "B7d-parent-is-not-attached-to-itself"
fi

# --- B8: stdout shape -------------------------------------------------------------------
lines=$(printf '%s\n' "$OUT" | grep -c .) || true
if [ "${lines:-0}" -eq 2 ]; then
    pass "B8-stdout-has-two-lines"
else
    fail "B8-stdout-has-two-lines" "want 2 stdout lines (got: ${lines:-0}): $OUT"
fi
first="$(printf '%s\n' "$OUT" | sed -n '1p')"
last="$(printf '%s\n' "$OUT" | grep . | tail -n 1)"
if [ "$first" = "https://github.com/nirecom/agents/issues/201" ]; then
    pass "B8b-stdout-first-line-is-parent"
else
    fail "B8b-stdout-first-line-is-parent" "want the parent URL first (got: '$first')"
fi
# The compatibility hinge: existing callers pipe through `tail -n 1`.
if [ "$last" = "https://github.com/nirecom/agents/issues/202" ]; then
    pass "B8c-stdout-last-line-is-child"
else
    fail "B8c-stdout-last-line-is-child" "want the child URL last so 'tail -n 1' still yields the proposal (got: '$last')"
fi
teardown_mock

# --- B6: Group: prefixing is idempotent -------------------------------------------------
setup_mock
export GH_MOCK_ISSUE_NUMS="211,212"
run_dispatch --verdict make-parent --children "42" -- \
    --title "Group: retry semantics" \
    --body "$(printf "$CANONICAL_BODY")"
P="$(nth_create_file 1)"
ptitle="$( [ -n "$P" ] && arg_after "$P" "--title")"
if [ "$ptitle" = "Group: retry semantics" ]; then
    pass "B6-group-prefix-is-idempotent"
else
    fail "B6-group-prefix-is-idempotent" "want 'Group: retry semantics' unchanged (got: '$ptitle')"
fi
teardown_mock

# --- B9: argument validation happens before any creation --------------------------------
setup_mock
export GH_MOCK_ISSUE_NUMS="221,222"
run_dispatch --verdict make-parent --children "42" -- --body "$(printf "$CANONICAL_BODY")"
if [ "$RC" -eq 2 ] && [ "$(count_creates)" -eq 0 ]; then
    pass "B9-missing-title-rc2-zero-creates"
else
    fail "B9-missing-title-rc2-zero-creates" "want rc 2 with 0 creates (rc=$RC, creates=$(count_creates)); stderr: $ERR"
fi
teardown_mock

setup_mock
export GH_MOCK_ISSUE_NUMS="221,222"
run_dispatch --verdict make-parent --children "42" -- --title "no body here"
if [ "$RC" -eq 2 ] && [ "$(count_creates)" -eq 0 ]; then
    pass "B9b-missing-body-rc2-zero-creates"
else
    fail "B9b-missing-body-rc2-zero-creates" "want rc 2 with 0 creates (rc=$RC, creates=$(count_creates)); stderr: $ERR"
fi
teardown_mock

# --- B10: partial attach failure still reports both created issues ----------------------
# Both issues exist at that point; swallowing their URLs would strand them.
setup_mock
export GH_MOCK_ISSUE_NUMS="231,232"
export GH_MOCK_SUBISSUE_FAIL_FROM=2
mp_run
if [ "$RC" -ne 0 ]; then
    pass "B10-partial-attach-failure-nonzero"
else
    fail "B10-partial-attach-failure-nonzero" "want non-zero rc when an attach fails (got: 0)"
fi
lines=$(printf '%s\n' "$OUT" | grep -c .) || true
if [ "${lines:-0}" -eq 2 ]; then
    pass "B10b-partial-attach-failure-keeps-two-urls"
else
    fail "B10b-partial-attach-failure-keeps-two-urls" "want both URLs on stdout despite the failure (got ${lines:-0} lines): $OUT"
fi
if printf '%s' "$ERR" | grep -q '231' && printf '%s' "$ERR" | grep -qi 'attach\|failed'; then
    pass "B10c-partial-attach-failure-describes-state"
else
    fail "B10c-partial-attach-failure-describes-state" "stderr does not describe the intermediate state (parent #231 created, some children unattached): $ERR"
fi
teardown_mock
