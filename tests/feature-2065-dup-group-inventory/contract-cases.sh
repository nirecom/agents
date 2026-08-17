# S12 category 7: the output contract — scope, ordering, purity (#2065, S2/S11)
# Tests: bin/lib/test-dup-group.sh, bin/audit-tests.sh, bin/audit-tests-common.sh, bin/check-test-frontmatter.sh
# Tags: TL2, audit-tests, dup-groups, tsv, contract, scope:issue-specific
# Sourced by tests/feature-2065-dup-group-inventory.sh

# The inventory is a corpus-wide fact, so it must not inherit either
# entrypoint's audience filter: the same TSV from both, no scope filtering, and
# a scan range of `tests/*.sh` only — nested fragments carry their own headers
# and would otherwise invent groups that no reviewer can act on.

CC_REPO="$(make_repo)"
add_src "$CC_REPO" "bin/cc-x.sh"
add_src "$CC_REPO" "bin/cc-y.sh"
add_src "$CC_REPO" "bin/cc-gone.sh"

# One group deliberately straddles the issue-specific / common boundary.
add_test_file "$CC_REPO" "feature-999-x.sh" "bin/cc-x.sh" "TL2, scope:issue-specific"
add_test_file "$CC_REPO" "common-y.sh" "bin/cc-x.sh" "TL2, scope:common"
# A second, smaller group so ordering by count is observable.
add_test_file "$CC_REPO" "cc-pair-a.sh" "bin/cc-y.sh, bin/cc-x.sh"
add_test_file "$CC_REPO" "cc-pair-b.sh" "bin/cc-y.sh, bin/cc-x.sh"
add_test_file "$CC_REPO" "cc-pair-c.sh" "bin/cc-y.sh, bin/cc-x.sh"

# Out-of-range files that would form phantom groups if the glob recursed.
mkdir -p "$CC_REPO/tests/feature-999-x"
add_test_file "$CC_REPO" "feature-999-x/frag.sh" "bin/cc-x.sh"
mkdir -p "$CC_REPO/tests/_archive"
add_test_file "$CC_REPO" "_archive/arch.sh" "bin/cc-x.sh"

# Retirement-eligible: names a target that does not exist, which is what the
# --fix-headers / retire paths would want to rewrite or delete.
rm -f "$CC_REPO/bin/cc-gone.sh"
add_test_file "$CC_REPO" "cc-retire-a.sh" "bin/cc-gone.sh"
add_test_file "$CC_REPO" "cc-retire-b.sh" "bin/cc-gone.sh"
commit_repo "$CC_REPO" "contract fixture"

run_dup "$CC_REPO" "$AUDIT"
CC_A_OUT="$OUT"; CC_A_RC="$RC"
run_dup "$CC_REPO" "$AUDIT_COMMON"
CC_B_OUT="$OUT"

# CC1 — one corpus, one answer. Byte identity is the strongest available form.
printf '%s\n' "$CC_A_OUT" > "$TMPDIR_BASE/cc-audit.tsv"
printf '%s\n' "$CC_B_OUT" > "$TMPDIR_BASE/cc-common.tsv"
if diff -u "$TMPDIR_BASE/cc-audit.tsv" "$TMPDIR_BASE/cc-common.tsv" >/dev/null 2>&1; then
    pass "CC1 both entrypoints emit byte-identical TSV for the same corpus"
else
    fail "CC1 the two entrypoints disagree: $(diff "$TMPDIR_BASE/cc-audit.tsv" "$TMPDIR_BASE/cc-common.tsv" | head -10 | tr '\n' '|')"
fi

# CC2 — no scope filtering: an issue-specific file and a common file group.
assert_eq "CC2a a cross-scope pair forms one token group of 2" \
    "2" "$(row_count "$CC_A_OUT" token "bin/cc-x.sh" )"
assert_eq "CC2b the issue-specific member is present in the group" \
    "yes" "$(row_has_member "$CC_A_OUT" token "bin/cc-x.sh" "tests/feature-999-x.sh")"
assert_eq "CC2c the common member is present in the same group" \
    "yes" "$(row_has_member "$CC_A_OUT" token "bin/cc-x.sh" "tests/common-y.sh")"

# CC3 — scan range. Both exclusions come from `tests/*.sh` not crossing `/`.
assert_eq "CC3a nested fragments are outside the scan range" \
    "0" "$(printf '%s\n' "$CC_A_OUT" | grep -c 'feature-999-x/frag\.sh' || true)"
assert_eq "CC3b tests/_archive is outside the scan range" \
    "0" "$(printf '%s\n' "$CC_A_OUT" | grep -c '_archive/arch\.sh' || true)"

# CC4 — deterministic ordering: count descending, then key ascending. A reader
# diffing two inventories must see only real changes.
CC_FULL_ORDER="$(printf '%s\n' "$CC_A_OUT" | awk -F'\t' 'substr($0,1,1)!="#" && $1=="full" { print $3"\t"$2 }')"
CC_FULL_SORTED="$(printf '%s\n' "$CC_FULL_ORDER" | sort -k1,1nr -k2,2)"
assert_eq "CC4a full rows are ordered by count desc then key asc" \
    "$CC_FULL_SORTED" "$CC_FULL_ORDER"
