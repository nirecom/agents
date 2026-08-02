#!/usr/bin/env bash
# tests/fix-1780-round4-command-tool-payload.sh
# Tests: hooks/lib/tool-command-text.js, hooks/block-off-clearance-write.js, hooks/supervisor-off-proposal-shim.js, hooks/lib/sentinel-patterns.js
# Tags: off-clearance, runcommands, runinterminal, tool-payload, pretooluse, classifier, security, scope:issue-specific, pwsh-not-required, TL1, TL2, hook-registration
# TL3 gap (what this test does NOT catch):
# - That Claude Code's real runCommands / runInTerminal tools deliver the payload
#   shapes assumed here ({commands:[...]} and {command:"..."}). Both hooks are node
#   subprocesses fed synthetic PreToolUse JSON, so a change to the HOST's payload
#   contract would go unnoticed until a real session runs.
# - settings.json actually registering both hooks for runCommands / runInTerminal
#   (asserted statically by tests/feature-1610-settings-worktree-entries.sh and by
#   the R-block of tests/fix-1780-round4-write-tool-parity.sh, never dynamically).
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
#
# ---------------------------------------------------------------------------
# WHAT THIS FILE DEFENDS (#1780 round-4 H-1)
#
# Claude Code ships THREE command-executing tools that do not agree on a payload:
# Bash and runInTerminal put a string under `command`, runCommands puts an ARRAY
# under `commands`. Every guard that scans command text used to read `.command`
# only, so a runCommands call handed the scanner `undefined` — not a degraded
# check, a silent FULL BYPASS of both the protected-write block and the OFF
# clearance gate.
#
# The fix has two halves and this file pins both:
#
#   (a) NORMALIZATION (Section C). hooks/lib/tool-command-text.js is the single
#       place that knows the three shapes.
#   (b) PER-ELEMENT ADJUDICATION (Sections C2 / E). Every pattern in
#       hooks/lib/sentinel-patterns.js is `^`-anchored WITHOUT the `m` flag, so a
#       "\n"-joined array can NEVER match a sentinel sitting in commands[N>0].
#       Joining is right for "does any protected path appear anywhere?" and wrong
#       for "is THIS command a sentinel emission?" — two questions, two shapes.
#
# Every case that targets commands[N] deliberately uses N > 0. An index-0 hit is
# indistinguishable from the pre-fix behaviour once the array is joined, so a
# suite that only ever probed commands[0] would stay green against the bug.
#
# CLASSIFIER SYMMETRY (test-design.md): every block case is paired with a benign
# call through the SAME tool, so a hook that blocked everything could not pass.
#
# HERMETICITY: CLAUDE_WORKFLOW_DIR / WORKFLOW_PLANS_DIR point at throwaway temp
# dirs and every session id is a throwaway ("rc4sid" etc). No real token, marker
# or audit file is created, read or removed.
# ---------------------------------------------------------------------------

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
TCT_NODE="$_AGENTS_DIR_NODE/hooks/lib/tool-command-text.js"
SP_NODE="$_AGENTS_DIR_NODE/hooks/lib/sentinel-patterns.js"
BLOCK_HOOK="$AGENTS_DIR/hooks/block-off-clearance-write.js"
SHIM="$AGENTS_DIR/hooks/supervisor-off-proposal-shim.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'rc4cmd'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
cleanup_tmp() { [ -n "${1:-}" ] && [ -d "$1" ] && chmod -R u+w "$1" 2>/dev/null; [ -n "${1:-}" ] && rm -r -f "$1" 2>/dev/null; return 0; }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"; else fail "$name - want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

if [ ! -f "$TCT_NODE" ]; then
    fail "H0 hooks/lib/tool-command-text.js missing - every case below is vacuous"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi
pass "H0 hooks/lib/tool-command-text.js present"

