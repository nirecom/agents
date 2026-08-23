#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js, hooks/confirm-forge-target-ownership/
# Tags: hook, pre-tool-use, github, gh, ownership, security, scope:issue-specific
# Part of tests/feature-2053-forge-target-ownership.sh (rules/coding/file-split.md).
# Block C9 — the session id and the cache files it names.
#
# WHY: the session id is interpolated into a FILE PATH under
# CLAUDE_WORKFLOW_DIR. (1) Path: a separator or dot-segment escapes the state
# directory (CWE-22). (2) Verdict: any state failure — missing id, unreadable
# cache, unwritable dir — must degrade to ask, never silent allow.

run_block_c9() {
    echo ""
    echo "=== C9-1: hostile and degenerate session ids never allow a foreign write ==="

    local FOREIGN_WRITE="gh issue create --repo $FOREIGN/r --title x"
    local LONG_SID; LONG_SID="$(printf 'a%.0s' $(seq 1 4096))"
    local name sid

    # Every row must reach ask. The command is a plain foreign write, so the id
    # is the only variable — a silent verdict on any row means the state layer
    # failed open.
    while IFS='|' read -r name sid; do
        [ -z "$name" ] && continue
        case "$sid" in "@LONG") sid="$LONG_SID" ;; esac
        reset_env
        run_sid_case "$sid" "$FX_OWNED" "$FOREIGN_WRITE"
        assert_decision "C9-1 [$name] foreign write -> ask" "ask"
        assert_eq "C9-1 [$name] the hook still exits 0" "0" "$HOOK_RC"
    done <<TABLE
