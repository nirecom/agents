#!/bin/bash
# tests/feature-2326-rtk-rewrite/test-hook-mechanism.sh
# Tests: hooks/rtk-rewrite.js
# Tags: rtk, hook, pretooluse, scope:issue-specific
#
# T-M gate: end-to-end mechanism check for the rtk-rewrite PreToolUse hook.
# Feeds a real Bash tool payload on stdin with a fake rtk binary injected via
# RTK_BIN and asserts the hook returns an allow decision whose updatedInput
# command is the original command prefixed with the rtk binary.

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

# Fake rtk: a passthrough exec wrapper. printf (not echo) so \n is a real newline.
FAKE_RTK="$TMPDIR_T/fake-rtk"
printf '#!/bin/sh\nexec "$@"\n' > "$FAKE_RTK"
chmod +x "$FAKE_RTK"

PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"git status"}}'

OUT="$(printf '%s' "$PAYLOAD" | RTK=on RTK_BIN="$FAKE_RTK" \
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
