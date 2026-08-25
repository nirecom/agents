#!/usr/bin/env bash
# tests/fix-2025-discovery-failure-failclosed/real-and-scope.sh
# Tests: bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/finalize.sh, bin/concern-ledger
# Tags: concern-ledger, discovery, fail-closed, permission-denied, call-site-census, atomic-publish, security, scope:issue-specific, pwsh-not-required

# Sourced by tests/fix-2025-discovery-failure-failclosed.sh (shares its counters
# and fixtures); split out per rules/coding/file-split.md.

echo ""
echo "--- discovery 6: the same failure, produced by the OS rather than by a stub ---"

# Cases 2-4 inject through a `find` on PATH. That models the failure but does not
# prove the model: what the helper meets in production is an OS refusal. A
# directory with no read bit is exactly that — the entry can still be opened by
# exact name, so it separates "cannot list" from "is not there", which is the
# distinction the helper collapses.

# lp <pattern> → "rc=<n> n=<matches>", one library call in its own subshell.
lp() {
    local rc=0 out
    out="$( set +u; . "$AGENTS_ROOT/bin/lib/concern-ledger.sh" >/dev/null 2>&1 || exit 127
            _cl_list_pattern_files "$1" )" || rc=$?
    printf 'rc=%s n=%s' "$rc" "$(printf '%s' "$out" | tr '\0' '\n' | grep -c . | tr -d ' ')"
}

# Probed, never assumed: chmod reports success on NTFS and changes nothing, so
# on such a host the case below would assert a falsehood rather than a contract.
PERMS_OK=no
PROBE="$TMPDIR_BASE/perm-probe"
mkdir -p "$PROBE"
: > "$PROBE/p-1.txt"
chmod 0111 "$PROBE" 2>/dev/null || true
find -- "$PROBE/" -maxdepth 1 -mindepth 1 -name 'p-*.txt' -print0 >/dev/null 2>&1 \
    || PERMS_OK=yes
chmod 0755 "$PROBE" 2>/dev/null || true

if [ "$PERMS_OK" = "yes" ]; then
    UNREAD="$TMPDIR_BASE/unreadable"
    mkdir -p "$UNREAD"
    : > "$UNREAD/$SID-$FMT-round-2-delta-review-code-codex.txt"
    REAL_ANSWER="$(chmod 0111 "$UNREAD" 2>/dev/null; lp "$UNREAD/$SID-$FMT-round-2-delta-*.txt")"
    chmod 0755 "$UNREAD" 2>/dev/null || true

    READABLE="$TMPDIR_BASE/readable-empty"
    mkdir -p "$READABLE"
    STUB_ANSWER="$(PATH="$STUB:$PATH" lp "$UNREAD/$SID-$FMT-round-2-delta-*.txt")"

    assert_eq_nz "6: a directory that cannot be listed yields no entries" \
        "n=0" "n=$(printf '%s' "$REAL_ANSWER" | sed 's/.*n=//')"
    assert_eq_nz "6: the PATH stub reproduces the OS failure exactly, so cases 2-4 are faithful" \
        "$REAL_ANSWER" "$STUB_ANSWER"
    assert_eq "6: and an OS refusal to list is reported, not returned as success" \
        "refused" \
        "$([ "$(printf '%s' "$REAL_ANSWER" | sed 's/rc=\([0-9]*\).*/\1/')" -ne 0 ] \
            && printf refused || printf accepted)"
    assert_eq "6: so that it is distinguishable from a directory that really is empty" \
        "distinct" \
        "$([ "$REAL_ANSWER" = "$(lp "$READABLE/$SID-$FMT-round-2-delta-*.txt")" ] \
            && printf identical || printf distinct)"
else
    # SKIPPED: the OS-produced discovery failure (case 6).
    # Because: this host does not enforce POSIX directory modes — chmod 0111
    #   succeeds and `find` still lists the directory, so the fixture cannot
    #   create the condition and the assertion would pass vacuously.
    # L3 gap: a POSIX CI host runs it; the PATH-stub route in cases 2-4 covers
    #   the same caller verdicts here, and case 5 pins that the stub shadows the
    #   mechanism the helper actually invokes.
    echo "NOTE: 6: SKIPPED — this host does not enforce POSIX directory modes"
fi

echo ""
echo "--- discovery 7: a failed round leaves no half-written artifact behind ---"

# The third fail-closed attribute, and the one that already holds: whatever the
# callers decide about a round they could not read, neither may leave a partial
# file where a reader could mistake it for a finished one. Publication goes
# through sp_publish_*, whose temp files are named .sp-tmp.* beside the
# destination, so a remnant is both detectable and unambiguous.

# leftovers <dir> — publication temporaries still present.
leftovers() {
    find -- "$1" -maxdepth 1 -mindepth 1 -name '.sp-tmp.*' 2>/dev/null | wc -l | tr -d ' '
}

{
    P7="$(mk_round fail-leftovers)"
    PATH="$STUB:$PATH" bash "$CLI" reduce --plans-dir "$P7" --session-id "$SID" \
        --format "$FMT" --round 2 >/dev/null 2>&1
    assert_eq_nz "7: a reduction with discovery broken leaves no publication temporary" \
        "0" "$(leftovers "$P7")"

    PATH="$STUB:$PATH" bash "$CLI" finalize --plans-dir "$P7" --session-id "$SID" \
        --format "$FMT" --round 2 --cap 2 --mode terminal --reason 'leftover check' \
        >/dev/null 2>&1
    assert_eq_nz "7: nor does a finalize that could not build its producer list" \
        "0" "$(leftovers "$P7")"

    # The detector has to be able to see one, or the two rows above are vacuous.
    : > "$P7/.sp-tmp.detectorcheck"
    assert_eq_nz "7: and a remnant would have been seen if there were one" \
        "1" "$(leftovers "$P7")"
    rm -f "$P7/.sp-tmp.detectorcheck"
}

echo ""
echo "--- discovery 8: three callers is the whole class, not a sample of it ---"

# Cases 2-4 assert one surface each. That is only a complete argument if there
# are exactly three surfaces: a fourth caller added later would inherit the same
# swallowed status and nothing here would say so (CPR-E2C). Pinned as a census
# of the call sites rather than a count, so a move is reported as a move.

{
    CALLERS="$(cd "$AGENTS_ROOT" && grep -rln '_cl_list_pattern_files' bin/ \
        | grep -v 'bin/lib/concern-ledger/core.sh' | LC_ALL=C sort | tr '\n' ' ')"
    assert_eq_nz "8: the callers of the shared helper are exactly the three surfaces covered above" \
        "bin/concern-ledger bin/lib/concern-ledger/finalize.sh bin/lib/concern-ledger/reduce.sh " \
        "$CALLERS"

    # And no sibling reaches around the helper to call find itself, which would
    # be a fourth surface the helper's fix could not reach. Matched as "find
    # invoked with a path-shaped first operand" rather than the old 'find -- '
    # literal: the option terminator was dropped because BSD/macOS find takes
    # it as a path operand, and a probe pinned to it would report zero call
    # sites — vacuously passing for whatever a sibling did next. The leading
    # `[^#]*` keeps the modules' prose about find out of the census.
    DIRECT="$(cd "$AGENTS_ROOT" && grep -rlnE '^[^#]*(^|[^[:alnum:]_-])find[[:space:]]+["$./-]' \
        bin/lib/concern-ledger/ bin/concern-ledger | LC_ALL=C sort | tr '\n' ' ')"
    assert_eq_nz "8: and nothing reaches around the helper to run find itself" \
        "bin/lib/concern-ledger/core.sh " "$DIRECT"
}