session_id absent|-
session_id null|@null
empty string|
single dot|.
parent traversal|..
traversal path|../../escape
absolute-looking|/etc/passwd
windows separator|a\\b
posix separator|a/b
trailing separator|abc/
nul-ish escape|abc%00def
newline inside|abc\ndef
shell metacharacters|a;rm -rf x
glob characters|a*?[]
dot prefix|.workflow-off
marker lookalike|s1.gh-login
very long|@LONG
TABLE

    echo ""
    echo "=== C9-2: nothing is written outside CLAUDE_WORKFLOW_DIR ==="

    # The traversal rows above ran with $BASE/workflow as the state dir. If any
    # id escaped it, the guard's own state files land in $BASE (or above it).
    local strays
    strays="$(find "$BASE" -maxdepth 3 -type f \
                \( -name '*gh-login*' -o -name '*gh-env*' -o -name '*gh-auth-dirty*' \) \
                -not -path "$CLAUDE_WORKFLOW_DIR/*" 2>/dev/null | head -5)"
    assert_eq "C9-2a no guard state file landed outside CLAUDE_WORKFLOW_DIR" "" "$strays"
    # And the plans dir — pinned separately per rules/test/fixture-isolation.md —
    # must stay free of guard state too. Scoped to the guard's own filenames on
    # purpose: the plans dir is shared fixture ground that other blocks in this
    # suite legitimately write to (e.g. the supervisor state file emitted by the
    # C5 enforce-issue-close rows), so total emptiness is not this case's claim.
    strays="$(find "$WORKFLOW_PLANS_DIR" -type f \
                \( -name '*gh-login*' -o -name '*gh-env*' -o -name '*gh-auth-dirty*' \) \
                2>/dev/null | head -5)"
    assert_eq "C9-2b no guard state file landed in the plans dir" "" "$strays"

    echo ""
    echo "=== C9-3: a corrupt or truncated cache proves nothing ==="

    # The proof cache is the guard's memory. A damaged one must be discarded and
    # re-proven, and when re-proof is impossible (GH_STUB_EXIT=1) the answer is
    # ask. A guard that trusts whatever it can parse out of the file allows a
    # foreign write to anyone who can drop a file in the state dir.
    local body
    while IFS='|' read -r name body; do
        [ -z "$name" ] && continue
        reset_env
        run_case "$FX_OWNED" "echo warmup"
        printf '%s' "$body" > "$CLAUDE_WORKFLOW_DIR/$SID.gh-login"
        printf '%s' "$body" > "$CLAUDE_WORKFLOW_DIR/$SID.gh-env"
        CASE_ENV=("GH_STUB_EXIT=1")
        resume_case "$FX_OWNED" "$FOREIGN_WRITE"
        assert_decision "C9-3 [$name] corrupt cache + unusable gh -> ask" "ask"
        assert_eq "C9-3 [$name] and no crash" "0" "$HOOK_RC"
        rm -f "$CLAUDE_WORKFLOW_DIR/$SID.gh-login" "$CLAUDE_WORKFLOW_DIR/$SID.gh-env"
    done <<TABLE
empty file|
truncated json|{"login":"tes
not json|<<<binary garbage>>>
json null|null
json array|[]
wrong shape|{"unexpected":true}
forged ownership claim|{"login":"$FOREIGN","owned":["$FOREIGN/r"],"admin":true}
TABLE

    # The forged-claim row deserves its own explicit control: with a WORKING gh
    # that reports a different login, a cache file claiming the foreign repo is
    # owned must still lose to the live probe.
    reset_env
    run_case "$FX_OWNED" "echo warmup"
    printf '{"login":"%s","owned":["%s/r"],"admin":true}' "$FOREIGN" "$FOREIGN" \
        > "$CLAUDE_WORKFLOW_DIR/$SID.gh-login"
    resume_case "$FX_OWNED" "$FOREIGN_WRITE"
    assert_decision "C9-4 a planted cache claiming foreign ownership -> ask" "ask"
    rm -f "$CLAUDE_WORKFLOW_DIR/$SID.gh-login"

    echo ""
    echo "=== C9-5: an unwritable state directory fails closed ==="

    # Skipped rather than faked where chmod has no effect (Windows/CI as admin):
    # a test that cannot make the directory unwritable is not testing this path.
    local rodir="$BASE/rostate"
    mkdir -p "$rodir"
    chmod 500 "$rodir" 2>/dev/null || true
    if : > "$rodir/probe" 2>/dev/null; then
        rm -f "$rodir/probe"
        skip "C9-5 unwritable state dir (chmod has no effect on this filesystem)"
    else
        reset_env; add_env "CLAUDE_WORKFLOW_DIR=$rodir"
        run_case "$FX_OWNED" "$FOREIGN_WRITE"
        assert_decision "C9-5a a read-only state dir still yields ask" "ask"
        assert_eq "C9-5b and the hook still exits 0" "0" "$HOOK_RC"
        # The owned side of the same failure: unable to REMEMBER is not the same
        # as unable to PROVE, so a live probe must still be able to allow.
        reset_env; add_env "CLAUDE_WORKFLOW_DIR=$rodir"
        run_case "$FX_OWNED" "gh issue create --repo $OWNER/agents --title x"
        assert_decision "C9-5c an owned target is still provable without state" "silent"
    fi
    chmod 700 "$rodir" 2>/dev/null || true

    echo ""
    echo "=== C9-6: the state dir env var itself can be missing ==="

    # With no CLAUDE_WORKFLOW_DIR the guard has nowhere to cache. It must not
    # invent a path in the developer's home, and it must not fail open.
    reset_env; add_env "CLAUDE_WORKFLOW_DIR="
    run_case "$FX_OWNED" "$FOREIGN_WRITE"
    assert_decision "C9-6a empty CLAUDE_WORKFLOW_DIR -> ask" "ask"
    assert_eq "C9-6b and no crash" "0" "$HOOK_RC"
    reset_env; add_env "CLAUDE_WORKFLOW_DIR=$BASE/does-not-exist-yet/nested"
    run_case "$FX_OWNED" "$FOREIGN_WRITE"
    assert_decision "C9-6c a nonexistent state dir -> ask" "ask"
    assert_eq "C9-6d and no crash" "0" "$HOOK_RC"
}
