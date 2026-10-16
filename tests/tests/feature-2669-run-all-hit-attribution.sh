#!/usr/bin/env bash
# Tests: tests/run-all.sh, bin/lib/run-all-hits.sh, bin/lib/run-all-report.sh, bin/lib/run-all-launch.sh, bin/lib/run-all-worktree-change-detect.sh
# Tags: run-all, command-guard, root-decoy, worktree-change-detection, hit-attribution, scope:issue-specific, tl2
#
# Hit attribution in tests/run-all.sh (#2669): a command guard or root decoy hit that carries a
# test id is that test's FAIL (named, counted once, whatever state the test ended in); a hit
# without one, and a worktree change, is HITS on the contract with a column-0 HIT line.
# Helpers and fixtures: feature-2669-run-all-hit-attribution/setup.sh.

# TL3 gap: a real grandchild that writes its hit record after run-all reported the test is not
# raced here; the late path is driven by writing the record between the report and the collect.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(np "$(make_tmp)")"
[[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]] || { echo "cannot create a temp root" >&2; exit 1; }
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/state"
unset CLAUDE_CODE_SESSION_ID
ROOT_N="$(np "$SCRIPT_CHECKOUT_ROOT")"
readonly ROOT_N
TAB="$(printf '\t')"
readonly TAB

PARTS="$SCRIPT_CHECKOUT_ROOT/tests/tests/feature-2669-run-all-hit-attribution"
. "$PARTS/setup.sh"
. "$PARTS/launched-cases.sh"
. "$PARTS/unit-cases.sh"
. "$PARTS/wcd-cases.sh"
. "$PARTS/parallel-cases.sh"

ha_setup || { echo "FAIL: fixture setup"; exit 1; }

case_begin "guard-hit-with-a-test-id-is-that-tests-fail" "tests/run-all.sh"
ha_case_guard_hit_is_named_fail
case_end

case_begin "decoy-hit-with-a-test-id-is-that-tests-fail" "tests/run-all.sh"
ha_case_decoy_hit_is_named_fail
case_end

case_begin "hit-without-a-test-id-is-hits" "tests/run-all.sh"
ha_case_hit_without_test_id_is_hits
case_end

case_begin "run-without-hits-prints-what-it-printed-before" "bin/lib/run-all-report.sh"
ha_case_no_hit_run_is_unchanged
case_end

case_begin "test-output-cannot-forge-a-hit-line" "bin/lib/run-all-report.sh"
ha_case_test_output_cannot_forge_a_hit
case_end

case_begin "claim-renames-guard-and-removes-decoy-records" "bin/lib/run-all-hits.sh"
ha_case_claim_handles_the_records
case_end

case_begin "claim-turns-unrunnable-and-unsupported-into-fail" "bin/lib/run-all-hits.sh"
ha_case_unrunnable_and_unsupported_claims
case_end

case_begin "late-record-turns-unrunnable-and-unsupported-into-fail" "bin/lib/run-all-report.sh"
ha_case_unrunnable_and_unsupported_late
case_end

case_begin "claim-turns-skip-into-fail-and-keeps-timeout" "bin/lib/run-all-hits.sh"
ha_case_skip_and_timeout_claims
case_end

case_begin "late-record-turns-skip-into-fail-and-keeps-timeout" "bin/lib/run-all-report.sh"
ha_case_skip_and_timeout_late
case_end

case_begin "late-record-turns-a-pass-into-one-fail" "bin/lib/run-all-report.sh"
ha_case_late_record_on_a_pass
case_end

case_begin "late-record-on-a-fail-adds-nothing" "bin/lib/run-all-report.sh"
ha_case_late_record_on_a_fail
case_end

case_begin "two-late-records-give-one-fail" "bin/lib/run-all-hits.sh"
ha_case_two_late_records_one_fail
case_end

case_begin "duplicate-late-id-is-applied-once" "bin/lib/run-all-report.sh"
ha_case_duplicate_late_id_applied_once
case_end

case_begin "late-record-without-a-test-id-is-hits" "bin/lib/run-all-hits.sh"
ha_case_late_record_without_id_is_hits
case_end

case_begin "worktree-change-is-a-hit-naming-its-paths" "bin/lib/run-all-worktree-change-detect.sh"
ha_case_worktree_change_is_a_hit_with_paths
case_end

case_begin "worktree-change-path-with-spaces-is-kept-whole" "bin/lib/run-all-worktree-change-detect.sh"
ha_case_worktree_change_path_with_spaces
case_end

case_begin "worktree-change-names-many-paths-up-to-five" "bin/lib/run-all-worktree-change-detect.sh"
ha_case_worktree_change_with_many_paths
case_end

case_begin "parallel-hits-are-charged-to-their-own-tests" "tests/run-all.sh"
ha_case_parallel_hits_are_charged_to_their_own_tests
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
