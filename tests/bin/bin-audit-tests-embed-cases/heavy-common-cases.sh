# Tests: bin/audit-tests-common.sh
# Tags: TL2, scope:issue-specific, audit-tests, sweep-tests, heavy, durations
# Sourced by tests/bin/bin-audit-tests-embed-cases-flags-common.sh — the twin of
# heavy-cases.sh for audit-tests-common.sh (CPR-ORTH). Uses heavy-helpers.sh.

case_begin "heavy-read-only-common" "bin/audit-tests-common.sh"
hv_read_only "$AUDIT_COMMON"
case_end

case_begin "heavy-no-gh-calls-common" "bin/audit-tests-common.sh"
hv_no_gh "$AUDIT_COMMON"
case_end

case_begin "heavy-missing-ledger-header-common" "bin/audit-tests-common.sh"
hv_missing "$AUDIT_COMMON"
case_end

case_begin "heavy-unreadable-ledger-header-common" "bin/audit-tests-common.sh"
hv_unreadable "$AUDIT_COMMON"
case_end

case_begin "heavy-order-hard-first-median-desc-common" "bin/audit-tests-common.sh"
hv_order "$AUDIT_COMMON"
case_end

case_begin "heavy-exclusive-flags-exit-2-common" "bin/audit-tests-common.sh"
hv_exclusive "$AUDIT_COMMON"
case_end

grp_done heavy-common-cases.sh
