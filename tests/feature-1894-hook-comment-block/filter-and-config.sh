#!/usr/bin/env bash
# tests/feature-1894-hook-comment-block/filter-and-config.sh
# Tests: hooks/block-comment-block-size.js, hooks/lib/load-env.js, hooks/lib/comment-block-scan.js
# Tags: comment-block-size, hook, pretooluse, dotenv, config, extensions, exclusions, spoofing, scope:issue-specific, scope:feature-1894, layer:TL2

# Part 4 — what the hook scans, and who gets to change the rules. Two
# questions sharing a code path (CPR-SC): Scope — extensions/excluded dirs,
# a hot-path filter run on every Edit, deliberately first; failure direction
# is "scanned something it shouldn't" (latency, false blocks in vendored
# trees). Control — numbers come from the config dir's .env and NOWHERE
# else; process.env is never consulted, since `COMMENT_BLOCK_MAX_LINES=999999
# claude` could otherwise disable the feature silently for the session. The
# spoof rows are the point: each has a matched .env/ambient pair with
# opposite meanings, so a hook reading process.env has to move on one.

# Sourced by the dispatcher; all helpers are defined there.

# ============================================================================
# C1 — extension filter, both verdicts
# ============================================================================
c1_extension_filter() {
    local f
    # Same 12-line comment run in three files; only the extension differs.
    f="$( { echo "var x = 1;"; cmt 12 c; } | wfile "c1.js" )"
    mkpayload Write "$REPO_M" "$f" "content=@$REPO/c1.js"
    hk_run
    assert_decision "C1/js-is-scanned" "block"

    f="$( { echo "text"; cmt 12 c; } | wfile "c1.md" )"
    mkpayload Write "$REPO_M" "$f" "content=@$REPO/c1.md"
    hk_run
    assert_decision "C1/md-is-not-scanned" "approve"

    f="$( { echo "text"; cmt 12 c; } | wfile "c1.txt" )"
    mkpayload Write "$REPO_M" "$f" "content=@$REPO/c1.txt"
    hk_run
    assert_decision "C1/txt-is-not-scanned" "approve"

    # The list is configurable, and CODE_FILE_EXTENSIONS is its only source.
    f="$( { echo "text"; cmt 12 c; } | wfile "c1b.md" )"
    mkpayload Write "$REPO_M" "$f" "content=@$REPO/c1b.md"
    hk_run "CODE_FILE_EXTENSIONS=md"
    assert_decision "C1/pinned-list-adds-md" "block"

    f="$( { echo "var x = 1;"; cmt 12 c; } | wfile "c1c.js" )"
    mkpayload Write "$REPO_M" "$f" "content=@$REPO/c1c.js"
    hk_run "CODE_FILE_EXTENSIONS=md"
    assert_decision "C1/pinned-list-drops-js" "approve"
}

# ============================================================================
# C2 — excluded path segments
#
# Vendored and archived trees are not the author's code. Blocking an Edit inside
# node_modules would be both useless and unfixable — and tests/_archive exists
# specifically to hold code that is no longer maintained to current standards.
# ============================================================================
c2_excluded_path_segments() {
    local seg f
    for seg in node_modules _archive _archived; do
        f="$( { echo "var x = 1;"; cmt 12 c; } | wfile "$seg/c2.js" )"
        mkpayload Write "$REPO_M" "$f" "content=@$REPO/$seg/c2.js"
        hk_run
        assert_decision "C2/$seg-is-excluded" "approve"

        # Nested deeper, since the segment can appear anywhere in the path.
        f="$( { echo "var x = 1;"; cmt 12 c; } | wfile "src/$seg/deep/c2.js" )"
        mkpayload Write "$REPO_M" "$f" "content=@$REPO/src/$seg/deep/c2.js"
        hk_run
        assert_decision "C2/$seg-is-excluded-when-nested" "approve"
    done

    # A .git directory should never be edited, but if it is, it is not source.
    f="$( { echo "var x = 1;"; cmt 12 c; } | wfile ".git/hooks-scratch/c2.js" )"
    mkpayload Write "$REPO_M" "$f" "content=@$REPO/.git/hooks-scratch/c2.js"
    hk_run
    assert_decision "C2/dot-git-is-excluded" "approve"

    # Control: a path that merely CONTAINS the substring is not excluded, or the
    # exclusion silently swallows ordinary files (my_archive_helper/, etc.).
    f="$( { echo "var x = 1;"; cmt 12 c; } | wfile "src/my_archived_notes/c2.js" )"
    mkpayload Write "$REPO_M" "$f" "content=@$REPO/src/my_archived_notes/c2.js"
    hk_run
    assert_decision "C2/substring-match-does-not-exclude" "block"
}

