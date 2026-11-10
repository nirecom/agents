# Tests: bin/audit-tests.sh
# Tags: TL2, scope:issue-specific, audit-tests, sweep-tests, heavy, durations
# Sourced by tests/bin/bin-audit-tests-embed-cases-flags.sh — #2932 `--heavy` on
# audit-tests.sh (heavy-common-cases.sh is the audit-tests-common.sh twin). Uses heavy-helpers.sh.

case_begin "heavy-read-only" "bin/audit-tests.sh"
hv_read_only "$AUDIT"
case_end

case_begin "heavy-no-gh-calls" "bin/audit-tests.sh"
hv_no_gh "$AUDIT"
case_end

case_begin "heavy-missing-ledger-header" "bin/audit-tests.sh"
hv_missing "$AUDIT"
case_end

case_begin "heavy-unreadable-ledger-header" "bin/audit-tests.sh"
hv_unreadable "$AUDIT"
case_end

case_begin "heavy-order-hard-first-median-desc" "bin/audit-tests.sh"
hv_order "$AUDIT"
case_end

case_begin "heavy-exclusive-flags-exit-2" "bin/audit-tests.sh"
hv_exclusive "$AUDIT"
case_end

grp_done heavy-cases.sh