CC_AXIS_ORDER="$(printf '%s\n' "$CC_A_OUT" | awk -F'\t' 'substr($0,1,1)!="#" && NF>0 { print $1 }' | uniq | tr '\n' ' ')"
CC_AXIS_WANT="$(printf 'full\ntoken\nskip\n' | grep -Fx -f <(printf '%s\n' "$CC_AXIS_ORDER" | tr ' ' '\n' | grep -v '^$' | sort -u) | tr '\n' ' ')"
assert_eq "CC4b axes are emitted contiguously in the order full, token, skip" \
    "$CC_AXIS_WANT" "$CC_AXIS_ORDER"

# CC5 — idempotency. Same input, same bytes, twice.
run_dup "$CC_REPO" "$AUDIT"
printf '%s\n' "$OUT" > "$TMPDIR_BASE/cc-audit-2.tsv"
if diff -u "$TMPDIR_BASE/cc-audit.tsv" "$TMPDIR_BASE/cc-audit-2.tsv" >/dev/null 2>&1; then
    pass "CC5 a second run over an unchanged corpus emits identical bytes"
else
    fail "CC5 repeated runs over an unchanged corpus differ"
fi

# CC6 — read-only. The corpus contains retirement-eligible files precisely so a
# leaked write path would leave a trace in the worktree.
CC_STATUS_BEFORE="$(git -C "$CC_REPO" status --porcelain)"
run_dup "$CC_REPO" "$AUDIT"
run_dup "$CC_REPO" "$AUDIT_COMMON"
assert_eq "CC6 the working tree is untouched by both --dup-groups runs" \
    "$CC_STATUS_BEFORE" "$(git -C "$CC_REPO" status --porcelain)"

# CC7 — exit codes. 0 = something to act on, 1 = nothing, and "skip rows only"
# is nothing: a corpus of malformed files is not a duplicate finding.
assert_eq "CC7a a corpus with groups exits 0" "0" "$CC_A_RC"
CC_NONE="$(make_repo)"
add_src "$CC_NONE" "bin/cc-solo.sh"
add_test_file "$CC_NONE" "cc-only.sh" "bin/cc-solo.sh"
commit_repo "$CC_NONE" "no-dup fixture"
run_dup "$CC_NONE" "$AUDIT"
assert_eq "CC7b a corpus with no groups exits 1" "1" "$RC"

CC_SKIPONLY="$(make_repo)"
add_test_file "$CC_SKIPONLY" "cc-bad-a.sh" "bin/*.sh"
add_test_file "$CC_SKIPONLY" "cc-bad-b.sh" "bin/c d.sh"
commit_repo "$CC_SKIPONLY" "skip-only fixture"
run_dup "$CC_SKIPONLY" "$AUDIT"
assert_eq "CC7c a corpus that yields only skip rows exits 1" "1" "$RC"
# CC7d-f — per-reason aggregation (S2 output contract): the skip axis emits ONE
# row per reason, not one per file, and `count` carries the number of matching
# files. Both fixture files are malformed_header, so a per-file implementation
# would show up here as two rows of count 1 instead of one row of count 2.
assert_eq "CC7d the two same-reason skips aggregate into a single skip row" \
    "1" "$(axis_row_count "$OUT" skip)"
assert_eq "CC7e the aggregated skip row's count is the number of matching files" \
    "2" "$(row_count "$OUT" skip malformed_header)"
assert_eq "CC7f both malformed files are listed in that one row" \
    "yes,yes" "$(printf '%s,%s' \
        "$(row_has_member "$OUT" skip malformed_header "tests/cc-bad-a.sh")" \
        "$(row_has_member "$OUT" skip malformed_header "tests/cc-bad-b.sh")")"

# CC8 — discoverability. `-h` prints a fixed line range of the script header, so
# a new mode that is not also documented there is invisible to the operator.
for cc_script in "$AUDIT" "$AUDIT_COMMON"; do
    cc_tag="$(basename "$cc_script")"
    run_in_repo "$CC_REPO" "$cc_script" -h
    assert_eq "CC8[$cc_tag] -h output documents --dup-groups" \
        "yes" "$( printf '%s\n%s\n' "$OUT" "$ERR" | grep -q -- '--dup-groups' && echo yes || echo no )"
done

# CC9 — the S11 interaction: a file that opts out of a reported group with the
# `dup-group-keep:` tag must remain acceptable to the pre-commit HARD gate,
# which is a closed-vocabulary check over the Tags line.
CC_TAG_REPO="$(make_repo)"
add_src "$CC_TAG_REPO" "bin/cc-x.sh"
add_test_file "$CC_TAG_REPO" "cc-keep.sh" "bin/cc-x.sh" "TL2, scope:common, dup-group-keep:cross-hook"
commit_repo "$CC_TAG_REPO" "keep-tag fixture"
git -C "$CC_TAG_REPO" add -A >/dev/null 2>&1
run_in_repo "$CC_TAG_REPO" "$FM_CHECK" --staged
assert_eq "CC9 a dup-group-keep: tagged file passes the staged frontmatter gate" \
    "0" "$RC"
