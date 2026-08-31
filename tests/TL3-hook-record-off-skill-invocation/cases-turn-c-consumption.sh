# tests/TL3-hook-record-off-skill-invocation/cases-turn-c-consumption.sh
# Turn C: the same-turn producer/consumer seam - the typed command and the
# emergency sentinel live in ONE session - plus the Bash guard canaries and the
# runtime-enforcement probe that keep that turn honest. Sourced by
# ../TL3-hook-record-off-skill-invocation.sh; relies on that file's shared
# fixtures and helpers (run_turn, assert_turn_ok, assert_hook_fired_for,
# assert_recorder_exit_clean, pass/fail, GUARD, GUARD_LOG, EMERG_CMD,
# EMERG_REASON, SID3, MARKER3, OVERRIDE_MARKER3, AUDIT3, PLANSDIR, node_path).
# Tests: hooks/record-off-skill-invocation.js, hooks/workflow-mark.js, hooks/workflow-mark/enforce-override-handlers/off-clearance.js
# Tags: off-clearance, emergency-off, provenance, hook, userpromptsubmit, posttooluse, TL3, run-e2e, scope:common

run_turn_C_consumption() {
echo ""
echo "=== C: same-turn CONSUMPTION - invocation and emergency sentinel together ==="
# Turns A/B only prove the PRODUCER writes a file. The claim the feature actually
# makes is that a marker written by the real UserPromptSubmit hook is read, in the
# SAME turn, by the real PostToolUse consumer - so the emergency activation is
# stamped provenance=user_skill_invocation instead of unattributed (#1780 M-2).
# That needs both halves live in one turn: the typed command on line 1 (producer)
# and the emergency sentinel as a Bash tool call (consumer trigger).
# The PreToolUse guard (see GUARD above) denies any Bash call whose command does
# not match this exact string - so a live model given free Bash cannot wander
# off the sentinel even if it ignores the prompt's instruction.
export TL3_ALLOWED_BASH_CMD="$EMERG_CMD"

# Canary: a green turn C below would look identical whether the guard denied
# anything or never ran at all - this exercises its own decision logic directly.
GUARD_NODE_PATH="$(node_path "$GUARD")"
GUARD_ALLOW_PAYLOAD=$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.env.TL3_ALLOWED_BASH_CMD}}))')
GUARD_ALLOW_OUT=$(printf '%s' "$GUARD_ALLOW_PAYLOAD" | node "$GUARD_NODE_PATH")
if printf '%s' "$GUARD_ALLOW_OUT" | grep -qF '"decision":"approve"'; then
    pass "guard-canary-approves-the-expected-command"
else
    fail "guard-canary-approves-the-expected-command" "$GUARD_ALLOW_OUT"
fi
GUARD_DENY_PAYLOAD=$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"echo not-the-sentinel"}}))')
GUARD_DENY_OUT=$(printf '%s' "$GUARD_DENY_PAYLOAD" | node "$GUARD_NODE_PATH")
if printf '%s' "$GUARD_DENY_OUT" | grep -qF '"decision":"block"'; then
    pass "guard-canary-denies-a-different-command"
else
    fail "guard-canary-denies-a-different-command" "$GUARD_DENY_OUT"
fi

# Runtime-enforcement probe: the two canaries above only pin the guard SCRIPT's
# own decision logic, never that the CC runtime actually calls it and honors a
# deny under --dangerously-skip-permissions. A second, disallowed command inside
# this same live turn closes that gap - if the runtime ignored the guard, this
# file would exist and GUARD_LOG would carry no record of the attempt.
PROBE_FILE="$BASE/should-not-exist.txt"
PROBE_FILE_M="$(node_path "$PROBE_FILE")"
PROBE_CMD="echo probe > \"$PROBE_FILE_M\""
GUARD_LOG_BASELINE=0
[ -f "$GUARD_LOG" ] && GUARD_LOG_BASELINE=$(wc -l < "$GUARD_LOG" | tr -d '[:space:]')

run_turn "$SID3" "/enforce-workflow-off $EMERG_REASON
Do not read any files, do not explain.
Run exactly these two Bash commands, in this order, once each:
1. $EMERG_CMD
2. $PROBE_CMD
Then reply with the single word: done" --tools Bash
assert_turn_ok "turn-c-cli-exit-zero" "$BASE/$SID3.out"
assert_hook_fired_for "turn-c-userpromptsubmit-fired" "$SID3"
assert_recorder_exit_clean "turn-c-recorder-exited-cleanly" "$SID3"