# ===========================================================================
# Section C (TL1) - hooks/lib/tool-command-text.js normalization.
#
# Driven through one node driver that takes a JSON tool call on argv and prints
# a compact, assertable summary. The driver is written to a FILE rather than
# passed with `node -e` so the assertions read as data, not as escaped script.
# ===========================================================================
TMPC=$(make_tmp)
CDRV="$TMPC/tct-driver.js"
cat > "$CDRV" <<'CDRV_EOF'
"use strict";
// argv[2]: module path. argv[3]: JSON {toolName, toolInput}. argv[4]: query.
const m = require(process.argv[2]);
const { toolName, toolInput } = JSON.parse(process.argv[3]);
const q = process.argv[4];
if (q === "list") {
  // JSON so an element containing whitespace or a separator stays visible.
  process.stdout.write(JSON.stringify(m.commandListOf(toolName, toolInput)));
} else if (q === "text") {
  process.stdout.write(JSON.stringify(m.commandTextOf(toolName, toolInput)));
} else if (q === "isCommandTool") {
  process.stdout.write(String(m.isCommandTool(toolName)));
} else if (q === "names") {
  process.stdout.write(JSON.stringify(m.COMMAND_TOOL_NAMES));
}
CDRV_EOF
tct() { "$RWT" 10 node "$CDRV" "$TCT_NODE" "$1" "$2" 2>/dev/null; }

# C0 - the tool set is exactly the three command-executing tools. Guards gate on
# this list before normalizing, so a name dropped here silently un-guards a tool.
assert_eq "C0 COMMAND_TOOL_NAMES is exactly Bash/runInTerminal/runCommands" \
    '["Bash","runInTerminal","runCommands"]' "$(tct '{"toolName":"Bash","toolInput":{}}' names)"

# C1 - PER-ELEMENT: the array is kept separate, in order, including index > 0.
assert_eq "C1 runCommands commands[] is adjudicated per element, in order" \
    '["git status","echo second","echo third"]' \
    "$(tct '{"toolName":"runCommands","toolInput":{"commands":["git status","echo second","echo third"]}}' list)"

