#!/bin/bash
# Tests: hooks/lib/workflow-state/completion-approval.js, hooks/lib/workflow-state/effective-state.js, hooks/lib/workflow-state/state-io.js, hooks/workflow-mark/confirm-approval-handler.js, hooks/workflow-mark/reset-handler.js, bin/workflow/next-step, bin/workflow/reconcile-state
# Tags: workflow, next-step, approval-gate, outline, detail, confirm-sentinel, scope:common, pwsh-not-required
#
# TL3 gap (what this test does NOT catch):
# - A real Claude Code session where PostToolUse fires workflow-mark.js and the
#   CONFIRM_OUTLINE/CONFIRM_DETAIL dialog is surfaced by confirm-checkpoint.js.
# - The live next-step consultation triggered by PostCompact / SessionStart hooks.
# These tests spawn the real node subprocesses (next-step, reconcile-state,
# workflow-mark.js) against real on-disk state/plans fixtures (TL2 broad
# integration), but never drive a real `claude -p` turn.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.
#
# Covers #1133 + #1148 (approval gate for outline/detail completion):
#   Completion of the approval-gated steps (outline, detail) must NEVER be
#   persisted without a recorded plan_approvals[step] approval, across ALL write
#   paths (direct markStep, MARK_STEP sentinel, next-step evidence auto-complete,
#   reconcile-state), and the #1148 inconsistency-scan reordering around a
#   read-only effective-state snapshot.
#
# fail-before-fix: the approval invariant, plan_approvals state, completion-approval.js,
# effective-state.js, and confirm-approval-handler.js do NOT exist in the pre-fix
# codebase, so these tests are EXPECTED to fail now. That is correct for this step.

set -uo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEXT_STEP="$AGENTS_DIR/bin/workflow/next-step"
RECONCILE="$AGENTS_DIR/bin/workflow/reconcile-state"
HOOK_MARK="$AGENTS_DIR/hooks/workflow-mark.js"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_DIR="$SCRIPT_DIR/fix-1133-1148-approval-gate"
MK_STATE="$SUB_DIR/mk-state.js"
MK_PAYLOAD="$SUB_DIR/mk-payload.js"

to_node_path() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(to_node_path "$AGENTS_DIR")"
WFSTATE_N="$AGENTS_DIR_N/hooks/lib/workflow-state.js"
COMPLETION_APPROVAL_N="$AGENTS_DIR_N/hooks/lib/workflow-state/completion-approval.js"
EFFECTIVE_STATE_N="$AGENTS_DIR_N/hooks/lib/workflow-state/effective-state.js"

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"
export CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR"
export WORKFLOW_PLANS_DIR="$PLANS_DIR"

# Pin the CONFIRM_* stage gates ON for the whole suite. The developer's ambient
# config may carry CONFIRM_OUTLINE=off / CONFIRM_DETAIL=off, which is a LEGITIMATE
# waiver of the approval gate (evaluateCompletionApproval → source
# "confirm-flag-off") and would silently mask every "must NOT complete without an
# approval record" assertion below.
# The gate decision is resolved from the CONFIG FILE only (isConfirmOffForStageFromFile),
# so process.env exports alone cannot isolate the suite: it must point
# AGENTS_CONFIG_DIR at a scratch config whose contents are known. Both a gates-ON
# and a gates-OFF scratch config are provided; cases that exercise the legitimate
# waiver (G05, G14c/d) select CONFIG_DIR_OFF per invocation.
CONFIG_DIR_ON="$TMPDIR_BASE/config-on"
CONFIG_DIR_OFF="$TMPDIR_BASE/config-off"
mkdir -p "$CONFIG_DIR_ON" "$CONFIG_DIR_OFF"
printf 'CONFIRM_INTENT=on\nCONFIRM_OUTLINE=on\nCONFIRM_DETAIL=on\n' > "$CONFIG_DIR_ON/.env"
printf 'CONFIRM_INTENT=off\nCONFIRM_OUTLINE=off\nCONFIRM_DETAIL=off\n' > "$CONFIG_DIR_OFF/.env"
export AGENTS_CONFIG_DIR="$CONFIG_DIR_ON"
export CONFIRM_OUTLINE=on
export CONFIRM_DETAIL=on

PASS=0
FAIL=0

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    perl -e 'alarm 120; exec @ARGV' -- "$@"
  fi
}

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then echo "PASS: $desc"; PASS=$((PASS + 1));
  else echo "FAIL: $desc -- expected [$expected] got [$actual]"; FAIL=$((FAIL + 1)); fi
}

check_ne() {
  local desc="$1" notexpected="$2" actual="$3"
  if [ "$actual" != "$notexpected" ]; then echo "PASS: $desc"; PASS=$((PASS + 1));
  else echo "FAIL: $desc -- did NOT expect [$notexpected] but got it"; FAIL=$((FAIL + 1)); fi
}

check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then echo "PASS: $desc"; PASS=$((PASS + 1));
  else echo "FAIL: $desc -- expected [$needle] in: $haystack"; FAIL=$((FAIL + 1)); fi
}

check_nonzero() {
  local desc="$1" rc="$2"
  if [ "$rc" -ne 0 ]; then echo "PASS: $desc"; PASS=$((PASS + 1));
  else echo "FAIL: $desc -- expected nonzero exit, got 0"; FAIL=$((FAIL + 1)); fi
}

check_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo "FAIL: $desc -- did NOT expect [$needle] in: $haystack"; FAIL=$((FAIL + 1));
  else echo "PASS: $desc"; PASS=$((PASS + 1)); fi
}

