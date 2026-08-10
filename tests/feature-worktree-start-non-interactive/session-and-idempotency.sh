#!/bin/bash
# tests/feature-worktree-start-non-interactive/session-and-idempotency.sh
# Tests: skills/worktree-start/scripts/derive-worktree-name.sh, skills/worktree-start/SKILL.md
# Tags: worktree, start, session, idempotency, TL2, scope:issue-specific
# B11 (production session-resolution path) and B12 (WS-2/WS-4/WS-6 idempotency).
# Part of the feature-worktree-start-non-interactive suite — see the dispatcher.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
setup_fixture

# --repo-dir is pinned to a remote-less fixture repo for B11 (and reused for B12
# below) so D4's gh label lookup can never fire: without the pin, an invocation with no
# --repo-dir falls back to `git rev-parse --show-toplevel` of the suite's own CWD,
# which resolves to this real agents checkout — bin/is-github-dotcom-remote then exits
# 0 and D4 fires a LIVE, credentialed `gh issue view` against the real repo for
# whatever fixture issue number the case happens to use (rules/test/fixture-isolation.md
# "Neutral CWD and fixture project dir"). B11's fixture issue #4242 in particular is
# unlikely to exist, so a live lookup would also cost a slow/rate-limited round trip.
B11_REPO="$FIXTURE/b11-repo"
mkdir -p "$B11_REPO"
git -C "$B11_REPO" init -q >/dev/null 2>&1
git -C "$B11_REPO" config core.hooksPath /dev/null

# --- B11 [C1]: production session-resolution path (no --intent) ------------
# The other behavioral cases pin --intent. This one exercises what /worktree-start
# actually runs: PLANS_DIR from bin/workflow-plans-dir + session id from
# bin/resolve-session-id -> "$PLANS_DIR/<sid>-intent.md". CLAUDE_CODE_SESSION_ID is
# resolve-session-id's priority-2 source and is the one reliably present in a
# Bash-tool subprocess, so it is what the fixture pins — scoped to these two calls,
# then dropped again.
B11_SID="wtstartfixture0001"
write_intent "$WORKFLOW_PLANS_DIR/$B11_SID-intent.md" \
    'Auto resolved session path for worktree naming' '- #4242: session resolution'

export CLAUDE_CODE_SESSION_ID="$B11_SID"
run_derive B11 --repo-dir "$B11_REPO"
unset CLAUDE_CODE_SESSION_ID
if [ "$RC" -eq 0 ] \
    && has_line 'TASK_NAME=4242-auto-resolved-session-path-for' \
    && has_line 'BRANCH_TYPE=feature'; then
    pass "B11: no --intent resolves \$PLANS_DIR/<sid>-intent.md and derives 4242-auto-resolved-session-path-for / feature"
else
    fail "B11: expected TASK_NAME=4242-auto-resolved-session-path-for + BRANCH_TYPE=feature from the resolved intent (rc=$RC, out='$OUT', err='$ERR')"
fi

# Negative control: without a resolvable <sid>-intent.md in the pinned PLANS_DIR the
# same invocation must fail. Without this, B11 could pass off some other naming source
# as "session resolution worked".
run_derive B11/neg
if [ "$RC" -ne 0 ] && ! printf '%s\n' "$OUT" | grep -q '^TASK_NAME='; then
    pass "B11/neg: with no session intent.md the same no-flag invocation exits non-zero"
else
    fail "B11/neg: expected rc!=0 and no TASK_NAME when no <sid>-intent.md is resolvable (rc=$RC, out='$OUT')"
fi

# --- B11/redact [F5]: the D2 failure diagnostic never echoes the session id --
# The intent path is derived from the session id, so a message that interpolated the
# path — or just its <sid>-intent.md basename — would leak a raw session id into any
# log or report capturing stderr. B11/neg only pins the exit code; this pins the text.
# The message is a fixed literal with no format substitution, so it is asserted
# verbatim: a re-introduced `%s` cannot pass a whole-line match.
B11_LEAK_SID="wtstartleaksid0002"
[ -e "$WORKFLOW_PLANS_DIR/$B11_LEAK_SID-intent.md" ] \
    && rm -f "$WORKFLOW_PLANS_DIR/$B11_LEAK_SID-intent.md"
D2_MSG='derive-worktree-name: no readable intent.md and no --headless <label>; cannot derive a task name'

export CLAUDE_CODE_SESSION_ID="$B11_LEAK_SID"
run_derive B11/redact
unset CLAUDE_CODE_SESSION_ID

B11R_LINES="$(printf '%s\n' "$ERR" | grep -c '[^[:space:]]')"
if [ "$RC" -ne 0 ] && [ "$B11R_LINES" -eq 1 ] && printf '%s\n' "$ERR" | grep -qxF "$D2_MSG"; then
    pass "B11/redact: the D2 failure emits exactly the fixed diagnostic, verbatim and alone"
