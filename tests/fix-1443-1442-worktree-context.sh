#!/usr/bin/env bash
# tests/fix-1443-1442-worktree-context.sh
# Tests: hooks/detect-worktree-conflict.js, skills/worktree-end/SKILL.md, settings.json
# Tags: worktree-end, worktree-context, hook-registration, scope:issue-specific, pwsh-not-required
#
# Issue #1443 / #1442 — keep CWD in the linked worktree until WE-13, detect
# `git worktree add`-style "already used by worktree" conflicts. The sibling
# session-id scan (Sections B/C) lives in tests/fix-1443-1442-session-id-resolvers.sh.
#
# FAIL-BEFORE-FIX (BUGFIX session): the implementation does NOT exist yet.
#   - hooks/detect-worktree-conflict.js is a NEW file — Section A cases FAIL with
#     "hook file missing (expected pre-implementation)".
#   - WE-7/WE-8/Rules text and the settings.json PostToolUse entry do not exist —
#     Sections D/E FAIL on the missing grep target / JSON entry.
# Every FAIL below must be attributable to a missing implementation, never to a
# harness bug.
#
# HIGH-1 own-worktree exclusion (codex review) — fix cases in this file:
#   - A8 (FAIL now): tool_name "runInTerminal" reaches the hook once the matcher/guard
#     widen to Bash|runInTerminal|runCommands; today only "Bash" is admitted -> noop.
#   - E2 (FAIL now): settings.json matcher must be "Bash|runInTerminal|runCommands".
#
# L3 gap (what this L2 test does NOT catch):
# - Real `claude -p` session CWD switching: whether Claude actually stays in the
#   linked worktree through WE-12 is only observable in a live session.
# - Whether detect-worktree-conflict.js actually fires in the real host process
#   requires the settings.json PostToolUse wiring that only a live CC session confirms.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK="$AGENTS_DIR/hooks/detect-worktree-conflict.js"
HOOK_NODE="$AGENTS_DIR_NODE/hooks/detect-worktree-conflict.js"
SKILL_MD="$AGENTS_DIR/skills/worktree-end/SKILL.md"
SETTINGS_JSON="$AGENTS_DIR_NODE/settings.json"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# ===========================================================================
# Section A — detect-worktree-conflict.js (PostToolUse hook, JSON stdin)
# Table-driven per skills/_shared/test-design/parser-regex-tests.md.
# ===========================================================================
echo ""
echo "=== Section A — detect-worktree-conflict.js (JSON stdin) ==="

STDERR_MATCH="fatal: 'main' is already used by worktree at 'C:/git/agents'"

# run_conflict_hook <json> -> stdout of hook (empty on noop / non-zero exit).
run_conflict_hook() {
    local json="$1"
    local infile
    infile="$(mktemp)"
    printf '%s' "$json" > "$infile"
    run_with_timeout 10 node "$HOOK_NODE" < "$infile" 2>/dev/null
    local rc=$?
    rm -f "$infile"
    return $rc
}

# assert_conflict_output <id> <desc> <json> <needle...>
# PASS when hook stdout is non-empty AND contains every needle.
assert_conflict_output() {
    local id="$1" desc="$2" json="$3"; shift 3
    if [ ! -f "$HOOK" ]; then
        fail "$id. $desc — hook file missing (expected pre-implementation): hooks/detect-worktree-conflict.js"
        return
    fi
    local out n missing=""
    out="$(run_conflict_hook "$json")"
    if [ -z "$out" ]; then
        fail "$id. $desc — expected additionalContext output, got empty stdout"
        return
    fi
    for n in "$@"; do
        printf '%s' "$out" | grep -qF "$n" || missing="$missing '$n'"
    done
    if [ -z "$missing" ]; then
        pass "$id. $desc"
    else
        fail "$id. $desc — stdout missing:$missing — got: $out"
    fi
}

