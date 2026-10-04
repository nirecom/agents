#!/usr/bin/env bash
# Tests: hooks/block-credentials.js, hooks/block-dotenv.js, hooks/block-history-direct.js, hooks/block-memory-direct.js, hooks/lib/tool-command-text.js, hooks/block-capture-echo.js, hooks/block-shell-config.js, hooks/lib/scannable-command-list.js, hooks/workflow-gate.js
# Tags: runcommands-array, tool-command-text, security, scope:issue-specific, pwsh-not-required
# Serial: no

# `runCommands` carries its payload in `tool_input.commands[]`. The five guards
# (credentials, dotenv, history, memory, shell-config) route every command tool
# through commandListOf() and test each element on its own (#2206), so a protected
# operation is denied whether it is the scalar `.command`, the sole array element,
# or hidden behind a benign first element. block-capture-echo.js rows prove the
# array event is well-formed and reachable.
# TL3 gap: hooks run as subprocesses here; no live session dispatches runCommands.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export AGENTS_DIR
# `require()` needs a native path: Git Bash hands back `/c/...`, which Node cannot
# resolve on Windows (rules/coding/nodejs.md "POSIX path normalization").
NODE_AGENTS_DIR="$AGENTS_DIR"
if command -v cygpath >/dev/null 2>&1; then
    NODE_AGENTS_DIR="$(cygpath -m "$AGENTS_DIR")"
fi
SUITE="$AGENTS_DIR/tests/hooks/feature-2170-capture-echo-guard"
command -v node >/dev/null 2>&1 || exit 77
[ -f "$SUITE/mk-event.js" ] || exit 77

PASS=0
FAIL=0

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "PASS: $name"; PASS=$((PASS + 1))
    else
        echo "FAIL: $name — want=$want got=$got"; FAIL=$((FAIL + 1))
    fi
}

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
EV="$TMPD/event.json"
OUT="$TMPD/out.json"

unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
export WORKFLOW_STATE_DIR="$TMPD/workflow"
export WORKFLOW_PLANS_DIR="$TMPD/plans"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR"
cd "$TMPD" || exit 1

# verdict <hook> <tool> <cmd...> -> block|deny-partial|allow|passthrough|other:...
verdict() {
    local hook="$1" tool="$2"
    shift 2
    node "$SUITE/mk-event.js" "$tool" "$@" >"$EV"
    node "$AGENTS_DIR/hooks/$hook" <"$EV" >"$OUT" 2>/dev/null
    node "$SUITE/hook-out.js" "$OUT"
}

# verdict_rc_scalar <hook> <cmd> -> same tokens, for runCommands carrying a scalar
# `.command` (the shape hooks/lib/scannable-command-list.js keeps scanning).
verdict_rc_scalar() {
    node -e 'process.stdout.write(JSON.stringify({session_id:"test-2170",hook_event_name:"PreToolUse",tool_name:"runCommands",tool_input:{command:process.argv[1]}}))' "$2" >"$EV"
    node "$AGENTS_DIR/hooks/$1" <"$EV" >"$OUT" 2>/dev/null
    node "$SUITE/hook-out.js" "$OUT"
}
APPROVE='other:{"decision":"approve"}'

# The memory guard's protected root is derived from the real homedir, so ask the
# module rather than hard-coding a path that would differ per host (CPR-UNV).
MEMDIR="$(node -p "require('$NODE_AGENTS_DIR/hooks/lib/memory-path-check.js').MEMORY_DIR.replace(/\\\\/g,'/')" 2>/dev/null)"
if [ -z "$MEMDIR" ]; then
    assert_eq "RC-0-memory-dir-resolved" "resolved" "MODULE_MISSING"
    MEMDIR="/nonexistent/memory"
fi

# id|hook|triggering command
while IFS='|' read -r id hook trigger; do
    [ -z "$id" ] && continue
    trigger="${trigger//@MEMDIR@/$MEMDIR}"

    # Control: the scalar `.command` field — the operation is genuinely protected.
    assert_eq "$id-a-control-scalar-command-is-denied" \
        "deny-partial" "$(verdict "$hook" Bash "$trigger")"

    # Same operation as the ONLY element of a runCommands array.
    assert_eq "$id-b-array-sole-element-is-denied" \
        "deny-partial" "$(verdict "$hook" runCommands "$trigger")"

    # Same operation hidden behind a benign first element (per-element check).
    assert_eq "$id-c-array-later-element-is-denied" \
        "deny-partial" "$(verdict "$hook" runCommands 'ls' "$trigger")"

    # runInTerminal shares the scalar field; it must stay caught after the switch
    # cases moved into the isCommandTool() branch.
    assert_eq "$id-d-control-runInTerminal-scalar-is-denied" \
        "deny-partial" "$(verdict "$hook" runInTerminal "$trigger")"

    # runCommands with a scalar `.command` instead of commands[] stays scanned.
    assert_eq "$id-e-runCommands-scalar-command-is-denied" \
        "deny-partial" "$(verdict_rc_scalar "$hook" "$trigger")"

    # Allow side (C9): benign elements / benign scalar must not over-block.
    assert_eq "$id-f-array-of-benign-elements-approves" \
        "$APPROVE" "$(verdict "$hook" runCommands 'ls' 'git status')"
    assert_eq "$id-g-runCommands-benign-scalar-approves" \
        "$APPROVE" "$(verdict_rc_scalar "$hook" 'git status')"
done <<TABLE
RC-1|block-credentials.js|cat ~/.aws/credentials
RC-2|block-dotenv.js|cat /repo/.env
RC-3|block-history-direct.js|echo x >> docs/history.md
RC-4|block-memory-direct.js|echo x > @MEMDIR@/MEMORY.md
RC-7|block-shell-config.js|echo x >> ~/.bashrc
TABLE

# --- RC-5: the array event IS reachable — block-capture-echo.js reads commands[] ---
# Without this row a b/c failure above could be explained by a malformed fixture.
CAPTURE='X=$(git rev-parse HEAD); echo "$X"'
assert_eq "RC-5a-capture-echo-sees-array-sole-element" \
    "block" "$(verdict block-capture-echo.js runCommands "$CAPTURE")"
assert_eq "RC-5b-capture-echo-sees-array-later-element" \
    "block" "$(verdict block-capture-echo.js runCommands 'ls' "$CAPTURE")"
assert_eq "RC-5c-capture-echo-array-of-benign-passes" \
    "passthrough" "$(verdict block-capture-echo.js runCommands 'ls' 'git status')"

# --- RC-6: the SSOT helper the guards iterate exposes every array element ---------
listed="$(node -p "JSON.stringify(require('$NODE_AGENTS_DIR/hooks/lib/tool-command-text.js').commandListOf('runCommands',{commands:['a','b']}))" 2>/dev/null)"
assert_eq "RC-6-commandListOf-returns-every-array-element" '["a","b"]' "$listed"

# --- RC-8: workflow-gate judges a runCommands scalar `.command` like the Bash one --
# (commit gate reached; before the fix the scalar read as "" and was approved).
assert_eq "RC-8a-workflow-gate-bash-commit-control" \
    "deny-partial" "$(verdict workflow-gate.js Bash 'git commit -m x')"
assert_eq "RC-8b-workflow-gate-runCommands-scalar-commit-gated" \
    "deny-partial" "$(verdict_rc_scalar workflow-gate.js 'git commit -m x')"
assert_eq "RC-8c-workflow-gate-runCommands-benign-scalar-approves" \
    "$APPROVE" "$(verdict_rc_scalar workflow-gate.js 'git status')"

echo ""
echo "runcommands-array: PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
