#!/usr/bin/env bash
# tests/bin/feature-3055-branch-decoy-base-fail.sh
# Tests: bin/lib/run-tests-baseline-classify.sh, bin/lib/run-tests-baseline-branch.sh, bin/run-tests-baseline
# Tags: run-tests, baseline, classify, root-names, scope:issue-specific, pwsh-not-required, TL2
# #3055: a branch solo run that hit the root decoy against a base failure of an unchanged test is
# undetermined root-decoy-hit-on-branch (auto); a changed test, git unable to tell, a rename source,
# a base pass, unrunnable and a branch timeout stay records missing / broken as before.
# Setup reuses feature-2688-branch-rerun/_lib.sh (CLI) and feature-3015's driver.sh (lib cases).
# TL3 gap: the lib cases set BR_DECOY by hand; only the CLI case runs a real decoy hit.
# Case bodies: feature-3055-branch-decoy-base-fail/{classify,cli}.sh; setup: _lib.sh.

set -uo pipefail

# Pin once at top level for the isolation checker; feature-2688's _lib.sh re-points both into its temp root.
export WORKFLOW_STATE_DIR="${TMPDIR:-/tmp}/rtb-3055-decoy-state-$$" WORKFLOW_PLANS_DIR="${TMPDIR:-/tmp}/rtb-3055-decoy-plans-$$"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2688-branch-rerun/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-2688-branch-rerun/_lib.sh"
BD_DIR="$(dirname "${BASH_SOURCE[0]}")/feature-3055-branch-decoy-base-fail"
# shellcheck source=tests/bin/feature-3055-branch-decoy-base-fail/_lib.sh
. "$BD_DIR/_lib.sh"
# shellcheck source=tests/bin/feature-3055-branch-decoy-base-fail/classify.sh
. "$BD_DIR/classify.sh"
# shellcheck source=tests/bin/feature-3055-branch-decoy-base-fail/cli.sh
. "$BD_DIR/cli.sh"

case_begin "decoy-fixture-premises" "bin/lib/run-tests-baseline-classify.sh"
bd_setup
case_end

case_begin "decoy-unchanged-base-fail-is-root-decoy-hit-on-branch" "bin/lib/run-tests-baseline-classify.sh"
bd_unchanged_base_fail
case_end

case_begin "decoy-changed-base-fail-is-records-missing" "bin/lib/run-tests-baseline-classify.sh"
bd_changed_base_fail
case_end

case_begin "decoy-git-unknown-is-records-missing" "bin/lib/run-tests-baseline-classify.sh"
bd_git_unknown
case_end

case_begin "decoy-rename-source-is-records-missing" "bin/lib/run-tests-baseline-classify.sh"
bd_rename_source
case_end

case_begin "decoy-base-pass-is-records-missing" "bin/lib/run-tests-baseline-classify.sh"
bd_base_pass
case_end

case_begin "unrunnable-base-fail-is-records-missing" "bin/lib/run-tests-baseline-classify.sh"
bd_unrunnable
case_end

case_begin "timeout-path-unchanged-control" "bin/lib/run-tests-baseline-classify.sh"
bd_timeout_control
case_end

case_begin "branch-classify-splits-decoy-from-unrunnable" "bin/lib/run-tests-baseline-branch.sh"
bd_branch_flags
case_end

case_begin "cli-decoy-hit-unchanged-test-base-fail-is-auto" "bin/run-tests-baseline"
bd_cli_auto
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
