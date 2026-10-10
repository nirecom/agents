#!/usr/bin/env bash
# tests/hooks/feature-block-send-user-file.sh
# Tests: hooks/block-send-user-file.js, settings.json
# Tags: hook, pretooluse, send-user-file, plan-link, deny, fail-open, hook-registration, TL2, scope:common
# hooks/block-send-user-file.js denies the SendUserFile tool (the plan is shown by blob URL
# in the response text instead), leaves every other tool alone, and fails open on bad stdin.
#
# TL3 gap (hook-registration): this file checks the settings.json registration statically and
# drives the hook with synthetic stdin. Only a real `claude -p` session proves that Claude Code
# routes a SendUserFile tool call through the PreToolUse matcher and honors the deny.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

BSU_TMP="$(np "$(make_tmp)")"
trap 'rm -rf "$BSU_TMP"' EXIT
harness_isolate "$BSU_TMP"
export AGENTS_CONFIG_DIR="$BSU_TMP/cfg"
mkdir -p "$AGENTS_CONFIG_DIR"
cd "$BSU_TMP" || exit 1
HOOK="$(np "$AGENTS_DIR/hooks/block-send-user-file.js")"
SETTINGS="$(np "$AGENTS_DIR/settings.json")"

# bsu_run <stdin> — sets BSU_OUT, BSU_RC; BSU_DECISION / BSU_REASON from hookSpecificOutput.
bsu_run() {
  if [ ! -f "$HOOK" ]; then
    BSU_OUT=""; BSU_RC=127; BSU_DECISION="not implemented: hooks/block-send-user-file.js absent"; BSU_REASON=""
    return
  fi
  BSU_OUT="$(printf '%s' "$1" | run_with_timeout 60 node "$HOOK" 2>/dev/null)"
  BSU_RC=$?
  BSU_DECISION="$(printf '%s' "$BSU_OUT" | run_with_timeout 30 node -e "
let d = {}; try { d = JSON.parse(require('fs').readFileSync(0, 'utf8') || '{}'); } catch (e) { process.stdout.write('UNPARSEABLE'); process.exit(0); }
const h = d.hookSpecificOutput || {};
process.stdout.write(String(h.permissionDecision || ''));")"
  BSU_REASON="$(printf '%s' "$BSU_OUT" | run_with_timeout 30 node -e "
let d = {}; try { d = JSON.parse(require('fs').readFileSync(0, 'utf8') || '{}'); } catch (e) { process.exit(0); }
const h = d.hookSpecificOutput || {};
process.stdout.write(String(h.permissionDecisionReason || ''));")"
}

case_begin "send-user-file-denied" "hooks/block-send-user-file.js"
bsu_run '{"session_id":"0d2c5d7e-1111-4222-8333-444455556666","hook_event_name":"PreToolUse","tool_name":"SendUserFile","tool_input":{"file_path":"/tmp/x/plan-intent.md"}}'
if [ "$BSU_RC" -eq 0 ]; then pass "SendUserFile -> exit 0"; else fail "SendUserFile -> exit 0" "rc=$BSU_RC"; fi
if [ "$BSU_DECISION" = "deny" ]; then pass "SendUserFile -> permissionDecision deny"; else fail "SendUserFile -> permissionDecision deny" "decision=$BSU_DECISION out=$BSU_OUT"; fi
case "$BSU_REASON" in
  *SendUserFile*) pass "deny reason names SendUserFile" ;;
  *) fail "deny reason names SendUserFile" "reason=$BSU_REASON" ;;
esac
if printf '%s' "$BSU_REASON" | grep -qi "url"; then pass "deny reason points at the URL in the response text"; else fail "deny reason points at the URL in the response text" "reason=$BSU_REASON"; fi
if [ -z "$BSU_REASON" ] || printf '%s' "$BSU_REASON" | grep -q "/tmp/x"; then fail "deny reason does not echo the file path" "reason=$BSU_REASON"; else pass "deny reason does not echo the file path"; fi
case_end

case_begin "other-tools-not-denied" "hooks/block-send-user-file.js"
for tool in Write Bash Read; do
  bsu_run "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"$tool\",\"tool_input\":{\"file_path\":\"a.txt\",\"command\":\"true\"}}"
  if [ "$BSU_RC" -eq 0 ] && [ "$BSU_DECISION" != "deny" ] && [ "$BSU_DECISION" != "UNPARSEABLE" ] && [ -f "$HOOK" ]; then
    pass "$tool -> not denied, exit 0"
  else
    fail "$tool -> not denied, exit 0" "rc=$BSU_RC decision=$BSU_DECISION out=$BSU_OUT"
  fi
done
case_end

case_begin "bad-stdin-fails-open" "hooks/block-send-user-file.js"
for input in "" "not json" "{\"tool_name\":" "[]"; do
  bsu_run "$input"
  if [ "$BSU_RC" -eq 0 ] && [ "$BSU_DECISION" != "deny" ] && [ "$BSU_DECISION" != "UNPARSEABLE" ] && [ -f "$HOOK" ]; then
    pass "stdin '$input' -> exit 0, no deny"
  else
    fail "stdin '$input' -> exit 0, no deny" "rc=$BSU_RC decision=$BSU_DECISION out=$BSU_OUT"
  fi
done
case_end

case_begin "settings-registration" "settings.json"
BSU_REG="$(SETTINGS="$SETTINGS" run_with_timeout 30 node -e "
const s = JSON.parse(require('fs').readFileSync(process.env.SETTINGS, 'utf8'));
const pre = (s.hooks && s.hooks.PreToolUse) || [];
const hit = pre.find((e) => String(e.matcher || '').split('|').includes('SendUserFile')
  && (e.hooks || []).some((h) => /hooks\/block-send-user-file\.js/.test(String(h.command || ''))));
process.stdout.write(hit ? 'ok' : 'missing');" 2>&1)"
if [ "$BSU_REG" = "ok" ]; then
  pass "settings.json PreToolUse matcher SendUserFile runs block-send-user-file.js"
else
  fail "settings.json PreToolUse matcher SendUserFile runs block-send-user-file.js" "$BSU_REG"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