# C2 - THE REASON PER-ELEMENT EXISTS. A `^`-anchored, non-`m` pattern can never
# match an element that is not first once the array is joined with "\n". This
# case asserts the joined text FAILS and the element SUCCEEDS against the REAL
# shipping regex - not a mock copy - so the anchoring premise is verified rather
# than assumed. If sentinel-patterns.js ever gains the `m` flag, this goes red
# and the reasoning above must be revisited (it does not become safe by itself:
# `m` would also let an embedded newline forge a line start).
_S_OPEN="<<"
_S_OFF="${_S_OPEN}WORKFLOW_ENFORCE_WORKFLOW_OFF: [workflow-bug] examiner is broken>>"
OFF_CMD="echo \"${_S_OFF}\""
got=$("$RWT" 10 node -e '
"use strict";
const tct = require(process.argv[1]);
const p = require(process.argv[2]);
// The sentinel arrives on argv and is placed at index 2 HERE, so no shell-side
// JSON escaping can quietly turn this case into an empty payload.
const toolInput = { commands: ["git status", "npm test", process.argv[3]] };
const re = p.ENFORCE_WORKFLOW_OFF_RE_DQ;
const joined = tct.commandTextOf("runCommands", toolInput);
const list = tct.commandListOf("runCommands", toolInput);
process.stdout.write(String(re.test(joined)) + "," + String(list.some((c) => re.test(c))) + "," + String(re.multiline));
' "$TCT_NODE" "$SP_NODE" "$OFF_CMD" 2>/dev/null)
assert_eq "C2 joined text CANNOT match a commands[2] sentinel; the element can (regex is non-multiline)" \
    "false,true,false" "$got"

# C3 - non-array `commands` degrades safely. The forbidden outcome is the literal
# string "undefined": it contains no protected name, so a scanner handed it reads
# "scanned and clean" and the call sails through.
assert_eq "C3a commands as a bare string degrades to that one command" \
    '["echo hi"]' "$(tct '{"toolName":"runCommands","toolInput":{"commands":"echo hi"}}' list)"
assert_eq "C3b commands=null yields an empty list, never [\"undefined\"]" \
    '[]' "$(tct '{"toolName":"runCommands","toolInput":{"commands":null}}' list)"
assert_eq "C3c commands=null yields empty TEXT, never the literal \"undefined\"" \
    '""' "$(tct '{"toolName":"runCommands","toolInput":{"commands":null}}' text)"
assert_eq "C3d commands as a number degrades to its string form" \
    '["42"]' "$(tct '{"toolName":"runCommands","toolInput":{"commands":42}}' list)"
assert_eq "C3e missing commands key yields an empty list" \
    '[]' "$(tct '{"toolName":"runCommands","toolInput":{}}' list)"
assert_eq "C3f a null-valued ELEMENT is dropped, not stringified to \"null\"" \
    '["echo a"]' "$(tct '{"toolName":"runCommands","toolInput":{"commands":["echo a",null,""]}}' list)"
assert_eq "C3g a missing tool_input entirely yields an empty list" \
    '[]' "$(tct '{"toolName":"runCommands","toolInput":null}' list)"

# C4 - runInTerminal and Bash read `.command` (CPR-5: identical treatment).
for t in Bash runInTerminal; do
    assert_eq "C4 $t reads .command" '["echo one"]' \
        "$(tct "{\"toolName\":\"$t\",\"toolInput\":{\"command\":\"echo one\"}}" list)"
    assert_eq "C4 $t with no .command yields an empty list" '[]' \
        "$(tct "{\"toolName\":\"$t\",\"toolInput\":{}}" list)"
    assert_eq "C4 $t is recognized as a command tool" "true" \
        "$(tct "{\"toolName\":\"$t\",\"toolInput\":{}}" isCommandTool)"
done
# A command tool must NOT be tempted by a `commands` array it does not own.
assert_eq "C4x Bash ignores a stray commands[] (its payload key is .command)" \
    '[]' "$(tct '{"toolName":"Bash","toolInput":{"commands":["echo x"]}}' list)"

# C5 - unknown tools yield nothing and are not command tools. Guards branch on
# isCommandTool first, so both halves matter.
assert_eq "C5a an unknown tool is not a command tool" "false" \
    "$(tct '{"toolName":"Read","toolInput":{"commands":["echo x"]}}' isCommandTool)"
assert_eq "C5b an unknown tool carrying commands[] yields an empty list" \
    '[]' "$(tct '{"toolName":"Read","toolInput":{"commands":["echo x"]}}' list)"
assert_eq "C5c an empty tool name is not a command tool" "false" \
    "$(tct '{"toolName":"","toolInput":{"command":"echo x"}}' isCommandTool)"
cleanup_tmp "$TMPC"

# ===========================================================================
# Section D (TL2) - hooks/block-off-clearance-write.js end-to-end via stdin JSON.
#
# The verdict vocabulary is deliberately strict (mirrors
# tests/enforce-off-clearance-write.sh): an allow counts only when the process
# exited 0 AND affirmatively said "approve". A crash, a timeout or empty stdout
# each get their own token so they can never be mistaken for an approval.
# ===========================================================================
classify() {
    local raw="$1" rc out
    rc="${raw%%|*}"; out="${raw#*|}"
    case "$rc" in
        absent) printf 'hook-absent'; return ;;
        124)    printf 'timeout'; return ;;
        0)      ;;
        *)      printf 'crash:%s' "$rc"; return ;;
    esac
    [ -z "$out" ] && { printf 'empty'; return; }
    case "$out" in
        *'"decision":"block"'*)   printf 'block'; return ;;
        *'"decision":"approve"'*) printf 'approve'; return ;;
    esac
    printf 'unrecognized'
}
run_block_hook() { # <tmp_node> <input-json> -> "<rc>|<stdout>"
    local tn="$1" input="$2" out rc
    [ -f "$BLOCK_HOOK" ] || { printf 'absent|'; return; }
    out=$(CLAUDE_WORKFLOW_DIR="$tn" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        "$RWT" 15 node "$BLOCK_HOOK" <<< "$input" 2>/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr -d '\r\n')"
}
assert_verdict() { # <label> <want> <raw>
    local got; got="$(classify "$3")"
    if [ "$got" = "$2" ]; then pass "$1 -> $got"; else fail "$1 want=$2 got=$got [raw=$(printf '%.200s' "$3")]"; fi
}

if [ ! -f "$BLOCK_HOOK" ]; then
    skip "D block-off-clearance-write.js not present"
else
    TMPD=$(make_tmp); TND=$(node_path "$TMPD")
    DDRV="$TMPD/mk-input.js"
    cat > "$DDRV" <<'DDRV_EOF'
