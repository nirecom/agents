#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js, hooks/confirm-forge-target-ownership/
# Tags: hook, pre-tool-use, github, gh, ownership, security, scope:issue-specific
# Part of tests/feature-2053-forge-target-ownership.sh (rules/coding/file-split.md).
# Block C6 — multi-target sequencing and per-target cache isolation.

# WHY: the per-session cache (block I) is what makes the guard affordable. Its
# failure mode is a cache keyed too coarsely: one proven target teaching the
# guard that the SESSION is trusted, after which every later target rides free.
# Order matters both ways — owned->foreign is the "cache poisons the future"
# direction, foreign->owned is the "one ask makes everything ask" direction.

run_block_c6() {
    echo ""
    echo "=== C6-1: two targets in ONE command line, across every separator ==="

    local OWNED_C="gh issue create --repo $OWNER/agents --title x"
    local FOREIGN_C="gh issue create --repo $FOREIGN/r --title x"
    local sep name token

    # A separator table. Each row is one Bash payload holding both writes; the
    # foreign one is in scope whichever side of the separator it sits on. The
    # token column exists because a literal newline cannot survive a here-doc
    # field, and an empty field would silently concatenate the two commands.
    while IFS='|' read -r name token; do
        [ -z "$name" ] && continue
        case "$token" in
            NL)   sep=$'\n' ;;
            SEMI) sep="; " ;;
            AND)  sep=" && " ;;
            *)    fail "C6-1 [$name] unknown separator token" "$token"; continue ;;
        esac
        reset_env
        run_case "$FX_OWNED" "$OWNED_C$sep$FOREIGN_C"
        assert_decision "C6-1a [$name] owned then foreign -> ask" "ask" "$FOREIGN/r"
        reset_env
        run_case "$FX_OWNED" "$FOREIGN_C$sep$OWNED_C"
        assert_decision "C6-1b [$name] foreign then owned -> ask" "ask" "$FOREIGN/r"
        # The control that keeps C6-1a/b honest: the same shape, both owned.
        # Without it a guard that asks at any separator would pass every row.
        reset_env
        run_case "$FX_OWNED" "$OWNED_C$sep$OWNED_C"
        assert_decision "C6-1c [$name] owned then owned -> silent allow" "silent"
    done <<'TABLE'
newline|NL
semicolon|SEMI
and-and|AND
TABLE

    echo ""
    echo "=== C6-2: the same sequencing across separate calls in ONE session ==="

    # Sequencing across tool calls is the shape the per-session cache actually
    # lives in: a fresh hook PROCESS, the same session id, a different target.
    reset_env
    run_case "$FX_OWNED" "$OWNED_C"
    assert_decision "C6-2a first call, owned -> silent allow" "silent"
    resume_case "$FX_OWNED" "$FOREIGN_C"
    assert_decision "C6-2b same session, foreign target -> ask" "ask"

    reset_env
    run_case "$FX_OWNED" "$FOREIGN_C"
    assert_decision "C6-2c first call, foreign -> ask" "ask"
    resume_case "$FX_OWNED" "$OWNED_C"
    assert_decision "C6-2d same session, owned target -> silent allow again" "silent"

    echo ""
    echo "=== C6-3: a cached result belongs to ONE target, never to the session ==="

    # The capability rung (P2): admin=true proves $OWNER/agents only. The stub
    # answers admin for whatever repo it is asked about, so if the second target
    # were re-queried it would ALSO come back admin — meaning a silent allow here
    # cannot be blamed on the stub. It can only mean the cached YES was reused.
    reset_env; add_env "GH_STUB_LOGIN=orgmember"; add_env "GH_STUB_ADMIN=true"
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "C6-3a admin capability proves the FIRST target" "silent"
    assert_probes "C6-3b one capability query for it" "api repos/" 1
    # Now the same session asks about a DIFFERENT repo with the capability query
    # disabled outright (non-zero exit). Nothing can be proven, so: ask.
    CASE_ENV=("GH_STUB_LOGIN=orgmember" "GH_STUB_EXIT=1")
    resume_case "$FX_OWNED" "gh issue create --repo $FOREIGN/other --title x"
    assert_decision "C6-3c a different target is NOT covered by that cache -> ask" "ask"

    # The mirror: a cached NO must not stick to a target that was never denied.
    reset_env; add_env "GH_STUB_LOGIN=other"; add_env "GH_STUB_ADMIN=false"
    run_case "$FX_OWNED" "gh issue create --repo $FOREIGN/r --title x"
    assert_decision "C6-3d the first target is unprovable -> ask" "ask"
    CASE_ENV=("GH_STUB_LOGIN=$OWNER")
    resume_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_decision "C6-3e a provable target is not tarred by it -> silent allow" "silent"

    # Login identity is session-wide (one authenticated user), so THAT may be
    # cached across targets — this pins the boundary between the two caches.
    reset_env
    run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
    assert_probes "C6-4a the login is probed once" "api user" 1
    resume_case "$FX_OWNED" "gh issue create --repo $OWNER/other --title x"
    assert_decision "C6-4b a second repo under the same login -> silent allow" "silent"
    assert_probes "C6-4c and the login is not re-probed" "api user" 0

    echo ""
    echo "=== C6-5: three targets, only the middle one unprovable ==="

    # A scan that stops at the first proven target, or at the first line, misses
    # a target parked between two provable ones.
    reset_env; add_env "GH_STUB_LOGIN=$OWNER"
    run_case "$FX_OWNED" "$OWNED_C && gh issue create --repo $FOREIGN/mid --title m && $OWNED_C"
    assert_decision "C6-5 owned, foreign, owned in one line -> ask" "ask" "$FOREIGN/mid"
}
