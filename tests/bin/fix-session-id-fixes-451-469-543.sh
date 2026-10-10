#!/bin/bash
# tests/bin/fix-session-id-fixes-451-469-543.sh
# Tests: bin/github-issues/wip-state.sh, bin/github-issues/wip-set-single.sh, bin/workflow/workflow-init-driver, hooks/workflow-state/state-io.js, skills/clarify-intent/SKILL.md, skills/workflow-init/SKILL.md
# Tags: session-id, wip-state, cleanup-zombies, scope:issue-specific
# #451 SKILL.md session-id recovery hint; #469 cleanupZombies deletes stale off-markers;
# #543 wip-state CLIs accept and propagate --session-id.
# Dispatcher only: helpers + sourcing of fix-session-id-fixes-451-469-543/ sub-files.

set -u

# isolation (#2512): pin state and plans dirs once for this file
_ISOLATION_TMP_ROOT="$(mktemp -d)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WIP_STATE="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/wip-state.sh"
WIP_SET_SINGLE="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/wip-set-single.sh"
WIP_SET_RESUME="$SCRIPT_CHECKOUT_ROOT/skills/workflow-init/scripts/wip-set-resume.sh"
AGG_WIP_CHECK="$SCRIPT_CHECKOUT_ROOT/skills/workflow-init/scripts/aggregate-wip-check.sh"
DRIVER="$SCRIPT_CHECKOUT_ROOT/bin/workflow/workflow-init-driver"
STATE_IO_JS="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state/state-io.js"
CLARIFY_SKILL="$SCRIPT_CHECKOUT_ROOT/skills/clarify-intent/SKILL.md"
WI_SKILL="$SCRIPT_CHECKOUT_ROOT/skills/workflow-init/SKILL.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")/fix-session-id-fixes-451-469-543"
# shellcheck source=../lib/script-checkout-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"

# shellcheck source=./fix-session-id-fixes-451-469-543/skill-hints-451.sh
. "$SCRIPT_DIR/skill-hints-451.sh"
# shellcheck source=./fix-session-id-fixes-451-469-543/cleanup-zombies-469.sh
. "$SCRIPT_DIR/cleanup-zombies-469.sh"
# shellcheck source=./fix-session-id-fixes-451-469-543/wip-session-id-543.sh
. "$SCRIPT_DIR/wip-session-id-543.sh"
# shellcheck source=./fix-session-id-fixes-451-469-543/wip-resume-check-543.sh
. "$SCRIPT_DIR/wip-resume-check-543.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
