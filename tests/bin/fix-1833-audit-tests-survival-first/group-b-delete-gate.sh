# Group B: the DELETE GATE is independent of scan ownership (#1833)
# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, delete-gate, scope:issue-specific
# Sourced by tests/fix-1833-audit-tests-survival-first.sh
#
# Scan ownership (`^feature-[0-9]+-` → audit-tests.sh, everything else →
# audit-tests-common.sh) and issue-reference strength (explicit / ambiguous /
# none) are two INDEPENDENT axes. A common-scope file that carries an explicit
# issue number must still be protected by that issue's state; an issue-specific
# file with no reachable metadata must still be held. Collapsing the axes is the
# accident this group exists to prevent.

B_TODAY_CLOSED="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"

# ── B1: issue-specific scope, three issue states ────────────────────────────

B_REPO="$(make_repo)"
add_test_file "$B_REPO" "feature-201-closedstale.sh" "bin/gone-201.sh" "TL2, scope:issue-specific"
add_test_file "$B_REPO" "feature-202-closedrecent.sh" "bin/gone-202.sh" "TL2, scope:issue-specific"
add_test_file "$B_REPO" "feature-203-open.sh" "bin/gone-203.sh" "TL2, scope:issue-specific"
commit_repo "$B_REPO" "issue-specific delete-gate fixtures"

B_STUB="$TMPDIR_BASE/b-stub"
install_gh_mock "$B_STUB"
export MOCK_ISSUES="201 closed 2019-01-01T00:00:00Z
202 closed $B_TODAY_CLOSED
203 open "

run_in_repo "$B_REPO" "$B_STUB" "$AUDIT" --apply --format text
B_OUT="$OUT"; B_RC="$RC"

# B1a–B1f — issue-specific scope × the three reachable issue states. Only
# CLOSED-and-stale authorises deletion; every hold still reports the candidate.
run_gate_table "B1-issue-specific" "$B_OUT" "$B_REPO" <<'TABLE'
# name          | fixture file                    | report    | gate         | fs
closed-stale    | feature-201-closedstale.sh      | candidate | deleted      | gone
closed-recent   | feature-202-closedrecent.sh     | candidate | issue-active | kept
open            | feature-203-open.sh             | candidate | issue-active | kept
TABLE

if git -C "$B_REPO" status --porcelain | grep -qE '^D  tests/feature-201-closedstale\.sh$'; then
    pass "B1b deletion is staged in the index (git rm, not plain rm)"
else
    fail "B1b deletion not staged: $(git -C "$B_REPO" status --porcelain)"
fi

# B1g — the retired combined label must not come back; the hold reason is now
# always one of the three specific SKIP_DELETE_* verdicts.
if echo "$B_OUT" | grep -q "SKIP_DELETE_HAS_A_OR_B"; then
    fail "B1g retired SKIP_DELETE_HAS_A_OR_B label still emitted (out=<<$B_OUT>>)"
else
    pass "B1g retired SKIP_DELETE_HAS_A_OR_B label is gone"
fi

# ── B2: common scope carries the same delete gate ───────────────────────────

BC_REPO="$(make_repo)"
add_test_file "$BC_REPO" "fix-301-open.sh" "bin/gone-301.sh"
add_test_file "$BC_REPO" "fix-302-closedstale.sh" "bin/gone-302.sh"
add_test_file "$BC_REPO" "fix-foo-bar.sh" "bin/gone-foo.sh"
add_test_file "$BC_REPO" "feature-test-cleanup-944.sh" "bin/gone-944.sh"
add_test_file "$BC_REPO" "fix-supervisor-write-layer3-routing.sh" "bin/gone-layer3.sh"
commit_repo "$BC_REPO" "common-scope delete-gate fixtures"

BC_STUB="$TMPDIR_BASE/bc-stub"
install_gh_mock "$BC_STUB"
export MOCK_ISSUES="301 open
302 closed 2019-01-01T00:00:00Z
944 open "

run_in_repo "$BC_REPO" "$BC_STUB" "$AUDIT_COMMON" --apply --format text
BC_OUT="$OUT"; BC_RC="$RC"

# B2a–B2f — common scope × issue-reference strength. The rows below are the
# cross product that proves the delete gate reads the issue-reference axis and
# NOT the scan-ownership axis: same script, same scope, five different gates.
#   explicit + OPEN         -> held (deleting it would destroy a live issue's test)
#   explicit + CLOSED-stale -> deleted
#   none                    -> deleted (metadata inapplicable, not unavailable)
#   ambiguous               -> held (fail-closed)
#   embedded digit (layer3) -> classified none, so the fail-closed rule still opens
run_gate_table "B2-common" "$BC_OUT" "$BC_REPO" <<'TABLE'
# name             | fixture file                            | report | gate          | fs
explicit-open      | fix-301-open.sh                         | orphan | issue-active  | kept
explicit-stale     | fix-302-closedstale.sh                  | orphan | deleted       | gone
no-issue-ref       | fix-foo-bar.sh                          | orphan | deleted       | gone
ambiguous-ref      | feature-test-cleanup-944.sh             | orphan | ambiguous-ref | kept
embedded-digit     | fix-supervisor-write-layer3-routing.sh  | orphan | deleted       | gone
TABLE