else
    fail "B11/redact: expected the exact fixed D2 diagnostic as the only stderr line (rc=$RC, lines=$B11R_LINES, err='$ERR')"
fi
if [[ "$ERR" == *"$B11_LEAK_SID"* || "$ERR" == *"$WORKFLOW_PLANS_DIR"* ]]; then
    fail "B11/redact/leak: the session id or its resolved intent path reached stderr (err='$ERR')"
else
    pass "B11/redact/leak: neither the raw session id nor its <sid>-intent.md path reaches stderr"
fi

# --- B12 [C2]: WS-2/WS-4/WS-6 idempotency, behaviorally --------------------
# TC3 only greps SKILL.md prose. This reproduces the documented algorithm against a
# real fixture repo: derive a name, then run the create-or-reuse sequence twice and
# assert `git worktree add` fires exactly once across both invocations.
#
# Reuse safety has two halves and both are pinned here. (1) Derivation must be
# deterministic — a second WS-2 run on the same inputs has to reproduce the same
# TASK_NAME/BRANCH_TYPE byte for byte, or WS-4 would look up a name that never
# matches and WS-6 would keep creating worktrees. The naming source is therefore an
# intent.md, not --headless: the headless path appends a wall-clock disambiguator
# and is deliberately non-reproducible. (2) The create-or-reuse sequence itself must
# add exactly once across both runs — not zero (first run silently reused nothing),
# not twice (WS-4 failed to detect the existing worktree).
IDEM_REPO="$FIXTURE/idem-repo"
mkdir -p "$IDEM_REPO"
git -C "$IDEM_REPO" init -q >/dev/null 2>&1
git -C "$IDEM_REPO" config core.hooksPath /dev/null
git -C "$IDEM_REPO" config user.email "fixture@example.com"
git -C "$IDEM_REPO" config user.name "Fixture"
git -C "$IDEM_REPO" commit -q --allow-empty -m "fixture base" >/dev/null 2>&1
IDEM_BASE="$FIXTURE/idem-base"

INTENT_B12="$FIXTURE/b12-intent.md"
write_intent "$INTENT_B12" 'Idempotency probe for worktree reuse' ''

run_derive B12 --intent "$INTENT_B12" --repo-dir "$IDEM_REPO"
IDEM_TASK="$(task_name)"
IDEM_TYPE="$(branch_type)"
run_derive B12/again --intent "$INTENT_B12" --repo-dir "$IDEM_REPO"
IDEM_TASK2="$(task_name)"
IDEM_TYPE2="$(branch_type)"

# The one path WS-2 sanctions: <WORKTREE_BASE_DIR>/<task-name>/<repo-name>. Resolved
# once here, in the spelling `git worktree list` reports, so the reuse check below can
# compare whole lines rather than search for a fragment.
IDEM_WT_PATH="$IDEM_BASE/$IDEM_TASK/idem-repo"
IDEM_WT_NATIVE="$(native_path "$IDEM_WT_PATH")"

IDEM_ADDS=0
WS_RESULT=""
# WS-4 idempotency check + WS-6 create, as written in SKILL.md. Not run in a subshell:
# the add counter has to survive the call.
#
# WS-2 specifies the reuse test as "a worktree already exists at
# <WORKTREE_BASE_DIR>/<task-name>/<repo-name>" — exact path identity, so the check is an
# exact whole-line match (`grep -qxF`) against that one path. A substring search for the
# task name alone (the shape this case originally reproduced) fails the contract in both
# directions: it reports reuse for any unrelated worktree whose path merely contains the
# task name, and it never verifies that the hit is the expected <task>/<repo> location.
# The decoy worktree created below is what keeps this assertion honest.
ws_create_or_reuse() {
    if git -C "$IDEM_REPO" worktree list --porcelain \
        | sed -n 's/^worktree //p' | grep -qxF "$IDEM_WT_NATIVE"; then
        WS_RESULT="reuse"
        return 0
    fi
    mkdir -p "$IDEM_BASE/$IDEM_TASK"
    IDEM_ADDS=$((IDEM_ADDS + 1))
    if git -C "$IDEM_REPO" worktree add "$IDEM_WT_PATH" -b "$IDEM_TYPE/$IDEM_TASK" >/dev/null 2>&1; then
        WS_RESULT="created"
    else
        WS_RESULT="add-failed"
    fi
}

if [ -z "$IDEM_TASK" ] || [ -z "$IDEM_TYPE" ]; then
    fail "B12: could not derive a task name for the idempotency fixture (rc=$RC, out='$OUT')"
