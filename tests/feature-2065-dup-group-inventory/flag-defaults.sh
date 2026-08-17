# S12 category 4: flag defaults and the APPLY=1 trap (#2065, S3)
# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh
# Tags: TL2, audit-tests, dup-groups, cli, flags, scope:issue-specific
# Sourced by tests/feature-2065-dup-group-inventory.sh

# `sweep_write_mode_init` sets APPLY=1 BEFORE argv parsing, so `$APPLY` means
# "not --dry-run", never "the user passed --apply". A guard written against
# `$APPLY` inverts the mode: bare --dup-groups would exit 2 and only
# `--dup-groups --dry-run` would work. The guard must read FIX_APPLY.

FD_REPO="$(make_repo)"
add_src "$FD_REPO" "bin/fd-x.sh"
add_test_file "$FD_REPO" "fd-one.sh" "bin/fd-x.sh"
add_test_file "$FD_REPO" "fd-two.sh" "bin/fd-x.sh"
commit_repo "$FD_REPO" "flag defaults fixture"

# Both entrypoints carry the same argv loop, so per CPR-ORTH every row runs twice.
for fd_script in "$AUDIT" "$AUDIT_COMMON"; do
    fd_tag="$(basename "$fd_script")"

    # FD1 — the regression guard for the inversion. Bare --dup-groups is the
    # primary invocation; rc 2 here means the guard misread the default.
    run_dup "$FD_REPO" "$fd_script"
    FD_BARE_OUT="$OUT"; FD_BARE_RC="$RC"; FD_BARE_ERR="$ERR"
    assert_eq "FD1a[$fd_tag] bare --dup-groups is not rejected as a mode error" \
        "not-2" "$( [[ "$FD_BARE_RC" == "2" ]] && echo "2" || echo "not-2" )"
    assert_eq "FD1b[$fd_tag] bare --dup-groups emits no ERROR line" \
        "0" "$(printf '%s\n' "$FD_BARE_ERR" | grep -c '^ERROR:' || true)"
    assert_eq "FD1c[$fd_tag] bare --dup-groups emits the TSV column comment" \
        "1" "$(printf '%s\n' "$FD_BARE_OUT" | grep -c '^#' || true)"

    # FD2 — --dry-run is a no-op for a read-only mode: same bytes, same class of
    # exit code. Divergence would mean the mode branches on write intent.
    run_dup "$FD_REPO" "$fd_script" --dry-run
    FD_DRY_OUT="$OUT"; FD_DRY_RC="$RC"
    printf '%s\n' "$FD_BARE_OUT" > "$TMPDIR_BASE/fd-bare-$fd_tag.tsv"
    printf '%s\n' "$FD_DRY_OUT" > "$TMPDIR_BASE/fd-dry-$fd_tag.tsv"
    if diff -u "$TMPDIR_BASE/fd-bare-$fd_tag.tsv" "$TMPDIR_BASE/fd-dry-$fd_tag.tsv" >/dev/null 2>&1; then
        pass "FD2a[$fd_tag] --dup-groups --dry-run emits byte-identical TSV to bare"
    else
        fail "FD2a[$fd_tag] --dup-groups --dry-run TSV differs from bare --dup-groups"
    fi
    assert_eq "FD2b[$fd_tag] --dry-run exit code matches the bare run" \
        "$FD_BARE_RC" "$FD_DRY_RC"

    # FD3 — --apply is the only spelling that must be refused. Asserting the
    # message too, because an unknown-argument rejection also exits 2 today and
    # would false-green a bare exit-code check.
    run_dup "$FD_REPO" "$fd_script" --apply
    assert_eq "FD3a[$fd_tag] --dup-groups --apply exits 2" "2" "$RC"
    assert_eq "FD3b[$fd_tag] --dup-groups --apply explains that --apply is not applicable" \
        "1" "$(printf '%s\n' "$ERR" | grep -c -- '--dup-groups is read-only; --apply is not applicable' || true)"
done
