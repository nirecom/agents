#!/usr/bin/env bash
# tests/fix-1780-enforce-workflow-off-emergency.sh
# Tests: skills/enforce-workflow-off/SKILL.md, hooks/lib/sentinel-patterns.js, hooks/supervisor-off-proposal-shim.js, hooks/workflow-mark/enforce-override-handlers/off-clearance.js
# Tags: off-clearance, workflow-off, sentinel, skill-prompt, emergency, scope:issue-specific, pwsh-not-required, TL1, TL2
# TL3 gap (what this test does NOT catch):
# - The shim / workflow-mark firing as REAL hooks inside a live claude -p session
#   (here both are node subprocesses fed a synthetic PreToolUse payload), and the
#   settings.json `ask` permission that makes the EMERGENCY sentinel human-gated.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
#
# #1780 (S-7): /enforce-workflow-off is the *user-invoked, deliberate* escape hatch.
# The standard `<<WORKFLOW_ENFORCE_WORKFLOW_OFF: {reason}>>` sentinel is now gated by the
# OFF-clearance pipeline (Phase-1 examiner + minted token + shim), so a skill that emits it
# unconditionally cannot succeed - it is intercepted by supervisor-off-proposal-shim.js and
# the user is left with a dead slash-command. The emergency sentinel
# `<<WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY: {reason}>>` already exists in the pattern layer
# (hooks/lib/sentinel-patterns.js) and already carries "ask" permission + audit, so the fix is
# a SKILL.md prompt change only - no hook and no settings change.
#
# Section 1 (S1-S4) is TL1: it reads the skill prompt as data and re-validates the extracted
# line against the REAL parser regex (no mock copy of the pattern), so a typo in the SKILL.md
# instruction cannot pass. These are the fail-before-fix (RED) cases for S-7.
#
# Section 2 (E0-E5) is TL2 and is deliberately NOT a fail-before-fix section: it exercises the
# ALREADY-SHIPPED emergency runtime path that S-7 is about to start depending on. A prompt-only
# fix is only safe if the runtime it points at actually works, so these must be GREEN against
# current code. If one of them goes red, the S-7 premise ("the emergency path already exists
# and already carries ask + audit") is false and the fix must be re-planned, not the test.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
SP_NODE="$_AGENTS_DIR_NODE/hooks/lib/sentinel-patterns.js"
SKILL="$AGENTS_DIR/skills/enforce-workflow-off/SKILL.md"
SHIM="$AGENTS_DIR/hooks/supervisor-off-proposal-shim.js"
HANDLER_NODE="$_AGENTS_DIR_NODE/hooks/workflow-mark/enforce-override-handlers.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; SKIP=0
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name - want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1)); fi
}
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'emerg1780'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
cleanup_tmp() { [ -n "${1:-}" ] && [ -d "$1" ] && chmod -R u+w "$1" 2>/dev/null; [ -n "${1:-}" ] && rm -r -f "$1" 2>/dev/null; return 0; }

if [ ! -f "$SKILL" ]; then
    echo "FAIL: S0 skill prompt exists - $SKILL not found"
    echo ""
    echo "Results: 0 passed, 1 failed, 0 skipped"
    exit 1
fi
echo "PASS: S0 skill prompt exists"; PASS=$((PASS + 1))

# ===========================================================================
# Section 1 (TL1) - prompt text vs the real parser regex.
# ===========================================================================

# ---------------------------------------------------------------------------
# S1 - the skill must instruct the EMERGENCY sentinel.
got=no
grep -q 'WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY' "$SKILL" && got=yes
assert_eq "S1 skill instructs the EMERGENCY sentinel" "yes" "$got"

# ---------------------------------------------------------------------------
# S2 - the skill must NOT instruct the standard (clearance-gated) OFF sentinel.
# Matched on the emission form `<<WORKFLOW_ENFORCE_WORKFLOW_OFF:` specifically, so that
# prose mentions of the *name* WORKFLOW_ENFORCE_WORKFLOW_OFF (e.g. permission tables,
# or the _EMERGENCY token itself) do not produce a false positive.
got=no
grep -q '<<WORKFLOW_ENFORCE_WORKFLOW_OFF:' "$SKILL" && got=yes
assert_eq "S2 skill no longer instructs the gated standard sentinel" "no" "$got"

