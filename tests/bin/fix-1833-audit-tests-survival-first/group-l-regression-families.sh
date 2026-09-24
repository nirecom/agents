# Group L: the two real regression families that motivated #1833 (#1833)
# Tests: bin/audit-tests.sh, bin/audit-tests-common.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, regression-family, scope:issue-specific
# Sourced by tests/fix-1833-audit-tests-survival-first.sh
#
# Every other group uses invented fixture names (feature-701-*, cc-orphan-*).
# Synthetic names cannot show a naming-shaped bug: `trp_scope_of` and
# `trp_issue_ref` both key on the BASENAME, so a family whose real names carry
# an embedded digit, a hyphenated multi-word stem, or a trailing number can be
# routed to the wrong script or the wrong issue-reference class while every
# synthetic fixture still passes.
#
# The names below are taken verbatim from the two families that survive in the
# live tests/ tree today and that #1833 exists to make sweepable:
#   feat-migrate-repo-*  — /migrate-repo coverage, common scope, hyphenated stem
#   feature-canary*      — canary fixtures whose stem starts with `feature-` but
#                          is NOT `feature-<N>-`, so they belong to the COMMON
#                          script; misrouting them means neither script owns them
#                          and they can never be retired (the #1833 false
#                          negative in its purest form).

L_REPO="$(make_repo)"
add_src "$L_REPO" "bin/migrate-repo-alive.sh"

# --- feat-migrate-repo-* : dead targets, no issue reference -----------------
add_test_file "$L_REPO" "feat-migrate-repo-preflight.sh" "bin/migrate-repo/preflight.sh"
add_test_file "$L_REPO" "feat-migrate-repo-dry-run.sh"   "bin/migrate-repo/dry-run.sh"
# ...and one whose target is still alive: the family must not be swept wholesale
# just because its siblings are dead.
add_test_file "$L_REPO" "feat-migrate-repo-state.sh"     "bin/migrate-repo-alive.sh"
# ...and one carrying a REAL trailing number (`-commit-446`). Per the delete
# gate this is an AMBIGUOUS reference, not an issue number: it must still be
# reported, and must be held back from deletion (fail-closed).
add_test_file "$L_REPO" "feat-migrate-repo-commit-446.sh" "bin/migrate-repo/commit.sh"

# --- feature-canary* : `feature-` prefix without the `-<N>-` shape ----------
add_test_file "$L_REPO" "feature-canary5-6git.sh"           "bin/canary/6git.sh"
add_test_file "$L_REPO" "feature-canary6a-pkgmgr-interpc.sh" "bin/canary/pkgmgr.sh"
commit_repo "$L_REPO" "real regression-family fixture"

L_STUB="$TMPDIR_BASE/l-stub"
install_gh_mock "$L_STUB"
# No MOCK_ISSUES record matches: issue 446 must never be looked up in the first
# place, because `-commit-446` is an ambiguous reference, not an issue number.
export MOCK_ISSUES="446 open "

# ── L1: dry-run discovers the families ──────────────────────────────────────
# Ownership first: `feature-canary*` is NOT `feature-<N>-`, so audit-tests.sh
# must report none of these files and audit-tests-common.sh must report them.

run_in_repo "$L_REPO" "$L_STUB" "$AUDIT" --dry-run --format text
L1_OUT="$OUT"; L1_RC="$RC"
run_in_repo "$L_REPO" "$L_STUB" "$AUDIT_COMMON" --dry-run --format text
L1C_OUT="$OUT"; L1C_RC="$RC"

assert_eq "L1a audit-tests.sh claims none of the two families (rc=$L1_RC)" \
    "0 0" "$(count_lines "$L1_OUT" CANDIDATE) $(count_lines "$L1_OUT" ORPHAN)"

L_DRY_TABLE_OUT="$L1C_OUT"
while IFS='|' read -r l_name l_file l_want; do
    [[ -z "${l_name//[[:space:]]/}" || "$l_name" =~ ^[[:space:]]*# ]] && continue
    l_name="${l_name//[[:space:]]/}"; l_file="${l_file//[[:space:]]/}"
    l_want="${l_want//[[:space:]]/}"
    assert_eq "L1b[$l_name] --dry-run verdict for tests/$l_file" \
        "$l_want" "$(report_of "$L_DRY_TABLE_OUT" "tests/$l_file")"
done <<'TABLE'
# name              | fixture file                          | want report
migrate-preflight   | feat-migrate-repo-preflight.sh        | orphan
migrate-dry-run     | feat-migrate-repo-dry-run.sh          | orphan
migrate-alive       | feat-migrate-repo-state.sh            | none
migrate-commit-446  | feat-migrate-repo-commit-446.sh       | orphan
canary-6git         | feature-canary5-6git.sh               | orphan
canary-pkgmgr       | feature-canary6a-pkgmgr-interpc.sh    | orphan
TABLE

assert_eq "L1c --dry-run finds exactly the 5 dead-target family members" \
    "5" "$(count_lines "$L1C_OUT" ORPHAN)"
assert_eq "L1d --dry-run wrote nothing to the index" \
    "" "$(git -C "$L_REPO" status --porcelain)"

# ── L2: --apply performs an authorised git rm on the family members ─────────

run_in_repo "$L_REPO" "$L_STUB" "$AUDIT_COMMON" --apply --format text
L2_OUT="$OUT"; L2_RC="$RC"

run_gate_table "L2-families" "$L2_OUT" "$L_REPO" <<'TABLE'
# name              | fixture file                          | report | gate          | fs
migrate-preflight   | feat-migrate-repo-preflight.sh        | orphan | deleted       | gone
migrate-dry-run     | feat-migrate-repo-dry-run.sh          | orphan | deleted       | gone
canary-6git         | feature-canary5-6git.sh               | orphan | deleted       | gone
canary-pkgmgr       | feature-canary6a-pkgmgr-interpc.sh    | orphan | deleted       | gone
migrate-commit-446  | feat-migrate-repo-commit-446.sh       | orphan | ambiguous-ref | kept
migrate-alive       | feat-migrate-repo-state.sh            | none   | none          | kept
TABLE

assert_eq "L2a --apply deletes exactly the 4 authorised family members (rc=$L2_RC)" \
    "4" "$(count_lines "$L2_OUT" DELETED)"

# L2b — the removals are STAGED (git rm), and the index carries nothing else.
# A plain `rm` would leave the paths as unstaged deletions (` D`), which is the
# difference between a sweep the user can review and one they cannot.
assert_eq "L2b the index holds exactly the four staged family deletions" \
"D  tests/feat-migrate-repo-dry-run.sh
D  tests/feat-migrate-repo-preflight.sh
D  tests/feature-canary5-6git.sh
D  tests/feature-canary6a-pkgmgr-interpc.sh" \
"$(git -C "$L_REPO" status --porcelain | sort)"

# L2c — audit-tests.sh, run over the same tree, must still delete nothing: the
# families are not its property and a second owner would double-delete.
run_in_repo "$L_REPO" "$L_STUB" "$AUDIT" --apply --format text
assert_eq "L2c audit-tests.sh deletes none of the family files" \
    "0" "$(count_lines "$OUT" DELETED)"
assert_eq "L2d the surviving family members are untouched by audit-tests.sh" \
    "kept kept" \
    "$(fs_of "$L_REPO" "tests/feat-migrate-repo-state.sh") $(fs_of "$L_REPO" "tests/feat-migrate-repo-commit-446.sh")"

unset MOCK_ISSUES