# ============================================================================
# C3 — the threshold comes from .env
# ============================================================================
c3_threshold_from_dotenv() {
    local f
    f="$( { echo "var x = 1;"; cmt 6 c; } | wfile "c3.js" )"
    mkpayload Write "$REPO_M" "$f" "content=@$REPO/c3.js"
    hk_run "COMMENT_BLOCK_MAX_LINES=5"
    assert_decision "C3/lowered-threshold-blocks" "block"
    hk_run "COMMENT_BLOCK_MAX_LINES=6"
    assert_decision "C3/at-lowered-threshold-approves" "approve"
    hk_run "COMMENT_BLOCK_MAX_LINES=20"
    assert_decision "C3/raised-threshold-approves" "approve"

    # A malformed value must fall back to the built-in default rather than
    # becoming an accidental "no limit" (or an accidental "zero limit").
    f="$( { echo "var x = 1;"; cmt 11 c; } | wfile "c3b.js" )"
    mkpayload Write "$REPO_M" "$f" "content=@$REPO/c3b.js"
    local v
    for v in "" "abc" "0" "-5" "3.5" "10abc"; do
        hk_run "COMMENT_BLOCK_MAX_LINES=$v"
        assert_decision "C3/invalid-[$v]-falls-back-to-default" "block"
    done
    f="$( { echo "var x = 1;"; cmt 10 c; } | wfile "c3c.js" )"
    mkpayload Write "$REPO_M" "$f" "content=@$REPO/c3c.js"
    for v in "" "abc" "0" "-5"; do
        hk_run "COMMENT_BLOCK_MAX_LINES=$v"
        assert_decision "C3/invalid-[$v]-default-still-allows-10" "approve"
    done
}

# ============================================================================
# C4 — the kill switch, and only the exact value
# ============================================================================
c4_kill_switch() {
    local f
    f="$( { echo "var x = 1;"; cmt 12 c; } | wfile "c4.js" )"
    mkpayload Write "$REPO_M" "$f" "content=@$REPO/c4.js"
    hk_run "COMMENT_BLOCK_ENFORCE=off"
    assert_decision "C4/off-approves" "approve"
    hk_run "COMMENT_BLOCK_ENFORCE=on"
    assert_decision "C4/on-blocks" "block"
    hk_run
    assert_decision "C4/default-is-on" "block"
    # A near-miss must not disable the gate: "off " or "OFF" in a hand-edited
    # .env would otherwise be an invisible bypass.
    local v
    for v in "offf" "OFF" "0" "false" "no"; do
        hk_run "COMMENT_BLOCK_ENFORCE=$v"
        assert_decision "C4/[$v]-does-not-disable" "block"
    done
}

# ============================================================================
# C5 — process.env cannot steer any of it
#
# The whole reason config is .env-only. Each pair sets the .env one way and the
# ambient environment the other, so a hook that reads process.env moves.
# ============================================================================
c5_ambient_env_is_ignored() {
    local f
    f="$( { echo "var x = 1;"; cmt 12 c; } | wfile "c5.js" )"
    mkpayload Write "$REPO_M" "$f" "content=@$REPO/c5.js"

    # .env on + ambient off -> still blocked.
    _hk_env 0 "COMMENT_BLOCK_ENFORCE=on"
    HK_ENVS+=("COMMENT_BLOCK_ENFORCE=off")
    _hk_exec
    assert_decision "C5/ambient-off-cannot-disable" "block"

    # .env off + ambient on -> still approved (the mirror; without it, a hook
    # that ignored BOTH sources would pass the row above).
    _hk_env 0 "COMMENT_BLOCK_ENFORCE=off"
    HK_ENVS+=("COMMENT_BLOCK_ENFORCE=on")
    _hk_exec
    assert_decision "C5/ambient-on-cannot-enable" "approve"

    # Threshold, same two directions.
    _hk_env 0 "COMMENT_BLOCK_MAX_LINES=10"
    HK_ENVS+=("COMMENT_BLOCK_MAX_LINES=999999")
    _hk_exec
    assert_decision "C5/ambient-threshold-cannot-lift" "block"

    _hk_env 0 "COMMENT_BLOCK_MAX_LINES=999999"
    HK_ENVS+=("COMMENT_BLOCK_MAX_LINES=10")
    _hk_exec
    assert_decision "C5/ambient-threshold-cannot-lower" "approve"

    # Extension list, same two directions.
    _hk_env 0 "CODE_FILE_EXTENSIONS=js"
    HK_ENVS+=("CODE_FILE_EXTENSIONS=md")
    _hk_exec
    assert_decision "C5/ambient-extensions-cannot-narrow" "block"

    _hk_env 0 "CODE_FILE_EXTENSIONS=md"
    HK_ENVS+=("CODE_FILE_EXTENSIONS=js")
    _hk_exec
    assert_decision "C5/ambient-extensions-cannot-widen" "approve"
}