# ---------------------------------------------------------------------------
# S3 - the exact echo line the skill tells the model to run must be accepted by the
# REAL parser (ENFORCE_WORKFLOW_OFF_EMERGENCY_RE_DQ), with {reason} substituted.
# This ties the prompt text to the shipping regex: quoting slips (single quotes, a
# missing `>>`, a stray space after the colon) fail here rather than at runtime.
SKILL_LINE="$(grep -m1 -o 'echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY:[^`]*>>"' "$SKILL" 2>/dev/null || true)"
if [ -z "$SKILL_LINE" ]; then
    echo "FAIL: S3 instructed echo line matches the real parser regex - no candidate echo line found in $SKILL"
    FAIL=$((FAIL + 1))
else
    concrete="${SKILL_LINE//\{reason\}/next-step bug blocks progress}"
    got=$("$RWT" 10 node -e "
const p=require(process.argv[2]);
process.stdout.write(String(p.ENFORCE_WORKFLOW_OFF_EMERGENCY_RE_DQ.test(process.argv[1])));" "$concrete" "$SP_NODE" 2>/dev/null)
    assert_eq "S3 instructed echo line matches the real parser regex" "true" "$got"
fi

# ---------------------------------------------------------------------------
# S4 - orthogonality guard (CPR-5): the counterpart restore skill must keep pointing at
# the plain WORKFLOW_ENFORCE_WORKFLOW_ON sentinel. There is no _EMERGENCY variant of the
# ON side (restoring enforcement is always safe and auto-approved), so the S-7 edit must
# NOT be mirrored onto the ON path.
ON_SKILL="$AGENTS_DIR/skills/enforce-workflow-on/SKILL.md"
if [ -f "$ON_SKILL" ]; then
    got=no
    grep -q 'WORKFLOW_ENFORCE_WORKFLOW_ON_EMERGENCY' "$ON_SKILL" && got=yes
    assert_eq "S4 restore skill has no bogus _EMERGENCY ON variant" "no" "$got"
else
    echo "SKIP: S4 restore skill has no bogus _EMERGENCY ON variant - $ON_SKILL not present"
    SKIP=$((SKIP + 1))
fi

# ===========================================================================
# Section 2 (TL2) - the runtime the S-7 prompt change points at.
#
# The sentinel strings are ASSEMBLED from fragments rather than written literally.
# A literal, well-formed sentinel sitting in a source file is indistinguishable from
# an emission to any tool that scans command text, so building it at runtime keeps
# this file safe to author and edit while producing the exact same bytes the model
# would emit. E0 proves the assembly still matches the shipping regexes.
# ===========================================================================
EMERG_REASON="next-step bug blocks progress"
_S_OPEN="<<"
_S_EMERG="${_S_OPEN}WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY: ${EMERG_REASON}>>"
_S_PLAIN="${_S_OPEN}WORKFLOW_ENFORCE_WORKFLOW_OFF: [workflow-bug] ${EMERG_REASON}>>"
EMERG_CMD="echo \"${_S_EMERG}\""
PLAIN_CMD="echo \"${_S_PLAIN}\""

# E0 - harness self-check. Without it, every assertion below could silently degrade
# into "the shim ignores some unrelated command", which would look green forever.
got=$("$RWT" 10 node -e "
const p=require(process.argv[3]);
process.stdout.write(String(p.ENFORCE_WORKFLOW_OFF_EMERGENCY_RE_DQ.test(process.argv[1])) + ',' +
                     String(p.ENFORCE_WORKFLOW_OFF_RE_DQ.test(process.argv[2])));" \
    "$EMERG_CMD" "$PLAIN_CMD" "$SP_NODE" 2>/dev/null)
assert_eq "E0 harness self-check: assembled sentinels match the real regexes" "true,true" "$got"

mk_input() {  # <sid> <cmd>
    "$RWT" 10 node -e "
process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:process.argv[1],tool_input:{command:process.argv[2]}}));" "$1" "$2"
}

