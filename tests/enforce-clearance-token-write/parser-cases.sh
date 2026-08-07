#!/usr/bin/env bash
# tests/enforce-clearance-token-write/parser-cases.sh
# Tests: hooks/block-clearance-token-write.js
# Tags: anti-cheat, clearance-token, pretooluse, classifier, parser-regex-tests, table-driven, scope:issue-specific, pwsh-not-required, TL2, hook-registration
# TL3 gap (what this test does NOT catch):
# - The hook firing on a real host. Covered by tests/TL3-hook-clearance-token-write.sh.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.
#
# Split out of tests/enforce-clearance-token-write.sh (rules/coding/file-split.md
# Pattern A). That file asserts the SECURITY behaviour — which commands are blocked
# and which files stay unchanged. This file asserts the PARSER underneath it: given
# an arbitrary PreToolUse payload, does the classifier reach a decision at all?
#
# Why the two are separated (CPR-SC): a security assertion presumes the parser produced
# a verdict. When the payload is empty, truncated, or shaped for a tool the hook was
# never written for, there is no verdict to assert on — the interesting question is
# whether the hook answers cleanly (exit 0, parseable stdout, no stack trace) or dies.
# A PreToolUse hook that throws is not "failing safe": Claude Code surfaces the crash
# and the user learns nothing about why their command was refused.
#
# Table-driven per the parser-regex-tests pattern: each row is one payload and the
# decision class it must land in — block, approve, or answer (a defined non-crash
# response, where either verdict is contractually acceptable).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
_AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"
HOOK="$AGENTS_DIR/hooks/block-clearance-token-write.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

HOOK_PRESENT=no; [ -f "$HOOK" ] && HOOK_PRESENT=yes

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
WD="$WORK/workflow"; mkdir -p "$WD"
WDN="$(node_path "$WD")"
printf '{"granted_at":1750000000}' > "$WD/wsid.off-clearance"

# feed <raw-stdin> → sets HRC / HOUT / HERR
feed() {
    if [ "$HOOK_PRESENT" != "yes" ]; then HRC=127; HOUT=""; HERR=""; return; fi
    HOUT=$(printf '%s' "$1" | CLAUDE_WORKFLOW_DIR="$WDN" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
            "$RWT" 12 node "$HOOK" 2>"$WORK/stderr.txt")
    HRC=$?
    HERR=$(cat "$WORK/stderr.txt" 2>/dev/null)
}

# assert_row <name> <payload> <want: block|approve|answer>
assert_row() {
    local name="$1" payload="$2" want="$3"
    feed "$payload"
    if [ "$HOOK_PRESENT" != "yes" ]; then
        fail "$name" "RED-EXPECTED: hooks/block-clearance-token-write.js not yet created"
        return
    fi
    # Common contract for every row, whatever the verdict: a PreToolUse hook must exit
    # 0 and must not emit a stack trace. Anything else is a crash wearing a decision.
    if [ "$HRC" -ne 0 ]; then
        fail "$name" "hook exited $HRC (a PreToolUse hook must always exit 0); stderr: $(printf '%s' "$HERR" | head -n 1)"
        return
    fi
    if printf '%s' "$HERR" | grep -qE '^\s+at |Error:|Traceback'; then
        fail "$name" "hook emitted a stack trace: $(printf '%s' "$HERR" | head -n 2 | tr '\n' ' ')"
        return
    fi
    case "$want" in
        block)
            if printf '%s' "$HOUT" | grep -q '"decision":"block"'; then pass "$name"
            else fail "$name" "want block, got: ${HOUT:-<empty>}"; fi ;;
        approve)
            if printf '%s' "$HOUT" | grep -q '"decision":"block"'; then
                fail "$name" "over-blocking: this payload must not be blocked (got: $HOUT)"
            else pass "$name"; fi ;;
        answer)
            # Either verdict is acceptable; what is not acceptable is a crash (already
            # excluded above) or output that is neither empty nor valid JSON — the
            # harness would then treat garbage on stdout as an undefined decision.
            if [ -z "$HOUT" ]; then pass "$name"
            elif printf '%s' "$HOUT" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{JSON.parse(s);process.exit(0)}catch(e){process.exit(1)}})" 2>/dev/null; then
                pass "$name"
            else
                fail "$name" "hook answered with non-JSON stdout: $(printf '%s' "$HOUT" | head -c 120)"
            fi ;;
    esac
}

# Payload builders — kept as functions so the table rows stay readable.
p_bash()  { node -e "process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:'wsid',tool_input:{command:process.argv[1]}}))" "$1"; }
p_file()  { node -e "process.stdout.write(JSON.stringify({tool_name:process.argv[1],session_id:'wsid',tool_input:{file_path:process.argv[2]}}))" "$1" "$2"; }
p_raw()   { printf '%s' "$1"; }

