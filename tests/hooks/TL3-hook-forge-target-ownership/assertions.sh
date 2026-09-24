#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js
# Tags: forge-ownership, gh, github, pre-tool-use, hook, security, TL3, run-e2e, scope:issue-specific
# Part of tests/TL3-hook-forge-target-ownership.sh (rules/coding/file-split.md).
# The assertion half: everything that reads the two live turns.

# Sourced, not executed — it reads GUARD, LOG_A/LOG_B, TOK_A/TOK_B, RC_A/RC_B,
# GH_LOG, GH_ENV_LOG, GHCONFIG, FOREIGN and BASE from the parent, which owns the
# fixture and the turns.
# guard_lines <log> <token> — dispatches of the guard carrying that turn's token.
guard_lines() { grep -F "$GUARD" "$1" 2>/dev/null | grep -cF "$2"; }

# other_blocks <log> <token> — non-guard hooks that BLOCKED that command.
# Round-2 C1: a hook in this chain signals a block two different ways — exit 2,
# or exit 0 with {"decision":"block"} on stdout (which is what enforce-worktree.js
# does). Reading only the exit code declared the chain clean while the intended
# ask had in fact been replaced by a hard block.
other_blocks() {
    grep -F "$2" "$1" 2>/dev/null | grep -v "^$GUARD	" \
        | awk -F'\t' '$2 == 2 || $4 ~ /"decision" *: *"block"/ || $4 ~ /"permissionDecision" *: *"deny"/ { print $1 }' \
        | sort -u | tr '\n' ' '
}

# C2-1/2: an exit code that was never read is a test that passes when the CLI
# times out, crashes, or refuses the prompt. Read it, and say which turn it was.
for pair in "A:$RC_A" "B:$RC_B"; do
    turn="${pair%%:*}"; rc="${pair#*:}"
    if [ "$rc" -eq 0 ]; then
        pass "C2-1 turn $turn: the claude CLI exited 0"
    else
        fail "C2-1 turn $turn: the claude CLI exited 0" \
             "exit=$rc (124 = the 180s timeout fired) — every verdict from this turn is unreliable"
    fi
done

# C2-2: exactly one correlated dispatch per turn. Zero means the command never
# reached the guard; more than one means the agent retried and the verdicts below
# would be an average of several attempts rather than one observation.
NA="$(guard_lines "$LOG_A" "$TOK_A")"; NB="$(guard_lines "$LOG_B" "$TOK_B")"
if [ "$NA" -eq 1 ]; then
    pass "C2-2 turn A dispatched the guard exactly once ($TOK_A)"
else
    fail "C2-2 turn A dispatched the guard exactly once ($TOK_A)" "counted $NA dispatches in $LOG_A"
fi
if [ "$NB" -eq 1 ]; then
    pass "C2-3 turn B dispatched the guard exactly once ($TOK_B)"
else
    fail "C2-3 turn B dispatched the guard exactly once ($TOK_B)" "counted $NB dispatches in $LOG_B"
fi

# C1-5: the verdict itself, read only from the correlated line.
if grep -F "$GUARD" "$LOG_A" 2>/dev/null | grep -F "$TOK_A" | grep -q '"permissionDecision" *: *"ask"'; then
    pass "C1-5 the foreign target produced an ask in a real dispatch"
else
    fail "C1-5 the foreign target produced an ask in a real dispatch" \
         "no ask recorded for $FOREIGN/some-repo (see $LOG_A)"
fi

# C1-6: the control. Its whole job is to prove C1-5 is not "asks at everything":
# a guard that always asks is unusable and would pass C1-5 while failing here.
if grep -F "$GUARD" "$LOG_B" 2>/dev/null | grep -F "$TOK_B" | grep -q '"permissionDecision" *: *"ask"'; then
    fail "C1-6 the provably-owned origin was not asked about" \
         "the guard asked about its own origin — it asks unconditionally"
else
    pass "C1-6 the provably-owned origin was not asked about"
fi

# C1-7/C1-8: the chain, not just the guard. An earlier hook that blocks replaces
# the intended ask with a hard refusal — the user never sees the prompt, and the
# guard looks fine in isolation. This is the defect only the real chain can show,
# and the C1-P preflight is its static twin.
DENY_A="$(other_blocks "$LOG_A" "$TOK_A")"
if [ -z "$DENY_A" ]; then
    pass "C1-7 no other hook in the chain blocked the foreign command"
else
    fail "C1-7 no other hook in the chain blocked the foreign command" \
         "blocked by:$DENY_A — the ask was replaced by a block"
fi
DENY_B="$(other_blocks "$LOG_B" "$TOK_B")"
if [ -z "$DENY_B" ]; then
    pass "C1-8 no other hook in the chain blocked the owned command"
else
    fail "C1-8 no other hook in the chain blocked the owned command" "blocked by:$DENY_B"
fi

