#!/usr/bin/env bash
# Tests: bin/audit-tests.sh, bin/lib/test-embed-cases.sh
# Tags: TL2, scope:common, audit-tests, sweep-tests, embed-cases, case-markers, flag-exclusivity, help
# Part of the bin-audit-tests-embed-cases group (cases in that sibling folder), split out
# so run-all runs it in parallel: flag exclusivity and help on audit-tests.sh
# (-flags-common.sh runs the same table on audit-tests-common.sh).
# TL3 gap — the real stage-2 subagent rewrite and a real codex CLI are never run;
# checked when the first band is applied in its own PR (verification report).

set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$AGENTS_ROOT/tests/lib/harness.sh"
# shellcheck source=../lib/test-language-registry-fixture.sh
source "$AGENTS_ROOT/tests/lib/test-language-registry-fixture.sh"
# shellcheck source=../../bin/lib/run-all-launch.sh
source "$AGENTS_ROOT/bin/lib/run-all-launch.sh"
GROUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin-audit-tests-embed-cases"
AUDIT="${AUDIT_TESTS_BIN:-$AGENTS_ROOT/bin/audit-tests.sh}"
AUDIT_COMMON="${AUDIT_TESTS_COMMON_BIN:-$AGENTS_ROOT/bin/audit-tests-common.sh}"

EC_TMP="$(make_tmp)"
readonly EC_TMP
trap 'chmod -R u+rwX "$EC_TMP" 2>/dev/null; rm -rf "$EC_TMP"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md + detail Steps 7).
mkdir -p "$EC_TMP/home" "$EC_TMP/fakebin"
export HOME="$EC_TMP/home"
export NO_LOG=true
harness_isolate "$EC_TMP/state"
unset CLAUDE_CODE_SESSION_ID
export RUN_ALL_CACHE_DIR="$EC_TMP/run-all-cache"
export SWEEP_TESTS_STATE_DIR="$EC_TMP/sweep-state"
export PATH="$EC_TMP/fakebin:$PATH"

# shellcheck source=bin-audit-tests-embed-cases/suite-common.sh
. "$GROUP_DIR/suite-common.sh"
# shellcheck source=bin-audit-tests-embed-cases/fixture-helpers.sh
. "$GROUP_DIR/fixture-helpers.sh"
# shellcheck source=bin-audit-tests-embed-cases/exclusivity-table.sh
. "$GROUP_DIR/exclusivity-table.sh"
# shellcheck source=bin-audit-tests-embed-cases/exclusivity-help-cases.sh
. "$GROUP_DIR/exclusivity-help-cases.sh"
# shellcheck source=bin-audit-tests-embed-cases/heavy-helpers.sh
. "$GROUP_DIR/heavy-helpers.sh"
# shellcheck source=bin-audit-tests-embed-cases/heavy-cases.sh
. "$GROUP_DIR/heavy-cases.sh"

case_begin "suite-integrity-flags" "bin/lib/test-embed-cases.sh"
ec_suite_integrity "${BASH_SOURCE[0]}"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
