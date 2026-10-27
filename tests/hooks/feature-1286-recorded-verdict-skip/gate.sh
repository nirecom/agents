#!/bin/bash
# shellcheck shell=bash
# feature-1286 gate cases: hooks/gate-plan-skip-sentinel.js reads
# hasValidSkipJudgment(sid, target) to allow the *_NOT_NEEDED sentinel.
# Relies on helpers.sh being sourced by the dispatcher.

# shellcheck source=../../lib/confirm-env-fixture.sh
. "$_HELPERS_SCRIPT_CHECKOUT_ROOT/tests/lib/confirm-env-fixture.sh"

# Plant a valid record only if the API exists (otherwise it's a no-op; the
# gate is still exercised for its fail-safe/legacy behavior).
plant_record() {
  local sid="$1" target="$2" cond="$3" source="${4:-subagent}"
  api_exists || return 0
  run_with_timeout node -e "
    const r = require('$RESOLVER_N');
    r.recordSkipJudgment('$sid', '$target', $cond, '$source');
  " 2>/dev/null || true
}

assert_allow_gate() {
  local desc="$1" out="$2"
  if echo "$out" | grep -q '"permissionDecision":"allow"'; then pass "$desc"
  else fail "$desc (expected allow, got: $out)"; fi
}

assert_passthrough_gate() {
  local desc="$1" out="$2"
  if [ -z "$out" ] || [ "$out" = "{}" ] || ! echo "$out" | grep -q '"permissionDecision"'; then
    pass "$desc"
  else fail "$desc (expected pass-through, got: $out)"; fi
}

# All gate cases isolate from the repo .env via AGENTS_MAIN_ROOT="$EMPTY_CFG_ROOT"
# so CONFIRM_* reflects only what each case explicitly sets (load-env.js would
# otherwise honor the repo's .env CONFIRM_DETAIL=off / CONFIRM_OUTLINE=off).

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-7: valid outline record → OUTLINE_NOT_NEEDED allowed w/o CONFIRM_OUTLINE ==="
plant_valid_skip "$PLANS_GLOBAL_DIR" "rv7" "outline" "{ so_c1: true, so_c2: true }"
INPUT="$(build_bash_input 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: recorded judgment>>"')"
OUT="$(unset CONFIRM_OUTLINE 2>/dev/null || true
  AGENTS_MAIN_ROOT="$EMPTY_CFG_ROOT" WORKFLOW_STATE_DIR="$WORKFLOW_DIR" WORKFLOW_SESSION_ID="rv7" run_gate "$INPUT")"
assert_allow_gate "RV-7: valid skip_judgment → allow OUTLINE_NOT_NEEDED w/o CONFIRM_OUTLINE" "$OUT"
plant_valid_skip "$PLANS_GLOBAL_DIR" "rv7d" "detail" "{ sd_single_approach: true, sd_no_open_decision: true }" "jev"
INPUT="$(build_bash_input 'echo "<<WORKFLOW_DETAIL_NOT_NEEDED: recorded judgment>>"')"
OUT="$(unset CONFIRM_DETAIL 2>/dev/null || true
  AGENTS_MAIN_ROOT="$EMPTY_CFG_ROOT" WORKFLOW_STATE_DIR="$WORKFLOW_DIR" WORKFLOW_SESSION_ID="rv7d" run_gate "$INPUT")"
assert_allow_gate "RV-7b: valid jev detail record (new keys) → allow DETAIL_NOT_NEEDED w/o CONFIRM_DETAIL" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-38: retired record shapes no longer authorize the sentinel ==="
plant_valid_skip "$PLANS_GLOBAL_DIR" "rv38o" "outline" "{ so_c1: true, so_c2: true }" "orchestrator"
INPUT="$(build_bash_input 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: retired source>>"')"
OUT="$(unset CONFIRM_OUTLINE 2>/dev/null || true
  AGENTS_MAIN_ROOT="$EMPTY_CFG_ROOT" WORKFLOW_STATE_DIR="$WORKFLOW_DIR" WORKFLOW_SESSION_ID="rv38o" run_gate "$INPUT")"
assert_passthrough_gate "RV-38a: source=orchestrator outline record must NOT allow OUTLINE_NOT_NEEDED" "$OUT"
plant_valid_skip "$PLANS_GLOBAL_DIR" "rv38d" "detail" "{ sd_c1: true, sd_c2: true, sd_c3: true }" "jev"
INPUT="$(build_bash_input 'echo "<<WORKFLOW_DETAIL_NOT_NEEDED: retired keys>>"')"
OUT="$(unset CONFIRM_DETAIL 2>/dev/null || true
  AGENTS_MAIN_ROOT="$EMPTY_CFG_ROOT" WORKFLOW_STATE_DIR="$WORKFLOW_DIR" WORKFLOW_SESSION_ID="rv38d" run_gate "$INPUT")"