# C1-10: enforce-worktree.js is the specific neighbour round-2 C1 named. Name it
# explicitly: "some hook blocked" and "the worktree gate blocked" are different
# findings, and only the second one invalidates the fixture design.
EW_LINES="$(grep -F 'enforce-worktree.js' "$LOG_A" "$LOG_B" 2>/dev/null | grep -cE '"decision" *: *"block"')"
if [ "${EW_LINES:-0}" -eq 0 ]; then
    pass "C1-10 the existing worktree gate permitted both live turns"
else
    fail "C1-10 the existing worktree gate permitted both live turns" \
         "$EW_LINES blocking dispatch(es) — the fixture is not a sanctioned location after all"
fi

# C2-4: the probe really ran against the stub, so C1-6 reflects a proof that was
# performed rather than a check that was skipped.
if grep -q "api user" "$GH_LOG" 2>/dev/null; then
    pass "C2-4 the ownership probe executed against the stub"
else
    fail "C2-4 the ownership probe executed against the stub" \
         "the guard never probed identity — C1-6 proves nothing"
fi

# C2-5: creation against the FOREIGN repo must be absent. The old form of this
# assertion passed whether or not `issue create` ran at all, which is exactly the
# outcome it was supposed to rule out. Absence of the foreign target is the claim.
if grep -F "issue create" "$GH_LOG" 2>/dev/null | grep -qF "$FOREIGN/some-repo"; then
    fail "C2-5 no creation ran against the foreign repo before confirmation" \
         "the foreign target reached gh issue create (stubbed, so nothing was filed — but the guard let it through)"
else
    pass "C2-5 no creation ran against the foreign repo before confirmation"
fi

# C2-6 (round-2 C2): the allow path must be OBSERVED, not assumed. The previous
# form passed when the owned command never executed at all — the one outcome that
# makes "the guard allows what it can prove" unproven. Both halves are required:
# exactly one owned `issue create` in the stub log, AND the stub's own refusal
# sentinel in the turn output, which only the stub can produce (a real gh 404s).
OWNED_CREATES="$(grep -F 'issue create' "$GH_LOG" 2>/dev/null | grep -cF "$TOK_B")"
if [ "${OWNED_CREATES:-0}" -eq 1 ]; then
    pass "C2-6a the owned creation executed exactly once against the stub"
else
    fail "C2-6a the owned creation executed exactly once against the stub" \
         "counted ${OWNED_CREATES:-0} owned 'issue create' invocations carrying $TOK_B in $GH_LOG"
fi
if grep -qF "STUB: refusing to file an issue" "$BASE/$TOK_B.out" 2>/dev/null; then
    pass "C2-6b and its refusal sentinel reached the transcript (stub, not a real gh)"
else
    fail "C2-6b and its refusal sentinel reached the transcript (stub, not a real gh)" \
         "the stub's refusal never surfaced — either the command never ran or PATH shadowing was bypassed"
fi

# C3-3 (round-2 C3): credential isolation, verified where it matters — inside the
# process a real gh would have been. A setup that exports the right variables and
# a session that actually sees them are different claims.
if [ -s "$GH_ENV_LOG" ]; then
    LEAKED="$(grep -vE '^GH_TOKEN=<unset>\|GITHUB_TOKEN=<unset>\|GH_ENTERPRISE_TOKEN=<unset>\|GITHUB_ENTERPRISE_TOKEN=<unset>' \
                "$GH_ENV_LOG" | head -1)"
    if [ -z "$LEAKED" ]; then
        pass "C3-3 every gh invocation ran with all four credential variables unset"
    else
        fail "C3-3 every gh invocation ran with all four credential variables unset" \
             "a token was visible to gh: $LEAKED"
    fi
    if grep -qF "GH_CONFIG_DIR=$GHCONFIG" "$GH_ENV_LOG"; then
        pass "C3-4 gh saw the isolated GH_CONFIG_DIR, not the developer's hosts.yml"
    else
        fail "C3-4 gh saw the isolated GH_CONFIG_DIR, not the developer's hosts.yml" \
             "expected GH_CONFIG_DIR=$GHCONFIG in $GH_ENV_LOG"
    fi
    if [ -z "$(find "$GHCONFIG" -type f 2>/dev/null | head -1)" ]; then
        pass "C3-5 the isolated config dir held no credential file at any point"
    else
        fail "C3-5 the isolated config dir held no credential file at any point" \
             "files appeared under $GHCONFIG"
    fi
else
    fail "C3-3 every gh invocation ran with all four credential variables unset" \
         "no gh invocation was recorded — the isolation claim is untested"
    fail "C3-4 gh saw the isolated GH_CONFIG_DIR, not the developer's hosts.yml" "no gh invocation recorded"
    fail "C3-5 the isolated config dir held no credential file at any point" "no gh invocation recorded"
fi

# C2-7: the positive control for the whole file. If neither turn produced output
# and no hook was ever dispatched, everything above is vacuous.
if [ -s "$LOG_A" ] && [ -s "$LOG_B" ]; then
    pass "C2-7 both turns dispatched the production hook chain"
else
    fail "C2-7 both turns dispatched the production hook chain" \
         "an empty hook log means no PreToolUse fired — the verdicts above prove nothing"
fi