# assert_conflict_noop <id> <desc> <json>
# PASS when hook exits 0 AND emits no stdout.
assert_conflict_noop() {
    local id="$1" desc="$2" json="$3"
    if [ ! -f "$HOOK" ]; then
        fail "$id. $desc — hook file missing (expected pre-implementation): hooks/detect-worktree-conflict.js"
        return
    fi
    local out rc
    out="$(run_conflict_hook "$json")"; rc=$?
    if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
        pass "$id. $desc"
    else
        fail "$id. $desc — expected exit 0 + no output, got rc=$rc out='$out'"
    fi
}

# A1: Bash + exit_code 1 + matching stderr -> additionalContext + branch + worktree path.
assert_conflict_output "A1" "Bash + exit_code 1 + matching stderr -> additionalContext + branch + path" \
    "$(node -e 'const s=process.argv[1];process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"git worktree add x"},tool_response:{exit_code:1,stderr:s}}))' "$STDERR_MATCH")" \
    "additionalContext" "main" "C:/git/agents"

# A1b: exitCode 1 (camelCase, no snake_case field) + matching stderr -> same match output.
# CPR-5 counterpart of A4b: the camelCase field must drive the FAILURE path too,
# not only the success-noop path.
assert_conflict_output "A1b" "exitCode 1 (camelCase) + matching stderr -> additionalContext + branch + path" \
    "$(node -e 'const s=process.argv[1];process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"git worktree add x"},tool_response:{exitCode:1,stderr:s}}))' "$STDERR_MATCH")" \
    "additionalContext" "main" "C:/git/agents"

# A2: Bash + exit_code 1 + non-matching stderr -> noop.
assert_conflict_noop "A2" "Bash + exit_code 1 + unrelated stderr -> noop" \
    '{"tool_name":"Bash","tool_input":{"command":"git worktree add x"},"tool_response":{"exit_code":1,"stderr":"some other error"}}'

# A3: Read tool with matching stderr -> noop (tool_name gate).
assert_conflict_noop "A3" "Read tool + matching stderr -> noop" \
    "$(node -e 'const s=process.argv[1];process.stdout.write(JSON.stringify({tool_name:"Read",tool_input:{},tool_response:{exit_code:1,stderr:s}}))' "$STDERR_MATCH")"

# A4: exit_code 0 + matching stderr -> noop (success contract, snake_case).
assert_conflict_noop "A4" "exit_code 0 + matching stderr -> noop" \
    "$(node -e 'const s=process.argv[1];process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{},tool_response:{exit_code:0,stderr:s}}))' "$STDERR_MATCH")"

# A4b: exitCode 0 (camelCase, no snake_case field) + matching stderr -> noop.
assert_conflict_noop "A4b" "exitCode 0 (camelCase) + matching stderr -> noop" \
    "$(node -e 'const s=process.argv[1];process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{},tool_response:{exitCode:0,stderr:s}}))' "$STDERR_MATCH")"

# A4c: success true (no exit codes) + matching stderr -> noop.
assert_conflict_noop "A4c" "success true (no exit codes) + matching stderr -> noop" \
    "$(node -e 'const s=process.argv[1];process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{},tool_response:{success:true,stderr:s}}))' "$STDERR_MATCH")"

# A4d: success false (no exit codes) + matching stderr -> additionalContext (trigger side).
# The 3-field contract treats success===false as exit 1, so the hook must fire.
assert_conflict_output "A4d" "success false (no exit codes) + matching stderr -> additionalContext + branch" \
    "$(node -e 'const s=process.argv[1];process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{},tool_response:{success:false,stderr:s}}))' "$STDERR_MATCH")" \
    "additionalContext" "main"

# A4e: exit_code 0 + success false + matching stderr -> noop (field precedence).
# The 3-field contract is: exit_code ?? exitCode ?? (success===false ? 1 : 0).
# An explicit exit_code:0 wins over success:false, so the hook must NOT fire.
assert_conflict_noop "A4e" "exit_code 0 + success false + matching stderr -> noop (exit_code wins)" \
    "$(node -e 'const s=process.argv[1];process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{},tool_response:{success:false,exit_code:0,stderr:s}}))' "$STDERR_MATCH")"

