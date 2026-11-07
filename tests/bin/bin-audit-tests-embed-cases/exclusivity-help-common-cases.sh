# Tests: bin/lib/test-embed-cases.sh, bin/audit-tests-common.sh
# Tags: TL2, scope:common, audit-tests, embed-cases, flag-exclusivity, help
# Sourced by tests/bin/bin-audit-tests-embed-cases-flags-common.sh — the twin of
# exclusivity-help-cases.sh for audit-tests-common.sh: every table row, the --only-file
# messages, the tec_main -h usage and the --help lines. Uses exclusivity-table.sh.

case_begin "exclusivity-table-audit-tests-common" "bin/audit-tests-common.sh"
for _row in "${EX_TABLE[@]}"; do ex_row "$AUDIT_COMMON" "$_row"; done
case_end

case_begin "only-file-rejection-messages-common" "bin/lib/test-embed-cases.sh"
ex_only_msgs "$AUDIT_COMMON"
case_end

case_begin "exclusivity-rejects-leave-repo-clean-common" "bin/lib/test-embed-cases.sh"
check_eq "EX the whole audit-tests-common.sh table leaves no worktree change in the fixture" "" "$(git -C "$EX_REPO" status --porcelain)"
case_end

case_begin "embed-cases-short-help-common" "bin/lib/test-embed-cases.sh"
ex_short_help "$AUDIT_COMMON"
case_end

case_begin "entrypoint-common-help-lists-embed-cases" "bin/audit-tests-common.sh"
ec_run "$EX_REPO" "$AUDIT_COMMON" --help
check_eq "H3 audit-tests-common.sh --help exits 0" "0" "$RC"
for _w in "--embed-cases" "--band-size" "--order frequency|priority" "sweep-tests-embed-cases.md" "unit=case" "--only-file"; do
  if [[ "$OUT" == *"$_w"* ]]; then pass "H3 audit-tests-common.sh --help mentions $_w"; else fail "H3 audit-tests-common.sh --help mentions $_w" "out=${OUT:0:400}"; fi
done
case_end

grp_done exclusivity-help-common-cases.sh
