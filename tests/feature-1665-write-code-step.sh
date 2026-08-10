#!/usr/bin/env bash
# Tests: hooks/workflow-state/state-io/core.js, hooks/workflow-state/state-io/migrations/v2-to-v3.js, hooks/workflow-state/effective-state.js, bin/workflow/lib/next-step/steps.js, bin/workflow/lib/next-step/verdict.js, bin/workflow/next-step, hooks/workflow-gate.js, hooks/workflow-mark/reset-handler.js
# Tags: TL1, TL2, workflow, write-code, next-step, workflow-gate, wf-meta, scope:issue-specific, pwsh-not-required
#
# #1665 commit 1 — write_code as a first-class workflow step.
#
# Background: /write-code has always been invoked by hand because write_code is
# absent from VALID_STEPS, so nothing tracks whether the implementation was
# actually written between review_tests and run_tests. This suite pins the
# vocabulary insertion and every consumer that walks it by array position.
#
# Dispatcher: shared helpers/fixtures live in feature-1665-write-code-step/common.sh;
# case groups live in a-vocabulary.sh .. e-commit-gate.sh.
#
# TL3 gap (what this test does NOT catch):
# - Whether Claude Code's live PreToolUse dispatch actually routes a real
#   `git commit` Bash call into hooks/workflow-gate.js (registration only).
# - Whether skills/write-code/SKILL.md emits the write_code MARK_STEP sentinels
#   when the model reaches its completion step in a real session.
# - Whether the permission layer auto-approves the write_code sentinel literals.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
AGENTS_DIR="$(cd "$AGENTS_DIR" && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"

# Derived from this file's own location so a worktree run tests the worktree's
# sources rather than the deployed $AGENTS_CONFIG_DIR copy.
NEXT_STEP_N="$AGENTS_DIR_N/bin/workflow/next-step"
WORKFLOW_MARK_N="$AGENTS_DIR_N/hooks/workflow-mark.js"
GATE_HOOK_N="$AGENTS_DIR_N/hooks/workflow-gate.js"
WFSTATE_MODULE="$AGENTS_DIR_N/hooks/workflow-state"
STEPS_MODULE="$AGENTS_DIR_N/bin/workflow/lib/next-step/steps.js"
# Reused read-only fixture-state probe (CPR-SSOT: one reader for all suites).
PROBE_N="$AGENTS_DIR_N/tests/feature-1644-advance-transaction/state-probe.js"
export WFSTATE_MODULE STEPS_MODULE

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

WORKFLOW_DIR="$TMPDIR_BASE/wf"
PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"
# Dual-pin (#1799): pinning only one of the pair lets supervisor-emit append to
# the developer's real ~/.workflow-plans/.
export CLAUDE_WORKFLOW_DIR="$(nrm "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

# Empty agents config: keeps get-config-var reads deterministic and makes
# isAgentsSessionRepo() treat the fixture repo as the session repo.
CONFIG_EMPTY="$TMPDIR_BASE/cfg-empty"
mkdir -p "$CONFIG_EMPTY"
: > "$CONFIG_EMPTY/.env"
export AGENTS_CONFIG_DIR="$(nrm "$CONFIG_EMPTY")"

# Fixture repo for the commit gate: one staged non-docs file, nothing unstaged
# (Gate 1) and no staged tests/ (review_tests token path stays silent).
GATE_REPO="$TMPDIR_BASE/repo-gate"
mkdir -p "$GATE_REPO/hooks"
git init -q "$GATE_REPO" >/dev/null 2>&1
git -C "$GATE_REPO" config core.hooksPath /dev/null
git -C "$GATE_REPO" config user.email "test@example.com"
git -C "$GATE_REPO" config user.name "test"
printf '// code\n' > "$GATE_REPO/hooks/thing.js"
git -C "$GATE_REPO" add hooks/thing.js >/dev/null 2>&1
GATE_REPO_N="$(nrm "$GATE_REPO")"
export CLAUDE_PROJECT_DIR="$GATE_REPO_N"

# Neutral CWD: hooks that call `git rev-parse` must not resolve the real repo.
cd "$TMPDIR_BASE" || exit 1

SCRIPT_DIR="$AGENTS_DIR/tests/feature-1665-write-code-step"

# shellcheck source=./feature-1665-write-code-step/common.sh
. "$SCRIPT_DIR/common.sh"
# shellcheck source=./feature-1665-write-code-step/a-vocabulary.sh
. "$SCRIPT_DIR/a-vocabulary.sh"
# shellcheck source=./feature-1665-write-code-step/b-list-reset.sh
. "$SCRIPT_DIR/b-list-reset.sh"
# shellcheck source=./feature-1665-write-code-step/c-legacy-state.sh
. "$SCRIPT_DIR/c-legacy-state.sh"
# shellcheck source=./feature-1665-write-code-step/d-wf-meta.sh
. "$SCRIPT_DIR/d-wf-meta.sh"
# shellcheck source=./feature-1665-write-code-step/e-commit-gate.sh
. "$SCRIPT_DIR/e-commit-gate.sh"
# shellcheck source=./feature-1665-write-code-step/f-v2-to-v3.sh
. "$SCRIPT_DIR/f-v2-to-v3.sh"

echo "=== A: step vocabulary (TL1) ==="
run_vocabulary_tests
echo ""
echo "=== B: --list + RESET_FROM (TL2) ==="
run_list_reset_tests
echo ""
echo "=== C: legacy state recovery hint (TL2) ==="
run_legacy_state_tests
echo ""
echo "=== D: wf-meta auto-skip / wf-code control (TL2) ==="
run_wf_meta_tests
echo ""
echo "=== E: commit gate (TL2) ==="
run_commit_gate_tests
echo ""
echo "=== F: v2 -> v3 state migration (TL2) ==="
run_v2_to_v3_tests

echo ""
echo "Total: $PASS passed, $FAIL failed"
exit "$FAIL"
