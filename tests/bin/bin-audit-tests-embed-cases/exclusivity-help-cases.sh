# Tests: bin/lib/test-embed-cases.sh, bin/audit-tests.sh
# Tags: TL2, scope:common, audit-tests, embed-cases, flag-exclusivity, help
# Sourced by tests/bin/bin-audit-tests-embed-cases-flags.sh — every row of the flag
# exclusivity table on audit-tests.sh, its --only-file messages, the tec_main -h usage,
# and the new --help lines. exclusivity-help-common-cases.sh is the twin for
# audit-tests-common.sh. Uses the table and checks of exclusivity-table.sh.

case_begin "exclusivity-table-audit-tests" "bin/audit-tests.sh"
for _row in "${EX_TABLE[@]}"; do ex_row "$AUDIT" "$_row"; done
case_end

case_begin "only-file-rejection-messages" "bin/lib/test-embed-cases.sh"
ex_only_msgs "$AUDIT"
case_end

case_begin "exclusivity-rejects-leave-repo-clean" "bin/lib/test-embed-cases.sh"
check_eq "EX the whole audit-tests.sh table leaves no worktree change in the fixture" "" "$(git -C "$EX_REPO" status --porcelain)"
case_end

case_begin "embed-cases-short-help" "bin/lib/test-embed-cases.sh"
ex_short_help "$AUDIT"
case_end

case_begin "entrypoint-help-lists-embed-cases" "bin/audit-tests.sh"
ec_run "$EX_REPO" "$AUDIT" --help
check_eq "H2 audit-tests.sh --help exits 0" "0" "$RC"
for _w in "--embed-cases" "--band-size" "--order frequency|priority" "sweep-tests-embed-cases.md" "Unit=case" "--only-file"; do
  if [[ "$OUT" == *"$_w"* ]]; then pass "H2 audit-tests.sh --help mentions $_w"; else fail "H2 audit-tests.sh --help mentions $_w" "out=${OUT:0:400}"; fi
done
case_end

grp_done exclusivity-help-cases.sh
