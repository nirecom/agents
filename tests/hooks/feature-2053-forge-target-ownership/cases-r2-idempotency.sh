#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js, hooks/confirm-forge-target-ownership/
# Tags: hook, pre-tool-use, github, gh, ownership, security, scope:issue-specific
# Part of tests/feature-2053-forge-target-ownership.sh (rules/coding/file-split.md).
# Round-2 C6 — security IDEMPOTENCY: an ask must survive being asked again.
#
# WHY: the danger is a negative cache read as a positive one — a failed first
# probe writes "already looked at this" and a second read treats it as settled
# and allows silently (issue #2053 in miniature: ask once, retry sails
# through). Every row runs the SAME command twice in ONE session; both must ask.

run_block_r2_idempotency() {
    echo ""
    echo "=== R2-C6-1: the same unprovable target, twice in one session ==="

    local FOREIGN_C="gh issue create --repo $FOREIGN/r --title x"
    local name env1 env2

    # Each row names the REASON the first proof failed. A negative cache keyed on
    # "we probed and got nothing" is equally wrong for all of them; only the
    # timeout row exercises the branch where no answer arrived at all. The login
    # row must report a THIRD party — a login equal to the target's own owner
    # ($FOREIGN) proves ownership and turns the row into a silent-allow case.
    # env1/env2 are identical on purpose: nothing about the world changed between
    # the two calls, so nothing may have changed about the verdict.
    while IFS='|' read -r name env1 env2; do
        [ -z "$name" ] && continue
        reset_env
        CASE_ENV=()
        [ -n "$env1" ] && CASE_ENV=("$env1")
        run_case "$FX_OWNED" "$FOREIGN_C"
        assert_decision "R2-C6-1 [$name] first invocation -> ask" "ask"
        CASE_ENV=()
        [ -n "$env2" ] && CASE_ENV=("$env2")
        resume_case "$FX_OWNED" "$FOREIGN_C"
        assert_decision "R2-C6-1 [$name] SECOND invocation still asks" "ask"
        assert_eq "R2-C6-1 [$name] and the second one did not crash" "0" "$HOOK_RC"
    done <<TABLE
false capability|GH_STUB_ADMIN=false|GH_STUB_ADMIN=false
probe error|GH_STUB_EXIT=1|GH_STUB_EXIT=1
probe timeout|GH_STUB_SLEEP=30|GH_STUB_SLEEP=30
third-party login|GH_STUB_LOGIN=someoneelse-r2|GH_STUB_LOGIN=someoneelse-r2
TABLE

    echo ""
    echo "=== R2-C6-2: a third invocation, and the ask is still an ask ==="

    # Two calls can be satisfied by a guard that simply never caches. Three calls
    # with a repeat of the SECOND failure mode is what catches a cache that is
    # written on the second miss rather than the first.
    reset_env; add_env "GH_STUB_EXIT=1"
    run_case "$FX_OWNED" "$FOREIGN_C"
    assert_decision "R2-C6-2a call 1 -> ask" "ask"
    CASE_ENV=("GH_STUB_EXIT=1")
    resume_case "$FX_OWNED" "$FOREIGN_C"
    assert_decision "R2-C6-2b call 2 -> ask" "ask"
    CASE_ENV=("GH_STUB_EXIT=1")
    resume_case "$FX_OWNED" "$FOREIGN_C"
    assert_decision "R2-C6-2c call 3 -> ask" "ask"

    echo ""
    echo "=== R2-C6-3: repeating does not silently stop probing either ==="

    # The mirror defect: caching the FAILURE so aggressively that the guard stops
    # re-checking. That is not a security hole, but it is the mechanism that turns
    # into one the moment the cached entry is reused for a different question, so
    # pin that the second call still spends a live probe.
    reset_env
    run_case "$FX_OWNED" "$FOREIGN_C"
    assert_decision "R2-C6-3a first call -> ask" "ask"
    resume_case "$FX_OWNED" "$FOREIGN_C"
    assert_decision "R2-C6-3b second call -> ask" "ask"
    assert_probes "R2-C6-3c the target is re-checked, not read from a negative cache" "api repos/" 1

    echo ""
    echo "=== R2-C6-4: the control — repetition does not break the allow path ==="

    # Without this, a guard that answered "ask" to absolutely everything would
    # pass every row above. The provable target must still be silent on BOTH
    # invocations, which is also the property that makes the guard usable.
    reset_env
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "R2-C6-4a owned, first call -> silent allow" "silent"
    resume_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title y"
    assert_decision "R2-C6-4b owned, second call -> silent allow" "silent"
}
