#!/bin/bash
# tests/tests/feature-689-run-all-all-flag.sh
# Tests: tests/run-all.sh
# Tags: bin, tests, scope:issue-specific
# #689 run-all dispatch (--all, default sweep minus _archive/, positional files);
# #1836 every case runs on a mktemp fixture suite, never the repo's own tests/.
# #2473 another repo as the sweep target. Helpers and cases: feature-689-run-all-all-flag/.

set -u

# RECURSION CONTRACT (#1836): never launch the repo runner with TESTS_DIR unset
# or empty AND no positional argument — it would re-run the whole suite from
# inside itself. Every launch pins TESTS_DIR=, a fixture target root, or names a file; C6(a) enforces it.

# TL3 gap: non-bash /bin/sh and CI glob/locale drift in category discovery.
# Mitigation: the runner is bash-pinned by its shebang.

# isolation (#2512): pin state and plans dirs once for this file
_ISOLATION_TMP_ROOT="$(mktemp -d)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_ALL="$SCRIPT_CHECKOUT_ROOT/tests/run-all.sh"
PARTS="$SCRIPT_CHECKOUT_ROOT/tests/tests/feature-689-run-all-all-flag"

# Belt-and-braces for the recursion contract: if the suite ever re-enters this
# file, stop instead of forking another level.
if [ -n "${FEATURE_689_REENTRY_GUARD:-}" ]; then
    echo "SKIP: feature-689-run-all-all-flag re-entered recursively (recursion contract violated)"
    exit 77
fi
export FEATURE_689_REENTRY_GUARD=1

. "$PARTS/setup.sh"
. "$PARTS/dispatch-cases.sh"
. "$PARTS/guard-cases.sh"
. "$PARTS/unsupported-cases.sh"
. "$PARTS/target-root-cases.sh"

# C5a/C6a/C6b read the launches of the whole file family, so SELF is the dispatcher plus every part.
SELF="$TMPROOT/feature-689-family.sh"
cat "${BASH_SOURCE[0]}" "$PARTS"/*.sh > "$SELF"
rat_setup

test_C1_all_flag_iterates
test_C2_positional_single_file
test_C3_default_excludes_archive
test_C4a_missing_tests_dir
test_C4b_default_from_agents_dir
test_C4c_positional_beats_tests_dir
test_C5a_timeout_helper_delegates
test_C5b_timeout_helper_bounds
test_C6a_no_unpinned_launch
test_C6b_captured_output_masked
test_C6c_mask_contract_strips_marker
test_C7_ambient_sanitized
test_C8_not_launched_unsupported_not_counted
test_RAT_by_type_target
test_RAT_flat_target
test_RAT_uninitialized_exit_6
test_RAT_tests_dir_override_first
test_RAT_positional_no_settings
test_RAT_harness_dir_export

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
