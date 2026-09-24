# Group G: realistic multi-file end-to-end pass over one repository (#1833)
# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, e2e-scale, scope:issue-specific
# Sourced by tests/fix-1833-audit-tests-survival-first.sh
#
# Groups A/B isolate one verdict per fixture. This group does the opposite: ONE
# repository holding 14 files that span every verdict at once, scanned by both
# scripts, then actually applied. Two failure modes only show up here:
#   - a filter that is correct per-file but over/under-counts in aggregate
#     (asserted as an exact candidate COUNT, not mere membership), and
#   - an apply pass whose blast radius exceeds the reported candidate set
#     (asserted as the exact deleted set + the exact surviving file list).

G_REPO="$(make_repo)"
add_src "$G_REPO" "bin/alive-g1.sh"
add_src "$G_REPO" "bin/alive-g2.sh"

# issue-specific scope (audit-tests.sh owns these)
add_test_file "$G_REPO" "feature-701-alive.sh"        "bin/alive-g1.sh" "TL2, scope:issue-specific"
add_test_file "$G_REPO" "feature-702-alive.sh"        "bin/alive-g2.sh" "TL2, scope:issue-specific"
add_test_file "$G_REPO" "feature-703-orphan-stale.sh" "bin/gone-g1.sh"  "TL2, scope:issue-specific"
add_test_file "$G_REPO" "feature-704-orphan-stale.sh" "bin/gone-g2.sh"  "TL2, scope:issue-specific"
add_test_file "$G_REPO" "feature-705-orphan-open.sh"  "bin/gone-g3.sh"  "TL2, scope:issue-specific"
add_test_file "$G_REPO" "feature-706-malformed.sh"    "bin/gone-g4.sh (see the ADR for why)" "TL2, scope:issue-specific"
add_test_file_nohdr "$G_REPO" "feature-707-noheader.sh"

# common scope (audit-tests-common.sh owns these)
add_test_file "$G_REPO" "cc-alive-g.sh"          "bin/alive-g1.sh"
add_test_file "$G_REPO" "cc-orphan-a.sh"         "bin/gone-g5.sh"
add_test_file "$G_REPO" "cc-orphan-b.sh"         "bin/gone-g6.sh"
add_test_file "$G_REPO" "fix-801-orphan-open.sh" "bin/gone-g7.sh"
add_test_file "$G_REPO" "cc-malformed-g.sh"      "bin/gone-g8.sh — prose tail, not a path"
add_test_file_nohdr "$G_REPO" "cc-noheader-g.sh"
add_test_file "$G_REPO" "feature-cleanup-902.sh" "bin/gone-g9.sh"
commit_repo "$G_REPO" "realistic mixed fixture"

G_STUB="$TMPDIR_BASE/g-stub"
install_gh_mock "$G_STUB"
export MOCK_ISSUES="703 closed 2019-01-01T00:00:00Z
704 closed 2019-01-01T00:00:00Z
705 open
801 open
902 open "

G_ALL_FILES="cc-alive-g.sh
cc-malformed-g.sh
cc-noheader-g.sh
cc-orphan-a.sh
cc-orphan-b.sh
feature-701-alive.sh
feature-702-alive.sh
feature-703-orphan-stale.sh
feature-704-orphan-stale.sh
feature-705-orphan-open.sh
feature-706-malformed.sh
feature-707-noheader.sh
feature-cleanup-902.sh
fix-801-orphan-open.sh"

