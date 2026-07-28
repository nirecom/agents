# shellcheck shell=bash
# Tests: hooks/lib/plan-confirm-flag.js, hooks/lib/load-env.js, hooks/workflow-state/completion-approval.js, bin/workflow/next-step
# Tags: workflow, approval-gate, outline, detail, confirm-flag, security, scope:common
# (Sourced fragment of tests/fix-1133-1148-approval-gate.sh — not run standalone.)
# ===========================================================================
# G14 (F1): the CONFIRM_<STAGE>=off waiver is resolved from the .env FILE only.
# bin/workflow/next-step is spawnable by the Bash tool, so an inline
# `CONFIRM_OUTLINE=off node bin/workflow/next-step ...` prefix is attacker/model
# controlled. evaluateCompletionApproval must therefore consult
# isConfirmOffForStageFromFile (parsed .env contents) and NEVER process.env.
# fail-before-fix: the pre-fix gate called isConfirmOffForStage (process.env), so
# the inline prefix below waived the gate and minted a confirm-flag-off record.
# Both gated members (outline AND detail) are exercised — CPR-5.
# ===========================================================================

echo ""
echo "=== G14 (F1): CONFIRM_<STAGE>=off waiver comes from the .env file, not process.env ==="

# mark_probe <config-dir> <CONFIRM_OUTLINE> <CONFIRM_DETAIL> <sid> <step>
# Calls markStep(<sid>, <step>, "complete") in a child node process with the
# given process.env CONFIRM_* values. Prints NOERROR or THREW:<code>.
mark_probe() {
  local cfg="$1" co="$2" cd_="$3" sid="$4" step="$5"
  CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" WORKFLOW_PLANS_DIR="$PLANS_DIR" \
    AGENTS_CONFIG_DIR="$cfg" CONFIRM_OUTLINE="$co" CONFIRM_DETAIL="$cd_" \
    run_with_timeout node -e '
      const { markStep } = require(process.argv[1]);
      try { markStep(process.argv[2], process.argv[3], "complete"); console.log("NOERROR"); }
      catch (e) { console.log("THREW:" + (e.code || e.name)); }
    ' "$WFSTATE_N" "$sid" "$step" 2>&1 || true
}

# --- G14a/b: process.env-only "off" must NOT waive the gate (config file says on)

SID="g14a-$$"
write_state "$SID" "$(gen_state '{"workflow_init":"complete","clarify_intent":"complete","research":"complete"}')"
touch "$PLANS_DIR/${SID}-outline.md"

CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" WORKFLOW_PLANS_DIR="$PLANS_DIR" \
  AGENTS_CONFIG_DIR="$CONFIG_DIR_ON" CONFIRM_OUTLINE=off \
  run_with_timeout node "$NEXT_STEP" --session "$SID" >/dev/null 2>&1 || true

check "G14a. inline process.env CONFIRM_OUTLINE=off does NOT complete outline" \
  "pending" "$(read_state_status "$SID" outline)"
check "G14a2. no confirm-flag-off record minted from process.env" \
  "no" "$(has_approval "$SID" outline)"

SID_D="g14b-$$"
write_state "$SID_D" "$(gen_state '{"workflow_init":"complete","clarify_intent":"complete","research":"complete","outline":"complete"}' wf-code '{"plan_approvals":{"outline":{"source":"reset-sentinel","artifact_sha256":null,"artifact_hash_status":"not-applicable"}}}')"

OUT="$(mark_probe "$CONFIG_DIR_ON" on off "$SID_D" detail)"
check_contains "G14b. inline process.env CONFIRM_DETAIL=off still throws on detail completion" \
  "THREW:no-approval-record" "$OUT"
check "G14b2. detail not persisted complete by the refused markStep" \
  "pending" "$(read_state_status "$SID_D" detail)"

# --- G14c/d: positive control — .env FILE contents off DO waive the gate,
#     even when process.env says the opposite ("on"). Proves the decision is
#     sourced from the file, not merely that process.env is ignored when unset.

SID_C="g14c-$$"
write_state "$SID_C" "$(gen_state '{"workflow_init":"complete","clarify_intent":"complete","research":"complete"}')"
touch "$PLANS_DIR/${SID_C}-outline.md"

CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" WORKFLOW_PLANS_DIR="$PLANS_DIR" \
  AGENTS_CONFIG_DIR="$CONFIG_DIR_OFF" CONFIRM_OUTLINE=on \
  run_with_timeout node "$NEXT_STEP" --session "$SID_C" >/dev/null 2>&1 || true

check "G14c. config-file CONFIRM_OUTLINE=off waives the gate (outline completes)" \
  "complete" "$(read_state_status "$SID_C" outline)"
check "G14c2. waiver is stamped as a confirm-flag-off audit record" \
  "confirm-flag-off" "$(read_approval_source "$SID_C" outline)"

SID_CD="g14d-$$"
write_state "$SID_CD" "$(gen_state '{"workflow_init":"complete","clarify_intent":"complete","research":"complete","outline":"complete"}' wf-code '{"plan_approvals":{"outline":{"source":"reset-sentinel","artifact_sha256":null,"artifact_hash_status":"not-applicable"}}}')"

OUT_CD="$(mark_probe "$CONFIG_DIR_OFF" on on "$SID_CD" detail)"
check "G14d. config-file CONFIRM_DETAIL=off waives the detail gate (no throw)" \
  "NOERROR" "$OUT_CD"
check "G14d2. detail persisted complete under the file-sourced waiver" \
  "complete" "$(read_state_status "$SID_CD" detail)"
