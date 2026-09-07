#!/usr/bin/env bash
# tests/bin-check-on-demand-rules-fixture-git-discipline.sh
# Tests: tests/bin-check-on-demand-rules/fixtures.sh, tests/bin-check-on-demand-rules/cases-staged.sh, tests/bin-check-on-demand-rules.sh
# Tags: rules-injection, on-demand-rules, fixtures, git-discipline, static-check, real-git, positive-control, TL2, scope:common
set -uo pipefail

# WHY (CPR-WPH): every fixture repo is built one way (hooks disabled, identity set,
# template reused), so a case file reaching for `git` itself bypasses that, silently.

# Two substrates (CPR-SC): D1-D12 READ TEXT — spellings a run cannot reach, failing before
# any repo exists. E1-E7/F1-F7 RUN fixtures.sh in child bashes against real git — the
# hooks-disabled guarantee, the one-template-build count, the failure/half-built paths.
# TL3 gap (still open): D2's order check is literal (a dead-branch call satisfies it), and
# indirect calls are pinned at the ASSIGNMENT only, so a `$GIT add` aliased by a caller or
# by `eval` stays invisible; the E block's real git runs only inside this suite's temp tree.
# Closest-to-action mitigation: detail plan Step 4 verification 3, on the real host —
# disable fx_ensure_git by hand and require cases-staged.sh / cases-injection.sh to turn red.

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUITE_DIR="$AGENTS_ROOT/tests/bin-check-on-demand-rules"
DISPATCHER="$AGENTS_ROOT/tests/bin-check-on-demand-rules.sh"
FIXTURES="$SUITE_DIR/fixtures.sh"
TIMEOUT="$AGENTS_ROOT/bin/run-with-timeout.sh"
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin-check-on-demand-rules-fixture-git-discipline"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Fixture isolation (rules/test/fixture-isolation.md): dual-pinned plans dir,
# no inherited session id, neutral CWD.
TMPDIR_BASE=$(mktemp -d)
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export AGENTS_CONFIG_DIR="$AGENTS_ROOT"

WORK="$TMPDIR_BASE/work"
mkdir -p "$WORK"
cd "$TMPDIR_BASE" || exit 1

for _f in "$FIXTURES" "$DISPATCHER"; do
    if [[ ! -f "$_f" ]]; then
        echo "SKIP-BLOCKED: ${_f#"$AGENTS_ROOT/"} missing"
        fail "target missing: ${_f#"$AGENTS_ROOT/"} (the cases below fail for this reason)"
    fi
done

# shellcheck source=./bin-check-on-demand-rules-fixture-git-discipline/scanners.sh
. "$CASE_DIR/scanners.sh"
# shellcheck source=./bin-check-on-demand-rules-fixture-git-discipline/cases-direct-git.sh
. "$CASE_DIR/cases-direct-git.sh"
# shellcheck source=./bin-check-on-demand-rules-fixture-git-discipline/cases-fixture-routing.sh
. "$CASE_DIR/cases-fixture-routing.sh"
# shellcheck source=./bin-check-on-demand-rules-fixture-git-discipline/cases-failure-handling.sh
. "$CASE_DIR/cases-failure-handling.sh"
# shellcheck source=./bin-check-on-demand-rules-fixture-git-discipline/cases-regex-tables.sh
. "$CASE_DIR/cases-regex-tables.sh"
# shellcheck source=./bin-check-on-demand-rules-fixture-git-discipline/cases-regex-tables-fx.sh
. "$CASE_DIR/cases-regex-tables-fx.sh"
# The E/F blocks below RUN fixtures.sh instead of reading it, so they come last: each one
# spawns child bashes that plant a `git` shim on PATH and build real repositories.
# shellcheck source=./bin-check-on-demand-rules-fixture-git-discipline/runner.sh
. "$CASE_DIR/runner.sh"
# shellcheck source=./bin-check-on-demand-rules-fixture-git-discipline/cases-real-git.sh
. "$CASE_DIR/cases-real-git.sh"
# shellcheck source=./bin-check-on-demand-rules-fixture-git-discipline/cases-error-propagation.sh
. "$CASE_DIR/cases-error-propagation.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
