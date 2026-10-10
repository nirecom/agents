#!/usr/bin/env bash
# tests/hooks/TL3-hook-session-id-entrypoint-coverage.sh
# Tests: hooks/lib/resolve-workflow-session-id.js, hooks/session-start.js
# Tags: TL3, scope:issue-specific, pwsh-not-required, session-id
# Issue #1091: with the repo-made env-file relay gone, every entrypoint must see the
# CC-native CLAUDE_CODE_SESSION_ID. A probe hook records what real `claude -p` delivers
# to SessionStart / PreToolUse(Bash), and what a Bash tool call and a git-hook grandchild see.
# TL3 gap: interactive TTY sessions, --resume / --fork-session id rollover, and non-Windows
# CI hosts are not exercised; the TL2 day-to-day runners are
# tests/hooks/feature-883-resolve-workflow-session-id.sh and legacy-session-id-relay-purge.sh.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

[ -x "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" ] || exit 77
"$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" --is-off RUN_TL3 off && exit 77
command -v claude >/dev/null 2>&1 || exit 77

. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

E_BASE="$(make_tmp)"
trap 'rm -rf "$E_BASE"' EXIT
harness_isolate "$E_BASE"
export CLAUDE_TRANSCRIPT_BASE_DIR="$E_BASE/transcripts"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"

E_REPO="$E_BASE/repo"
E_GITHOOKS="$E_BASE/githooks"
E_OUT="$E_BASE/out"
mkdir -p "$E_REPO/.claude" "$E_GITHOOKS" "$E_OUT"
git init -q "$E_REPO"
# A fixture-owned hooks dir (not /dev/null): E3 needs a pre-commit, and no installed hook can fire.
git -C "$E_REPO" config core.hooksPath "$(np "$E_GITHOOKS")"
git -C "$E_REPO" config user.email "test@example.com"
git -C "$E_REPO" config user.name "Test"

E_PROBE_JS="$(np "$E_BASE/probe.js")"
E_PROBE_LOG="$(np "$E_OUT/probe.jsonl")"
E_PRECOMMIT_OUT="$(np "$E_OUT/precommit-sid.txt")"

cat > "$E_BASE/probe.js" <<'PROBE_EOF'
const fs = require("fs");
let raw = "";
process.stdin.on("data", (d) => (raw += d)).on("end", () => {
  let input = {};
  try { input = JSON.parse(raw); } catch (_) {}
  const rec = {
    event: input.hook_event_name || null,
    input_session_id: input.session_id || null,
    agent_id: input.agent_id || null,
    command: (input.tool_input && input.tool_input.command) || null,
    env_code_sid: process.env.CLAUDE_CODE_SESSION_ID || null,
  };
  try { fs.appendFileSync(process.argv[2], JSON.stringify(rec) + "\n"); } catch (_) {}
  process.stdout.write("{}");
});
PROBE_EOF

cat > "$E_GITHOOKS/pre-commit" <<HOOK_EOF
#!/usr/bin/env bash
printf '%s' "\${CLAUDE_CODE_SESSION_ID:-}" > "$E_PRECOMMIT_OUT"
exit 0
HOOK_EOF
chmod +x "$E_GITHOOKS/pre-commit"

# Minimal settings.json: only the probe; no disableBypassPermissionsMode.
cat > "$E_REPO/.claude/settings.json" <<SETTINGS_EOF
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "node \"$E_PROBE_JS\" \"$E_PROBE_LOG\"", "timeout": 10 } ] }
    ],
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "node \"$E_PROBE_JS\" \"$E_PROBE_LOG\"", "timeout": 10 } ] }
    ]
  }
}
SETTINGS_EOF

# run_claude <session-uuid> <prompt> — sets CLAUDE_RC / CLAUDE_OUT.
CLAUDE_RC=0
CLAUDE_OUT=""
run_claude() {
  CLAUDE_OUT="$(cd "$E_REPO" && unset CLAUDECODE CLAUDE_CODE_SESSION_ID && \
    run_with_timeout 180 claude -p "$2" \
      --session-id "$1" \
      --setting-sources project \
      --dangerously-skip-permissions \
      --output-format json 2>&1)" && CLAUDE_RC=0 || CLAUDE_RC=$?
}

