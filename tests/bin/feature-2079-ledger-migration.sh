#!/usr/bin/env bash
# tests/bin/feature-2079-ledger-migration.sh
# Tests: bin/lib/run-all-ledger-migrate.sh, bin/lib/run-all-parallelism.sh, bin/lib/run-all-durations.sh, bin/lib/run-tests-baseline-ledger.sh, tests/run-all.sh, bin/lib/run-all-durations-consolidate.sh
# Tags: TL2, scope:issue-specific, ledger, host-identity, migration, durations, baseline, consolidate, retention, concurrency
# Dispatcher for #2079 n16 (host identity + OS attribute), n17 (duration ledger), baseline ledger migration and S7b n18-n20 (consolidation, abandoned segments, expiry).
# TL3 gap (what this test does NOT catch):
# - a real Windows host switching between Git Bash, MSYS2 and a Windows update mid-week, or refusing a rename of a file another process holds open (stubbed mv)
# - several real run-all processes migrating or consolidating one shared ~/.claude/run-all at once
# - a real bin/run-tests-baseline run, or a pre-#2079 writer appending, over a real months-old ledger grown by real runs
# Mitigation: WORKFLOW_USER_VERIFIED preflight on a Windows host with an existing ledger.

set -uo pipefail
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"
unset CLAUDE_CODE_SESSION_ID RUN_ALL_CACHE_DIR
. "$AGENTS_DIR/tests/bin/feature-2079-ledger-migration/_lib.sh"
for part in "$LM_PARTS"/*-cases.sh; do . "$part"; done

case_begin "n16-windows-one-key" "bin/lib/run-all-parallelism.sh"
run_identity_windows_cases
case_end

case_begin "n16-other-os-unchanged" "bin/lib/run-all-parallelism.sh"
run_identity_other_os_cases
case_end

case_begin "n16-os-attribute" "bin/lib/run-all-parallelism.sh"
run_identity_attr_cases
case_end

case_begin "n16-duration-writer-v2" "bin/lib/run-all-durations.sh"
run_identity_writer_cases
case_end

case_begin "n16-baseline-writer-v2" "bin/lib/run-tests-baseline-ledger.sh"
run_identity_baseline_cases
case_end

case_begin "n17-bulk-migration" "bin/lib/run-all-ledger-migrate.sh"
run_migrate_bulk_cases
case_end

case_begin "n17-young-open-kept" "bin/lib/run-all-durations.sh"
run_migrate_young_open_cases
case_end

case_begin "n17-closed-folded" "bin/lib/run-all-durations-consolidate.sh"
run_migrate_closed_cases
case_end

case_begin "n17-newest-wins" "bin/lib/run-all-ledger-migrate.sh"
run_migrate_order_cases
case_end

case_begin "n17-interrupted-claims" "bin/lib/run-all-ledger-migrate.sh"
run_migrate_interrupt_cases
case_end

case_begin "n17-new-format-foreign" "bin/lib/run-all-ledger-migrate.sh"
run_migrate_foreign_new_cases
case_end

case_begin "n17-non-windows-same-token" "bin/lib/run-all-ledger-migrate.sh"
run_migrate_nonwindows_cases
case_end

case_begin "n17-quiet-path" "bin/lib/run-all-ledger-migrate.sh"
run_migrate_quiet_cases
case_end

case_begin "n17-window-and-lock" "bin/lib/run-all-ledger-migrate.sh"
run_migrate_window_lock_cases
case_end

case_begin "n17-line-filter" "bin/lib/run-all-ledger-migrate.sh"
run_migrate_line_cases
case_end

case_begin "n17-line-shapes" "bin/lib/run-all-ledger-migrate.sh"
run_migrate_line_shape_cases
case_end

case_begin "n17-late-append" "bin/lib/run-all-ledger-migrate.sh"
run_migrate_late_append_cases
case_end

case_begin "n17-interruption-recovery" "bin/lib/run-all-ledger-migrate.sh"
run_migrate_recovery_cases
case_end

case_begin "n17-rename-failure-retry" "bin/lib/run-all-ledger-migrate.sh"
run_migrate_rename_fail_cases
case_end

case_begin "n17-runner-lpt" "tests/run-all.sh"
run_migrate_runner_lpt_cases
case_end

case_begin "n21-closed-marker-real-runner" "tests/run-all.sh"
run_closed_runner_cases
case_end

case_begin "n21-failing-test-closed-and-recorded" "tests/run-all.sh"
run_closed_fail_cases
case_end

case_begin "n21-close-direct" "bin/lib/run-all-durations.sh"
run_closed_direct_cases
case_end

case_begin "baseline-old-file-becomes-v2" "bin/lib/run-all-ledger-migrate.sh"
run_baseline_format_cases
case_end

case_begin "baseline-attribute-by-old-token" "bin/lib/run-all-ledger-migrate.sh"
run_baseline_attr_cases
case_end

case_begin "baseline-mtime-and-lookups" "bin/lib/run-tests-baseline-ledger.sh"
run_baseline_mtime_lookup_cases
case_end

case_begin "baseline-other-lines-kept" "bin/lib/run-all-ledger-migrate.sh"
run_baseline_keep_lines_cases
case_end

case_begin "baseline-new-format-and-young-untouched" "bin/lib/run-all-ledger-migrate.sh"
run_baseline_untouched_cases
case_end

case_begin "baseline-non-windows-same-token" "bin/lib/run-all-ledger-migrate.sh"
run_baseline_nonwindows_cases
case_end

case_begin "baseline-collision-and-idempotency" "bin/lib/run-all-ledger-migrate.sh"
run_baseline_collision_idempotent_cases
case_end

case_begin "baseline-late-append" "bin/lib/run-all-ledger-migrate.sh"
run_baseline_late_append_cases
case_end

case_begin "baseline-interruption-recovery" "bin/lib/run-all-ledger-migrate.sh"
run_baseline_recovery_cases
case_end

case_begin "baseline-rename-failure-retry" "bin/lib/run-all-ledger-migrate.sh"
run_baseline_rename_fail_cases
case_end

case_begin "baseline-crash-after-publish-rerun-no-dup" "bin/lib/run-all-ledger-migrate.sh"
run_baseline_crash_after_publish_cases
case_end

case_begin "baseline-append-path-migrates" "bin/lib/run-tests-baseline-ledger.sh"
run_baseline_append_path_cases
case_end

case_begin "baseline-expired-record-not-inheritable" "bin/lib/run-all-ledger-migrate.sh"
run_baseline_expired_record_cases
case_end

case_begin "n18-attr-bases" "bin/lib/run-all-durations-consolidate.sh"
run_cons_attr_cases
case_end

case_begin "n18-provenance-wins" "bin/lib/run-all-durations-consolidate.sh"
run_cons_provenance_cases
case_end

case_begin "n18-reader-all-states" "bin/lib/run-all-durations.sh"
run_cons_reader_states_cases
case_end

case_begin "n18-quiet-path" "bin/lib/run-all-durations-consolidate.sh"
run_cons_quiet_cases
case_end

case_begin "n18-merge-old-bases" "bin/lib/run-all-durations-consolidate.sh"
run_cons_merge_cases
case_end

case_begin "n18-foreign-untouched" "bin/lib/run-all-durations-consolidate.sh"
run_cons_foreign_cases
case_end

case_begin "n18-attr-reorder-and-aside-name" "bin/lib/run-all-durations-consolidate.sh"
run_cons_reorder_cases
case_end

case_begin "n18-beyond-read-window" "bin/lib/run-all-durations-consolidate.sh"
run_cons_window_cases
case_end

case_begin "n18-same-key-across-os-attributes" "bin/lib/run-all-durations-consolidate.sh"
run_attr_cross_cases
case_end

case_begin "n22-segment-name-table" "bin/lib/run-all-durations-consolidate.sh"
run_parse_name_cases
case_end

case_begin "n22-record-line-table" "bin/lib/run-all-durations-consolidate.sh"
run_parse_line_cases
case_end

case_begin "n22-header-line-table" "bin/lib/run-all-durations-consolidate.sh"
run_parse_header_cases
case_end

case_begin "n19-abandon-boundary" "bin/lib/run-all-durations-consolidate.sh"
run_abandon_boundary_cases
case_end

case_begin "n19-abandon-boundary-359-361" "bin/lib/run-all-durations-consolidate.sh"
run_abandon_tight_boundary_cases
case_end

case_begin "n19-late-line-kept" "bin/lib/run-all-durations-consolidate.sh"
run_abandon_late_line_cases
case_end

case_begin "n19-lock" "bin/lib/run-all-durations-consolidate.sh"
run_abandon_lock_cases
case_end

case_begin "n19-publish-interrupted" "bin/lib/run-all-durations-consolidate.sh"
run_abandon_publish_cases
case_end

case_begin "n19-claim-and-temp" "bin/lib/run-all-durations-consolidate.sh"
run_abandon_claim_cases
case_end

case_begin "n19-aside-failure" "bin/lib/run-all-durations-consolidate.sh"
run_abandon_aside_fail_cases
case_end

case_begin "n20-expiry-boundary" "bin/lib/run-all-durations-consolidate.sh"
run_expiry_boundary_cases
case_end

case_begin "n20-expiry-winner-and-layout" "bin/lib/run-all-durations-consolidate.sh"
run_expiry_winner_cases
case_end

case_begin "n20-expiry-migrated" "bin/lib/run-all-ledger-migrate.sh"
run_expiry_migrated_cases
case_end

case_begin "n20-expiry-env-and-aside" "bin/lib/run-all-durations-consolidate.sh"
run_expiry_env_cases
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
