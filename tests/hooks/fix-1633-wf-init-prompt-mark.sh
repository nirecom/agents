#!/usr/bin/env bash
# fix-1633-wf-init-prompt-mark.sh
# Tests: hooks/user-prompt-submit-wf-init-mark.js, hooks/lib/wf-init-begun-mark.js, hooks/lib/step-in-flight-policy.js, settings.json
# Tags: workflow, userpromptsubmit, wf-init, step-in-flight, hook-registration, regression-1633, scope:issue-specific, pwsh-not-required, TL2
# fix-1633 (TL2): a typed /workflow-init never becomes a Skill tool call, so the
# UserPromptSubmit hook records the WF-begun mark (workflow_init in_progress).

# TL3 gap: synthetic stdin here; only a real session proves Claude Code fires
# UserPromptSubmit with the typed slash command in the `prompt` field shape used below.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT"
unset CLAUDE_CODE_SESSION_ID
# Prevent MSYS2/Git Bash from rewriting PROMPT values that start with / to Windows paths.
export MSYS2_ENV_CONV_EXCL=PROMPT
mkdir -p "$TMP_ROOT/transcripts"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMP_ROOT/transcripts"

node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
ROOT_NODE="$(node_path "$SCRIPT_CHECKOUT_ROOT")"
HOOK="$SCRIPT_CHECKOUT_ROOT/hooks/user-prompt-submit-wf-init-mark.js"
POSTUSE_HOOK="$SCRIPT_CHECKOUT_ROOT/hooks/postuse-step-in-flight-mark.js"
POLICY="$SCRIPT_CHECKOUT_ROOT/hooks/lib/step-in-flight-policy.js"
STATEIO_NODE="$ROOT_NODE/hooks/workflow-state/state-io.js"
LIFECYCLE_NODE="$ROOT_NODE/hooks/workflow-state/lifecycle.js"
POLICY_NODE="$ROOT_NODE/hooks/lib/step-in-flight-policy.js"
SETTINGS="$SCRIPT_CHECKOUT_ROOT/settings.json"
STATE_DIR="$WORKFLOW_STATE_DIR"

# run_prompt <sid> <prompt> — drive the hook with a UserPromptSubmit payload; sets HK_OUT/HK_RC.
run_prompt() {
  HK_OUT="$(SID="$1" PROMPT="$2" bash "$RWT" 15 node -e "
process.stdout.write(JSON.stringify({ hook_event_name: 'UserPromptSubmit', session_id: process.env.SID,
  transcript_path: '', prompt: process.env.PROMPT }));" \
    | bash "$RWT" 20 node "$(node_path "$HOOK")" 2>/dev/null)"
  HK_RC=$?
}

# run_raw <stdin> — the hook against an arbitrary stdin; sets HK_OUT/HK_RC.
run_raw() {
  HK_OUT="$(printf '%s' "$1" | bash "$RWT" 20 node "$(node_path "$HOOK")" 2>/dev/null)"
  HK_RC=$?
}

seed_initial() {
  SID="$1" bash "$RWT" 15 node -e "require('$STATEIO_NODE').updateTopLevel(process.env.SID, () => {});" >/dev/null 2>&1
}
seed_init_complete() {
  SID="$1" bash "$RWT" 15 node -e "require('$STATEIO_NODE').markStep(process.env.SID, 'workflow_init', 'complete');" >/dev/null 2>&1
}

# wi_view <sid> — "<status>|<last workflow_init origin>|<isLookaheadOnlyInFlight>|<event count>".
wi_view() {
  SID="$1" bash "$RWT" 15 node -e "
const L = require('$LIFECYCLE_NODE');
const s = require('$STATEIO_NODE').readState(process.env.SID);
if (!s) { process.stdout.write('<no-state>'); process.exit(0); }
const evs = (s.events || []).filter((e) => e && e.kind === 'step_status' && e.step === 'workflow_init');
const last = evs.length ? String(evs[evs.length - 1].origin) : '<no-event>';
const st = ((s.steps || {}).workflow_init || {}).status || '<absent>';
process.stdout.write(st + '|' + last + '|' + L.isLookaheadOnlyInFlight(process.env.SID, 'workflow_init') + '|' + (s.events || []).length);" 2>/dev/null
}

