# tests/fix-2025-safe-plans-path/publish.sh
# Tests: bin/lib/safe-plans-path.sh
# Tags: safe-plans-path, atomic-publish, symlink, table-driven, security, scope:issue-specific, pwsh-not-required
# Sourced by tests/fix-2025-safe-plans-path.sh.

echo ""
echo "--- sp 5: publishing beside the destination ---"

# The temp file is created in the destination's own directory so the rename is
# atomic, and created private: a world-readable temp in a shared plans dir
# exposes a ledger to any local reader for the length of the write.
{
    P="$TMPDIR_BASE/publish"
    mkdir -p "$P"
    # sp_mktemp_beside takes the destination *file* path and creates the temp in
    # that file's own directory, so the argument is a name inside $P, not $P.
    TMPF="$(sp sp_mktemp_beside "$P/dest.txt" 2>/dev/null)"
    assert_eq "5: the temp file is created inside the destination's own directory" \
        "beside" \
        "$(case "${TMPF:-}" in "$P"/*) printf beside ;; '') printf none ;; *) printf 'elsewhere:%s' "$TMPF" ;; esac)"
    if [ "$MODES_OK" = "yes" ]; then
        assert_eq_nz "5: and it is created private to its owner (0600)" \
            "600" "$([ -n "${TMPF:-}" ] && [ -f "$TMPF" ] \
                && { stat -c '%a' "$TMPF" 2>/dev/null || stat -f '%Lp' "$TMPF" 2>/dev/null; } \
                || printf 'no-temp')"
    else
        echo "SKIP: 5: and it is created private to its owner (0600) (this host does not honour POSIX modes)"
    fi
    assert_eq "5: asking for a temp beside a directory that does not exist fails closed" \
        "rejected" "$(verdict sp_mktemp_beside "$P/absent-subdir/dest.txt")"
}

# A plans dir the process may read but not write is the ordinary shape of a
# permission failure in production — a dir owned by another user, or one a
# container mounted read-only. Publication has to refuse it and leave nothing,
# rather than half-creating a temp that a later reader takes for an artifact.
# Probed by attempting a write, never inferred from chmod's exit status.
{
    RO="$TMPDIR_BASE/publish-readonly"
    mkdir -p "$RO"
    chmod 0555 "$RO" 2>/dev/null || true
    RO_ENFORCED=no
    : > "$RO/.write-probe" 2>/dev/null || RO_ENFORCED=yes

    if [ "$RO_ENFORCED" = "yes" ]; then
        assert_eq "5: publishing into a directory the process cannot write is refused" \
            "rejected" "$(printf 'x\n' | sp sp_publish_stdin "$RO/dest.txt" >/dev/null 2>&1 \
                && printf accepted || printf rejected)"
        assert_eq "5: with no destination created and no temp left behind" \
            "dest=absent temps=0" \
            "dest=$([ -e "$RO/dest.txt" ] && printf present || printf absent) temps=$(find "$RO" -maxdepth 1 -name '.sp-tmp.*' 2>/dev/null | wc -l | tr -d ' ')"
    else
        # SKIPPED: this host lets the process write to a 0555 directory (the
        # write probe above succeeded), so the condition can't be created.
        # L3 gap: a POSIX CI host runs it; the absent-directory case above
        # covers the same fail-closed shape without needing modes.
        echo "NOTE: 5: SKIPPED — this host does not enforce read-only directories"
    fi
    chmod 0755 "$RO" 2>/dev/null || true
    rm -f "$RO/.write-probe" 2>/dev/null || true
}

# lands <dest> → the destination's content when it is a plain file, else a
# named state, so "a directory is standing here" cannot read as empty content.
lands() {
    if [ -h "$1" ]; then printf 'symlink'
    elif [ -d "$1" ]; then printf 'directory'
    elif [ -f "$1" ]; then cat "$1"
    else printf 'absent'
    fi
}

