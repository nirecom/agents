#!/usr/bin/env bash
# tests/enforce-off-clearance-write.sh
# Tests: hooks/block-off-clearance-write.js
# Tags: anti-cheat, off-clearance, pretooluse, block-write, vector2, classifier, scope:issue-specific, pwsh-not-required, TL1, hook-registration
#
# #1608 anti-cheat (best-effort): block direct writes to the clearance-token path
# (<workflowDir>/<sid>.off-clearance). Mirrors block-memory-direct.js + adds a vector2
# interpreter-body heuristic (node -e / python -c writing to the token dir).
#
# KNOWN-BYPASS (accepted limitation — detail plan "Anti-cheat 信頼モデル(確定)"):
#   Dynamic path construction (variable concat / base64 / alternate interpreter),
#   editing the examiner script / codex / this hook itself are NOT detectable.
#   The TRUE gate is Phase2 human approval + audit, NOT this best-effort block.
# Classifier symmetry (test-design.md L36): every block case is paired with a
# sanctioned unrelated-path APPROVE case so the hook does not over-block.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
HOOK="$AGENTS_DIR/hooks/block-off-clearance-write.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'offwrite'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

HOOK_PRESENT=no; [ -f "$HOOK" ] && HOOK_PRESENT=yes

# run_hook <tmp_node> <hook-input-json> → prints stdout of the hook (empty if hook absent)
run_hook() {
    local tn="$1" input="$2"
    [ "$HOOK_PRESENT" = "yes" ] || { printf ''; return; }
    CLAUDE_WORKFLOW_DIR="$tn" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        "$RWT" 12 node "$HOOK" <<< "$input" 2>/dev/null
}
mk_bash_input() { "$RWT" 8 node -e "process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:'wsid',tool_input:{command:process.argv[1]}}))" "$1"; }
mk_file_input() { "$RWT" 8 node -e "process.stdout.write(JSON.stringify({tool_name:process.argv[1],session_id:'wsid',tool_input:{file_path:process.argv[2]}}))" "$1" "$2"; }
is_block() { echo "$1" | grep -q '"decision":"block"'; }

assert_block() {  # <label> <hook-out>
    if is_block "$2"; then pass "$1 → block"
    else
        if [ "$HOOK_PRESENT" = "yes" ]; then fail "$1 must block (got: ${2:-<none>})"
        else fail "$1 → block  [RED-EXPECTED: block-off-clearance-write.js not yet created]"; fi
    fi
}
assert_approve() {  # <label> <hook-out>
    if is_block "$2"; then fail "$1 must NOT block (over-blocking; got: $2)"
    else pass "$1 → approve (not blocked)"; fi
}

TMP=$(make_tmp); TN=$(node_path "$TMP")
TOKEN="$TN/wsid.off-clearance"

# --- block: Bash redirect / tee / cp to token path ---
assert_block "B1 redirect > token"        "$(run_hook "$TN" "$(mk_bash_input "echo x > $TOKEN")")"
assert_block "B2 tee token"               "$(run_hook "$TN" "$(mk_bash_input "echo x | tee $TOKEN")")"
assert_block "B3 cp to token"             "$(run_hook "$TN" "$(mk_bash_input "cp /etc/hosts $TOKEN")")"

# --- block: Write / Edit tool on token path ---
assert_block "B4 Write token file_path"   "$(run_hook "$TN" "$(mk_file_input Write "$TOKEN")")"
assert_block "B5 Edit token file_path"    "$(run_hook "$TN" "$(mk_file_input Edit "$TOKEN")")"

# --- block: vector2 interpreter-body heuristic (node -e writing into token dir) ---
V2CMD="node -e \"require('fs').writeFileSync(process.env.CLAUDE_WORKFLOW_DIR + '/wsid.off-clearance','forged')\""
assert_block "B6 vector2 node -e .off-clearance" "$(run_hook "$TN" "$(mk_bash_input "$V2CMD")")"

# --- approve: sanctioned unrelated paths (CPR-5 counterparts) ---
assert_approve "A1 redirect > unrelated file"  "$(run_hook "$TN" "$(mk_bash_input "echo x > $TN/notes.txt")")"
assert_approve "A2 Write unrelated file_path"  "$(run_hook "$TN" "$(mk_file_input Write "$TN/other.json")")"
assert_approve "A3 harmless node -e (no token)" "$(run_hook "$TN" "$(mk_bash_input "node -e \"console.log(1+1)\"")")"

rm -rf "$TMP" 2>/dev/null || true

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