expect_marked() {
  local label="$1" sid="$2" view
  view="$(wi_view "$sid")"
  case "$HK_RC|$HK_OUT|$view" in
    "0|{}|in_progress|postuse-in-flight|true|"*) pass "$label" ;;
    *) fail "$label" "rc=$HK_RC out='$HK_OUT' view='$view'" ;;
  esac
}

expect_same() {
  local label="$1" before="$2" after="$3"
  if [ "$HK_RC" -eq 0 ] && [ "$HK_OUT" = "{}" ] && [ "$before" = "$after" ]; then
    pass "$label"
  else
    fail "$label" "rc=$HK_RC out='$HK_OUT' '$before' -> '$after'"
  fi
}

echo "=== fix-1633: UserPromptSubmit WF-begun mark ==="

case_begin "wrapped-command-name-marks" "hooks/user-prompt-submit-wf-init-mark.js"
seed_initial p1
run_prompt p1 "$(printf '<command-message>workflow-init</command-message>\n<command-name>/workflow-init</command-name>\n<command-args></command-args>')"
expect_marked "<command-name>/workflow-init</command-name> marks workflow_init in_progress (postuse-in-flight)" p1
case_end

case_begin "bare-first-line-wf-init-marks" "hooks/user-prompt-submit-wf-init-mark.js"
seed_initial p2
run_prompt p2 "$(printf '/wf-init\nplease start')"
expect_marked "first line '/wf-init' marks workflow_init the same way" p2
case_end

case_begin "bare-namespaced-marks" "hooks/user-prompt-submit-wf-init-mark.js"
seed_initial p3
run_prompt p3 "/agents:workflow-init"
expect_marked "first line '/agents:workflow-init' (namespaced) marks workflow_init the same way" p3
case_end

case_begin "no-state-creates-mark" "hooks/user-prompt-submit-wf-init-mark.js"
run_prompt p3b "/workflow-init"
expect_marked "'/workflow-init' with no state file creates one with workflow_init in_progress" p3b
case_end

case_begin "non-invocations-do-nothing" "hooks/lib/step-in-flight-policy.js"
for pair in "p4a|$(printf 'see below\n/workflow-init')" "p4b|/workflow-init-foo" "p4c|$(printf '<command-name>/workflow-init-foo</command-name>')" "p4d|please run workflow-init"; do
  sid="${pair%%|*}"; prompt="${pair#*|}"
  seed_initial "$sid"
  before="$(wi_view "$sid")"
  run_prompt "$sid" "$prompt"
  expect_same "prompt '$(printf '%s' "$prompt" | tr '\n' ' ')' leaves workflow_init untouched" "$before" "$(wi_view "$sid")"
done
case_end

case_begin "idempotent-second-prompt" "hooks/lib/wf-init-begun-mark.js"
seed_initial p5
run_prompt p5 "/workflow-init"
first="$(wi_view p5)"
run_prompt p5 "/workflow-init"
second="$(wi_view p5)"
case "$first" in
  in_progress\|*) expect_same "a second /workflow-init prompt appends no event" "$first" "$second" ;;
  *) fail "a second /workflow-init prompt appends no event" "first prompt did not mark: '$first'" ;;
esac
case_end

case_begin "complete-unchanged" "hooks/lib/wf-init-begun-mark.js"
seed_init_complete p6
before="$(wi_view p6)"
run_prompt p6 "/workflow-init"
after="$(wi_view p6)"
case "$before" in
  complete\|*) expect_same "workflow_init already complete is left alone" "$before" "$after" ;;
  *) fail "workflow_init already complete is left alone" "fixture not complete: '$before'" ;;
esac
case_end

case_begin "corrupt-state-untouched" "hooks/lib/wf-init-begun-mark.js"
printf '{not json' >"$STATE_DIR/p7.json"
run_prompt p7 "/workflow-init"
after="$(cat "$STATE_DIR/p7.json" 2>/dev/null)"
expect_same "a corrupt state file is not written" "{not json" "$after"
case_end

