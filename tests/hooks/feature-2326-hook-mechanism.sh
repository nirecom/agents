#!/bin/bash
# tests/hooks/feature-2326-hook-mechanism.sh
# Tests: hooks/rtk-rewrite.js
# Tags: rtk, hook, pretooluse, scope:issue-specific
#
# T-M gate: end-to-end mechanism check for the rtk-rewrite PreToolUse hook.
# The hook delegates to `rtk hook claude` via spawnSync, feeding the PreToolUse
# payload on stdin and passing through the RTK's hookSpecificOutput. This test
# injects a fake rtk (via RTK_BIN) that speaks that delegation protocol: on
# `hook claude` it reads the payload from stdin and returns an allow decision
# whose updatedInput command is the original command prefixed with the rtk path.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$AGENTS_DIR/hooks/rtk-rewrite.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Fixture isolation: never resolve the developer's live session/state.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

# Fake rtk speaking the `hook claude` delegation protocol. The hook spawns the
# rtk binary with fixed args `["hook","claude"]` via spawnSync (no shell), so the
# fake must be a real executable node can launch on every platform — a shebang
# script or a .cmd is unspawnable by Windows node. We therefore use the node
# binary itself as RTK_BIN and let its first arg, "hook", be the program: node
# resolves argv[1]="hook" against the child's cwd, so a file literally named
# `hook` placed there runs as the delegate. It reads the PreToolUse payload from
# stdin (arg "claude" confirms the subcommand) and emits a hookSpecificOutput
# whose updatedInput.command is its own path ($argv[1]) + ' ' + tool_input.command.
NODE_BIN="$(node -e 'process.stdout.write(process.execPath)')"
FAKE_DIR="$TMPDIR_T"
cat > "$FAKE_DIR/hook" << 'SCRIPT_END'
const fs = require("fs");
if (process.argv[2] === "claude") {
  let s = "";
  try { s = fs.readFileSync(0, "utf8"); } catch (_e) {}
  const d = JSON.parse(s);
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      permissionDecision: "allow",
      updatedInput: { command: process.argv[1] + " " + d.tool_input.command },
    },
  }));
}
process.exit(0);
SCRIPT_END

PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"git status"}}'

# cd into FAKE_DIR (in a subshell, leaving the test's own cwd untouched) so the
# hook's child resolves "hook" to our delegate; run-with-timeout does not alter cwd.
OUT="$(cd "$FAKE_DIR"; printf '%s' "$PAYLOAD" | RTK=on RTK_BIN="$NODE_BIN" \
    "$AGENTS_DIR/bin/run-with-timeout.sh" 180 node "$HOOK" 2>/dev/null)"

echo "hook output: $OUT"

DECISION="$(printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const o=JSON.parse(s);process.stdout.write((o.hookSpecificOutput&&o.hookSpecificOutput.permissionDecision)||"");}catch(e){}})')"
COMMAND="$(printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const o=JSON.parse(s);process.stdout.write((o.hookSpecificOutput&&o.hookSpecificOutput.updatedInput&&o.hookSpecificOutput.updatedInput.command)||"");}catch(e){}})')"

if [ "$DECISION" = "allow" ]; then
    pass "permissionDecision is allow"
else
    fail "permissionDecision expected allow, got '$DECISION'"
fi

case "$COMMAND" in
    *" git status")
        pass "updatedInput.command ends with ' git status' (got '$COMMAND')" ;;
    *)
        fail "updatedInput.command expected to end with ' git status', got '$COMMAND'" ;;
esac

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
