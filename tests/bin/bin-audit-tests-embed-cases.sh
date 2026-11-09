#!/usr/bin/env bash
# Tests: bin/lib/test-embed-cases.sh, bin/lib/test-embed-cases/select.sh, bin/lib/test-embed-cases/order.sh, bin/lib/test-embed-cases/stage-plan.sh, bin/lib/test-embed-cases/stage-apply.sh, bin/lib/test-embed-cases/retry-record.sh, bin/lib/test-embed-cases/codex-band-check.sh, bin/audit-tests.sh, bin/audit-tests-common.sh
# Tags: TL2, scope:common, audit-tests, sweep-tests, embed-cases, case-markers, stage-protocol
# Dispatcher for the sweep-tests --embed-cases tool (cases in the sibling folder): the
# preconditions, ordering, band, stage 1, entrypoint symmetry and the GC hand-off. Its
# siblings -skip / -apply / -harden / -flags / -flags-common run the rest in parallel.
# Stage 2 (LLM rewrite) is simulated with mock output files; codex is a fake binary first on PATH.
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
TEC_LIB="$AGENTS_ROOT/bin/lib/test-embed-cases"

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

# ── Preconditions (one case per # Tests: path) ──────────────────────────────
case_begin "preconditions-entry-lib" "bin/lib/test-embed-cases.sh"
if [[ -f "$AGENTS_ROOT/bin/lib/test-embed-cases.sh" ]]; then pass "P0 test-embed-cases.sh exists"; else fail "P0 test-embed-cases.sh exists" "missing (not implemented yet)"; fi
case_end

case_begin "preconditions-select" "bin/lib/test-embed-cases/select.sh"
if [[ -f "$TEC_LIB/select.sh" ]]; then pass "P0 select.sh exists"; else fail "P0 select.sh exists" "missing (not implemented yet)"; fi
case_end

case_begin "preconditions-order" "bin/lib/test-embed-cases/order.sh"
if [[ -f "$TEC_LIB/order.sh" ]]; then pass "P0 order.sh exists"; else fail "P0 order.sh exists" "missing (not implemented yet)"; fi
case_end

case_begin "preconditions-stage-plan" "bin/lib/test-embed-cases/stage-plan.sh"
if [[ -f "$TEC_LIB/stage-plan.sh" ]]; then pass "P0 stage-plan.sh exists"; else fail "P0 stage-plan.sh exists" "missing (not implemented yet)"; fi
case_end

case_begin "preconditions-stage-apply" "bin/lib/test-embed-cases/stage-apply.sh"
if [[ -f "$TEC_LIB/stage-apply.sh" ]]; then pass "P0 stage-apply.sh exists"; else fail "P0 stage-apply.sh exists" "missing (not implemented yet)"; fi
case_end

case_begin "preconditions-retry-record" "bin/lib/test-embed-cases/retry-record.sh"
if [[ -f "$TEC_LIB/retry-record.sh" ]]; then pass "P0 retry-record.sh exists"; else fail "P0 retry-record.sh exists" "missing (not implemented yet)"; fi
case_end

case_begin "preconditions-codex-band-check" "bin/lib/test-embed-cases/codex-band-check.sh"
if [[ -f "$TEC_LIB/codex-band-check.sh" ]]; then pass "P0 codex-band-check.sh exists"; else fail "P0 codex-band-check.sh exists" "missing (not implemented yet)"; fi
case_end

case_begin "preconditions-entrypoints" "bin/audit-tests.sh"
if [[ -f "$AUDIT" ]]; then pass "P0 audit-tests.sh exists"; else fail "P0 audit-tests.sh exists" "missing at $AUDIT"; fi
case_end

case_begin "preconditions-entrypoint-common" "bin/audit-tests-common.sh"
if [[ -f "$AUDIT_COMMON" ]]; then pass "P0 audit-tests-common.sh exists"; else fail "P0 audit-tests-common.sh exists" "missing at $AUDIT_COMMON"; fi
case_end

# shellcheck source=bin-audit-tests-embed-cases/fixture-helpers.sh
. "$GROUP_DIR/fixture-helpers.sh"
# shellcheck source=bin-audit-tests-embed-cases/order-cases.sh
. "$GROUP_DIR/order-cases.sh"
# shellcheck source=bin-audit-tests-embed-cases/band-dryrun-cases.sh
. "$GROUP_DIR/band-dryrun-cases.sh"
# shellcheck source=bin-audit-tests-embed-cases/stage1-cases.sh
. "$GROUP_DIR/stage1-cases.sh"
# shellcheck source=bin-audit-tests-embed-cases/symmetry-gc-cases.sh
. "$GROUP_DIR/symmetry-gc-cases.sh"

case_begin "suite-integrity" "bin/lib/test-embed-cases.sh"
ec_suite_integrity "${BASH_SOURCE[0]}"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
