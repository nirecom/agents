# tests/TL3-hook-record-off-skill-invocation/cases-turn-a-invocation.sh
# Turn A (a real typed /enforce-workflow-off slash command in a live session) and
# the production-command fidelity replay that follows it. Sourced by
# ../TL3-hook-record-off-skill-invocation.sh; relies on that file's shared
# fixtures and helpers (run_turn, assert_turn_ok, assert_recorder_exit_clean,
# pass/fail, CAPTURE, MARKER, MARKER_KIND, SID, BASE, PLANSDIR, node_path,
# run_with_timeout).
# Tests: hooks/record-off-skill-invocation.js, hooks/workflow-mark.js, hooks/workflow-mark/enforce-override-handlers/off-clearance.js
# Tags: off-clearance, emergency-off, provenance, hook, userpromptsubmit, posttooluse, TL3, run-e2e, scope:common

run_turn_A_invocation() {
echo "=== A: a real typed /enforce-workflow-off slash command ==="
run_turn "$SID" "/enforce-workflow-off TL3 provenance seam check" --tools ""
assert_turn_ok "turn-a-cli-exit-zero" "$BASE/$SID.out"

if [ ! -s "$BASE/$SID.out" ]; then
    fail "turn-a-produced-output" "the session produced no output - every assertion below would be vacuous"
else
    pass "turn-a-produced-output"
fi

if [ ! -f "$CAPTURE" ]; then
    fail "userpromptsubmit-fired" "no stdin was captured - UserPromptSubmit never reached the hook"
else
    pass "userpromptsubmit-fired"
    # The typed command must survive into `prompt` intact. This also catches the
    # MSYS mangling above: a rewritten argument still fires the hook, so without
    # this the run would look green while never testing a slash command.
    if grep -qF -- '"prompt":"/enforce-workflow-off TL3 provenance seam check"' "$CAPTURE"; then
        pass "typed-slash-command-delivered-verbatim"
    else
        fail "typed-slash-command-delivered-verbatim" "the captured payload does not carry the typed command as its prompt: $(head -c 400 "$CAPTURE")"
    fi
fi

assert_recorder_exit_clean "turn-a-recorder-exited-cleanly" "$SID"

if [ ! -f "$MARKER" ]; then
    fail "provenance-marker-written" "the real hook did not accept the real payload: no $SID.$MARKER_KIND"
else
    pass "provenance-marker-written"
    BODY="$(cat "$MARKER" 2>/dev/null)"
    if printf '%s' "$BODY" | grep -qF -- '"source":"user_skill_invocation"'; then
        pass "provenance-marker-attributes-the-user"
    else
        fail "provenance-marker-attributes-the-user" "marker content is not an attributed payload: $(printf '%.300s' "$BODY")"
    fi
    if run_with_timeout 20 node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$(node_path "$MARKER")" >/dev/null 2>&1; then
        pass "provenance-marker-is-valid-json"
    else
        fail "provenance-marker-is-valid-json" "the consumer parses this file; a corrupt one degrades silently to unattributed"
    fi
fi
}

run_production_command_fidelity() {
# The registered PRODUCTION command string, replayed on turn A's real payload:
# P9 only checks that string is present in settings.json and the wrapper above
# spawns the hook by argv, so neither one ever runs it - a quoting, timeout or
# $AGENTS_CONFIG_DIR-expansion regression would pass both suites silently.
PROD_CMD=$(run_with_timeout 20 node -e '
const s = require(process.argv[1]);
const hooks = ((s.hooks || {}).UserPromptSubmit || []);
const cmds = hooks.flatMap((h) => (h.hooks || []).map((x) => String(x.command || "")));
process.stdout.write(cmds.find((c) => c.includes("record-off-skill-invocation.js")) || "");
' "$(node_path "$AGENTS_DIR/settings.json")" 2>/dev/null)
# FRESH dir, never $WFDIR: the wrapper already wrote a marker there, so reusing it
# would let this assertion pass with the production command entirely broken.
PROD_WFDIR="$BASE/prod-workflow"; mkdir -p "$PROD_WFDIR"
PROD_MARKER="$PROD_WFDIR/$SID.$MARKER_KIND"
PROD_PAYLOAD="$BASE/prod-payload.json"
PROD_OUT="$BASE/prod-cmd.out"
[ -f "$CAPTURE" ] && sed -n '/^---$/q;p' "$CAPTURE" > "$PROD_PAYLOAD" 2>/dev/null
if [ -z "$PROD_CMD" ]; then
    fail "production-command-records-provenance" "settings.json registers no UserPromptSubmit command containing record-off-skill-invocation.js"
elif [ ! -s "$PROD_PAYLOAD" ]; then
    fail "production-command-records-provenance" "no captured turn-A payload to replay through the registered command"
else
    ( CLAUDE_WORKFLOW_DIR="$(node_path "$PROD_WFDIR")" \
      WORKFLOW_PLANS_DIR="$(node_path "$PLANSDIR")" \
      AGENTS_CONFIG_DIR="$(node_path "$AGENTS_DIR")" \
      run_with_timeout 20 bash -c "$PROD_CMD" <"$PROD_PAYLOAD" >"$PROD_OUT" 2>&1 )
    PROD_STATUS=$?
    if [ "$PROD_STATUS" -eq 0 ]; then
        pass "production-command-exits-zero"
    else
        fail "production-command-exits-zero" "\`$PROD_CMD\` exited $PROD_STATUS on the real payload: $(head -c 400 "$PROD_OUT" 2>/dev/null)"
    fi
    if [ ! -f "$PROD_MARKER" ]; then
        fail "production-command-wrote-the-marker" "the registered command wrote no $SID.$MARKER_KIND into $PROD_WFDIR - the wrapper's argv invocation works but production's would not: $(head -c 400 "$PROD_OUT" 2>/dev/null)"
    else
        pass "production-command-wrote-the-marker"
        PROD_BODY="$(cat "$PROD_MARKER" 2>/dev/null)"
        if printf '%s' "$PROD_BODY" | grep -qF -- '"source":"user_skill_invocation"'; then
            pass "production-command-attributes-the-user"
        else
            fail "production-command-attributes-the-user" "marker content is not an attributed payload: $(printf '%.300s' "$PROD_BODY")"
        fi
    fi
fi
}
