# tests/TL3-hook-record-off-skill-invocation/cases-turn-b-negative-control.sh
# Turn B: the negative control - prose that merely NAMES the skill, in its own
# session, must leave no provenance marker. Sourced by
# ../TL3-hook-record-off-skill-invocation.sh; relies on that file's shared
# fixtures and helpers (run_turn, assert_turn_ok, assert_hook_fired_for,
# assert_recorder_exit_clean, pass/fail, SID2, MARKER2, BASE).
# Tests: hooks/record-off-skill-invocation.js, hooks/workflow-mark.js, hooks/workflow-mark/enforce-override-handlers/off-clearance.js
# Tags: off-clearance, emergency-off, provenance, hook, userpromptsubmit, posttooluse, TL3, run-e2e, scope:common

run_turn_B_negative_control() {
echo ""
echo "=== B: negative control - an unrelated prompt in another session ==="
run_turn "$SID2" "please refactor the parser, do not mention enforce-workflow-off" --tools ""
assert_turn_ok "turn-b-cli-exit-zero" "$BASE/$SID2.out"

# Order matters: the absent-marker claim is only worth making once the turn is
# known to have run AND the hook is known to have seen this turn's prompt.
assert_hook_fired_for "turn-b-userpromptsubmit-fired" "$SID2"
# ...and the recorder for this turn finished on its own terms: THIS is what turns
# the absent marker below from "nothing happened" into "the hook declined".
assert_recorder_exit_clean "turn-b-recorder-exited-cleanly" "$SID2"
if [ -f "$MARKER2" ]; then
    fail "no-marker-for-an-unrelated-prompt" "prose that merely names the skill produced a provenance marker at $MARKER2"
else
    pass "no-marker-for-an-unrelated-prompt"
fi
if [ -s "$BASE/$SID2.out" ]; then
    pass "turn-b-produced-output"
else
    fail "turn-b-produced-output" "the control session produced no output - the absent marker proves nothing"
fi
}