# run_shim <tmp_node> <sid> <cmd> -> "rc|<stdout>"
run_shim() {
    local tn="$1" sid="$2" cmd="$3" hi out rc
    hi=$(mk_input "$sid" "$cmd")
    out=$(WORKFLOW_PLANS_DIR="$tn" CLAUDE_WORKFLOW_DIR="$tn" AGENTS_CONFIG_DIR="$tn" \
        "$RWT" 12 node "$SHIM" <<< "$hi" 2>/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$out"
}
blocked_of() { if echo "$1" | grep -q '"decision":"block"'; then printf 'yes'; else printf 'no'; fi; }

if [ ! -f "$SHIM" ]; then
    echo "SKIP: E1-E3 shim integration - $SHIM not present"; SKIP=$((SKIP + 3))
else
    # E1 - EMERGENCY sentinel through the shim with NO clearance token present.
    # Expected: the Step-1a emergency exclusion fires -> exit 0, no block payload.
    # rc is asserted explicitly so a crash (rc!=0) can never read as "allowed".
    TMP1=$(make_tmp); TN1=$(node_path "$TMP1")
    r=$(run_shim "$TN1" "e1sid" "$EMERG_CMD"); rc="${r%%|*}"; out="${r#*|}"
    ntok=$(ls -1 "$TMP1" 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "E1 emergency sentinel bypasses the clearance gate (rc=0, no block, no token file required)" \
        "0|no|0" "$rc|$(blocked_of "$out")|$ntok"
    cleanup_tmp "$TMP1"

    # E2 - CONTROL (CPR-5 counterpart). The SAME shim, the same empty token dir, but
    # the STANDARD sentinel: it must be blocked. Without this, E1 could pass simply
    # because the shim ignores everything it is fed.
    TMP2=$(make_tmp); TN2=$(node_path "$TMP2")
    r=$(run_shim "$TN2" "e2sid" "$PLAIN_CMD"); rc="${r%%|*}"; out="${r#*|}"
    assert_eq "E2 control: standard sentinel with no token IS blocked by the same shim" \
        "2|yes" "$rc|$(blocked_of "$out")"
    cleanup_tmp "$TMP2"

    # E3 - the emergency bypass must not write anything (no token, no marker, no temp).
    TMP3=$(make_tmp); TN3=$(node_path "$TMP3")
    run_shim "$TN3" "e3sid" "$EMERG_CMD" >/dev/null 2>&1
    leaked=$(ls -1 "$TMP3" 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "E3 shim emergency path writes nothing (read-only bypass)" "0" "$leaked"
    cleanup_tmp "$TMP3"
fi

# E4/E5 - workflow-mark side: the EMERGENCY sentinel must actually ACTIVATE the OFF
# marker and leave an audit entry. This is the half of the runtime that makes the S-7
# prompt change useful; a bypass that activates nothing would be a dead slash-command.
if [ ! -f "$AGENTS_DIR/hooks/workflow-mark/enforce-override-handlers.js" ]; then
    echo "SKIP: E4-E5 workflow-mark integration - enforce-override-handlers.js not present"; SKIP=$((SKIP + 2))
else
    TMP4=$(make_tmp); TN4=$(node_path "$TMP4")
    handled=$(WORKFLOW_PLANS_DIR="$TN4" CLAUDE_WORKFLOW_DIR="$TN4" "$RWT" 12 node -e "
process.stdout.write(String(require(process.argv[1]).handle({cmd:process.argv[2],sessionId:'e4sid',pushMessage:()=>{},signalFatal:()=>{}})));" \
        "$HANDLER_NODE" "$EMERG_CMD" 2>/dev/null)
    marker=no; [ -f "$TMP4/e4sid.workflow-off" ] && marker=yes
    eflag=no; grep -q '"emergency":true' "$TMP4/e4sid.workflow-off" 2>/dev/null && eflag=yes
    assert_eq "E4 emergency sentinel is handled and writes the WORKFLOW_OFF marker with emergency:true" \
        "true|yes|yes" "$handled|$marker|$eflag"

    audited=no
    grep -q 'escape_hatch_event' "$TMP4/e4sid-supervisor-state.json" 2>/dev/null && audited=yes
    assert_eq "E5 emergency activation emits an escape_hatch_event audit entry" "yes" "$audited"
    cleanup_tmp "$TMP4"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
