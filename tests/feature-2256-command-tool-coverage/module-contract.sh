#!/usr/bin/env bash
# tests/feature-2256-command-tool-coverage/module-contract.sh
# Tests: hooks/lib/tool-command-text.js, hooks/lib/sentinel-patterns.js
# Tags: supervisor, command-tool, tool-command-text, normalization, TL2, scope:issue-specific
# #2256 S5-a1 / round-2 C1: the shared command-tool accessor and the per-element
# matching requirement it exists to satisfy.

# Parent: tests/feature-2256-command-tool-coverage.sh

set -uo pipefail
# shellcheck source=./_common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

tct() {
    TCT="$TCT_NODE" TBODY="$1" node -e "
const tct = require(process.env.TCT);
const out = (v) => process.stdout.write(typeof v === 'object' ? JSON.stringify(v) : String(v));
eval(process.env.TBODY);
" 2>&1
}

# --- 1-2: the module exists and publishes the closed tool-name set ---
names="$(tct "out(tct.COMMAND_TOOL_NAMES)")"
assert_eq "1: COMMAND_TOOL_NAMES is exactly Bash, runInTerminal, runCommands" \
    "$names" '["Bash","runInTerminal","runCommands"]'
api="$(tct "out([typeof tct.isCommandTool, typeof tct.commandTextOf, typeof tct.commandListOf].join(','))")"
assert_eq "2: the three accessors are all exported as functions" "$api" "function,function,function"

# --- 3-4: isCommandTool covers every command tool and no other tool ---
yes="$(tct "out(['Bash','runInTerminal','runCommands'].map((n) => tct.isCommandTool(n)).join(','))")"
assert_eq "3: isCommandTool is true for all three command tools" "$yes" "true,true,true"
no="$(tct "out(['Edit','Write','Read','Task',''].map((n) => tct.isCommandTool(n)).join(','))")"
assert_eq "4: isCommandTool is false for non-command tools and the empty name" "$no" "false,false,false,false,false"

# --- 5-7: commandTextOf yields one searchable blob per shape ---
t1="$(tct "out(tct.commandTextOf('Bash', { command: 'echo one' }))")"
assert_eq "5: commandTextOf reads Bash.command" "$t1" "echo one"
t2="$(tct "out(tct.commandTextOf('runInTerminal', { command: 'echo two' }))")"
assert_eq "6: commandTextOf reads runInTerminal.command" "$t2" "echo two"
t3="$(tct "out(tct.commandTextOf('runCommands', { commands: ['a', 'b'] }).replace(/\n/g, '|'))")"
assert_match "7: commandTextOf joins every runCommands element" "$t3" '^a\|b$'

# --- 8-11: commandListOf yields the per-element view the anchors need ---
l1="$(tct "out(tct.commandListOf('Bash', { command: 'echo one' }))")"
assert_eq "8: commandListOf wraps Bash.command in a one-element list" "$l1" '["echo one"]'
l2="$(tct "out(tct.commandListOf('runInTerminal', { command: 'echo two' }))")"
assert_eq "9: commandListOf wraps runInTerminal.command in a one-element list" "$l2" '["echo two"]'
l3="$(tct "out(tct.commandListOf('runCommands', { commands: ['a', 'b'] }))")"
assert_eq "10: commandListOf preserves runCommands order" "$l3" '["a","b"]'
l4="$(tct "out([JSON.stringify(tct.commandListOf('runCommands', {})), JSON.stringify(tct.commandListOf('Edit', { file_path: 'a.txt' })), JSON.stringify(tct.commandListOf('Bash', {}))].join(';'))")"
assert_eq "11: a missing command, a non-command payload and a missing list all yield []" "$l4" "[];[];[]"

# --- 12: commandTextOf on a non-command tool is the empty string, never a throw ---
t4="$(tct "out(JSON.stringify(tct.commandTextOf('Edit', { file_path: 'a.txt', new_string: 'echo x' })))")"
assert_eq "12: commandTextOf returns '' for a non-command tool" "$t4" '""'

# --- 13-15: WHY per-element matching is mandatory — the anchors have no /m flag ---
anch="$(SP="$HOOKS_NODE/lib/sentinel-patterns.js" SENT="$SENTINEL_UV" node -e "
const sp = require(process.env.SP);
const s = process.env.SENT;
const joined = ['git status --short', s].join('\n');
process.stdout.write([
  sp.USER_VERIFIED_RE_DQ.test(s),
  sp.USER_VERIFIED_RE_DQ.test(joined),
  sp.USER_VERIFIED_RE_DQ.flags.includes('m'),
].join(','));
" 2>&1)"
assert_match "13: the strict sentinel regex matches the sentinel element on its own" "$anch" '^true,'
assert_match "14: it does NOT match the joined two-element text (the rc1 trap)" "$anch" '^true,false,'
assert_match "15: the regex carries no /m flag, so joining can never rescue it" "$anch" ',false$'

# --- 16-21: the six migrated hooks must consult the shared accessor, not 'Bash' ---
for h in workflow-gate.js workflow-mark.js confirm-checkpoint.js \
         gate-plan-skip-sentinel.js show-user-verified-context.js supervisor-trigger.js; do
    src="$AGENTS_DIR/hooks/$h"
    if ! grep -q "tool-command-text" "$src" 2>/dev/null; then
        fail "16-21: $h uses the shared command-tool accessor" "no require of hooks/lib/tool-command-text.js"
    elif grep -Eq '!==\s*"Bash"' "$src" 2>/dev/null; then
        fail "16-21: $h uses the shared command-tool accessor" 'a literal !== "Bash" tool-name test remains'
    else
        pass "16-21: $h uses the shared command-tool accessor"
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