# The runtime-enforcement probe's verdict: a guard the runtime ignored would let
# the model's second command actually run, leaving this file behind.
if [ -f "$PROBE_FILE" ]; then
    fail "guard-blocks-a-second-command-at-runtime" "the disallowed probe command ran and created $PROBE_FILE - the live CC runtime did not honor the guard's deny"
else
    pass "guard-blocks-a-second-command-at-runtime"
fi
# ...and the guard was actually consulted for it, not merely absent from the run:
# an empty GUARD_LOG delta here would mean the model never attempted the probe,
# which proves nothing about enforcement either way.
GUARD_LOG_AFTER=0
[ -f "$GUARD_LOG" ] && GUARD_LOG_AFTER=$(wc -l < "$GUARD_LOG" | tr -d '[:space:]')
if [ "$GUARD_LOG_AFTER" -gt "$GUARD_LOG_BASELINE" ] && tail -n "+$((GUARD_LOG_BASELINE + 1))" "$GUARD_LOG" 2>/dev/null | grep -qF -- "$PROBE_CMD"; then
    pass "guard-log-records-the-runtime-denial"
else
    fail "guard-log-records-the-runtime-denial" "no new $GUARD_LOG entry for the probe command during turn C - the guard was never consulted for it (baseline=$GUARD_LOG_BASELINE after=$GUARD_LOG_AFTER)"
fi

if [ ! -f "$OVERRIDE_MARKER3" ]; then
    fail "consumer-wrote-the-override-marker" "no $SID3.workflow-off - the emergency sentinel never reached hooks/workflow-mark.js in this turn (did the session run the Bash command? $(head -c 400 "$BASE/$SID3.out" 2>/dev/null))"
else
    pass "consumer-wrote-the-override-marker"
    OVERRIDE_BODY="$(cat "$OVERRIDE_MARKER3" 2>/dev/null)"
    # The whole point: `unattributed` here means the marker the producer wrote was
    # not readable as evidence by the consumer - the exact #1780 M-2 failure.
    if printf '%s' "$OVERRIDE_BODY" | grep -qF -- '"provenance":"user_skill_invocation"'; then
        pass "override-marker-stamped-user_skill_invocation"
    else
        fail "override-marker-stamped-user_skill_invocation" "the live producer/consumer seam did not attribute the activation: $(printf '%.300s' "$OVERRIDE_BODY")"
    fi
fi

# Single-use: consumption must REMOVE the producer's marker, or one invocation
# would keep vouching for every later emission in the session.
if [ -f "$MARKER3" ]; then
    fail "provenance-marker-consumed-in-the-same-turn" "the marker survived consumption at $MARKER3"
else
    pass "provenance-marker-consumed-in-the-same-turn"
fi

# The audit record is the durable half of the claim; the override marker alone is
# session state that disappears with the session.
if [ ! -f "$AUDIT3" ]; then
    fail "audit-record-written" "no $SID3-supervisor-state.json in $PLANSDIR - the activation left no audit trail"
else
    pass "audit-record-written"
    AUDIT_BODY="$(cat "$AUDIT3" 2>/dev/null)"
    # Pretty-printed JSON, so key and value are whitespace-separated (unlike the
    # compact override marker above).
    if printf '%s' "$AUDIT_BODY" | grep -qE '"record_type"[[:space:]]*:[[:space:]]*"escape_hatch_event"'; then
        pass "audit-record-is-an-escape_hatch_event"
    else
        fail "audit-record-is-an-escape_hatch_event" "the audit trail has no escape_hatch_event for this activation: $(printf '%.400s' "$AUDIT_BODY")"
    fi
    if printf '%s' "$AUDIT_BODY" | grep -qE '"provenance"[[:space:]]*:[[:space:]]*"user_skill_invocation"'; then
        pass "audit-record-stamped-user_skill_invocation"
    else
        fail "audit-record-stamped-user_skill_invocation" "the audit trail did not record the activation as user-invoked: $(printf '%.400s' "$AUDIT_BODY")"
    fi
fi
}
