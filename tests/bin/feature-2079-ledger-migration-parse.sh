#!/usr/bin/env bash
# tests/bin/feature-2079-ledger-migration-parse.sh
# Tests: bin/lib/run-all-durations-consolidate.sh, bin/lib/run-all-durations.sh
# Tags: TL2, scope:issue-specific, ledger, host-identity, migration, durations, baseline, consolidate, retention, concurrency
# Dispatcher for the #2079 S7b n22 parse tables; split from feature-2079-ledger-migration.sh (#2723).
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

case_begin "n22-segment-name-table" "bin/lib/run-all-durations-consolidate.sh"
run_parse_name_cases
case_end

case_begin "n22-record-line-table" "bin/lib/run-all-durations-consolidate.sh"
run_parse_line_cases
case_end

case_begin "n22-header-line-table" "bin/lib/run-all-durations-consolidate.sh"
run_parse_header_cases
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
