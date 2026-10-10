# shellcheck shell=bash
# tests/bin/feat-2490-next-step-gate/common.sh
# Tests: bin/workflow/next-step
# Tags: tl2, workflow, confirm-gate, scope:common
#
# Shared fixture for the #2490 suites (value-line.sh, gate-mode.sh). Sourced only;
# the caller sets SCRIPT_CHECKOUT_ROOT first. Owns the isolation contract once: dual-pinned
# state/plans dirs, unset session ids, a neutral non-git CWD, a fixture settings root,
# and every CONFIRM_* gate pinned explicitly so the developer's .env never leaks in.

# shellcheck source=../../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

GT_BASE="$(make_tmp)"
trap 'cd /; rm -rf "$GT_BASE"' EXIT
harness_isolate "$GT_BASE"
WORKFLOW_STATE_DIR="$(np "$GT_BASE/workflow-state")"; export WORKFLOW_STATE_DIR
WORKFLOW_PLANS_DIR="$(np "$GT_BASE/plans")"; export WORKFLOW_PLANS_DIR
PLANS="$GT_BASE/plans"
mkdir -p "$GT_BASE/transcripts" "$GT_BASE/cwd"
CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$GT_BASE/transcripts")"; export CLAUDE_TRANSCRIPT_BASE_DIR
unset CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID

# Reuse the bin-workflow-next-step helpers (write_state / run_next_step / check).
# Sourced AFTER the harness: it re-zeroes PASS/FAIL (nothing counted yet) and
# replaces the harness run_with_timeout with the argv-only form run_next_step expects.
NEXT_STEP_AGENTS_DIR="$SCRIPT_CHECKOUT_ROOT"
TMPDIR_WT="$GT_BASE/workflow-state"
# shellcheck source=../bin-workflow-next-step/common.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/bin-workflow-next-step/common.sh"

# Fixture settings root: only its .env is read. next-step finds confirm-off, get-config-var
# and the scope-change detector beside itself, so a case that needs one of them broken or
# stubbed builds a tree with mk_tree and runs that tree's next-step with run_next_step_in.
CFG="$GT_BASE/cfg"; mkdir -p "$CFG"; : > "$CFG/.env"
export AGENTS_MAIN_ROOT="$(np "$CFG")"
# shellcheck source=../../lib/script-checkout-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"
mk_tree() {
  script_checkout_fixture_copy "$1" bin/workflow hooks bin/confirm-off bin/get-config-var bin/detect-scope-change.sh
  : > "$1/.env"
}
run_next_step_in() { # <tree> <next-step args...>
  local t; t="$(np "$1")"; shift
  AGENTS_MAIN_ROOT="$t" run_with_timeout node "$t/bin/workflow/next-step" "$@"
}

GATE_KEYS="CONFIRM_INTENT CONFIRM_OUTLINE CONFIRM_DETAIL CONFIRM_TESTS CONFIRM_CODE CONFIRM_DOCS CONFIRM_WORKTREE"
pin_confirm() { local k; for k in $GATE_KEYS; do export "$k=$1"; done; }
pin_confirm on
GATE_STEPS="clarify_intent outline detail write_tests write_code docs branching_complete"
gate_key_of() {
  case "$1" in
    clarify_intent) echo CONFIRM_INTENT ;; outline) echo CONFIRM_OUTLINE ;;
    detail) echo CONFIRM_DETAIL ;; write_tests) echo CONFIRM_TESTS ;;
    write_code) echo CONFIRM_CODE ;; docs) echo CONFIRM_DOCS ;;
    branching_complete) echo CONFIRM_WORKTREE ;; *) echo "" ;;
  esac
}

cd "$GT_BASE/cwd" || exit 1

# json_at <step>: every step before <step> complete, <step> and later pending.
GT_STEPS="workflow_init clarify_intent research outline detail branching_complete write_tests review_tests write_code run_tests review_security docs review_docs user_verification cleanup pre_final_report_gate"
json_at() {
  local cur="$1" st="complete" s body=""
  for s in $GT_STEPS; do
    [ "$s" = "$cur" ] && st="pending"
    body="$body\"$s\":{\"status\":\"$st\"},"
  done
  printf '{"steps":{%s},"closes_issues":[2490]}' "${body%,}"
}
# put_plan <sid> <kind> <text>: <PLANS>/<sid>-<kind>.md
put_plan() { printf '%s\n' "$3" > "$PLANS/$1-$2.md"; }
INTENT_FULL="Design a new confirm gate subsystem across several modules."

OUT=""; RC=0
ns() { RC=0; OUT="$(run_next_step "$@" 2>/dev/null)" || RC=$?; }
val() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -n 1; }
unq() { local v="$1"; v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"; printf '%s' "$v"; }
count_re() { printf '%s\n' "$1" | grep -cE -- "$2" || true; }
last_line() { printf '%s\n' "$1" | tail -n 1; }

gt_finish() {
  echo ""
  echo "Total: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
  exit $?
}