# _hk_exec — run the hook with HK_ENVS exactly as the caller left it. Used only
# by C5, where the whole point is an environment the normal helpers refuse to
# build (a config name present in BOTH .env and the child environment, with
# conflicting values).
_hk_exec() {
    local errfile="$TMPDIR_BASE/hook.err"
    HK_RC=0
    HK_OUT="$( (cd "$NEUTRAL_CWD" \
        && unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID \
        && run_with_timeout 30 env "${HK_ENVS[@]}" \
            node "$(mpath "$HOOK")" < "$PAYLOAD_FILE") 2>"$errfile" )" || HK_RC=$?
    HK_ERR="$(cat "$errfile" 2>/dev/null || true)"
    local squashed="${HK_OUT//[[:space:]]/}"
    case "$squashed" in
        *'"decision":"block"'*)   HK_DECISION="block" ;;
        *'"decision":"approve"'*) HK_DECISION="approve" ;;
        *)                        HK_DECISION="none" ;;
    esac
}

# ============================================================================
# C6 — the obsolete names are inert
#
# COMMENT_BLOCK_WARN=off used to silence a warning. Honouring it now would let a
# stale .env line switch a BLOCK off, which is the fail-open direction and the
# reason no backward-compatible dual read was written (detail plan S4-2).
# ============================================================================
c6_obsolete_names_are_inert() {
    local f
    f="$( { echo "var x = 1;"; cmt 12 c; } | wfile "c6.js" )"
    mkpayload Write "$REPO_M" "$f" "content=@$REPO/c6.js"
    hk_run "COMMENT_BLOCK_WARN=off"
    assert_decision "C6/obsolete-killswitch-does-not-disable" "block"
    hk_run "COMMENT_BLOCK_WARN_LINES=999999"
    assert_decision "C6/obsolete-threshold-does-not-lift" "block"

    # ...and it does not raise a floor either: with only the obsolete threshold
    # name set to something small, a 10-line run is still allowed by the real
    # default. An implementation that reads the old name would block here.
    f="$( { echo "var x = 1;"; cmt 10 c; } | wfile "c6b.js" )"
    mkpayload Write "$REPO_M" "$f" "content=@$REPO/c6b.js"
    hk_run "COMMENT_BLOCK_WARN_LINES=3"
    assert_decision "C6/obsolete-threshold-does-not-lower" "approve"
}

# ============================================================================
# C7 — a missing config dir is not a bypass
#
# If .env cannot be read, the built-in defaults apply. Failing OPEN on config
# resolution would mean deleting one file disables the gate.
# ============================================================================
c7_missing_env_uses_defaults() {
    local f
    f="$( { echo "var x = 1;"; cmt 12 c; } | wfile "c7.js" )"
    mkpayload Write "$REPO_M" "$f" "content=@$REPO/c7.js"
    _hk_env 0
    rm -f "$CFG_DIR/.env"
    _hk_exec
    assert_decision "C7/no-env-file-still-blocks" "block"

    _hk_env 0
    HK_ENVS+=("AGENTS_CONFIG_DIR=$(mpath "$TMPDIR_BASE/no-such-config-dir")")
    _hk_exec
    assert_decision "C7/missing-config-dir-still-blocks" "block"
    assert_clean_exit "C7/hook-exits-0"

    # Paired negative so the two rows above are not just "always blocks".
    f="$( { echo "var x = 1;"; cmt 10 c; } | wfile "c7b.js" )"
    mkpayload Write "$REPO_M" "$f" "content=@$REPO/c7b.js"
    _hk_env 0
    rm -f "$CFG_DIR/.env"
    _hk_exec
    assert_decision "C7/defaults-still-allow-10" "approve"
}

c1_extension_filter
c2_excluded_path_segments
c3_threshold_from_dotenv
c4_kill_switch
c5_ambient_env_is_ignored
c6_obsolete_names_are_inert
c7_missing_env_uses_defaults
