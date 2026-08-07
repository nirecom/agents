# Group M: automatic offline fallback — gh absent, gh broken, gh too slow (#1833)
# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, offline-fallback, scope:issue-specific
# Sourced by tests/fix-1833-audit-tests-survival-first.sh
#
# Group B covers the EXPLICIT `--offline` flag and the case where `gh api`
# returns non-zero. This group covers the three INVOLUNTARY ways metadata goes
# missing on a real host, which are separate code paths:
#   M1  `gh` is not installed at all — no directory on $PATH provides it, so the
#       `command -v gh` guard is what has to fire; nothing ever execs.
#   M2  `gh` runs but `gh repo view` exits non-zero — the slug never resolves, so
#       there is no URL to query. (Distinct from group B's B4, where the slug DID
#       resolve and only the per-issue lookup failed.)
#   M3  `gh` answers, but slower than $GH_TIMEOUT — run-with-timeout.sh kills it.
#
# All three must land on the SAME contract, and it has two halves that are easy
# to get individually right and jointly wrong:
#   (a) candidates stay VISIBLE — a host without gh must still get a full report,
#       otherwise the sweep silently under-reports and #1833 recurs offline;
#   (b) deletion of anything carrying an issue reference is HELD as
#       SKIP_DELETE_METADATA_UNAVAILABLE — never deleted, and never quietly
#       reclassified as "no issue reference, safe to delete".
# Asserting only (a) permits a script that deletes blind; asserting only (b)
# permits a script that drops the file from the report entirely.

# m_fixture <label> — a repo with one issue-referencing file (metadata APPLIES,
# so it must be held) and one reference-free file (metadata is INAPPLICABLE, so
# it must still be deleted). Echoes the repo root.
m_fixture() {
    local root
    root="$(make_repo)"
    add_test_file "$root" "feature-1201-gone.sh" "bin/gone-m1.sh" "TL2, scope:issue-specific"
    add_test_file "$root" "fix-1202-gone.sh" "bin/gone-m2.sh"
    add_test_file "$root" "cc-noref-gone.sh" "bin/gone-m3.sh"
    commit_repo "$root" "offline-fallback fixture ($1)"
    echo "$root"
}

# m_assert_fallback <label> <audit-output> <common-output> <root>
# The full contract for one fallback flavour, applied identically to all three
# (CPR-ORTH: the three causes differ, the required behaviour does not).
m_assert_fallback() {
    local label="$1" a_out="$2" c_out="$3" root="$4"

    assert_gate_row "$label a: issue-specific candidate stays visible, deletion held" \
        "$a_out" "$root" "tests/feature-1201-gone.sh" \
        candidate metadata-unavailable kept
    assert_gate_row "$label b: common orphan with an issue ref stays visible, deletion held" \
        "$c_out" "$root" "tests/fix-1202-gone.sh" \
        orphan metadata-unavailable kept
    assert_gate_row "$label c: a reference-free orphan is still deleted (metadata inapplicable)" \
        "$c_out" "$root" "tests/cc-noref-gone.sh" \
        orphan deleted gone
    # The held file must not be silently dropped from the report: "no line at
    # all" is the failure this row exists to separate from "held".
    assert_eq "$label d: exactly one deletion happened on the common side" \
        "1" "$(count_lines "$c_out" DELETED)"
}

# ── M1: gh is not installed on this host ────────────────────────────────────

M1_REPO="$(m_fixture no-gh)"
M1_PATH="$(path_without_gh)"

# Positive control: the sanitized PATH really has no gh (otherwise M1 silently
# degenerates into "gh works fine" and passes for the wrong reason).
if PATH="$M1_PATH" command -v gh >/dev/null 2>&1; then
    fail "M1z the sanitized PATH still resolves gh — the no-gh branch was not exercised"
else
    pass "M1z the sanitized PATH resolves no gh binary"
fi
# ...and the complementary control: removing gh must not have removed anything
# ELSE the scripts need. Without this row, an over-broad PATH surgery would make
# every M1 assertion fail for a reason that has nothing to do with #1833.
M1_LOST=""
for m_tool in bash git sed grep awk date find sort; do
    PATH="$M1_PATH" command -v "$m_tool" >/dev/null 2>&1 || M1_LOST="$M1_LOST $m_tool"
done
assert_eq "M1y the sanitized PATH still resolves every other tool the scripts use" \
    "" "$M1_LOST"

unset MOCK_ISSUES
run_in_repo_with_path "$M1_REPO" "$M1_PATH" "$AUDIT" --apply --format text
M1_OUT="$OUT"; M1_RC="$RC"; M1_ERR="$ERR"
run_in_repo_with_path "$M1_REPO" "$M1_PATH" "$AUDIT_COMMON" --apply --format text
M1C_OUT="$OUT"; M1C_RC="$RC"; M1C_ERR="$ERR"

m_assert_fallback "M1 (gh absent)" "$M1_OUT" "$M1C_OUT" "$M1_REPO"