case_begin "invalid-stdin-fail-open" "hooks/user-prompt-submit-wf-init-mark.js"
for raw in '{not json' '' '[]' 'null'; do
  run_raw "$raw"
  if [ "$HK_RC" -eq 0 ] && [ "$HK_OUT" = "{}" ]; then
    pass "stdin '$raw' -> exit 0 and {}"
  else
    fail "stdin '$raw' -> exit 0 and {}" "rc=$HK_RC out='$HK_OUT'"
  fi
done
case_end

case_begin "static-shared-recorder" "hooks/lib/wf-init-begun-mark.js"
for h in "$HOOK" "$POSTUSE_HOOK"; do
  if [ -f "$h" ] && grep -q "wf-init-begun-mark" "$h"; then
    pass "(static) $(basename "$h") requires wf-init-begun-mark"
  else
    fail "(static) $(basename "$h") requires wf-init-begun-mark"
  fi
done
# The prompt hook records nothing else; the PostToolUse hook still marks other steps,
# so for it only a markStep that names workflow_init is a second recorder.
if [ -f "$HOOK" ] && ! grep -q "markStep(" "$HOOK"; then
  pass "(static) user-prompt-submit-wf-init-mark.js does not call markStep( directly"
else
  fail "(static) user-prompt-submit-wf-init-mark.js does not call markStep( directly"
fi
if grep -E "markStep\(" "$POSTUSE_HOOK" | grep -q "workflow_init"; then
  fail "(static) postuse-step-in-flight-mark.js does not markStep workflow_init itself"
else
  pass "(static) postuse-step-in-flight-mark.js does not markStep workflow_init itself"
fi
case_end

case_begin "settings-registration" "settings.json"
reg="$(SETTINGS_PATH="$(node_path "$SETTINGS")" bash "$RWT" 15 node -e "
const s = JSON.parse(require('fs').readFileSync(process.env.SETTINGS_PATH, 'utf8'));
const cmds = ((s.hooks || {}).UserPromptSubmit || []).flatMap((g) => (g.hooks || []).map((h) => String(h.command || '')));
const i = cmds.findIndex((c) => c.includes('hooks/user-prompt-submit-wf-init-mark.js'));
const j = cmds.findIndex((c) => c.includes('hooks/record-off-skill-invocation.js'));
process.stdout.write(i < 0 ? 'missing' : (i === j + 1 ? 'after-off-recorder' : 'misplaced'));" 2>/dev/null)"
if [ "$reg" = "after-off-recorder" ]; then
  pass "settings.json registers the hook under UserPromptSubmit right after record-off-skill-invocation.js"
else
  fail "settings.json registers the hook under UserPromptSubmit right after record-off-skill-invocation.js" "$reg"
fi
case_end

case_begin "regex-built-from-wf-init-skills" "hooks/lib/step-in-flight-policy.js"
names="$(bash "$RWT" 15 node -e "
const P = require('$POLICY_NODE');
const L = P.WF_INIT_SKILLS;
if (!Array.isArray(L) || !Object.isFrozen(L) || L.length === 0) { process.stdout.write('bad-list'); process.exit(0); }
const bad = L.filter((n) => !(P.promptInvokesWfInit('/' + n) && P.promptInvokesWfInit('<command-name>/' + n + '</command-name>')
  && P.isWfInitDispatch('Skill', n) && !P.promptInvokesWfInit('/' + n + '-x') && !P.isWfInitDispatch('Agent', n)));
process.stdout.write(bad.length ? 'not-detected:' + bad.join(',') : 'ok:' + L.join(','));" 2>/dev/null)"
case "$names" in
  ok:*) pass "every WF_INIT_SKILLS name is detected on both paths ($names)" ;;
  *) fail "every WF_INIT_SKILLS name is detected on both paths" "${names:-<module-load-error>}" ;;
esac
# One list, no second copy: each name literal appears exactly once in the policy file.
for n in workflow-init wf-init; do
  cnt="$(grep -oE "[\"']$n[\"']" "$POLICY" | wc -l | tr -d ' ')"
  if [ "$cnt" = "1" ]; then
    pass "(static) '$n' is spelled once in step-in-flight-policy.js (the regex derives from WF_INIT_SKILLS)"
  else
    fail "(static) '$n' is spelled once in step-in-flight-policy.js" "found $cnt quoted occurrence(s)"
  fi
done
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