# A5: no stderr field + exit_code 1 -> noop.
assert_conflict_noop "A5" "no stderr field + exit_code 1 -> noop" \
    '{"tool_name":"Bash","tool_input":{},"tool_response":{"exit_code":1}}'

# A6: malformed JSON stdin -> exit 0 fail-open, no crash.
if [ ! -f "$HOOK" ]; then
    fail "A6. malformed JSON stdin -> exit 0 fail-open — hook file missing (expected pre-implementation): hooks/detect-worktree-conflict.js"
else
    a6_out="$(printf '%s' 'NOT JSON {{{' | run_with_timeout 10 node "$HOOK_NODE" 2>/dev/null)"; a6_rc=$?
    if [ "$a6_rc" -eq 0 ] && [ -z "$a6_out" ]; then
        pass "A6. malformed JSON stdin -> exit 0 fail-open, no output"
    else
        fail "A6. malformed JSON stdin -> exit 0 fail-open — got rc=$a6_rc out='$a6_out'"
    fi
fi

# A7: exported WORKTREE_CONFLICT_RE matches the canonical stderr, table-driven.
#
# SKIPPED: mutation probe (bin/mutation-probe.sh hooks/detect-worktree-conflict.js)
#   verifying WORKTREE_CONFLICT_RE is exercised by these tests (>=80% kill score).
# Because: the target file does not exist yet (fail-before-fix) — the probe must
#   be run post-implementation, at the write-code stage, once the regex constant lands.
# L3 gap: without the probe, a dead (never-exercised) regex constant in the shipped
#   hook would go undetected by this table alone.
if [ ! -f "$HOOK" ]; then
    fail "A7. WORKTREE_CONFLICT_RE regex table — hook file missing (expected pre-implementation): hooks/detect-worktree-conflict.js"
else
    while IFS='|' read -r name input want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        want="${want//[[:space:]]/}"
        got="$(RE_INPUT="$input" run_with_timeout 10 node -e '
const m = require(process.argv[1]);
const re = m.WORKTREE_CONFLICT_RE;
if (!(re instanceof RegExp)) { process.stdout.write("NO_RE"); process.exit(0); }
const mm = process.env.RE_INPUT.match(re);
process.stdout.write(mm ? "match:" + mm[1] : "nomatch");
' "$HOOK_NODE" 2>/dev/null)"
        if [ "$got" = "$want" ]; then
            pass "A7-$name. WORKTREE_CONFLICT_RE"
        else
            fail "A7-$name. WORKTREE_CONFLICT_RE — want='$want' got='$got'"
        fi
    done <<TABLE
main|fatal: 'main' is already used by worktree at 'C:/git/agents'|match:main
branchslash|fatal: 'fix/1443' is already used by worktree at '/x'|match:fix/1443
unrelated|fatal: something totally different|nomatch
TABLE
fi

# A8: tool_name "runInTerminal" + exit_code 1 + matching stderr -> additionalContext.
# The matcher widens from "Bash" to "Bash|runInTerminal|runCommands" (settings.json)
# plus an internal tool_name guard over the same 3-tool set. Currently the hook's
# tool_name guard admits only "Bash", so runInTerminal noops -> empty stdout.
assert_conflict_output "A8" "runInTerminal + exit_code 1 + matching stderr -> additionalContext + branch" \
    "$(node -e 'const s=process.argv[1];process.stdout.write(JSON.stringify({tool_name:"runInTerminal",tool_input:{command:"git worktree add x"},tool_response:{exit_code:1,stderr:s}}))' "$STDERR_MATCH")" \
    "additionalContext" "main"

# A8b: tool_name "runCommands" + exit_code 1 + matching stderr -> additionalContext.
# CPR-5 counterpart of A8: all three admitted tools must trigger the hook.
assert_conflict_output "A8b" "runCommands + exit_code 1 + matching stderr -> additionalContext + branch" \
    "$(node -e 'const s=process.argv[1];process.stdout.write(JSON.stringify({tool_name:"runCommands",tool_input:{command:"git worktree add x"},tool_response:{exit_code:1,stderr:s}}))' "$STDERR_MATCH")" \
    "additionalContext" "main"

