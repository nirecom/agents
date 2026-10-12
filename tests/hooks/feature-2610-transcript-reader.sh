#!/usr/bin/env bash
# tests/hooks/feature-2610-transcript-reader.sh
# Tests: hooks/lib/transcript-reader.js, hooks/stop-confirm-plan-guard.js, hooks/stop-final-report-guard.js, hooks/supervisor-guard/detect.js, hooks/stop-enforce-worktree-on-warn.js, hooks/stop-exit-worktree-warn.js
# Tags: transcript-reader, stop-hook, late-flush, fail-open, regression-2610, plan-link, final-report, TL2, scope:issue-specific
# #2610: a Stop hook can start before the turn's final assistant line is flushed to the transcript.
# The shared reader waits (50ms steps, 500ms cap) until the last text block matches
# last_assistant_message, and reports "undecidable" when it never does. Every transcript reader
# keeps working on missing, empty and malformed transcripts.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

# TL3 gap (hook-registration): the late flush is simulated by appending the final line while the
# hook runs; a real Stop dispatch racing a real flush is covered only by the RUN_TL3-gated
# tests/hooks/TL3-hook-stop-confirm-plan-guard/main.sh (SCP-E3).
# Closest-to-action mitigation: bin/check-verification-gate.sh category: hook-registration

TR_TMP="$(make_tmp)"
readonly TR_TMP
trap 'rm -rf "$TR_TMP"' EXIT
export WORKFLOW_STATE_DIR="$TR_TMP/workflow-state" WORKFLOW_PLANS_DIR="$TR_TMP/plans"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR" "$TR_TMP/no-transcripts" "$TR_TMP/cases"
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR PLAN_LANG DOCS_LANG_PUBLIC DOCS_LANG_PRIVATE 2>/dev/null || true
export CLAUDE_TRANSCRIPT_BASE_DIR="$TR_TMP/no-transcripts" PLAN_SYNC_REMOTE_URL=""
printf 'PLAN_LANG=english\nPLAN_SYNC_REMOTE_URL=\n' > "$AGENTS_MAIN_ROOT/.env"
cd "$TR_TMP" || exit 1

SUB_DIR="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2610-transcript-reader"
export TR_LIB TC_LIB TR_TDIR TR_SCHEMA_LIB
TR_LIB="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/lib/transcript-reader.js")"
TC_LIB="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/lib/plan-link-turn-check.js")"
TR_SCHEMA_LIB="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/lib/final-report-schema.js")"
TR_TDIR="$(np "$TR_TMP/cases")"
PL_PREFIX='[confirm-plan] plan-link:'
L2_PREFIX='[confirm-plan] Layer 2/follow-up:'

# tr_report <driver-output> — one pass/fail per PASS|name / FAIL|name|detail line.
tr_report() {
  local line rest name
  [ -z "$1" ] && { fail "driver produced no assertions"; return; }
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    rest="${line#*|}"; name="${rest%%|*}"
    case "$line" in
      PASS\|*) pass "$name" ;;
      FAIL\|*) fail "$name" "${rest#*|}" ;;
      *) fail "unparsed driver line" "$line" ;;
    esac
  done <<< "$1"
}

# tr_scene <kind> <sid> [plan-path] — builds a case dir and prints it.
tr_scene() {
  local d="$TR_TMP/cases/$1-$RANDOM$RANDOM"
  run_with_timeout 30 node "$SUB_DIR/sib-fixture.js" "$1" "$(np "$d")" "$2" "${3:-}" >/dev/null 2>&1 || return 1
  printf '%s' "$d"
}

# tr_stop <hook-file> <case-dir> — runs a Stop hook on the scene; when the scene has a late line,
# it is appended 350ms after the hook starts. Sets TR_OUT and TR_RC.
tr_stop() {
  local hook="$SCRIPT_CHECKOUT_ROOT/hooks/$1" d="$2"
  if [ -f "$d/late.jsonl" ]; then
    (sleep 0.35; cat "$d/late.jsonl" >> "$d/t.jsonl") &
  fi
  TR_OUT="$(run_with_timeout 60 node "$hook" < "$d/stdin.json" 2>/dev/null)"
  TR_RC=$?
  wait
}