assert_passthrough_gate "RV-38b: detail record with retired sd_c1..sd_c3 keys must NOT allow DETAIL_NOT_NEEDED" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-8: no record + no CONFIRM_OUTLINE → pass-through (fail-safe) ==="
INPUT="$(build_bash_input 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: no record>>"')"
OUT="$(unset CONFIRM_OUTLINE 2>/dev/null || true
  AGENTS_MAIN_ROOT="$EMPTY_CFG_ROOT" WORKFLOW_STATE_DIR="$WORKFLOW_DIR" WORKFLOW_SESSION_ID="rv8-no-record" run_gate "$INPUT")"
assert_passthrough_gate "RV-8: no record + no CONFIRM_OUTLINE → pass-through" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-9: CONFIRM_OUTLINE=off + no record → allow (legacy path) ==="
INPUT="$(build_bash_input 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: legacy path>>"')"
# The plan-stage flags come from $AGENTS_MAIN_ROOT/.env only (#2729): the off value lives in a
# per-case config file; confirm_env_root runs inside the subshell, so the pin stays local.
OUT="$(confirm_env_root "$TMPDIR_BASE/rv9-cfg" CONFIRM_OUTLINE=off
  WORKFLOW_STATE_DIR="$WORKFLOW_DIR" WORKFLOW_SESSION_ID="rv9-no-record" run_gate "$INPUT")"
assert_allow_gate "RV-9: CONFIRM_OUTLINE=off + no record → allow (legacy preserved)" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-13: gate isolation — record for one stage must not authorize the other ==="
# Valid OUTLINE record + DETAIL sentinel + no CONFIRM_DETAIL → pass-through.
plant_record "rv13o" "outline" "{ so_c1: true, so_c2: true }"
INPUT="$(build_bash_input 'echo "<<WORKFLOW_DETAIL_NOT_NEEDED: cross-stage>>"')"
OUT="$(unset CONFIRM_DETAIL 2>/dev/null || true
  AGENTS_MAIN_ROOT="$EMPTY_CFG_ROOT" WORKFLOW_STATE_DIR="$WORKFLOW_DIR" WORKFLOW_SESSION_ID="rv13o" run_gate "$INPUT")"
assert_passthrough_gate "RV-13a: outline record must NOT allow DETAIL_NOT_NEEDED" "$OUT"
# Valid DETAIL record + OUTLINE sentinel + no CONFIRM_OUTLINE → pass-through.
plant_record "rv13d" "detail" "{ sd_single_approach: true, sd_no_open_decision: true }"
INPUT="$(build_bash_input 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: cross-stage>>"')"
OUT="$(unset CONFIRM_OUTLINE 2>/dev/null || true
  AGENTS_MAIN_ROOT="$EMPTY_CFG_ROOT" WORKFLOW_STATE_DIR="$WORKFLOW_DIR" WORKFLOW_SESSION_ID="rv13d" run_gate "$INPUT")"
assert_passthrough_gate "RV-13b: detail record must NOT allow OUTLINE_NOT_NEEDED" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== RV-17: hook session-id fail-open — no session-id + no CONFIRM_OUTLINE → pass-through ==="
INPUT="$(build_bash_input 'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: no session>>"')"
# WORKFLOW_SESSION_ID absent entirely; must not throw, must pass-through.
OUT="$(unset CONFIRM_OUTLINE WORKFLOW_SESSION_ID 2>/dev/null || true
  AGENTS_MAIN_ROOT="$EMPTY_CFG_ROOT" WORKFLOW_STATE_DIR="$WORKFLOW_DIR" run_gate "$INPUT")"
assert_passthrough_gate "RV-17: no session-id + no CONFIRM_OUTLINE → pass-through (fail-open)" "$OUT"

# RV-32: hardening #5 — with WORKFLOW_SESSION_ID unset, the gate resolves the
# session from the hook input JSON's top-level session_id and allows the sentinel.
echo ""
echo "=== RV-32: hardening #5 — gate resolves session_id from input JSON (not only env) ==="
plant_valid_skip "$PLANS_GLOBAL_DIR" "rv32" "outline" "{ so_c1: true, so_c2: true }"
# Build input JSON with both the sentinel command AND top-level session_id.
RV32_CMD='echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: recorded judgment>>"'
RV32_CMD_ESC="${RV32_CMD//\\/\\\\}"
RV32_CMD_ESC="${RV32_CMD_ESC//\"/\\\"}"
RV32_INPUT="$(printf '{"tool_name":"Bash","session_id":"rv32","tool_input":{"command":"%s"}}' "$RV32_CMD_ESC")"
OUT="$(unset WORKFLOW_SESSION_ID 2>/dev/null || true
  AGENTS_MAIN_ROOT="$EMPTY_CFG_ROOT" WORKFLOW_STATE_DIR="$WORKFLOW_DIR" run_gate "$RV32_INPUT")"
assert_allow_gate "RV-32: gate resolves session_id from input JSON → allow (no WORKFLOW_SESSION_ID env)" "$OUT"
