# tests/fix-2025-safe-plans-path/contained-ops.sh
# Tests: bin/lib/safe-plans-path.sh
# Tags: safe-plans-path, containment, symlink, security, scope:issue-specific, pwsh-not-required
# Sourced by tests/fix-2025-safe-plans-path.sh.

echo ""
echo "--- sp 6: sp_contained_* — refusal and failure are different answers ---"

# rc 0 published, rc 2 the destination was not inside the directory so nothing
# was created anywhere, rc 1 the destination was inside but the write failed. A
# caller that cannot tell 2 from 1 either retries a security refusal or reports
# one as a disk error.
cp_rc() {
    sp "$@" >/dev/null 2>&1
    printf '%s' "$?"
}

{
    C="$TMPDIR_BASE/contained"
    mkdir -p "$C/plans"
    assert_eq_nz "6: an ordinary name inside the directory publishes with rc 0" \
        "0" "$(printf 'x\n' | cp_rc sp_contained_publish_stdin "$C/plans/ok.txt" "$C/plans")"
    assert_eq_nz "6: leaving the bytes at the name the caller asked for" \
        "x" "$(lands "$C/plans/ok.txt")"

    assert_eq_nz "6: a name that walks out of the directory is refused with rc 2" \
        "2" "$(printf 'x\n' | cp_rc sp_contained_publish_stdin "$C/plans/../escaped.txt" "$C/plans")"
    assert_eq "6: and rc 2 means nothing was created, inside or outside" \
        "absent absent" "$(lands "$C/escaped.txt") $(lands "$C/plans/escaped.txt")"

    assert_eq_nz "6: a separator-bearing name is refused the same way" \
        "2" "$(printf 'x\n' | cp_rc sp_contained_publish_stdin "$C/plans/sub/nested.txt" "$C/plans")"

    # rc 1: contained, but the write cannot succeed — here because a directory
    # already stands at the name.
    mkdir -p "$C/plans/blocked.txt"
    assert_eq_nz "6: a contained destination that cannot be written is rc 1, not rc 2" \
        "1" "$(printf 'x\n' | cp_rc sp_contained_publish_stdin "$C/plans/blocked.txt" "$C/plans")"

    SRC6="$TMPDIR_BASE/src6.txt"
    printf 'from-copy\n' > "$SRC6"
    assert_eq_nz "6: the copy form takes the same three answers" \
        "0" "$(cp_rc sp_contained_publish_copy "$SRC6" "$C/plans/copied.txt" "$C/plans")"
    assert_eq_nz "6: publishing the copy's bytes" "from-copy" "$(lands "$C/plans/copied.txt")"
    assert_eq_nz "6: and refusing an escaping name with rc 2 on that form too" \
        "2" "$(cp_rc sp_contained_publish_copy "$SRC6" "$C/plans/../escaped2.txt" "$C/plans")"

    # The third answer (rc 1: contained, but the write cannot succeed) for the
    # copy form too — same blocked.txt directory as the stdin case above.
    assert_eq_nz "6: a contained destination that cannot be written is rc 1 on the copy form too" \
        "1" "$(cp_rc sp_contained_publish_copy "$SRC6" "$C/plans/blocked.txt" "$C/plans")"
}

{
    # Deletion is the same containment question in the opposite direction: a
    # symlinked name inside the directory must not delete what it points at.
    R="$TMPDIR_BASE/contained-rm"
    mkdir -p "$R/plans" "$R/outside"
    printf 'keep\n' > "$R/outside/precious.txt"
    printf 'go\n' > "$R/plans/removable.txt"
    ln -s "$R/outside/precious.txt" "$R/plans/link.txt" 2>/dev/null || true

    assert_eq_nz "6: an ordinary file inside the directory is removed" \
        "0" "$(cp_rc sp_contained_rm "$R/plans/removable.txt" "$R/plans")"
    assert_eq "6: and is gone afterwards" "absent" "$(lands "$R/plans/removable.txt")"

    # Removing an already-absent name is the ordinary re-entry case: cleanup runs
    # after a publish that may never have happened, so a second removal has to be
    # the same harmless success as the first.
    assert_eq_nz "6: removing a name that is already gone is the same success" \
        "0" "$(cp_rc sp_contained_rm "$R/plans/removable.txt" "$R/plans")"
    assert_eq "6: and still leaves nothing at that name" \
        "absent" "$(lands "$R/plans/removable.txt")"

    RM_LINK_RC="$(cp_rc sp_contained_rm "$R/plans/link.txt" "$R/plans")"
    if [ "$SYMLINKS_OK" = "yes" ]; then
        assert_eq_nz "6: removing a symlinked name never reaches the file it points at" \
            "keep" "$(cat "$R/outside/precious.txt" 2>/dev/null)"
        # The link is inside the directory, so removing it is the contained,
        # documented outcome — the refusal belongs to the target, not the name.
        assert_eq_nz "6: the link itself is unlinked, and says so with rc 0" \
            "rc=0 absent" "rc=$RM_LINK_RC $(lands "$R/plans/link.txt")"
    else
        echo "SKIP: 6: removing a symlinked name never reaches its target (no symlinks here)"
    fi
    # sp_contained_rm has only two answers (0/1), unlike the publish forms'
    # three: it collapses "not contained" and "judgment failed" into the same
    # refusal, because deleting is the irreversible half.
    assert_eq_nz "6: an escaping name is refused with rc 1 rather than deleting anything" \
        "1" "$(cp_rc sp_contained_rm "$R/plans/../outside/precious.txt" "$R/plans")"
    assert_eq_nz "6: and the file it named is still there" \
        "keep" "$(cat "$R/outside/precious.txt" 2>/dev/null)"
}

{
    # Single resolution. Behaviourally this needs a writer racing the check,
    # which the threat model puts out of scope; pinned as source shape instead,
    # so a rewrite that re-resolves the directory after the gate is caught.
    assert_eq_nz "6: containment pins the directory once and works inside it" \
        "1" "$([ -f "$SPLIB" ] && grep -c -F 'cd -P -- "$1" && pwd -P' "$SPLIB" | tr -d ' ' || printf 0)"
    assert_eq_nz "6: and the removal operates on a bare basename, never a rebuilt path" \
        "1" "$([ -f "$SPLIB" ] && grep -c -F 'rm -f -- "$base"' "$SPLIB" | tr -d ' ' || printf 0)"
}