"use strict";
// argv[2]=tool name, argv[3]=cwd, argv[4..]=commands. One element -> .command
// for Bash/runInTerminal, the whole list -> .commands for runCommands, so the
// SAME call site can emit either payload shape.
const tool = process.argv[2];
const cwd = process.argv[3];
const cmds = process.argv.slice(4);
const input = tool === "runCommands" ? { commands: cmds, cwd } : { command: cmds.join("; "), cwd };
process.stdout.write(JSON.stringify({ tool_name: tool, session_id: "rc4sid", cwd, tool_input: input }));
DDRV_EOF
    mk_cmd_input() { "$RWT" 10 node "$DDRV" "$@"; }

    TOKEN="$TND/rc4sid.off-clearance"
    MARKER="$TND/rc4sid.workflow-off"
    BENIGN1="git status"
    BENIGN2="npm test"

    # D1/D2 - the load-bearing cases: the protected write sits at commands[2] and
    # commands[1]. Pre-fix, `.command` was undefined for runCommands and NOTHING
    # was scanned; a fix that only joined index 0 would still miss these.
    assert_verdict "D1 runCommands marker write at commands[2] is blocked" block \
        "$(run_block_hook "$TND" "$(mk_cmd_input runCommands "$TND" "$BENIGN1" "$BENIGN2" "printf x > $MARKER")")"
    assert_verdict "D2 runCommands token write at commands[1] is blocked" block \
        "$(run_block_hook "$TND" "$(mk_cmd_input runCommands "$TND" "$BENIGN1" "echo forged > $TOKEN")")"
    assert_verdict "D3 runCommands token write at commands[0] is blocked (baseline)" block \
        "$(run_block_hook "$TND" "$(mk_cmd_input runCommands "$TND" "echo forged > $TOKEN" "$BENIGN1")")"

    # D4/D5 - CPR-5 siblings: the same write through runInTerminal and Bash.
    assert_verdict "D4 runInTerminal token write is blocked" block \
        "$(run_block_hook "$TND" "$(mk_cmd_input runInTerminal "$TND" "echo forged > $TOKEN")")"
    assert_verdict "D5 Bash token write is blocked (already-covered member)" block \
        "$(run_block_hook "$TND" "$(mk_cmd_input Bash "$TND" "echo forged > $TOKEN")")"
    assert_verdict "D6 runInTerminal marker write is blocked" block \
        "$(run_block_hook "$TND" "$(mk_cmd_input runInTerminal "$TND" "printf x > $MARKER")")"

    # D7-D9 - FALSE POSITIVES. Without these the D-block would pass against a
    # hook that blocked every runCommands / runInTerminal call outright, which is
    # its own outage (every multi-command tool call dead).
    assert_verdict "D7 runCommands with only benign commands is approved" approve \
        "$(run_block_hook "$TND" "$(mk_cmd_input runCommands "$TND" "$BENIGN1" "$BENIGN2" "echo done > $TND/notes.txt")")"
    assert_verdict "D8 runInTerminal benign command is approved" approve \
        "$(run_block_hook "$TND" "$(mk_cmd_input runInTerminal "$TND" "echo done > $TND/notes.txt")")"
    assert_verdict "D9 Bash benign command is approved (symmetry control)" approve \
        "$(run_block_hook "$TND" "$(mk_cmd_input Bash "$TND" "echo done > $TND/notes.txt")")"
    # D10 - an empty runCommands payload must not crash the hook into a verdict.
    assert_verdict "D10 runCommands with an empty commands[] is approved" approve \
        "$(run_block_hook "$TND" '{"tool_name":"runCommands","session_id":"rc4sid","tool_input":{"commands":[]}}')"
    cleanup_tmp "$TMPD"
fi

# ===========================================================================
# Section E (TL2) - hooks/supervisor-off-proposal-shim.js.
#
# The shim decides whether an OFF sentinel emit may reach the human approval
# prompt. It exits 2 with a block payload when no clearance token backs the
# proposal, and exits 0 otherwise. rc is asserted alongside the payload so a
# crash (rc other than 0/2) can never be read as "allowed".
#
# The sentinel strings are ASSEMBLED, never written literally: a well-formed
# sentinel sitting in a source file is indistinguishable from an emission to any
# tool that scans command text. E0 proves the assembly matches the real regexes.
# ===========================================================================
_S_EMERG="${_S_OPEN}WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY: examiner is broken>>"
EMERG_CMD="echo \"${_S_EMERG}\""

