# #2277 per-stage off handling: intent has no off waiver (offWaivable:false), so CONFIRM_INTENT=off
# no longer skips the dialog; CONFIRM_DETAIL=off still does. The transcript is unreadable here,
# so the plan-link judgement fails open and only the skip branch decides the output.
# T27-T28 repeat the intent/outline pair with plan-stage-table unloadable from the hook.
# Sourced by ../feature-confirm-checkpoint.sh (needs make_bash_json, extract_system_message, clear_markers).
# isolation: inherits-from ../feature-confirm-checkpoint.sh

clear_markers
T25_JSON=$(make_bash_json "echo \"<<WORKFLOW_CONFIRM_INTENT>>\"")
T25_OUT=$(
  export CONFIRM_INTENT=off
  unset CONFIRM_OUTLINE CONFIRM_DETAIL 2>/dev/null || true
  echo "$T25_JSON" | run_with_timeout node "$HOOK" 2>/dev/null
)
T25_MSG=$(extract_system_message "$T25_OUT")
if echo "$T25_MSG" | grep -qF "[confirm-skipped"; then
  fail "T25 CONFIRM_INTENT=off — intent must not be skipped: $T25_MSG"
elif echo "$T25_MSG" | grep -qF "Click Allow"; then
  pass "T25 CONFIRM_INTENT=off — intent still shows the confirm dialog text"
else
  fail "T25 CONFIRM_INTENT=off — expected the regular confirm systemMessage, got: $T25_MSG"
fi

T26_JSON=$(make_bash_json "echo \"<<WORKFLOW_CONFIRM_DETAIL>>\"")
T26_OUT=$(
  export CONFIRM_DETAIL=off
  unset CONFIRM_INTENT CONFIRM_OUTLINE 2>/dev/null || true
  echo "$T26_JSON" | run_with_timeout node "$HOOK" 2>/dev/null
)
T26_MSG=$(extract_system_message "$T26_OUT")
if echo "$T26_MSG" | grep -qF "[confirm-skipped: CONFIRM_DETAIL=off]"; then
  pass "T26 CONFIRM_DETAIL=off — still '[confirm-skipped: CONFIRM_DETAIL=off]'"
else
  fail "T26 CONFIRM_DETAIL=off — missing expected skipped message: $T26_MSG"
fi

# T27-T28: plan-stage-table unloadable from the hook (preload stub; the real source is untouched).
# The intent waiver must not fall back to "waivable"; outline keeps its waiver regardless.
T27_STUB="$SCRIPT_CHECKOUT_ROOT_NATIVE/tests/hooks/feature-confirm-checkpoint/unloadable-stage-table-stub.js"
T27_PROBE_DIR="$WORKFLOW_DIR_TEST/t27-probe"
mkdir -p "$T27_PROBE_DIR"
printf 'try { require(%s); process.stdout.write("loaded"); } catch (_) { process.stdout.write("threw"); }\n' \
  "\"$SCRIPT_CHECKOUT_ROOT_NATIVE/hooks/workflow-state/plan-stage-table\"" > "$T27_PROBE_DIR/confirm-checkpoint.js"
T27_PROBE=$(NODE_OPTIONS="--require \"$T27_STUB\"" run_with_timeout node "$T27_PROBE_DIR/confirm-checkpoint.js" 2>/dev/null)
if [ "$T27_PROBE" = "threw" ]; then
  pass "T27 precondition — the stub makes plan-stage-table unloadable from confirm-checkpoint.js"
else
  fail "T27 precondition — stub did not take effect: $T27_PROBE"
fi

clear_markers
T27_JSON=$(make_bash_json "echo \"<<WORKFLOW_CONFIRM_INTENT>>\"")
T27_OUT=$(
  export CONFIRM_INTENT=off NODE_OPTIONS="--require \"$T27_STUB\""
  unset CONFIRM_OUTLINE CONFIRM_DETAIL 2>/dev/null || true
  echo "$T27_JSON" | run_with_timeout node "$HOOK" 2>/dev/null
)
T27_MSG=$(extract_system_message "$T27_OUT")
if echo "$T27_MSG" | grep -qF "[confirm-skipped"; then
  fail "T27 CONFIRM_INTENT=off + unloadable plan-stage-table — intent must not be skipped: $T27_MSG"
elif echo "$T27_MSG" | grep -qF "Click Allow"; then
  pass "T27 CONFIRM_INTENT=off + unloadable plan-stage-table — intent still shows the confirm dialog text"
else
  fail "T27 CONFIRM_INTENT=off + unloadable plan-stage-table — expected the regular confirm systemMessage, got: $T27_MSG"
fi

T28_JSON=$(make_bash_json "echo \"<<WORKFLOW_CONFIRM_OUTLINE>>\"")
T28_OUT=$(
  export CONFIRM_OUTLINE=off NODE_OPTIONS="--require \"$T27_STUB\""
  unset CONFIRM_INTENT CONFIRM_DETAIL 2>/dev/null || true
  echo "$T28_JSON" | run_with_timeout node "$HOOK" 2>/dev/null
)
T28_MSG=$(extract_system_message "$T28_OUT")
if echo "$T28_MSG" | grep -qF "[confirm-skipped: CONFIRM_OUTLINE=off]"; then
  pass "T28 CONFIRM_OUTLINE=off + unloadable plan-stage-table — still '[confirm-skipped: CONFIRM_OUTLINE=off]'"
else
  fail "T28 CONFIRM_OUTLINE=off + unloadable plan-stage-table — missing expected skipped message: $T28_MSG"
fi
