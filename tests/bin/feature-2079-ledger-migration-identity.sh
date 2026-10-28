#!/usr/bin/env bash
# tests/bin/feature-2079-ledger-migration-identity.sh
# Tests: bin/lib/run-all-parallelism.sh, bin/lib/run-all-durations.sh, bin/lib/run-tests-baseline-ledger.sh
# Tags: TL2, scope:issue-specific, ledger, host-identity, migration, durations, baseline, consolidate, retention, concurrency
# Dispatcher for #2079 n16 (host identity + OS attribute); split from feature-2079-ledger-migration.sh (#2723).
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

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
