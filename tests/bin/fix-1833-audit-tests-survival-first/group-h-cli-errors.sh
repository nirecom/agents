# Group H: CLI boundaries — bad argv, numeric edges, missing tests/, failed git rm (#1833)
# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, cli-errors, scope:issue-specific
# Sourced by tests/fix-1833-audit-tests-survival-first.sh
#
# Both scripts delete by default, so every path that ends in "I could not
# understand the request" must end in exit 2 with nothing removed. The numeric
# boundary matters for the same reason: --stale-months decides deletion, so an
# off-by-one at the cutoff is an off-by-one in what gets destroyed.

# days_ago_iso <n> — ISO-8601 UTC timestamp n days in the past (portable).
days_ago_iso() {
    date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || uv run python -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))"
}

# ── H1: malformed argv is rejected with exit 2 and destroys nothing ─────────

H1_REPO="$(make_repo)"
add_test_file "$H1_REPO" "cc-orphan-h1.sh" "bin/gone-h1.sh"
add_test_file "$H1_REPO" "feature-901-orphan-h1.sh" "bin/gone-h2.sh" "TL2, scope:issue-specific"
commit_repo "$H1_REPO" "argv-rejection fixture"

while IFS='|' read -r h_name h_script h_args; do
    [[ -z "${h_name//[[:space:]]/}" || "$h_name" =~ ^[[:space:]]*# ]] && continue
    h_name="${h_name//[[:space:]]/}"
    h_script="${h_script//[[:space:]]/}"
    h_args="$(echo "$h_args" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    case "$h_script" in
        AUDIT) h_bin="$AUDIT" ;;
        COMMON) h_bin="$AUDIT_COMMON" ;;
        *) fail "H1 table: unknown script token $h_script"; continue ;;
    esac
    # shellcheck disable=SC2086  # deliberate word-splitting of the argv column
    run_in_repo "$H1_REPO" "-" "$h_bin" $h_args
    assert_eq "H1[$h_name] exits 2 (err=<<$ERR>>)" "2" "$RC"
    if [[ -n "$ERR" ]]; then
        pass "H1[$h_name] explains the rejection on stderr"
    else
        fail "H1[$h_name] rejected the argv silently (stdout=<<$OUT>>)"
    fi
done <<'TABLE'
# name                   | script | argv
format-missing-value     | AUDIT  | --format
format-invalid-value     | AUDIT  | --format xml
unknown-flag             | AUDIT  | --bogus-flag
stale-missing-value      | AUDIT  | --stale-months
stale-non-numeric        | AUDIT  | --stale-months abc
stale-negative           | AUDIT  | --stale-months -1
stale-float              | AUDIT  | --stale-months 1.5
common-format-missing    | COMMON | --format
common-format-invalid    | COMMON | --format yaml
common-unknown-flag      | COMMON | --bogus-flag
common-stale-non-numeric | COMMON | --stale-months abc
common-stale-negative    | COMMON | --stale-months -1
TABLE

# H1z — the rejected runs are the ones most likely to half-execute. Nothing may
# have been deleted or staged by any of them.
assert_eq "H1z rejected argv deleted nothing (common fixture)" \
    "kept" "$(fs_of "$H1_REPO" "tests/cc-orphan-h1.sh")"
assert_eq "H1y rejected argv deleted nothing (issue-specific fixture)" \
    "kept" "$(fs_of "$H1_REPO" "tests/feature-901-orphan-h1.sh")"
assert_eq "H1x rejected argv staged nothing" "" "$(git -C "$H1_REPO" status --porcelain)"

# H1w — the symmetric positive: --stale-months IS a valid flag on both scripts
# (the common script needs the same cutoff now that it can delete). Without this
# row, "exit 2 for a bad value" could be satisfied by rejecting the flag itself.
run_in_repo "$H1_REPO" "-" "$AUDIT_COMMON" --dry-run --offline --stale-months 6 --format text
if [[ "$RC" -eq 0 || "$RC" -eq 1 ]]; then
    pass "H1w audit-tests-common accepts --stale-months (rc=$RC)"
