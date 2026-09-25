# S12 category 8: escaping and hostile names (#2065, S2 escape contract)
# Tests: bin/lib/test-dup-group.sh, bin/audit-tests.sh
# Tags: TL2, audit-tests, dup-groups, tsv, escaping, security, scope:issue-specific
# Sourced by tests/feature-2065-dup-group-inventory.sh
# TSV has exactly two structural characters (TAB, LF) and this format adds a
# third (the `,` that joins members), so all three plus the escape character
# itself must be encoded per element. Backslash is escaped first, otherwise the
# encoding of the other four is ambiguous on decode.

EH_REPO="$(make_repo)"
add_src "$EH_REPO" "bin/eh-x.sh"

# Comma in the FILENAME: the round-trip target. The member list is comma-joined,
# so an unescaped comma here would silently split one member into two.
add_test_file "$EH_REPO" "eh,comma-a.sh" "bin/eh-x.sh"
add_test_file "$EH_REPO" "eh,comma-b.sh" "bin/eh-x.sh"
# Space in the filename: legal on every filesystem, and a classic word-split bug.
add_test_file "$EH_REPO" "eh space a.sh" "bin/eh-x.sh"
commit_repo "$EH_REPO" "hostile names fixture"

run_dup "$EH_REPO" "$AUDIT"
EH_OUT="$OUT"; EH_ERR="$ERR"
EH_FILES="$(row_files "$EH_OUT" token "bin/eh-x.sh")"

# EH1 — round-trip: decoding the escaped member list must return the exact
# on-disk relative paths, commas and spaces intact.
assert_eq "EH1a the token group holds all three hostile-named files" \
    "3" "$(esc_count "$EH_FILES")"
assert_eq "EH1b a comma inside a filename survives the escape round-trip" \
    "yes" "$(row_has_member "$EH_OUT" token "bin/eh-x.sh" "tests/eh,comma-a.sh")"
assert_eq "EH1c a space inside a filename survives the escape round-trip" \
    "yes" "$(row_has_member "$EH_OUT" token "bin/eh-x.sh" "tests/eh space a.sh")"
assert_eq "EH1d the escaped member list contains no bare comma inside a member" \
    "3" "$(esc_members "$EH_FILES" | grep -c . || true)"

# EH2 — a backslash in a filename is legal on POSIX only; on Windows it is a
# path separator, so the case is platform-gated rather than silently absent.
if [[ "$IS_POSIX_FS" -eq 1 ]]; then
    EH_BS_REPO="$(make_repo)"
    add_src "$EH_BS_REPO" "bin/eh-x.sh"
    if add_test_file "$EH_BS_REPO" 'eh\back-a.sh' "bin/eh-x.sh" 2>/dev/null \
       && add_test_file "$EH_BS_REPO" 'eh\back-b.sh' "bin/eh-x.sh" 2>/dev/null; then
        commit_repo "$EH_BS_REPO" "backslash fixture"
        run_dup "$EH_BS_REPO" "$AUDIT"
        assert_eq "EH2 a backslash in a filename survives the escape round-trip" \
            "yes" "$(row_has_member "$OUT" token "bin/eh-x.sh" 'tests/eh\back-a.sh')"
    else
        skip "EH2 the filesystem refused a backslash in a filename"
    fi
else
    skip "EH2 backslash filenames are unrepresentable on this platform (Windows path separator)"
fi