else
    # Guarded by the non-empty check above, so an equal-but-empty pair cannot pass.
    assert_eq "B12/deterministic-task: a second WS-2 run derives a byte-identical TASK_NAME" \
        "$IDEM_TASK" "$IDEM_TASK2"
    assert_eq "B12/deterministic-type: a second WS-2 run derives a byte-identical BRANCH_TYPE" \
        "$IDEM_TYPE" "$IDEM_TYPE2"

    # Decoy: a real, registered worktree whose path contains $IDEM_TASK as a substring
    # but is NOT the WS-2 path. It exists before the first create-or-reuse call, so a
    # substring-based reuse test would report "reuse" and never add anything — turning
    # B12/create and B12/adds-total red. That is the point: the decoy is what makes
    # those two assertions discriminate between exact-path and substring matching.
    IDEM_DECOY="$IDEM_BASE/${IDEM_TASK}-decoy/idem-repo"
    mkdir -p "$IDEM_BASE/${IDEM_TASK}-decoy"
    git -C "$IDEM_REPO" worktree add "$IDEM_DECOY" -b "decoy/$IDEM_TASK" >/dev/null 2>&1
    IDEM_DECOY_NATIVE="$(native_path "$IDEM_DECOY")"
    if git -C "$IDEM_REPO" worktree list --porcelain \
        | sed -n 's/^worktree //p' | grep -qxF "$IDEM_DECOY_NATIVE"; then
        pass "B12/decoy-setup: a worktree containing '$IDEM_TASK' in its path but not at the WS-2 location is registered"
    else
        fail "B12/decoy-setup: could not register the decoy worktree at '$IDEM_DECOY' (listing='$(git -C "$IDEM_REPO" worktree list --porcelain | sed -n 's/^worktree //p' | tr '\n' ' ')')"
    fi

    ws_create_or_reuse
    IDEM_FIRST="$WS_RESULT"
    IDEM_ADDS_AFTER_FIRST="$IDEM_ADDS"

    # The expected-path string and the path git actually registered must be the same
    # value, byte for byte. Without this the exact-match reuse test could be vacuous in
    # the other direction — a path spelling git never emits would make every run look
    # like a fresh create, and B12/reuse would be the only thing catching it.
    if git -C "$IDEM_REPO" worktree list --porcelain \
        | sed -n 's/^worktree //p' | grep -qxF "$IDEM_WT_NATIVE"; then
        pass "B12/exact-path: the created worktree is registered at exactly the WS-2 path <base>/<task-name>/<repo-name>"
    else
        fail "B12/exact-path: expected a porcelain entry equal to '$IDEM_WT_NATIVE' (listing='$(git -C "$IDEM_REPO" worktree list --porcelain | sed -n 's/^worktree //p' | tr '\n' ' ')')"
    fi

    ws_create_or_reuse
    IDEM_SECOND="$WS_RESULT"
    IDEM_LINKED="$(git -C "$IDEM_REPO" worktree list --porcelain \
        | sed -n 's/^worktree //p' | grep -cxF "$IDEM_WT_NATIVE")"

    if [ "$IDEM_FIRST" = "created" ] && [ "$IDEM_ADDS_AFTER_FIRST" -eq 1 ]; then
        pass "B12/create: first invocation ran 'git worktree add' once and created the worktree, ignoring the decoy path"
    else
        fail "B12/create: expected first=created with 1 add — a pre-existing worktree merely containing '$IDEM_TASK' in its path must not count as reuse (first='$IDEM_FIRST', adds=$IDEM_ADDS_AFTER_FIRST)"
    fi
    if [ "$IDEM_SECOND" = "reuse" ] && [ "$IDEM_ADDS" -eq 1 ]; then
        pass "B12/reuse: second invocation detected the existing worktree and skipped 'git worktree add'"
    else
        fail "B12/reuse: expected second=reuse with the add count still 1 (second='$IDEM_SECOND', adds=$IDEM_ADDS)"
    fi
    # Stated as its own total, not as a by-product of the two per-run assertions:
    # zero adds and two adds are both failures of the same contract.
    if [ "$IDEM_ADDS" -eq 1 ]; then
        pass "B12/adds-total: 'git worktree add' ran exactly once across both invocations"
    else
        fail "B12/adds-total: expected exactly 1 'git worktree add' across both invocations (got $IDEM_ADDS)"
    fi
    if [ "$IDEM_LINKED" -eq 1 ]; then
        pass "B12/count: exactly one worktree exists at the WS-2 path after both invocations"
    else
        fail "B12/count: expected exactly 1 worktree registered at '$IDEM_WT_NATIVE' (got $IDEM_LINKED)"
    fi
fi

report_shape session
finish