g_tests_ls() { ( cd "$G_REPO/tests" && ls -1 ./*.sh 2>/dev/null | sed 's|^\./||' | sort ); }

assert_eq "G0 fixture starts with all 14 test files present" "$G_ALL_FILES" "$(g_tests_ls)"

# ── G1: --dry-run reports the exact candidate counts and writes nothing ─────

run_in_repo "$G_REPO" "$G_STUB" "$AUDIT" --dry-run --format text
G1_OUT="$OUT"; G1_RC="$RC"
run_in_repo "$G_REPO" "$G_STUB" "$AUDIT_COMMON" --dry-run --format text
G1C_OUT="$OUT"; G1C_RC="$RC"

# Exactly 3 of the 7 issue-specific files have every token dead: 703, 704, 705.
# Issue state is irrelevant to this count — that is the whole inversion.
assert_eq "G1a audit-tests --dry-run finds exactly 3 candidates (rc=$G1_RC)" \
    "3" "$(count_lines "$G1_OUT" CANDIDATE)"
assert_eq "G1b audit-tests --dry-run emits exactly 2 diagnostics" \
    "2" "$(( $(count_lines "$G1_OUT" MALFORMED_HEADER) + $(count_lines "$G1_OUT" NO_TESTS_HEADER) ))"
# Exactly 4 of the 7 common files: cc-orphan-a/b, fix-801, feature-cleanup-902.
assert_eq "G1c audit-tests-common --dry-run finds exactly 4 orphans (rc=$G1C_RC)" \
    "4" "$(count_lines "$G1C_OUT" ORPHAN)"
assert_eq "G1d audit-tests-common --dry-run emits exactly 2 diagnostics" \
    "2" "$(( $(count_lines "$G1C_OUT" MALFORMED_HEADER) + $(count_lines "$G1C_OUT" NO_TESTS_HEADER) ))"
assert_eq "G1e --dry-run deleted nothing on either side" "$G_ALL_FILES" "$(g_tests_ls)"
assert_eq "G1f --dry-run left the index clean" "" "$(git -C "$G_REPO" status --porcelain)"

# Per-file verdicts behind those counts — the count alone cannot show WHICH
# files were picked, and a compensating pair of errors would still total 3/4.
# The delete-gate column is deliberately absent here: --dry-run is a reporting
# run, so only the report axis is pinned (the gate is pinned in G2).
g_report_table() { # <label-prefix> <output> — reads `name|file|want` rows
    local prefix="$1" out="$2" name file want
    while IFS='|' read -r name file want; do
        [[ -z "${name//[[:space:]]/}" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"; file="${file//[[:space:]]/}"; want="${want//[[:space:]]/}"
        assert_eq "$prefix[$name]" "$want" "$(report_of "$out" "tests/$file")"
    done
}

g_report_table "G1-issue-specific" "$G1_OUT" <<'TABLE'
# name           | fixture file                  | want report
alive-1          | feature-701-alive.sh          | none
alive-2          | feature-702-alive.sh          | none
orphan-stale-1   | feature-703-orphan-stale.sh   | candidate
orphan-stale-2   | feature-704-orphan-stale.sh   | candidate
orphan-open      | feature-705-orphan-open.sh    | candidate
malformed        | feature-706-malformed.sh      | malformed
no-header        | feature-707-noheader.sh       | no-header
TABLE

g_report_table "G1-common" "$G1C_OUT" <<'TABLE'
# name           | fixture file              | want report
alive            | cc-alive-g.sh             | none
orphan-a         | cc-orphan-a.sh            | orphan
orphan-b         | cc-orphan-b.sh            | orphan
orphan-open-ref  | fix-801-orphan-open.sh    | orphan
malformed        | cc-malformed-g.sh         | malformed
no-header        | cc-noheader-g.sh          | no-header
ambiguous-ref    | feature-cleanup-902.sh    | orphan
TABLE

# ── G2: --apply removes exactly the authorised subset, and nothing else ─────

run_in_repo "$G_REPO" "$G_STUB" "$AUDIT" --apply --format text
G2_OUT="$OUT"; G2_RC="$RC"
run_in_repo "$G_REPO" "$G_STUB" "$AUDIT_COMMON" --apply --format text
G2C_OUT="$OUT"; G2C_RC="$RC"

# Only 703 and 704 clear the delete gate (closed + stale); 705 is held by its
# OPEN issue even though it is a candidate.
assert_eq "G2a audit-tests --apply deletes exactly 2 files (rc=$G2_RC)" \
    "2" "$(count_lines "$G2_OUT" DELETED)"
# Only the two reference-free common orphans clear it; fix-801 is held by its
# OPEN issue and feature-cleanup-902 by its ambiguous reference.
assert_eq "G2b audit-tests-common --apply deletes exactly 2 files (rc=$G2C_RC)" \
    "2" "$(count_lines "$G2C_OUT" DELETED)"

run_gate_table "G2-issue-specific" "$G2_OUT" "$G_REPO" <<'TABLE'
# name           | fixture file                  | report    | gate         | fs
orphan-stale-1   | feature-703-orphan-stale.sh   | candidate | deleted      | gone
orphan-stale-2   | feature-704-orphan-stale.sh   | candidate | deleted      | gone
orphan-open      | feature-705-orphan-open.sh    | candidate | issue-active | kept
alive-1          | feature-701-alive.sh          | none      | none         | kept
TABLE

run_gate_table "G2-common" "$G2C_OUT" "$G_REPO" <<'TABLE'
# name           | fixture file              | report    | gate          | fs
orphan-a         | cc-orphan-a.sh            | orphan    | deleted       | gone
orphan-b         | cc-orphan-b.sh            | orphan    | deleted       | gone
orphan-open-ref  | fix-801-orphan-open.sh    | orphan    | issue-active  | kept
ambiguous-ref    | feature-cleanup-902.sh    | orphan    | ambiguous-ref | kept
alive            | cc-alive-g.sh             | none      | none          | kept
TABLE

# The whole-tree assertion: 14 - 4 = 10 files remain, and they are exactly the
# ten named below. This is the check that a broad blast radius cannot survive.
G_EXPECTED_REMAINING="cc-alive-g.sh
cc-malformed-g.sh
cc-noheader-g.sh
feature-701-alive.sh
feature-702-alive.sh
feature-705-orphan-open.sh
feature-706-malformed.sh
feature-707-noheader.sh
feature-cleanup-902.sh
fix-801-orphan-open.sh"
assert_eq "G2c the surviving tests/ tree is exactly the expected 10 files" \
    "$G_EXPECTED_REMAINING" "$(g_tests_ls)"

# Every deletion is staged (git rm), and the index carries NOTHING else — no
# stray rewrite of a header, no accidentally staged source file.
G_STAGED="$(git -C "$G_REPO" status --porcelain | sort)"
assert_eq "G2d the index holds exactly the four expected staged deletions" \
"D  tests/cc-orphan-a.sh
D  tests/cc-orphan-b.sh
D  tests/feature-703-orphan-stale.sh
D  tests/feature-704-orphan-stale.sh" "$G_STAGED"

# The protected sources were never touched.
assert_eq "G2e alive targets still exist after --apply" \
    "kept kept" "$(fs_of "$G_REPO" "bin/alive-g1.sh") $(fs_of "$G_REPO" "bin/alive-g2.sh")"

unset MOCK_ISSUES
