#!/usr/bin/env bash
# tests/bin/feature-2079-ledger-migration-migrate-robust.sh
# Tests: bin/lib/run-all-ledger-migrate.sh, tests/run-all.sh
# Tags: TL2, scope:issue-specific, ledger, host-identity, migration, durations, baseline, consolidate, retention, concurrency
# Dispatcher for #2079 n17 (9)-(17), (19): the migration's quiet path, lock, window, invalid lines, recovery and real runner; split from feature-2079-ledger-migration.sh (#2723).
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

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