{
    # The normal path first, so the attack cases below are not vacuously true.
    P2="$TMPDIR_BASE/publish-ok"
    mkdir -p "$P2"
    assert_eq "5: sp_publish_stdin writes the bytes it was given" \
        "accepted" "$(printf 'hello\n' | sp sp_publish_stdin "$P2/a.txt" >/dev/null 2>&1 \
            && printf accepted || printf rejected)"
    assert_eq_nz "5: and the destination holds exactly those bytes" \
        "hello" "$(lands "$P2/a.txt")"

    SRC="$TMPDIR_BASE/src.txt"
    printf 'copied\n' > "$SRC"
    assert_eq "5: sp_publish_copy publishes an existing file" \
        "accepted" "$(verdict sp_publish_copy "$SRC" "$P2/b.txt")"
    assert_eq_nz "5: leaving the destination holding the source's bytes" \
        "copied" "$(lands "$P2/b.txt")"
    assert_eq_nz "5: and no temp file is left behind in the directory" \
        "0" "$(find "$P2" -maxdepth 1 -name '.sp-tmp.*' 2>/dev/null | wc -l | tr -d ' ')"

    # Republishing over a destination that already holds a regular file. This is
    # the ordinary case in production — a ledger is rewritten every round — and
    # a publish that refused it, or left the old bytes beside the new ones under
    # a second name, would be found only there.
    printf 'second\n' | sp sp_publish_stdin "$P2/a.txt" >/dev/null 2>&1
    assert_eq_nz "5: republishing over an existing file replaces its bytes exactly" \
        "second" "$(lands "$P2/a.txt")"
    printf 'recopied\n' > "$SRC"
    assert_eq "5: and the copy form replaces them too" \
        "accepted" "$(verdict sp_publish_copy "$SRC" "$P2/b.txt")"
    assert_eq_nz "5: leaving the destination on the source's new bytes" \
        "recopied" "$(lands "$P2/b.txt")"
    assert_eq_nz "5: with one file per destination name and no temp residue" \
        "2" "$(find "$P2" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"

    # Empty input is a legitimate publication, not a no-op: a round that
    # produced nothing still has to leave an empty artifact where the reader
    # looks, rather than the previous round's file.
    assert_eq "5: publishing empty input succeeds" \
        "accepted" "$(printf '' | sp sp_publish_stdin "$P2/empty.txt" >/dev/null 2>&1 \
            && printf accepted || printf rejected)"
    assert_eq_nz "5: creating a zero-byte regular file at the destination" \
        "file 0" \
        "$([ -f "$P2/empty.txt" ] && [ ! -h "$P2/empty.txt" ] && printf 'file ' || printf 'other ')$(wc -c < "$P2/empty.txt" 2>/dev/null | tr -d ' ')"
}

{
    # Error cases for the copy forms. A source that is not there must fail with
    # a status the caller can act on, leave the destination as it found it, and
    # leave no temp file behind holding a partial write.
    E="$TMPDIR_BASE/publish-err"
    mkdir -p "$E"
    printf 'original\n' > "$E/dest.txt"
    assert_eq "5: publishing from a source that does not exist fails" \
        "rejected" "$(verdict sp_publish_copy "$TMPDIR_BASE/no-such-source.txt" "$E/dest.txt")"
    assert_eq_nz "5: leaving the destination exactly as it was" \
        "original" "$(lands "$E/dest.txt")"
    assert_eq_nz "5: and no temp file holding a partial write" \
        "1" "$(find "$E" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"

    # Permission-denied is the sibling error and is deliberately not asserted:
    # under Git Bash on Windows a chmod 000 directory stays writable, so the
    # case would pass vacuously on the host this suite runs on. Named here so
    # the gap is a decision rather than an omission — TL3 gap, above.
}