# M1e — a missing optional dependency is a degraded mode, not a crash: the run
# must complete with a findings exit code, not an argv/abort code.
if [[ "$M1_RC" -eq 0 && "$M1C_RC" -eq 0 ]]; then
    pass "M1e both scripts complete normally without gh (rc=$M1_RC/$M1C_RC)"
else
    fail "M1e missing gh must not abort the run (rc=$M1_RC/$M1C_RC err=<<$M1_ERR>> / <<$M1C_ERR>>)"
fi

# M1f — the degradation is announced on stderr, so a cron log shows WHY nothing
# was deleted. Silence here is how an operator concludes "there was no work".
if echo "$M1_ERR$M1C_ERR" | grep -qiE "gh|offline|metadata"; then
    pass "M1f the fallback to offline mode is announced on stderr"
else
    fail "M1f the gh-less fallback was silent (err=<<$M1_ERR>> / <<$M1C_ERR>>)"
fi

# M1g — stdout stays machine-readable: the WARNING must not be printed into the
# JSON document (that is the classic way a fallback breaks every consumer).
run_in_repo_with_path "$M1_REPO" "$M1_PATH" "$AUDIT" --dry-run --format json
if json_parses "$OUT"; then
    pass "M1g --format json stays parseable when gh is missing"
else
    fail "M1g the gh-less warning corrupted the JSON document (out=<<$OUT>>)"
fi

# ── M2: gh exists but `gh repo view` fails ──────────────────────────────────

M2_REPO="$(m_fixture repo-view-fails)"
M2_STUB="$TMPDIR_BASE/m2-stub"
install_gh_mock_repo_view_fails "$M2_STUB"

run_in_repo "$M2_REPO" "$M2_STUB" "$AUDIT" --apply --format text
M2_OUT="$OUT"; M2_RC="$RC"
run_in_repo "$M2_REPO" "$M2_STUB" "$AUDIT_COMMON" --apply --format text
M2C_OUT="$OUT"; M2C_RC="$RC"

m_assert_fallback "M2 (gh repo view fails)" "$M2_OUT" "$M2C_OUT" "$M2_REPO"
if [[ "$M2_RC" -eq 0 && "$M2C_RC" -eq 0 ]]; then
    pass "M2e an unresolvable repo slug is a degraded mode, not an error (rc=$M2_RC/$M2C_RC)"
else
    fail "M2e unresolvable slug must not abort the run (rc=$M2_RC/$M2C_RC)"
fi

# ── M3: gh answers, but slower than the pinned GH_TIMEOUT ───────────────────
# GH_TIMEOUT is pinned on BOTH sides of this comparison rather than inherited:
# GH_TIMEOUT_PIN=30 for every other case in the suite (set in the dispatcher),
# and GH_TIMEOUT_PIN=1 here. Without the pin an ambient GH_TIMEOUT=1 would make
# M3 pass while every "online" case in groups B/G silently became this case.

M3_REPO="$(m_fixture slow-gh)"
M3_STUB="$TMPDIR_BASE/m3-stub"
install_gh_mock_slow "$M3_STUB" 5

GH_TIMEOUT_PIN=1 run_in_repo "$M3_REPO" "$M3_STUB" "$AUDIT" --apply --format text
M3_OUT="$OUT"; M3_RC="$RC"
GH_TIMEOUT_PIN=1 run_in_repo "$M3_REPO" "$M3_STUB" "$AUDIT_COMMON" --apply --format text
M3C_OUT="$OUT"; M3C_RC="$RC"

m_assert_fallback "M3 (gh slower than GH_TIMEOUT=1)" "$M3_OUT" "$M3C_OUT" "$M3_REPO"

# M3e — the control row: the SAME slow stub with a generous pinned timeout must
# resolve the metadata and reach a real gate verdict. Without this row, M3 would
# also pass against a script that ignores gh entirely.
M3B_REPO="$(m_fixture slow-gh-generous)"
M3B_STUB="$TMPDIR_BASE/m3b-stub"
install_gh_mock_slow "$M3B_STUB" 1

GH_TIMEOUT_PIN=20 run_in_repo "$M3B_REPO" "$M3B_STUB" "$AUDIT" --apply --format text
M3B_OUT="$OUT"
# The verdict must be a POSITIVELY metadata-derived one. Accepting "anything but
# metadata-unavailable" would also accept `none` — which is what a script that
# never reported the file at all produces, i.e. the assertion would pass today,
# before the fix, for the opposite reason.
M3B_GATE="$(gate_of "$M3B_OUT" "tests/feature-1201-gone.sh")"
case "$M3B_GATE" in
    deleted|issue-active)
        pass "M3e a generous pinned GH_TIMEOUT lets the same slow stub resolve metadata (gate=$M3B_GATE)" ;;
    *)
        fail "M3e with GH_TIMEOUT=20 the 1s stub must resolve metadata, want gate=deleted|issue-active got=$M3B_GATE (out=<<$M3B_OUT>>)" ;;
esac

unset MOCK_ISSUES
