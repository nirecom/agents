#!/usr/bin/env bash
# Tests: hooks/block-credentials.js, hooks/block-dotenv.js, hooks/block-history-direct.js, hooks/block-memory-direct.js, hooks/lib/tool-command-text.js, hooks/block-capture-echo.js
# Tags: runcommands-array, tool-command-text, security, known-gap, characterization, scope:issue-specific, pwsh-not-required
# Serial: no

# Round 13, C6 — `runCommands` carries its payload in `tool_input.commands[]`, but the
# four extracted guards read `tool_input.command`, which is undefined for that tool.
# CHARACTERIZATION: rows named KNOWN-GAP pin today's (bypassing) behaviour so a source
# fix flips a named row; each is paired with a `.command` control proving the very same
# operation IS caught, and with a block-capture-echo.js control proving the array event
# is well-formed and reachable. Fixing the guards is out of scope for a tests-only round.
# TL3 gap: hooks run as subprocesses here; no live session dispatches runCommands.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export AGENTS_DIR
# `require()` needs a native path: Git Bash hands back `/c/...`, which Node cannot
# resolve on Windows (rules/coding/nodejs.md "POSIX path normalization").
NODE_AGENTS_DIR="$AGENTS_DIR"
if command -v cygpath >/dev/null 2>&1; then
    NODE_AGENTS_DIR="$(cygpath -m "$AGENTS_DIR")"
fi
SUITE="$AGENTS_DIR/tests/feature-2170-capture-echo-guard"
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

unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
export CLAUDE_WORKFLOW_DIR="$TMPD/workflow"
export WORKFLOW_PLANS_DIR="$TMPD/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"

# verdict <hook> <tool> <cmd...> -> block|deny-partial|allow|passthrough|other:...
verdict() {
    local hook="$1" tool="$2"
    shift 2
    node "$SUITE/mk-event.js" "$tool" "$@" >"$EV"
    node "$AGENTS_DIR/hooks/$hook" <"$EV" >"$OUT" 2>/dev/null
    node "$SUITE/hook-out.js" "$OUT"
}

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

    # KNOWN GAP: same operation as the ONLY element of a runCommands array.
    assert_eq "$id-b-KNOWN-GAP-array-sole-element-bypasses" \
        "other:{\"decision\":\"approve\"}" "$(verdict "$hook" runCommands "$trigger")"

    # KNOWN GAP: same operation hidden behind a benign first element.
    assert_eq "$id-c-KNOWN-GAP-array-later-element-bypasses" \
        "other:{\"decision\":\"approve\"}" "$(verdict "$hook" runCommands 'ls' "$trigger")"

    # Control: runInTerminal shares the scalar field, so it must still be caught —
    # this isolates the defect to the array shape, not to the non-Bash tool name.
    assert_eq "$id-d-control-runInTerminal-scalar-is-denied" \
        "deny-partial" "$(verdict "$hook" runInTerminal "$trigger")"
done <<TABLE
RC-1|block-credentials.js|cat ~/.aws/credentials
RC-2|block-dotenv.js|cat /repo/.env
RC-3|block-history-direct.js|echo x >> docs/history.md
RC-4|block-memory-direct.js|echo x > @MEMDIR@/MEMORY.md
TABLE

# --- RC-5: the array event IS reachable — block-capture-echo.js reads commands[] ---
# Without this row every KNOWN-GAP above could be explained by a malformed fixture.
CAPTURE='X=$(git rev-parse HEAD); echo "$X"'
assert_eq "RC-5a-capture-echo-sees-array-sole-element" \
    "block" "$(verdict block-capture-echo.js runCommands "$CAPTURE")"
assert_eq "RC-5b-capture-echo-sees-array-later-element" \
    "block" "$(verdict block-capture-echo.js runCommands 'ls' "$CAPTURE")"
assert_eq "RC-5c-capture-echo-array-of-benign-passes" \
    "passthrough" "$(verdict block-capture-echo.js runCommands 'ls' 'git status')"

# --- RC-6: the SSOT helper already exposes the array; only the guards ignore it ----
listed="$(node -p "JSON.stringify(require('$NODE_AGENTS_DIR/hooks/lib/tool-command-text.js').commandListOf('runCommands',{commands:['a','b']}))" 2>/dev/null)"
assert_eq "RC-6-commandListOf-returns-every-array-element" '["a","b"]' "$listed"

echo ""
echo "runcommands-array: PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