# EH3 — TAB and LF in filenames. Most CI filesystems accept them and they are
# the two characters that can actually break the TSV grid, so attempt them and
# declare the gap explicitly when creation fails.
EH_CTL_REPO="$(make_repo)"
add_src "$EH_CTL_REPO" "bin/eh-x.sh"
EH_CTL_OK=1
add_test_file "$EH_CTL_REPO" "$(printf 'eh\ttab-a.sh')" "bin/eh-x.sh" 2>/dev/null || EH_CTL_OK=0
add_test_file "$EH_CTL_REPO" "$(printf 'eh\ttab-b.sh')" "bin/eh-x.sh" 2>/dev/null || EH_CTL_OK=0
if [[ "$EH_CTL_OK" -eq 1 && -f "$EH_CTL_REPO/tests/$(printf 'eh\ttab-a.sh')" ]]; then
    commit_repo "$EH_CTL_REPO" "control-char fixture"
    run_dup "$EH_CTL_REPO" "$AUDIT"
    assert_eq "EH3a a TAB in a filename does not break the 4-column grid" \
        "0" "$(bad_col_rows "$OUT")"
    assert_eq "EH3b a TAB in a filename survives the escape round-trip" \
        "yes" "$(row_has_member "$OUT" token "bin/eh-x.sh" "$(printf 'tests/eh\ttab-a.sh')")"
else
    skip "EH3 this filesystem refused a TAB in a filename — TSV column integrity under control characters is unverified here"
fi

# EH4 — a header value is DATA, never a command. The sentinel is the proof: if
# any layer evaluates the token, the subshell runs and the file appears.
EH_INJ_REPO="$(make_repo)"
EH_SENTINEL="$TMPDIR_BASE/eh-injection-sentinel"
rm -f "$EH_SENTINEL"
add_test_file "$EH_INJ_REPO" "eh-inj-semi.sh" "bin/x.sh; touch $EH_SENTINEL"
add_test_file "$EH_INJ_REPO" "eh-inj-subst.sh" "\$(touch $EH_SENTINEL)"
add_test_file "$EH_INJ_REPO" "eh-inj-tick.sh" "\`touch $EH_SENTINEL\`"
add_test_file "$EH_INJ_REPO" "eh-inj-tab.sh" "$(printf 'bin/eh\tx.sh')"
commit_repo "$EH_INJ_REPO" "injection fixture"

run_dup "$EH_INJ_REPO" "$AUDIT"
EH_INJ_OUT="$OUT"
while IFS='|' read -r eh_name eh_file eh_want; do
    [[ -z "${eh_name//[[:space:]]/}" || "$eh_name" =~ ^[[:space:]]*# ]] && continue
    eh_name="${eh_name//[[:space:]]/}"
    eh_file="${eh_file//[[:space:]]/}"
    eh_want="${eh_want//[[:space:]]/}"
    assert_eq "EH4[$eh_name] verdict" "$eh_want" "$(verdict_of "$EH_INJ_OUT" "tests/$eh_file")"
done <<'EH_TABLE'
semicolon      | eh-inj-semi.sh  | malformed_header
substitution   | eh-inj-subst.sh | malformed_header
backtick       | eh-inj-tick.sh  | malformed_header
tab-in-token   | eh-inj-tab.sh   | malformed_header
EH_TABLE

assert_eq "EH5a no header value was ever evaluated as a command" \
    "absent" "$( [[ -e "$EH_SENTINEL" ]] && echo present || echo absent )"
assert_eq "EH5b a TAB inside a token does not break the 4-column grid" \
    "0" "$(bad_col_rows "$EH_INJ_OUT")"

# EH6 — the degenerate corpus. An empty tests/ must produce the "nothing found"
# code, not a crash and not a phantom row.
EH_EMPTY="$(make_repo)"
commit_repo "$EH_EMPTY" "empty tests fixture"
run_dup "$EH_EMPTY" "$AUDIT"
assert_eq "EH6a an empty tests/ directory exits 1" "1" "$RC"
assert_eq "EH6b an empty tests/ directory emits no skip rows" \
    "0" "$(axis_row_count "$OUT" skip)"
assert_eq "EH6c an empty tests/ directory produces no shell error" \
    "0" "$(printf '%s\n' "$ERR" | grep -ciE 'unbound variable|syntax error|No such file' || true)"

assert_eq "EH7 the hostile-name run produced no shell error" \
    "0" "$(printf '%s\n' "$EH_ERR" | grep -ciE 'unbound variable|syntax error' || true)"

grp_done "escaping-hostile-names.sh"