TOKEN="$WDN/wsid.off-clearance"
SAFE="$WDN/notes.md"

echo "=== P: malformed and unexpected PreToolUse payloads ==="
# Every row here is something the hook can genuinely receive: a harness change, a new
# tool, a truncated pipe, or a tool whose input schema it was never taught.
while IFS='|' read -r name kind arg want; do
    [[ -z "${name// /}" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; kind="${kind//[[:space:]]/}"; want="${want//[[:space:]]/}"
    arg="${arg#"${arg%%[![:space:]]*}"}"; arg="${arg%"${arg##*[![:space:]]}"}"
    case "$kind" in
        raw) assert_row "$name" "$(p_raw "$arg")" "$want" ;;
        *)   assert_row "$name" "$arg" "$want" ;;
    esac
done <<TABLE
P1-empty-stdin              | raw |                                                                     | answer
P2-whitespace-only          | raw |                                                                     | answer
P3-literal-null             | raw | null                                                                | answer
P4-json-array-root          | raw | []                                                                  | answer
P5-json-string-root         | raw | "hello"                                                             | answer
P6-json-number-root         | raw | 42                                                                  | answer
P7-truncated-json           | raw | {"tool_name":"Bash","tool_input":{                                   | answer
P8-not-json-at-all          | raw | this is not json                                                    | answer
P9-empty-object             | raw | {}                                                                  | answer
P10-tool-name-missing       | raw | {"session_id":"wsid","tool_input":{"command":"rm $TOKEN"}}           | answer
P11-tool-name-null          | raw | {"tool_name":null,"tool_input":{"command":"rm $TOKEN"}}              | answer
P12-tool-name-number        | raw | {"tool_name":7,"tool_input":{"command":"rm $TOKEN"}}                 | answer
P13-tool-input-missing      | raw | {"tool_name":"Bash","session_id":"wsid"}                             | answer
P14-tool-input-null         | raw | {"tool_name":"Bash","session_id":"wsid","tool_input":null}           | answer
P15-tool-input-is-a-string  | raw | {"tool_name":"Bash","session_id":"wsid","tool_input":"rm $TOKEN"}    | answer
P16-command-null            | raw | {"tool_name":"Bash","session_id":"wsid","tool_input":{"command":null}} | answer
P17-command-is-an-array     | raw | {"tool_name":"Bash","session_id":"wsid","tool_input":{"command":["rm","$TOKEN"]}} | answer
P18-file-path-null          | raw | {"tool_name":"Write","session_id":"wsid","tool_input":{"file_path":null}} | answer
P19-session-id-missing      | raw | {"tool_name":"Bash","tool_input":{"command":"rm $TOKEN"}}            | answer
P20-deeply-nested-noise     | raw | {"tool_name":"Bash","session_id":"wsid","tool_input":{"command":"echo hi","extra":{"a":{"b":{"c":[1,2,3]}}}}} | approve
TABLE

echo ""
echo "=== U: tools the hook was not written for ==="
# A guard registered on a matcher list that later grows must not start blocking the
# new tools indiscriminately, and must not silently ignore ones that can write.
# WebFetch/Read/Glob cannot modify a file, so they must pass through untouched.
while IFS='|' read -r name tool path want; do
    [[ -z "${name// /}" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; tool="${tool//[[:space:]]/}"; path="${path//[[:space:]]/}"; want="${want//[[:space:]]/}"
    assert_row "$name" "$(p_file "$tool" "$path")" "$want"
done <<TABLE
U1-read-token              | Read         | $TOKEN | approve
U2-glob-over-workflow-dir  | Glob         | $WDN   | approve
U3-unknown-tool-on-token   | FutureTool   | $TOKEN | answer
U4-notebookedit-on-token   | NotebookEdit | $TOKEN | answer
U5-write-unrelated-path    | Write        | $SAFE  | approve
U6-edit-unrelated-path     | Edit         | $SAFE  | approve
TABLE

echo ""
echo "=== C: positive controls — the parser still classifies the real cases ==="
# Without these, a hook that answered "approve" to literally everything would pass
# every row above. These pin that the parser is doing its job on the payloads it was
# actually written for.
assert_row "C1-bash-rm-token-blocks"   "$(p_bash "rm $TOKEN")"     block
assert_row "C2-write-token-blocks"     "$(p_file Write "$TOKEN")"  block
assert_row "C3-bash-unrelated-approves" "$(p_bash "ls -la /tmp")"  approve

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
