# tests/fix-2025-safe-plans-path/containment.sh
# Tests: bin/lib/safe-plans-path.sh
# Tags: safe-plans-path, path-traversal, containment, symlink, security, scope:issue-specific, pwsh-not-required
# Sourced by tests/fix-2025-safe-plans-path.sh.

echo ""
echo "--- sp 4: sp_within_dir — containment after resolution ---"

{
    W="$TMPDIR_BASE/within"
    mkdir -p "$W/plans/sub" "$W/outside"
    : > "$W/plans/inside.txt"
    : > "$W/outside/target.txt"
    ln -s "$W/outside" "$W/plans/escape" 2>/dev/null || true

    assert_eq "4: a file directly in the directory is inside it" \
        "accepted" "$(verdict sp_within_dir "$W/plans/inside.txt" "$W/plans")"
    assert_eq "4: so is a file in a subdirectory of it" \
        "accepted" "$(verdict sp_within_dir "$W/plans/sub/x.txt" "$W/plans")"
    assert_eq "4: a sibling directory is not inside it" \
        "rejected" "$(verdict sp_within_dir "$W/outside/target.txt" "$W/plans")"
    assert_eq "4: a lexical parent reference does not get there either" \
        "rejected" "$(verdict sp_within_dir "$W/plans/../outside/target.txt" "$W/plans")"
    if [ "$SYMLINKS_OK" = "yes" ]; then
        assert_eq "4: a symlinked subdirectory pointing out is not inside it" \
            "rejected" "$(verdict sp_within_dir "$W/plans/escape/target.txt" "$W/plans")"
    else
        echo "SKIP: 4: a symlinked subdirectory pointing out is not inside it (no symlinks here)"
    fi

    # The prefix trap: a sibling whose name starts with the directory's name.
    mkdir -p "$W/plans-evil"
    : > "$W/plans-evil/x.txt"
    assert_eq "4: a sibling that merely shares the name prefix is not inside it" \
        "rejected" "$(verdict sp_within_dir "$W/plans-evil/x.txt" "$W/plans")"
}

echo ""
echo "--- sp 4b: the caller that owns a destructive step — finalize --ledger ---"

# 4b. The containment above only matters where something irreversible hangs off
#     it. `finalize --mode escalate` snapshots the ledger and then deletes it,
#     and --ledger names that file with no address validation of its own, so an
#     out-of-bounds override is a delete outside the plans dir (#2025 C3/C6/C8).
#     Both verdicts of the classifier are asserted: refused outside, performed
#     inside — a permission test that only ever sees "no" also passes when the
#     feature is gone.

# fin <plans> <ledger> <mode> <sid> — the real CLI, one finalize. Echoes its rc.
fin() {
    local rc=0
    bash "$AGENTS_ROOT/bin/concern-ledger" finalize --plans-dir "$1" \
        --ledger "$2" --session-id "$4" --format review-security-shared \
        --mode "$3" --reason 'cap reached' --round 2 --cap 2 \
        >/dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
}

# mk_led <path> — a two-entry ledger, so "still there" is a byte count and not
# just an existence check.
mk_led() {
    {
        printf '#concern-ledger-v2|review-security-shared|sid4b|cycle=1\n'
        printf 'C1|HIGH|open|1|1|bin/x#fn:security|d15c11|review-code-codex|review-code-codex|-|first concern\n'
        printf 'C2|LOW|open|1|1|bin/y#fn:security|d15c12|review-code-codex|review-code-codex|-|second concern\n'
    } > "$1"
}

# state <ledger> — what happened to the override, as one string: whether the
# ledger survived, its size, and whether a snapshot was created beside it.
state() {
    local snap="${1%.txt}-cap-snapshot.txt"
    printf 'ledger=%s bytes=%s snapshot=%s' \
        "$([ -f "$1" ] && printf kept || printf deleted)" \
        "$([ -f "$1" ] && wc -c < "$1" | tr -d ' ' || printf 0)" \
        "$([ -e "$snap" ] && printf created || printf none)"
}

{
    F="$TMPDIR_BASE/finalize"
    mkdir -p "$F/plans" "$F/outside"

    # Direction 1 — an override plainly outside the plans dir.
    OUT_LED="$F/outside/external-concern-ledger.txt"
    mk_led "$OUT_LED"
    BYTES="$(wc -c < "$OUT_LED" | tr -d ' ')"
    RC_ESC="$(fin "$F/plans" "$OUT_LED" escalate sid4bA)"
    assert_eq "4b: an out-of-plans --ledger is neither snapshotted nor deleted" \
        "ledger=kept bytes=$BYTES snapshot=none" "$(state "$OUT_LED")"
    assert_eq "4b: and finalize still produced its artifact, so this is a refusal not a crash" \
        "rc=0 artifact=1" \
        "rc=$RC_ESC artifact=$(find "$F/plans" -name 'sid4bA-*-unresolved-concerns.json' | wc -l | tr -d ' ')"

    # Direction 2 — the same override under the non-destructive mode. terminal
    # never snapshots or deletes, so it must leave the file alone for a second
    # reason; asserting it separately keeps mode and containment from being
    # confused for one another (CPR-SC).
    mk_led "$OUT_LED"
    fin "$F/plans" "$OUT_LED" terminal sid4bB >/dev/null
    assert_eq "4b: --mode terminal leaves an out-of-plans --ledger untouched too" \
        "ledger=kept bytes=$BYTES snapshot=none" "$(state "$OUT_LED")"

    # Direction 3 — a symlinked parent that resolves outside. Lexically the
    # path sits under the plans dir; only physical resolution catches it.
    if [ "$SYMLINKS_OK" = "yes" ]; then
        ln -s "$F/outside" "$F/plans/link" 2>/dev/null || true
        LINK_LED="$F/plans/link/external-concern-ledger.txt"
        mk_led "$OUT_LED"
        fin "$F/plans" "$LINK_LED" escalate sid4bC >/dev/null
        assert_eq "4b: a --ledger reached through a symlinked parent is refused as well" \
            "ledger=kept bytes=$BYTES snapshot=none" "$(state "$OUT_LED")"
    else
        echo "SKIP: 4b: a --ledger reached through a symlinked parent is refused as well (no symlinks here)"
    fi

    # Direction 4 — the sanctioned case. The same command over a ledger that is
    # really inside the plans dir must snapshot it and then delete it.
    IN_LED="$F/plans/sid4bD-review-security-shared-concern-ledger.txt"
    mk_led "$IN_LED"
    RC_IN="$(fin "$F/plans" "$IN_LED" escalate sid4bD)"
    assert_eq "4b: an in-plans --ledger is snapshotted and then deleted" \
        "rc=0 ledger=deleted bytes=0 snapshot=created" \
        "rc=$RC_IN $(state "$IN_LED")"
    assert_eq_nz "4b: and the snapshot carries the entries the ledger held" \
        "2" "$(grep -c '^C[0-9]' "$F/plans/sid4bD-review-security-shared-concern-ledger-cap-snapshot.txt" 2>/dev/null | tr -d ' ')"
}