# node_probe '<js>' [argv...] : run node -e with workflow env; prints NOERROR or
# THREW:<code> depending on how the js body reports. Body receives the barrel path
# as process.argv[1] when WFSTATE_N is passed. stderr merged; never fails the shell.
node_probe() {
  local code="$1"; shift
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" WORKFLOW_PLANS_DIR="$PLANS_DIR" \
    run_with_timeout node -e "$code" "$@" 2>&1 || true
}

# setup_repo : create a throwaway git repo with one commit; echoes its path.
# Used by the #1148 docs-evidence ordering case (group 07).
setup_repo() {
  local repo="$TMPDIR_BASE/repo-$RANDOM"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config core.hooksPath /dev/null
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q --no-verify -m "initial"
  echo "$repo"
}

# gen_state <overrides-json> [workflow_type] [extra-json] → full state JSON on stdout
# NB: avoid ${3:-{}} — bash mis-parses the brace default and appends a stray '}'.
gen_state() {
  local wt="${2:-wf-code}"
  local extra="${3:-}"
  [ -n "$extra" ] || extra='{}'
  run_with_timeout node "$MK_STATE" "$1" "$wt" "$extra"
}

write_state() {
  local sid="$1" json="$2"
  printf '%s' "$json" > "$WORKFLOW_DIR/${sid}.json"
}

read_state_status() {
  local sid="$1" step="$2"
  local f="$WORKFLOW_DIR/${sid}.json"
  [ -f "$f" ] || { echo "MISSING"; return; }
  node -e "try{const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));const st=s.steps&&s.steps[process.argv[2]];console.log(st&&st.status?st.status:'MISSING');}catch(e){console.log('ERR');}" "$f" "$step" 2>/dev/null || echo "ERR"
}

# read_approval_source <sid> <step> → plan_approvals[step].source or "MISSING"
read_approval_source() {
  local sid="$1" step="$2"
  local f="$WORKFLOW_DIR/${sid}.json"
  [ -f "$f" ] || { echo "MISSING"; return; }
  node -e "try{const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));const a=s.plan_approvals&&s.plan_approvals[process.argv[2]];console.log(a&&a.source?a.source:'MISSING');}catch(e){console.log('ERR');}" "$f" "$step" 2>/dev/null || echo "ERR"
}

# has_approval <sid> <step> → "yes" | "no"
has_approval() {
  local sid="$1" step="$2"
  local f="$WORKFLOW_DIR/${sid}.json"
  [ -f "$f" ] || { echo "no"; return; }
  node -e "try{const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));console.log(s.plan_approvals&&s.plan_approvals[process.argv[2]]?'yes':'no');}catch(e){console.log('no');}" "$f" "$step" 2>/dev/null || echo "no"
}

# run_next_step: KEY=value lines on stdout (always exits 0 in verdict mode)
run_next_step() {
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" WORKFLOW_PLANS_DIR="$PLANS_DIR" \
    run_with_timeout node "$NEXT_STEP" "$@" 2>/dev/null || true
}

# run_next_step_rc: capture exit code + stderr → globals RC, STDERR
run_next_step_rc() {
  local err_file="$TMPDIR_BASE/stderr.$RANDOM"
  set +e
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" WORKFLOW_PLANS_DIR="$PLANS_DIR" \
    run_with_timeout node "$NEXT_STEP" "$@" >/dev/null 2>"$err_file"
  RC=$?
  set -e 2>/dev/null || true
  STDERR="$(cat "$err_file" 2>/dev/null || true)"
  rm -f "$err_file"
}

# run_reconcile: capture stdout+stderr → global RECONCILE_OUT
run_reconcile() {
  local out_file="$TMPDIR_BASE/reconcile.$RANDOM"
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" WORKFLOW_PLANS_DIR="$PLANS_DIR" \
    run_with_timeout node "$RECONCILE" "$@" >"$out_file" 2>&1 || true
  RECONCILE_OUT="$(cat "$out_file" 2>/dev/null || true)"
  rm -f "$out_file"
}

# run_mark <command> <sid>: feed a PostToolUse payload to workflow-mark.js → global MARK_OUT
run_mark() {
  local command="$1" sid="$2"
  local payload_file="$TMPDIR_BASE/payload.$RANDOM"
  run_with_timeout node "$MK_PAYLOAD" "$command" "$sid" > "$payload_file"
  MARK_OUT="$(CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" WORKFLOW_PLANS_DIR="$PLANS_DIR" \
    run_with_timeout node "$HOOK_MARK" < "$payload_file" 2>&1 || true)"
  rm -f "$payload_file"
}

# ---------------------------------------------------------------------------
# Source case-group files
# ---------------------------------------------------------------------------
. "$SUB_DIR/01-invariant-all-callsites.sh"
. "$SUB_DIR/02-window1-review-not-started.sh"
. "$SUB_DIR/03-window2-review-unapproved.sh"
. "$SUB_DIR/04-approved-happy-path.sh"
. "$SUB_DIR/05-confirm-off-path.sh"
. "$SUB_DIR/06-sanctioned-passthrough.sh"
. "$SUB_DIR/07-order-1148.sh"
. "$SUB_DIR/08-non-gated-steps-unaffected.sh"
. "$SUB_DIR/10-approval-invalidation-c2.sh"
. "$SUB_DIR/11-chain-command-order-c3.sh"
. "$SUB_DIR/12-mark-cli-fail-closed-c4.sh"
. "$SUB_DIR/13-wf-meta-c5.sh"
. "$SUB_DIR/14-f1-env-file-only-gate.sh"
. "$SUB_DIR/15-f2-session-inherit-approval.sh"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
exit "$FAIL"
