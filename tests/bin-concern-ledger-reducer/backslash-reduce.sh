# tests/bin-concern-ledger-reducer/backslash-reduce.sh
# Tests: bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/finalize.sh, bin/lib/concern-ledger.sh, bin/lib/concern-ledger/core.sh
# Tags: concern-ledger, reducer, backslash, plans-dir, finalize, regression, scope:common, pwsh-not-required
# Sourced by tests/bin-concern-ledger-reducer.sh.

# #2088: a backslash-spelled plans dir made staged deltas invisible, so the
# reducer wrote a header-only ledger and the loop exited 4 claiming nothing
# was found. Every case runs twice — backslash-spelled dir vs ordinary
# spelling — asserting the two agree ("spelling does not matter").

echo ""
echo "--- reducer br-1: a round reduces through a backslash-spelled plans dir ---"

BFMT="backslash-fmt"

# br_dir <base> — a directory reachable through a path holding a backslash. On
# Windows that is cygpath -w of a real directory (the defect's own shape);
# elsewhere a backslash is a legal filename character, so one goes in the name.
br_dir() {
    local base="$1" d
    if command -v cygpath >/dev/null 2>&1; then
        d="$base/plansdir"
        mkdir -p "$d"
        cygpath -w "$d"
    else
        d="$base/plans\\evil"
        mkdir -p "$d"
        printf '%s' "$d"
    fi
}

# br_stage <plans> <sid> <round> <producer> <text> — put one COMPLETE delta into
# <plans>, named exactly the way the plans dir names it, so the same fixture
# serves both the reducer's discovery and finalize's producer scan.
br_stage() {
    local plans="$1" sid="$2" round="$3" prod="$4" text="$5" raw norm
    raw="$(mktemp "$TMPDIR_BASE/br-raw-XXXXXX")"
    norm="$(mktemp "$TMPDIR_BASE/br-norm-XXXXXX")"
    mk_delta_report "$raw" "$(anchored HIGH - bin/x.sh fn correctness "$text")"
    cl cl_parse_anchored "$raw" "$prod" "$norm" >/dev/null 2>&1
    export CL_STAGE_PREFIX="$sid-"
    cl cl_stage "$plans" "$BFMT" "$round" "$prod" PERFORMED COMPLETE "$norm" >/dev/null 2>&1
    unset CL_STAGE_PREFIX
}

# br_reduce <plans> <sid> <round> → "rc=<n> ids=<C1,...> count=<n>"
br_reduce() {
    local plans="$1" sid="$2" round="$3" inl outl rc
    inl="$(mktemp "$TMPDIR_BASE/br-in-XXXXXX")"
    outl="$(mktemp "$TMPDIR_BASE/br-out-XXXXXX")"
    mk_ledger "$inl" "$BFMT" "$sid" 1
    cl cl_reduce "$inl" "$plans/$sid-$BFMT-round-$round-delta-*.txt" "$round" "$BFMT" "$outl" \
        >/dev/null 2>&1
    rc=$?
    printf 'rc=%s ids=%s count=%s' "$rc" "$(entry_ids "$outl")" "$(entry_count "$outl")"
}

{
    BR_BS="$(br_dir "$TMPDIR_BASE/br-bs")"
    BR_OK="$TMPDIR_BASE/br-ok"
    mkdir -p "$BR_OK"

    assert_eq "br-1: the fixture really is a backslash-bearing path (precondition)" \
        "has-backslash" \
        "$(case "$BR_BS" in *\\*) printf has-backslash ;; *) printf 'no-backslash:%s' "$BR_BS" ;; esac)"

    br_stage "$BR_BS" bsid 1 review-code-codex "a concern staged under a backslash path"
    br_stage "$BR_OK" oksid 1 review-code-codex "a concern staged under a backslash path"

    BR_BS_OUT="$(br_reduce "$BR_BS" bsid 1)"
    BR_OK_OUT="$(br_reduce "$BR_OK" oksid 1)"

    # The ordinary spelling first, so a broken fixture shows as its own failure
    # rather than making the backslash comparison vacuously true.
    assert_eq_nz "br-1: the ordinary spelling folds the round's delta into the ledger" \
        "rc=0 ids=C1, count=1" "$BR_OK_OUT"
    assert_eq_nz "br-1: and the backslash spelling produces exactly the same ledger" \
        "$BR_OK_OUT" "$BR_BS_OUT"
    # Stated separately from the comparison: a regression that broke both
    # spellings identically would satisfy the equality above.
    assert_eq_nz "br-1: the backslash round is not the header-only ledger of #2088" \
        "rc=0 ids=C1, count=1" "$BR_BS_OUT"
}

echo ""
echo "--- reducer br-2: finalize's producer scan reads the same directory ---"

# The JSON spec lists the round's producers from its own scan of the plans dir
# (CPR-ORTH: the same class of discovery as the reducer's). A spec whose P rows
# are missing reports "no producer reviewed this round" to the loop's verdict.
br_spec_producers() {
    local plans="$1" sid="$2" round="$3" out
    out="$(mktemp "$TMPDIR_BASE/br-spec-XXXXXX")"
    cl _cl_json_spec "$plans" "$sid" "$BFMT" escalate cap-reached "$round" 3 1 0 "$out" \
        >/dev/null 2>&1
    grep -c '^P|review-code-codex|' "$out" 2>/dev/null | tr -d ' '
}

