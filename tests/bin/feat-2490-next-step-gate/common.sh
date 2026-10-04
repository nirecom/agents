# shellcheck shell=bash
# tests/bin/feat-2490-next-step-gate/common.sh
# Tests: bin/workflow/next-step
# Tags: tl2, workflow, confirm-gate, scope:common
#
# Shared fixture for the #2490 suites (value-line.sh, gate-mode.sh). Sourced only;
# the caller sets AGENTS_DIR first. Owns the isolation contract once: dual-pinned
# state/plans dirs, unset session ids, a neutral non-git CWD, a fixture config dir,
# and every CONFIRM_* gate pinned explicitly so the developer's .env never leaks in.

# shellcheck source=../../lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"
command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

GT_BASE="$(make_tmp)"
trap 'cd /; rm -rf "$GT_BASE"' EXIT
harness_isolate "$GT_BASE"
CLAUDE_WORKFLOW_DIR="$(np "$GT_BASE/workflow-state")"; export CLAUDE_WORKFLOW_DIR
WORKFLOW_PLANS_DIR="$(np "$GT_BASE/plans")"; export WORKFLOW_PLANS_DIR
PLANS="$GT_BASE/plans"
mkdir -p "$GT_BASE/transcripts" "$GT_BASE/cwd"
CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$GT_BASE/transcripts")"; export CLAUDE_TRANSCRIPT_BASE_DIR
unset CLAUDE_PROJECT_DIR CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE

# Reuse the bin-workflow-next-step helpers (write_state / run_next_step / check).
# Sourced AFTER the harness: it re-zeroes PASS/FAIL (nothing counted yet) and
# replaces the harness run_with_timeout with the argv-only form run_next_step expects.
NEXT_STEP_AGENTS_DIR="$AGENTS_DIR"
TMPDIR_WT="$GT_BASE/workflow-state"
# shellcheck source=../bin-workflow-next-step/common.sh
. "$AGENTS_DIR/tests/bin/bin-workflow-next-step/common.sh"

# Fixture config dir, same copy set as feature-2102-session-facts/values.sh mk_cfg,
# plus the relocated scope-change detector when it exists.
mk_cfg() {
  local d="$1" f
  mkdir -p "$d/bin" "$d/hooks/lib"
  cp "$AGENTS_DIR/bin/get-config-var" "$AGENTS_DIR/bin/confirm-off" "$d/bin/"
  for f in load-env local-env agents-config-dir path-normalize; do
    cp "$AGENTS_DIR/hooks/lib/$f.js" "$d/hooks/lib/"
  done
  if [ -f "$AGENTS_DIR/bin/detect-scope-change.sh" ]; then
    cp "$AGENTS_DIR/bin/detect-scope-change.sh" "$d/bin/"
  fi
  : > "$d/.env"
}
CFG="$GT_BASE/cfg"; mk_cfg "$CFG"
AGENTS_CONFIG_DIR="$(np "$CFG")"; export AGENTS_CONFIG_DIR

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