# A9: runInTerminal + exit_code 1 + non-matching stderr -> noop (deny path).
# Mirrors A2's deny case for the runInTerminal admission: the tool name is now
# admitted by the matcher, but a non-matching stderr must still produce no output.
assert_conflict_noop "A9" "runInTerminal + exit_code 1 + unrelated stderr -> noop" \
    '{"tool_name":"runInTerminal","tool_input":{"command":"git worktree add x"},"tool_response":{"exit_code":1,"stderr":"error: pathspec '"'"'foo'"'"' did not match any file(s) known to git"}}'

# ===========================================================================
# Section D — skills/worktree-end/SKILL.md WE-7/WE-8/Rules additions.
# ===========================================================================
echo ""
echo "=== Section D — worktree-end SKILL.md text ==="

D_NEEDLE="do not switch to main worktree before WE-13"

# D1: the WE-13 guidance sentence is present at least once.
if grep -qF "$D_NEEDLE" "$SKILL_MD"; then
    pass "D1. WE-7/WE-8 carries '$D_NEEDLE'"
else
    fail "D1. missing '$D_NEEDLE' in $SKILL_MD (WE-7/WE-8 addition not implemented)"
fi

# D2: the sentence appears >=2 times (WE-7 + WE-8).
d2_count="$(grep -cF "$D_NEEDLE" "$SKILL_MD")"
if [ "${d2_count:-0}" -ge 2 ]; then
    pass "D2. WE-13 guidance appears >=2 times (count=$d2_count)"
else
    fail "D2. WE-13 guidance must appear >=2 times (WE-7 + WE-8) — count=${d2_count:-0}"
fi

# D3: the Rules bullet is present.
if grep -qF "CWD must remain in the linked worktree" "$SKILL_MD"; then
    pass "D3. Rules bullet 'CWD must remain in the linked worktree' present"
else
    fail "D3. missing Rules bullet 'CWD must remain in the linked worktree' (not implemented)"
fi

# ===========================================================================
# Section E — settings.json PostToolUse registration.
# ===========================================================================
echo ""
echo "=== Section E — settings.json registration ==="

e1_out="$(run_with_timeout 10 node -e "
const s = require('$SETTINGS_JSON');
const arr = (s.hooks && s.hooks.PostToolUse) || [];
const found = arr.some(group =>
    Array.isArray(group.hooks) &&
    group.hooks.some(h => typeof h.command === 'string' && h.command.includes('detect-worktree-conflict.js'))
);
process.stdout.write(found ? 'FOUND' : 'MISSING');
" 2>/dev/null)"
if [ "$e1_out" = "FOUND" ]; then
    pass "E1. settings.json PostToolUse registers detect-worktree-conflict.js"
else
    fail "E1. settings.json PostToolUse must register detect-worktree-conflict.js — got '$e1_out'"
fi

# E2: the PostToolUse group registering detect-worktree-conflict.js must carry
# matcher exactly "Bash|runInTerminal|runCommands" (widened from "Bash"). Currently
# the matcher is "Bash", so runInTerminal/runCommands never trigger the hook.
e2_out="$(run_with_timeout 10 node -e "
const s = require('$SETTINGS_JSON');
const arr = (s.hooks && s.hooks.PostToolUse) || [];
const group = arr.find(g =>
    Array.isArray(g.hooks) &&
    g.hooks.some(h => typeof h.command === 'string' && h.command.includes('detect-worktree-conflict.js'))
);
process.stdout.write(group ? String(group.matcher) : 'NO_GROUP');
" 2>/dev/null)"
if [ "$e2_out" = "Bash|runInTerminal|runCommands" ]; then
    pass "E2. detect-worktree-conflict.js matcher is 'Bash|runInTerminal|runCommands'"
else
    fail "E2. matcher must be 'Bash|runInTerminal|runCommands' — got '$e2_out' (matcher not widened)"
fi

# ===========================================================================
# Results
# ===========================================================================
echo ""
TOTAL=$((PASS + FAIL))
echo "Results: $PASS passed, $FAIL failed ($TOTAL total)"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