{
    assert_eq_nz "br-2: the ordinary spelling finds the round's producer" \
        "1" "$(br_spec_producers "$BR_OK" oksid 1)"
    assert_eq_nz "br-2: and so does the backslash spelling" \
        "1" "$(br_spec_producers "$BR_BS" bsid 1)"
}

{
    # Why finalize is spared #2088: its delta scan does not reach pathname
    # expansion at all. It goes through the same find-based helper the reducer
    # now uses (CPR-SSOT), which takes the directory component literally, so a
    # backslash in the plans dir is never read as a glob escape. Pinned rather
    # than left to a later editor reintroducing a bare glob.
    assert_eq_nz "br-2: finalize's delta scan goes through the find-based helper, which is what spares it #2088" \
        "1" "$(grep -c -F '_cl_list_pattern_files "$plans/$sid-$fmt-round-$round-delta-*.txt"' \
            "$AGENTS_ROOT/bin/lib/concern-ledger/finalize.sh" | tr -d ' ')"
}

echo ""
echo "--- reducer br-3: escalate over a ledger that is not there ---"

# Escalate snapshots the ledger and then deletes it. When there is no ledger at
# all there is nothing to snapshot and nothing to delete, and the caller must be
# told that in those words rather than being handed a silent success or a
# "could not publish the snapshot" that names a failure which never happened.
{
    BR_E="$TMPDIR_BASE/br-escalate"
    mkdir -p "$BR_E"
    BR_E_ERR="$TMPDIR_BASE/br-escalate-err.txt"
    cl cl_finalize "$BR_E" esid "$BFMT" escalate cap-reached 1 3 1 0 \
        >/dev/null 2>"$BR_E_ERR"
    BR_E_RC=$?
    BR_E_SNAP="$BR_E/esid-$BFMT-concern-ledger-cap-snapshot.txt"

    assert_eq "br-3: a missing ledger is not a finalize failure" "0" "$BR_E_RC"
    assert_contains "br-3: and the caller is told there was nothing to snapshot or delete" \
        "nothing to snapshot or delete" "$(cat "$BR_E_ERR" 2>/dev/null)"
    assert_not_contains "br-3: not that a snapshot could not be published" \
        "could not publish the cap snapshot" "$(cat "$BR_E_ERR" 2>/dev/null)"
    assert_eq "br-3: no empty snapshot file is left behind to be read as a record" \
        "absent" "$([ -e "$BR_E_SNAP" ] && printf present || printf absent)"
}

echo ""
echo "--- reducer br-4: two files claiming the same producer in one round ---"

# Discovery is now ordered, so a directory holding two deltas for one producer
# has a defined winner (the last in sorted order) instead of whatever the
# filesystem happened to return. The round must still complete: a duplicate is a
# reason to warn the operator, never a reason to lose the round.
{
    BR_D="$TMPDIR_BASE/br-dup"
    mkdir -p "$BR_D"
    br_stage "$BR_D" dsid 1 review-code-codex "the first staged text"
    BR_D_F1="$BR_D/dsid-$BFMT-round-1-delta-review-code-codex.txt"
    BR_D_F2="$BR_D/dsid-$BFMT-round-1-delta-review-code-codex-2.txt"
    cp "$BR_D_F1" "$BR_D_F2" 2>/dev/null || true
    # Distinguish the two so "last wins" is observable rather than assumed.
    if [ -f "$BR_D_F2" ]; then
        sed -i.bak 's/the first staged text/the second staged text/' "$BR_D_F2" 2>/dev/null || true
        rm -f "$BR_D_F2.bak"
    fi
    # Which of the two is "last" is byte order, not the caller's locale and not
    # the order they were created in: '-' (0x2D) sorts ahead of '.' (0x2E), so
    # the '-2' name is actually the *earlier* one. The winner is derived here
    # rather than guessed, so the case pins the LC_ALL=C rule itself.
    BR_D_LAST="$(printf '%s\n%s\n' "$BR_D_F1" "$BR_D_F2" | LC_ALL=C sort | tail -n 1)"
    if [ "$BR_D_LAST" = "$BR_D_F2" ]; then
        BR_D_WANT="the second staged text"
    else
        BR_D_WANT="the first staged text"
    fi

    BR_D_IN="$TMPDIR_BASE/br-dup-in.txt"
    BR_D_OUT="$TMPDIR_BASE/br-dup-out.txt"
    BR_D_ERR="$TMPDIR_BASE/br-dup-err.txt"
    mk_ledger "$BR_D_IN" "$BFMT" dsid 1
    cl cl_reduce "$BR_D_IN" "$BR_D/dsid-$BFMT-round-1-delta-*.txt" 1 "$BFMT" "$BR_D_OUT" \
        >/dev/null 2>"$BR_D_ERR"
    BR_D_RC=$?

    assert_eq "br-4: a duplicated producer does not fail the round" "0" "$BR_D_RC"
    assert_eq_nz "br-4: the producer is folded in once, not twice" \
        "1" "$(entry_count "$BR_D_OUT")"
    assert_contains "br-4: and the duplicate is reported to the operator by name" \
        "review-code-codex" "$(cat "$BR_D_ERR" 2>/dev/null)"
    assert_eq_nz "br-4: the LC_ALL=C-last file is the one that wins" \
        "$BR_D_WANT" "$(entry_text "$BR_D_OUT" C1)"
}