# probe_query <js-predicate-body> — prints "ok" or a diagnostic; `recs` is the record array.
probe_query() {
  node -e '
const fs = require("fs");
let recs = [];
try { recs = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)); } catch (_) {}
const verdict = new Function("recs", "sid", process.argv[2])(recs, process.argv[3]);
process.stdout.write(verdict === true ? "ok" : "bad:" + JSON.stringify(recs).slice(0, 600));
' -- "$E_PROBE_LOG" "$1" "${2:-}"
}

# ---------------------------------------------------------------------------
case_begin "E1 headless main session sees its own native sid" "hooks/session-start.js"
E1_SID="1091e100-0000-4000-8000-0000000000e1"
E1_OUT="$(np "$E_OUT/e1-bash-sid.txt")"
run_claude "$E1_SID" "Run exactly these two Bash commands, one after the other, and nothing else: (1) printenv CLAUDE_CODE_SESSION_ID > $E1_OUT  (2) git commit --allow-empty -m probe"
E1_BASH="$(cat "$E_OUT/e1-bash-sid.txt" 2>/dev/null | tr -d '\r\n')"
if [ "$E1_BASH" = "$E1_SID" ]; then
  pass "E1a: Bash tool env carries the fixed session UUID"
else
  fail "E1a: Bash tool env" "got='$E1_BASH' rc=$CLAUDE_RC out=$(printf '%s' "$CLAUDE_OUT" | head -c 300)"
fi
v="$(probe_query 'const s=recs.filter(r=>r.event==="SessionStart"&&r.input_session_id===sid); return s.length>0&&s.every(r=>r.env_code_sid===sid);' "$E1_SID")"
[ "$v" = "ok" ] && pass "E1b: SessionStart env sid == input session_id == UUID" || fail "E1b: SessionStart probe" "$v"
v="$(probe_query 'const p=recs.filter(r=>r.event==="PreToolUse"&&r.input_session_id===sid&&!r.agent_id); return p.length>0&&p.every(r=>r.env_code_sid===sid);' "$E1_SID")"
[ "$v" = "ok" ] && pass "E1c: PreToolUse(Bash) env sid == input session_id == UUID" || fail "E1c: PreToolUse probe" "$v"
case_end

# ---------------------------------------------------------------------------
case_begin "E3 git hook grandchild inherits the native sid" "hooks/lib/resolve-workflow-session-id.js"
E3_VAL="$(cat "$E_OUT/precommit-sid.txt" 2>/dev/null | tr -d '\r\n')"
if [ "$E3_VAL" = "$E1_SID" ]; then
  pass "E3: pre-commit grandchild saw the fixed session UUID"
else
  fail "E3: pre-commit grandchild" "got='$E3_VAL' (empty means the commit never ran or the var was dropped)"
fi
case_end

# ---------------------------------------------------------------------------
case_begin "E2 headless subagent Bash sees its own session id" "hooks/lib/resolve-workflow-session-id.js"
E2_SID="1091e200-0000-4000-8000-0000000000e2"
E2_OUT="$(np "$E_OUT/e2-subagent-sid.txt")"
run_claude "$E2_SID" "Use the Task tool to launch a general-purpose subagent whose only job is to run this exact Bash command: printenv CLAUDE_CODE_SESSION_ID > $E2_OUT . Do not run it yourself."
# E2a: filter by agent_id (non-null) so records from the main agent's own Bash
# calls are excluded — only subagent PreToolUse records carry an agent_id.
v="$(probe_query 'const p=recs.filter(r=>r.event==="PreToolUse"&&r.agent_id&&r.command&&r.command.indexOf("e2-subagent-sid")!==-1); return p.length>0&&p.every(r=>r.env_code_sid&&r.env_code_sid===r.input_session_id);')"
[ "$v" = "ok" ] && pass "E2a: subagent PreToolUse (agent_id present) env sid == its input session_id" || fail "E2a: subagent PreToolUse probe" "$v rc=$CLAUDE_RC"
E2_FILE="$(cat "$E_OUT/e2-subagent-sid.txt" 2>/dev/null | tr -d '\r\n')"
# E2b: Bash output from the subagent's printenv matches the hook record's input_session_id.
# Same agent_id guard ensures we're correlating the subagent record, not the main agent.
v="$(probe_query 'const p=recs.filter(r=>r.event==="PreToolUse"&&r.agent_id&&r.command&&r.command.indexOf("e2-subagent-sid")!==-1); return p.length>0&&p[0].input_session_id===sid;' "$E2_FILE")"
[ "$v" = "ok" ] && pass "E2b: subagent Bash env value matches the subagent hook's session_id" || fail "E2b: subagent Bash env" "file='$E2_FILE' $v"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