# tr_expect <label> <allow|block> [reason-prefix]
tr_expect() {
  local label="$1" want="$2" prefix="${3:-}" reason=""
  reason="$(printf '%s' "$TR_OUT" | run_with_timeout 30 node -e '
let o = {}; try { o = JSON.parse(require("fs").readFileSync(0, "utf8") || "{}"); } catch (e) {}
process.stdout.write(o.decision === "block" && typeof o.reason === "string" ? o.reason : "");')"
  if [ "$want" = allow ] && [ "$TR_RC" -eq 0 ] && [ -z "$reason" ]; then pass "$label"
  elif [ "$want" = block ] && [ "$TR_RC" -eq 2 ] && [ -n "$reason" ] && [ "${reason#"$prefix"}" != "$reason" ]; then pass "$label"
  else fail "$label" "want=$want prefix='$prefix' rc=$TR_RC stdout=$TR_OUT"; fi
}

# tr_marker <sid> <stage> <abs-plan-path> — the per-turn marker show-plan-link.js drops.
tr_marker() {
  printf '{"session_id":"%s","absPath":"%s","suffix":"%s","ts":1234567890}\n' "$1" "$(np "$3")" "$2" \
    > "$WORKFLOW_STATE_DIR/$1.confirm-plan-turn-$RANDOM$RANDOM.json"
}

# ══ Unit: hooks/lib/transcript-reader.js ═══════════════════════════════════════
case_begin "reader-late-flush-and-fallbacks" "hooks/lib/transcript-reader.js"
tr_report "$(run_with_timeout 60 node "$SUB_DIR/reader-unit.js" 2>&1 || printf 'FAIL|reader driver|exit=%s\n' "$?")"
case_end

# ══ Sibling 1: Layer 2 of the confirm-plan guard ═════════════════════════════
case_begin "layer2-reads-last-entry" "hooks/stop-confirm-plan-guard.js"
SID_L2="2610aaaa-1111-4222-8333-000000000001"
d="$(tr_scene l2-block "$SID_L2")" || fail "scene l2-block"
tr_stop stop-confirm-plan-guard.js "$d"
tr_expect "L2-1 CONFIRM_OUTLINE without follow-up, final line flushed — Layer 2 block" block "$L2_PREFIX"
d="$(tr_scene l2-late "$SID_L2")" || fail "scene l2-late"
tr_stop stop-confirm-plan-guard.js "$d"
tr_expect "L2-2 CONFIRM_OUTLINE entry flushed late — the reader waits and Layer 2 still blocks" block "$L2_PREFIX"
case_end

# ══ Sibling 2: plan-link check (SCP-E3 repro, plan-sync off) ════════════════════
case_begin "plan-link-late-flush-scp-e3" "hooks/stop-confirm-plan-guard.js"
SID_PL="2610aaaa-1111-4222-8333-000000000002"
PLAN="$WORKFLOW_PLANS_DIR/$SID_PL-intent.md"
printf 'This artifact body is written entirely in English prose here.\n' > "$PLAN"
d="$(tr_scene pl-present "$SID_PL" "$(np "$PLAN")")" || fail "scene pl-present"
tr_marker "$SID_PL" intent "$PLAN"; tr_stop stop-confirm-plan-guard.js "$d"
tr_expect "PL-1 local path in the flushed final text — allow" allow
d="$(tr_scene pl-missing "$SID_PL" "$(np "$PLAN")")" || fail "scene pl-missing"
tr_marker "$SID_PL" intent "$PLAN"; tr_stop stop-confirm-plan-guard.js "$d"
tr_expect "PL-2 neither link nor path in the final text — plan-link block" block "$PL_PREFIX"
d="$(tr_scene pl-late "$SID_PL" "$(np "$PLAN")")" || fail "scene pl-late"
tr_marker "$SID_PL" intent "$PLAN"; tr_stop stop-confirm-plan-guard.js "$d"
tr_expect "PL-3 SCP-E3: the path reply is flushed after the hook starts — allow, not a false block" allow
d="$(tr_scene pl-undecidable "$SID_PL" "$(np "$PLAN")")" || fail "scene pl-undecidable"
tr_marker "$SID_PL" intent "$PLAN"; tr_stop stop-confirm-plan-guard.js "$d"
tr_expect "PL-4 final text never lands (undecidable) — allow" allow
rm -f "$WORKFLOW_STATE_DIR/$SID_PL".confirm-plan-turn-*.json
case_end