assert_eq "B2g common --apply deletes exactly the three authorised files (rc=$BC_RC)" \
    "3" "$(count_lines "$BC_OUT" DELETED)"

# ── B3: offline — candidates still emitted, deletions held per issue ref ────

BO_REPO="$(make_repo)"
add_test_file "$BO_REPO" "feature-401-gone.sh" "bin/gone-401.sh" "TL2, scope:issue-specific"
commit_repo "$BO_REPO" "offline issue-specific fixture"

unset MOCK_ISSUES
run_in_repo "$BO_REPO" "-" "$AUDIT" --offline --apply --format text
BO_OUT="$OUT"; BO_RC="$RC"

assert_gate_row "B3a --offline reports the candidate but holds the deletion" \
    "$BO_OUT" "$BO_REPO" "tests/feature-401-gone.sh" \
    candidate metadata-unavailable kept
if [[ "$BO_RC" -eq 0 ]]; then
    pass "B3b --offline with a candidate exits 0"
else
    fail "B3b expected exit 0 under --offline with a candidate, got $BO_RC"
fi
if echo "$BO_OUT" | grep -qi "no candidates will be emitted"; then
    fail "B3d stale OFFLINE banner still claims no candidates are emitted (out=<<$BO_OUT>>)"
else
    pass "B3d OFFLINE banner no longer claims candidates are suppressed"
fi

# B3e — offline + no issue reference: metadata was never applicable, so the
# deletion proceeds. This is the pair that must not be collapsed with B3c.
BO2_REPO="$(make_repo)"
add_test_file "$BO2_REPO" "fix-foo-offline.sh" "bin/gone-off.sh"
commit_repo "$BO2_REPO" "offline common fixture"

run_in_repo "$BO2_REPO" "-" "$AUDIT_COMMON" --offline --apply --format text
assert_gate_row "B3e --offline + no issue reference still deletes (metadata inapplicable)" \
    "$OUT" "$BO2_REPO" "tests/fix-foo-offline.sh" orphan deleted gone

# ── B4: gh reachable but the issue lookup fails ─────────────────────────────
# `gh repo view` succeeds so the script stays ONLINE; every `gh api` call fails,
# which is what a timeout, a 5xx, or a 404-from-another-repo looks like.

BF_REPO="$(make_repo)"
add_test_file "$BF_REPO" "feature-501-gone.sh" "bin/gone-501.sh" "TL2, scope:issue-specific"
commit_repo "$BF_REPO" "gh-failure fixture"

BF_STUB="$TMPDIR_BASE/bf-stub"
install_gh_mock_api_fails "$BF_STUB"
unset MOCK_ISSUES

run_in_repo "$BF_REPO" "$BF_STUB" "$AUDIT" --apply --format text
assert_gate_row "B4 failed issue lookup reports the candidate and holds the deletion" \
    "$OUT" "$BF_REPO" "tests/feature-501-gone.sh" \
    candidate metadata-unavailable kept

# ── B5: --stale-months still moves the delete-gate boundary ─────────────────
# The flag survives the inversion, but now it only affects deletion, never
# candidacy (backward-compat item 16 of the plan).

BS_REPO="$(make_repo)"
add_test_file "$BS_REPO" "feature-601-gone.sh" "bin/gone-601.sh" "TL2, scope:issue-specific"
commit_repo "$BS_REPO" "stale-months fixture"

B_120D="$(date -u -d '120 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-120d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || uv run python -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=120)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"

BS_STUB="$TMPDIR_BASE/bs-stub"
install_gh_mock "$BS_STUB"
export MOCK_ISSUES="601 closed $B_120D"

run_in_repo "$BS_REPO" "$BS_STUB" "$AUDIT" --dry-run --stale-months 6 --format text
assert_gate_row "B5a --stale-months 6 keeps the candidate but holds the deletion" \
    "$OUT" "$BS_REPO" "tests/feature-601-gone.sh" candidate issue-active kept

run_in_repo "$BS_REPO" "$BS_STUB" "$AUDIT" --apply --stale-months 3 --format text
assert_gate_row "B5b --stale-months 3 authorises deletion of the same 120-day-old issue" \
    "$OUT" "$BS_REPO" "tests/feature-601-gone.sh" candidate deleted gone

unset MOCK_ISSUES
