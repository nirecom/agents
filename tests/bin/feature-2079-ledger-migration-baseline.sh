#!/usr/bin/env bash
# tests/bin/feature-2079-ledger-migration-baseline.sh
# Tests: bin/lib/run-all-ledger-migrate.sh, bin/lib/run-all-parallelism.sh, bin/lib/run-all-durations.sh, bin/lib/run-tests-baseline-ledger.sh, tests/run-all.sh, bin/lib/run-all-durations-consolidate.sh
# Tags: TL2, scope:issue-specific, ledger, host-identity, migration, durations, baseline, consolidate, retention, concurrency
# Dispatcher for the #2079 baseline-ledger migration cases; split from feature-2079-ledger-migration.sh (#2723).
# TL3 gap (what this test does NOT catch):
# - a real Windows host switching between Git Bash, MSYS2 and a Windows update mid-week, or refusing a rename of a file another process holds open (stubbed mv)
# - several real run-all processes migrating or consolidating one shared ~/.claude/run-all at once
# - a real bin/run-tests-baseline run, or a pre-#2079 writer appending, over a real months-old ledger grown by real runs
# Mitigation: WORKFLOW_USER_VERIFIED preflight on a Windows host with an existing ledger.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
unset CLAUDE_CODE_SESSION_ID RUN_ALL_CACHE_DIR
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2079-ledger-migration/_lib.sh"
for part in "$LM_PARTS"/*-cases.sh; do . "$part"; done

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

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