else
    fail "H1w audit-tests-common must accept --stale-months (rc=$RC err=<<$ERR>>)"
fi

# ── H2: the --stale-months cutoff boundary ─────────────────────────────────
# cutoff = today - 30*N days; deletion needs closed_date STRICTLY older than it.
# Three rows straddle that line by one day each way.

H2_REPO="$(make_repo)"
add_test_file "$H2_REPO" "feature-911-at-cutoff.sh" "bin/gone-h11.sh" "TL2, scope:issue-specific"
add_test_file "$H2_REPO" "feature-912-past-cutoff.sh" "bin/gone-h12.sh" "TL2, scope:issue-specific"
add_test_file "$H2_REPO" "feature-913-inside-cutoff.sh" "bin/gone-h13.sh" "TL2, scope:issue-specific"
commit_repo "$H2_REPO" "cutoff-boundary fixture"

H2_STUB="$TMPDIR_BASE/h2-stub"
install_gh_mock "$H2_STUB"
export MOCK_ISSUES="911 closed $(days_ago_iso 90)
912 closed $(days_ago_iso 91)
913 closed $(days_ago_iso 89)"

run_in_repo "$H2_REPO" "$H2_STUB" "$AUDIT" --apply --stale-months 3 --format text
run_gate_table "H2-boundary" "$OUT" "$H2_REPO" <<'TABLE'
# name          | fixture file                   | report    | gate         | fs
exactly-at      | feature-911-at-cutoff.sh       | candidate | issue-active | kept
one-day-older   | feature-912-past-cutoff.sh     | candidate | deleted      | gone
one-day-newer   | feature-913-inside-cutoff.sh   | candidate | issue-active | kept
TABLE

# H2d — --stale-months 0 is a legal value (cutoff = today), not an error.
H2B_REPO="$(make_repo)"
add_test_file "$H2B_REPO" "feature-921-yesterday.sh" "bin/gone-h21.sh" "TL2, scope:issue-specific"
add_test_file "$H2B_REPO" "feature-922-today.sh" "bin/gone-h22.sh" "TL2, scope:issue-specific"
commit_repo "$H2B_REPO" "zero-stale-months fixture"
export MOCK_ISSUES="921 closed $(days_ago_iso 1)
922 closed $(days_ago_iso 0)"

run_in_repo "$H2B_REPO" "$H2_STUB" "$AUDIT" --apply --stale-months 0 --format text
H2B_OUT="$OUT"; H2B_RC="$RC"
if [[ "$H2B_RC" -ne 2 ]]; then
    pass "H2d --stale-months 0 is accepted (rc=$H2B_RC)"
else
    fail "H2d --stale-months 0 must not be an argv error (err=<<$ERR>>)"
fi
run_gate_table "H2-zero-months" "$H2B_OUT" "$H2B_REPO" <<'TABLE'
# name        | fixture file               | report    | gate         | fs
closed-1d-ago | feature-921-yesterday.sh   | candidate | deleted      | gone
closed-today  | feature-922-today.sh       | candidate | issue-active | kept
TABLE

# ── H3: a repository with no tests/ directory ──────────────────────────────

H3_REPO="$(make_repo)"
commit_repo "$H3_REPO" "pre-removal"
rm -rf "$H3_REPO/tests"

run_in_repo "$H3_REPO" "-" "$AUDIT" --dry-run --offline --format text
assert_eq "H3a audit-tests exits 2 when tests/ is absent (err=<<$ERR>>)" "2" "$RC"
run_in_repo "$H3_REPO" "-" "$AUDIT_COMMON" --dry-run --offline --format text
assert_eq "H3b audit-tests-common exits 2 when tests/ is absent (err=<<$ERR>>)" "2" "$RC"

# ── H4: a failed `git rm` must never be reported as DELETED ────────────────
# The stub answers every other git subcommand for real, so repo resolution and
# history lookups still work; only the removal fails, exactly as it would on a
# locked file or an index.lock collision.

