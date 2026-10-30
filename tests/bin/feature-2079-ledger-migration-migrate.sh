#!/usr/bin/env bash
# tests/bin/feature-2079-ledger-migration-migrate.sh
# Tests: bin/lib/run-all-ledger-migrate.sh, bin/lib/run-all-durations.sh, bin/lib/run-all-durations-consolidate.sh
# Tags: TL2, scope:issue-specific, ledger, host-identity, migration, durations, baseline, consolidate, retention, concurrency
# Dispatcher for #2079 n17 (1)-(8), (18): the duration ledger migration's folding, order, claims and foreign tokens; split from feature-2079-ledger-migration.sh (#2723).
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

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