{
    # Attack 1: a symlink pre-placed at the destination name. Publishing must
    # not follow it — the bytes would land wherever the attacker pointed.
    P3="$TMPDIR_BASE/publish-symlink"
    mkdir -p "$P3"
    OUTSIDE="$TMPDIR_BASE/publish-symlink-target.txt"
    printf 'untouched\n' > "$OUTSIDE"
    ln -s "$OUTSIDE" "$P3/dest.txt" 2>/dev/null || true

    printf 'payload\n' | sp sp_publish_stdin "$P3/dest.txt" >/dev/null 2>&1
    if [ "$SYMLINKS_OK" = "yes" ]; then
        assert_eq_nz "5: a pre-placed symlink does not carry the write to its target" \
            "untouched" "$(cat "$OUTSIDE")"
        assert_eq "5: and the destination name no longer points out of the directory" \
            "not-symlink" "$([ -h "$P3/dest.txt" ] && printf 'still-symlink' || printf 'not-symlink')"
    else
        echo "SKIP: 5: the pre-placed-symlink publish attack (no symlinks here)"
    fi
}

{
    # Attack 2: a directory pre-placed at the destination name. `mv` into it
    # moves the temp file *inside* the directory under its own temp name, so
    # the publish reports success while the destination nobody reads is a
    # directory still.
    P4="$TMPDIR_BASE/publish-dir"
    mkdir -p "$P4/dest.txt"
    BEFORE="$(find "$P4" | LC_ALL=C sort)"
    RC4="$(verdict sp_publish_stdin "$P4/dest.txt" </dev/null)"
    AFTER="$(find "$P4" | LC_ALL=C sort)"

    assert_eq "5: a directory standing at the destination name is refused" "rejected" "$RC4"
    assert_eq_nz "5: and the refusal leaves the tree exactly as it found it" \
        "$BEFORE" "$AFTER"
}

# Every publishing form meets both pre-placed attacks, not just the stdin one:
# a defence that lived in one of them is exactly the CPR-ORTH gap this library
# exists to close. attack_forms <label> runs one form against a fresh symlink
# and a fresh directory decoy and reports what the outside target holds.
publish_form() {
    case "$1" in
        stdin)          printf 'payload\n' | sp sp_publish_stdin "$2" ;;
        copy)           sp sp_publish_copy "$ATK_SRC" "$2" ;;
        contained_stdin) printf 'payload\n' | sp sp_contained_publish_stdin "$2" "$(dirname "$2")" ;;
        contained_copy) sp sp_contained_publish_copy "$ATK_SRC" "$2" "$(dirname "$2")" ;;
    esac
}

ATK_SRC="$TMPDIR_BASE/attack-src.txt"
printf 'payload\n' > "$ATK_SRC"

for FORM in stdin copy contained_stdin contained_copy; do
    A="$TMPDIR_BASE/attack-$FORM"
    mkdir -p "$A"
    A_OUT="$TMPDIR_BASE/attack-$FORM-target.txt"
    printf 'untouched\n' > "$A_OUT"
    ln -s "$A_OUT" "$A/dest.txt" 2>/dev/null || true
    publish_form "$FORM" "$A/dest.txt" >/dev/null 2>&1
    if [ "$SYMLINKS_OK" = "yes" ]; then
        assert_eq_nz "5: $FORM does not carry the write through a pre-placed symlink" \
            "untouched" "$(cat "$A_OUT")"
        assert_eq "5: $FORM leaves a regular file holding the payload, not a link" \
            "payload" "$(lands "$A/dest.txt")"
    else
        echo "SKIP: 5: $FORM against a pre-placed symlink (no symlinks here)"
    fi

    # The directory decoy needs no symlink support, so it runs on every host.
    D="$TMPDIR_BASE/attack-dir-$FORM"
    mkdir -p "$D/dest.txt"
    D_BEFORE="$(find "$D" | LC_ALL=C sort)"
    D_RC="$(publish_form "$FORM" "$D/dest.txt" >/dev/null 2>&1 && printf accepted || printf rejected)"
    assert_eq "5: $FORM refuses a directory standing at the destination name" \
        "rejected" "$D_RC"
    assert_eq_nz "5: $FORM leaves that tree exactly as it found it" \
        "$D_BEFORE" "$(find "$D" | LC_ALL=C sort)"
done