got=$("$RWT" 10 node -e '
const p = require(process.argv[3]);
process.stdout.write(String(p.ENFORCE_WORKFLOW_OFF_RE_DQ.test(process.argv[1])) + "," +
                     String(p.ENFORCE_WORKFLOW_OFF_EMERGENCY_RE_DQ.test(process.argv[2])));
' "$OFF_CMD" "$EMERG_CMD" "$SP_NODE" 2>/dev/null)
assert_eq "E0 harness self-check: assembled sentinels match the real regexes" "true,true" "$got"

if [ ! -f "$SHIM" ]; then
    skip "E supervisor-off-proposal-shim.js not present"
else
    TMPE=$(make_tmp); TNE=$(node_path "$TMPE")
    EDRV="$TMPE/mk-shim-input.js"
    cat > "$EDRV" <<'EDRV_EOF'
"use strict";
const tool = process.argv[2];
const sid = process.argv[3];
const cmds = process.argv.slice(4);
const input = tool === "runCommands" ? { commands: cmds } : { command: cmds.join("; ") };
process.stdout.write(JSON.stringify({ tool_name: tool, session_id: sid, tool_input: input }));
EDRV_EOF
    run_shim() { # <tool> <sid> <cmd...> -> "<rc>|<blocked yes/no>"
        local hi out rc
        hi=$("$RWT" 10 node "$EDRV" "$@" 2>/dev/null)
        out=$(WORKFLOW_PLANS_DIR="$TNE" CLAUDE_WORKFLOW_DIR="$TNE" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
            "$RWT" 15 node "$SHIM" <<< "$hi" 2>/dev/null)
        rc=$?
        if printf '%s' "$out" | grep -q '"decision":"block"'; then printf '%s|yes' "$rc"; else printf '%s|no' "$rc"; fi
    }

    # E1 - the load-bearing case: the OFF sentinel sits at commands[2]. Against a
    # joined-text gate this is invisible (see C2), so the proposal would reach the
    # approval prompt with no Phase1 clearance behind it at all.
    assert_eq "E1 OFF sentinel at runCommands commands[2] is gated (blocked, no token)" \
        "2|yes" "$(run_shim runCommands e1sid "git status" "npm test" "$OFF_CMD")"
    # E2 - CPR-5 control: the already-covered Bash member, same sentinel, same dir.
    assert_eq "E2 the same sentinel through Bash is gated identically" \
        "2|yes" "$(run_shim Bash e2sid "$OFF_CMD")"
    # E3 - and through runInTerminal.
    assert_eq "E3 the same sentinel through runInTerminal is gated identically" \
        "2|yes" "$(run_shim runInTerminal e3sid "$OFF_CMD")"

    # E4 - FALSE POSITIVE control. A runCommands call with no sentinel must pass
    # untouched; otherwise E1-E3 could be passing because the shim blocks
    # everything it does not understand.
    assert_eq "E4 runCommands with no sentinel is not gated" \
        "0|no" "$(run_shim runCommands e4sid "git status" "npm test" "echo done")"

    # E5 - the EMERGENCY sentinel is excluded from the gate BY CONSTRUCTION (it is
    # the escape when the examiner itself is broken), and that exclusion must hold
    # at commands[1] just as it does for Bash.
    assert_eq "E5 EMERGENCY sentinel at runCommands commands[1] still bypasses the gate" \
        "0|no" "$(run_shim runCommands e5sid "git status" "$EMERG_CMD")"

    # E6 - FAIL-CLOSED SELECTION, the security case E5 makes possible. A call
    # carrying BOTH forms must be judged on the gated one: otherwise an emergency
    # element could be appended to any call to smuggle a normal OFF proposal past
    # Phase1. Both orderings are asserted so the verdict cannot depend on which
    # element happens to be scanned first.
    assert_eq "E6a EMERGENCY + normal OFF in one runCommands call blocks (normal wins)" \
        "2|yes" "$(run_shim runCommands e6asid "$EMERG_CMD" "$OFF_CMD")"
    assert_eq "E6b the reverse order blocks too (order-independent)" \
        "2|yes" "$(run_shim runCommands e6bsid "$OFF_CMD" "$EMERG_CMD")"

    # E7 - the gated path must not leave state behind when it blocks: a blocked
    # proposal that minted or claimed anything would be a grant by another name.
    leaked=$(ls -1 "$TMPE" 2>/dev/null | grep -c 'off-clearance' | tr -d ' ')
    assert_eq "E7 no clearance token or claim file was created by any blocked proposal" "0" "$leaked"
    cleanup_tmp "$TMPE"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
