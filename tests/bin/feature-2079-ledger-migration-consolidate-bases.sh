#!/usr/bin/env bash
# tests/bin/feature-2079-ledger-migration-consolidate-bases.sh
# Tests: bin/lib/run-all-durations-consolidate.sh, bin/lib/run-all-durations.sh
# Tags: TL2, scope:issue-specific, ledger, host-identity, migration, durations, baseline, consolidate, retention, concurrency
# Dispatcher for the #2079 S7b n18 consolidation cases that build bases (attributes, provenance, merge, order); split from feature-2079-ledger-migration.sh (#2723).
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

case_begin "n18-attr-bases" "bin/lib/run-all-durations-consolidate.sh"
run_cons_attr_cases
case_end

case_begin "n18-provenance-wins" "bin/lib/run-all-durations-consolidate.sh"
run_cons_provenance_cases
case_end

case_begin "n18-reader-all-states" "bin/lib/run-all-durations.sh"
run_cons_reader_states_cases
case_end

case_begin "n18-merge-old-bases" "bin/lib/run-all-durations-consolidate.sh"
run_cons_merge_cases
case_end

case_begin "n18-attr-reorder-and-aside-name" "bin/lib/run-all-durations-consolidate.sh"
run_cons_reorder_cases
case_end

case_begin "n18-same-key-across-os-attributes" "bin/lib/run-all-durations-consolidate.sh"
run_attr_cross_cases
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
