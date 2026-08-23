#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js, hooks/confirm-forge-target-ownership/
# Tags: hook, pre-tool-use, github, gh, ownership, security, scope:issue-specific
# Part of tests/feature-2053-forge-target-ownership.sh (rules/coding/file-split.md).
# Block C5 — classifier symmetry across the whole gh issue / gh pr verb family.

# WHY: the approved scope is issue CREATION. Every other verb in the family is
# the CPR-ORTH counterpart — a classifier that widens by accident starts
# prompting on `gh issue edit`, which is over-blocking, a real defect.

# The second half is a CHAIN assertion: `gh issue close` is already owned by
# hooks/enforce-issue-close.js, and an `ask` from the new guard would downgrade
# that existing hard block into a click-through prompt.

run_block_c5() {
    echo ""
    echo "=== C5: the rest of the gh issue / gh pr verb family stays out of scope ==="

    # A verb-level table: same target, same cwd, only the verb changes. Every row
    # must be passThrough — silent AND probe-free, because a silent allow that
    # spent a probe means the verb was wrongly pulled into scope.
    local name cmd
    while IFS='|' read -r name cmd; do
        [ -z "$name" ] && continue
        reset_env
        run_case "$FX_OWNED" "$cmd"
        assert_decision "C5-verb [$name] -> passThrough" "silent"
        assert_probes "C5-verb [$name] spends no probe" "api user" 0
    done <<TABLE
issue edit|gh issue edit 5 --repo $FOREIGN/r --body b
issue comment|gh issue comment 5 --repo $FOREIGN/r --body b
issue reopen|gh issue reopen 5 --repo $FOREIGN/r
issue close|gh issue close 5 --repo $FOREIGN/r
issue view|gh issue view 5 --repo $FOREIGN/r
issue develop|gh issue develop 5 --repo $FOREIGN/r
issue transfer|gh issue transfer 5 $FOREIGN/other
issue pin|gh issue pin 5 --repo $FOREIGN/r
issue lock|gh issue lock 5 --repo $FOREIGN/r
pr create|gh pr create --repo $FOREIGN/r --title x --body y
pr edit|gh pr edit 5 --repo $FOREIGN/r --body b
pr comment|gh pr comment 5 --repo $FOREIGN/r --body b
pr close|gh pr close 5 --repo $FOREIGN/r
pr merge|gh pr merge 5 --repo $FOREIGN/r
pr review|gh pr review 5 --repo $FOREIGN/r --approve
release create|gh release create v1 --repo $FOREIGN/r
gist create|gh gist create f.txt
TABLE

    # The counterweight: `issue create` — one verb away from every row above —
    # must still be caught. Without it the table would also pass a guard that
    # classifies nothing at all.
    reset_env
    run_case "$FX_OWNED" "gh issue create --repo $FOREIGN/r --title x"
    assert_decision "C5-1 the neighbouring verb issue-create is still caught" "ask"

    # Verb-boundary spellings: a prefix match on "create" would drag these in.
    reset_env
    run_case "$FX_OWNED" "gh issue create-something --repo $FOREIGN/r"
    assert_decision "C5-2 a verb that merely starts with create -> passThrough" "silent"
    reset_env
    run_case "$FX_OWNED" "gh issue --repo $FOREIGN/r"
    assert_decision "C5-3 gh issue with no verb at all -> passThrough" "silent"

    echo ""
    echo "=== C5: the EXISTING close guard must keep blocking, not start asking ==="

    # Runs the real hooks/enforce-issue-close.js over the same payload. It exits
    # 2 (a hard block); the new guard passing the command through is what keeps
    # that outcome reachable by the user.
    local close_hook="$AGENTS_DIR/hooks/enforce-issue-close.js"
    if [ ! -f "$close_hook" ]; then
        fail "C5-4 close guard present" "hooks/enforce-issue-close.js is missing"
        return
    fi
    # A fresh session id with no markers: isWorkflowOff / isIssueCloseVerified
    # must not be pre-satisfied, or the block below would be vacuous.
    local close_sid="cccccccc-0000-4000-8000-000000000001" close_rc
    rm -f "$CLAUDE_WORKFLOW_DIR/$close_sid".* 2>/dev/null || true
    printf '{"session_id":"%s","tool_name":"Bash","cwd":"%s","tool_input":{"command":"gh issue close 5 --repo %s"}}' \
        "$close_sid" "$FX_OWNED" "$FOREIGN/r" > "$BASE/close-in.json"
    env "${ENV_UNSET[@]}" -u ISSUE_CLOSE_SKILL CLAUDE_WORKFLOW_DIR="$CLAUDE_WORKFLOW_DIR" \
        "$RWT" 15 node "$close_hook" < "$BASE/close-in.json" \
        > "$BASE/close-out.txt" 2> "$BASE/close-err.txt"
    close_rc=$?
    assert_eq "C5-4 the existing close guard still hard-blocks (exit 2)" "2" "$close_rc"
    if grep -qF "not allowed" "$BASE/close-err.txt" 2>/dev/null; then
        pass "C5-5 and it still explains why on stderr"
    else
        fail "C5-5 close guard message" "stderr lacked the refusal text"
    fi
    # Same payload, the NEW guard: it must not answer at all.
    reset_env
    run_case "$FX_OWNED" "gh issue close 5 --repo $FOREIGN/r"
    assert_decision "C5-6 the new guard does not downgrade that block to an ask" "silent"
    assert_probes "C5-6b and spends no probe on it" "api user" 0
}
