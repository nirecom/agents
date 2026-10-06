#!/usr/bin/env bash
# Tests: bin/lib/test-embed-cases.sh, bin/lib/test-embed-cases/select.sh, bin/lib/test-embed-cases/order.sh, bin/lib/test-embed-cases/stage-plan.sh, bin/lib/test-embed-cases/stage-apply.sh, bin/lib/test-embed-cases/retry-record.sh, bin/lib/test-embed-cases/codex-band-check.sh, bin/audit-tests.sh, bin/audit-tests-common.sh
# Tags: TL2, scope:common, audit-tests, sweep-tests, embed-cases, case-markers, stage-protocol
# Dispatcher for the sweep-tests --embed-cases tool: selection, ordering, band,
# stage 1 plan, stage 3 apply/retry/validation, flag exclusivity, entrypoint
# symmetry and the GC hand-off. Stage 2 (LLM rewrite) is simulated with mock
# output files; codex is a fake binary first on PATH. Cases live in the sibling folder.
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
trap 'chmod -R u+rwX "$EC_TMP" 2>/dev/null; rm -rf "$EC_TMP"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md + detail Steps 7).
mkdir -p "$EC_TMP/home" "$EC_TMP/fakebin"
export HOME="$EC_TMP/home"
export NO_LOG=true
run_all_pin_state_dirs "$EC_TMP/state" || { echo "FATAL: cannot pin state dirs" >&2; exit 1; }
unset CLAUDE_CODE_SESSION_ID
export RUN_ALL_CACHE_DIR="$EC_TMP/run-all-cache"
export SWEEP_TESTS_STATE_DIR="$EC_TMP/sweep-state"
export PATH="$EC_TMP/fakebin:$PATH"

# Completion ledger: every case file's LAST line is `grp_done <its own basename>`.
GRP_DONE=""
grp_done() { GRP_DONE="${GRP_DONE}$1"$'\n'; }

# check_eq <name> <want> <got> — named equality on top of the shared pass/fail.
check_eq() {
  if [[ "$2" == "$3" ]]; then
    pass "$1"
  else
    fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "$3")"
  fi
}

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
# shellcheck source=bin-audit-tests-embed-cases/skip-reason-cases.sh
. "$GROUP_DIR/skip-reason-cases.sh"
# shellcheck source=bin-audit-tests-embed-cases/stage1-cases.sh
. "$GROUP_DIR/stage1-cases.sh"
# shellcheck source=bin-audit-tests-embed-cases/stage3-apply-cases.sh
. "$GROUP_DIR/stage3-apply-cases.sh"
# shellcheck source=bin-audit-tests-embed-cases/stage3-retry-cases.sh
. "$GROUP_DIR/stage3-retry-cases.sh"
# shellcheck source=bin-audit-tests-embed-cases/retry-scope-cases.sh
. "$GROUP_DIR/retry-scope-cases.sh"
# shellcheck source=bin-audit-tests-embed-cases/stage3-validation-cases.sh
. "$GROUP_DIR/stage3-validation-cases.sh"
# shellcheck source=bin-audit-tests-embed-cases/stage3-hardening-cases.sh
. "$GROUP_DIR/stage3-hardening-cases.sh"
# shellcheck source=bin-audit-tests-embed-cases/exclusivity-help-cases.sh
. "$GROUP_DIR/exclusivity-help-cases.sh"
# shellcheck source=bin-audit-tests-embed-cases/symmetry-gc-cases.sh
. "$GROUP_DIR/symmetry-gc-cases.sh"

case_begin "suite-integrity" "bin/lib/test-embed-cases.sh"
# The `. "$GROUP_DIR/…"` lines are the only wiring a case file has; the ledger
# proves each sourced file also reached its last line.
GRP_PRESENT="$(ls -1 "$GROUP_DIR" 2>/dev/null | grep '\.sh$' | sort)"
GRP_SOURCED="$(sed -n 's|^\. "\$GROUP_DIR/\(.*\.sh\)"$|\1|p' "${BASH_SOURCE[0]}" | sort)"
GRP_DONE_SORTED="$(printf '%s' "$GRP_DONE" | sort)"
check_eq "GRP1 every case file is sourced and every sourced case file exists" "$GRP_PRESENT" "$GRP_SOURCED"
check_eq "GRP2 every sourced case file ran through to its completion marker" "$GRP_SOURCED" "$GRP_DONE_SORTED"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