install_failing_git_rm() {
    local bindir="$1" real_git
    real_git="$(command -v git)"
    mkdir -p "$bindir"
    cat > "$bindir/git" <<GITEOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "rm" ]]; then
  echo "fatal: simulated git rm failure" >&2
  exit 128
fi
exec "$real_git" "\$@"
GITEOF
    chmod +x "$bindir/git"
}

H4_REPO="$(make_repo)"
add_test_file "$H4_REPO" "cc-rmfail.sh" "bin/gone-h4.sh"
add_test_file "$H4_REPO" "feature-931-rmfail.sh" "bin/gone-h5.sh" "TL2, scope:issue-specific"
commit_repo "$H4_REPO" "git-rm-failure fixture"

H4_STUB="$TMPDIR_BASE/h4-stub"
install_gh_mock "$H4_STUB"
install_failing_git_rm "$H4_STUB"
export MOCK_ISSUES="931 closed 2019-01-01T00:00:00Z"

# Both scripts get the IDENTICAL five-part contract (CPR-ORTH): no DELETED line,
# non-success exit code, file still on disk, file still tracked in the index
# with a clean status, and the failure surfaced on stderr. Asserting only "no
# DELETED line" leaves a script that reports honestly but exits 0 and lets the
# caller (/sweep-tests, the nightly cron) record the sweep as successful.

# h_rmfail_contract <label> <script> <fixture-rel> — runs one script under the
# failing-git-rm stub and asserts all five facts.
h_rmfail_contract() {
    local label="$1" script="$2" rel="$3"
    local out err rc idx_before idx_after

    idx_before="$(git -C "$H4_REPO" status --porcelain -- "$rel")"

    run_in_repo "$H4_REPO" "$H4_STUB" "$script" --apply --format text
    out="$OUT"; err="$ERR"; rc="$RC"
    idx_after="$(git -C "$H4_REPO" status --porcelain -- "$rel")"

    # (c) the report must not claim a deletion that did not happen
    if line_has "$out" DELETED "$rel"; then
        fail "$label a: a failed git rm was reported as DELETED (out=<<$out>>)"
    else
        pass "$label a: a failed git rm is not reported as DELETED"
    fi

    # (b) the working tree is untouched...
    assert_eq "$label b: the file that could not be removed is still on disk" \
        "kept" "$(fs_of "$H4_REPO" "$rel")"
    # ...and so is the index: still tracked, still with the same (clean) status.
    # A `git rm --cached` that succeeded before the worktree removal failed
    # would leave the file on disk but untracked, which this row catches.
    assert_eq "$label c: the file is still tracked in the index" \
        "tracked" \
        "$(git -C "$H4_REPO" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 && echo tracked || echo untracked)"
    assert_eq "$label d: the index entry is unchanged by the failed attempt" \
        "$idx_before" "$idx_after"

    # (a) the exit code must not say success. 0 means "findings, all handled";
    # a deletion that could not be performed is an error the caller must see.
    if [[ "$rc" -eq 0 ]]; then
        fail "$label e: the run exited 0 despite a failed deletion (rc=$rc out=<<$out>>)"
    else
        pass "$label e: the run does not report success (rc=$rc)"
    fi

    if [[ -n "$err" ]]; then
        pass "$label f: the removal failure is surfaced on stderr"
    else
        fail "$label f: a failed git rm was swallowed silently (out=<<$out>>)"
    fi
}

h_rmfail_contract "H4 audit-tests"        "$AUDIT"        "tests/feature-931-rmfail.sh"
h_rmfail_contract "H4 audit-tests-common" "$AUDIT_COMMON" "tests/cc-rmfail.sh"

# H4g — the blast radius of a failed deletion is zero: no OTHER path may have
# been staged or removed while the failing one was being retried.
assert_eq "H4g a failed git rm left the whole index clean" \
    "" "$(git -C "$H4_REPO" status --porcelain)"

unset MOCK_ISSUES