# ══ Sibling 3: final-report guard ═════════════════════════════════════════════
case_begin "final-report-reads-final-text" "hooks/stop-final-report-guard.js"
SID_FR="2610aaaa-1111-4222-8333-000000000003"
ENV_FILE="$(run_with_timeout 30 node -e 'process.stdout.write(require(process.argv[1]).controlPath(process.argv[2], "final-report-env.json", { forWrite: true }))' \
  "$(np "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state/state-io/control-dir.js")" "$SID_FR" 2>/dev/null)"
if [ -n "$ENV_FILE" ]; then printf '{}\n' > "$ENV_FILE"; pass "FR env file written"; else fail "FR env file written" "controlPath gave nothing"; fi
d="$(tr_scene fr-present "$SID_FR")" || fail "scene fr-present"
tr_stop stop-final-report-guard.js "$d"
tr_expect "FR-1 full report in the flushed final text — allow" allow
d="$(tr_scene fr-absent "$SID_FR")" || fail "scene fr-absent"
tr_stop stop-final-report-guard.js "$d"
tr_expect "FR-2 no report heading — block" block "[final-report]"
case_end

# ══ Sibling 4: supervisor detectors ═══════════════════════════════════════════
case_begin "supervisor-detectors-regression" "hooks/supervisor-guard/detect.js"
tr_report "$(DETECT_LIB="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/supervisor-guard/detect.js")" \
  run_with_timeout 60 node "$SUB_DIR/detect-unit.js" 2>&1 || printf 'FAIL|detect driver|exit=%s\n' "$?")"
case_end

# tr_advisory <label> <hook-file> <want: warn|quiet> <jsonl-line>... — advisory Stop hooks.
tr_advisory() {
  local label="$1" hook="$2" want="$3" sid="2610aaaa-1111-4222-8333-000000000009" t
  shift 3
  t="$TR_TMP/cases/adv-$RANDOM$RANDOM.jsonl"
  printf '%s\n' "$@" > "$t"
  TR_OUT="$(printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Stop"}' "$sid" "$(np "$t")" \
    | run_with_timeout 60 node "$SCRIPT_CHECKOUT_ROOT/hooks/$hook" 2>/dev/null)"
  TR_RC=$?
  if [ "$TR_RC" -ne 0 ]; then fail "$label" "rc=$TR_RC stdout=$TR_OUT"
  elif [ "$want" = warn ] && printf '%s' "$TR_OUT" | grep -q '"additionalContext"'; then pass "$label"
  elif [ "$want" = quiet ] && [ -z "$TR_OUT" ]; then pass "$label"
  else fail "$label" "want=$want stdout=$TR_OUT"; fi
}
J_USER='{"type":"user","message":{"role":"user","content":"go"}}'
J_BAD='{broken json'
J_OFF='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKTREE_OFF: test reason>>\""}}]}}'
J_ON='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"echo \"<<WORKFLOW_ENFORCE_WORKTREE_ON: test reason>>\""}}]}}'
J_ENTER='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t3","name":"EnterWorktree","input":{}}]}}'
J_EXIT='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t4","name":"ExitWorktree","input":{}}]}}'
J_DONE='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]}}'

# ══ Sibling 5: ENFORCE_WORKTREE_ON advisory ═══════════════════════════════════
case_begin "worktree-on-warn-regression" "hooks/stop-enforce-worktree-on-warn.js"
tr_advisory "W1 OFF without ON, malformed line in between — advisory" stop-enforce-worktree-on-warn.js warn "$J_USER" "$J_OFF" "$J_BAD" "$J_DONE"
tr_advisory "W2 OFF then ON — quiet" stop-enforce-worktree-on-warn.js quiet "$J_USER" "$J_OFF" "$J_BAD" "$J_ON" "$J_DONE"
tr_advisory "W3 no sentinel at all — quiet" stop-enforce-worktree-on-warn.js quiet "$J_USER" "$J_DONE"
case_end

# ══ Sibling 6: ExitWorktree advisory ══════════════════════════════════════════
case_begin "exit-worktree-warn-regression" "hooks/stop-exit-worktree-warn.js"
tr_advisory "X1 EnterWorktree without ExitWorktree, malformed line — advisory" stop-exit-worktree-warn.js warn "$J_USER" "$J_ENTER" "$J_BAD" "$J_DONE"
tr_advisory "X2 EnterWorktree then ExitWorktree — quiet" stop-exit-worktree-warn.js quiet "$J_USER" "$J_ENTER" "$J_BAD" "$J_EXIT" "$J_DONE"
tr_advisory "X3 no worktree tool — quiet" stop-exit-worktree-warn.js quiet "$J_USER" "$J_DONE"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
