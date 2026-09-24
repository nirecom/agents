#!/usr/bin/env bash
# tests/feature-1611-verbose-prompt-injection/unit-model-identity.sh
# Tests: hooks/lib/model-identity.js, hooks/workflow-state/state-io.js
# Tags: hook, model-detection, session-state, prompt-injection, scope:issue-specific, TL2
#
# Fragment of tests/feature-1611-verbose-prompt-injection.sh — sourced by the
# parent, not run directly; the cases run at source time, so the parent's source
# order IS the execution order. Owns the module preconditions and groups A
# (extractModelIdFromHookInput shape tolerance), B (resolveModelId layer①) and
# C (recordSessionModel write-once + verbose_prompt decision).
#
# Depends on the parent for: REPO_DIR, MODEL_IDENTITY_JS, VERBOSE_PROMPT_JS,
# jsn, seed_state, state_file, state_field, assert_eq, assert_ne, pass, fail.

# ---------------------------------------------------------------------------
echo "=== preconditions (new modules) ==="
# ---------------------------------------------------------------------------

for f in "$MODEL_IDENTITY_JS" "$VERBOSE_PROMPT_JS"; do
    rel="${f#$REPO_DIR/}"
    if [ -f "$f" ]; then pass "X-exists-$rel"
    else fail "X-exists-$rel" "not implemented yet"; fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== A: extractModelIdFromHookInput (layer① shape tolerance) ==="
# ---------------------------------------------------------------------------

run_table() {
    local name expr want
    while IFS='@' read -r name expr want; do
        name="$(printf '%s' "$name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "$name" ] && continue
        case "$name" in '#'*) continue ;; esac
        want="$(printf '%s' "$want" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        assert_eq "$name" "$want" "$(jsn "$expr")"
    done
}

run_table <<'TABLE'
A01-model-string      @ MI.extractModelIdFromHookInput({model: 'claude-opus-4-8'})                          @ claude-opus-4-8
A02-model-object-id   @ MI.extractModelIdFromHookInput({model: {id: 'deepseek-v4-flash'}})                  @ deepseek-v4-flash
A03-id-beats-display  @ MI.extractModelIdFromHookInput({model: {id: 'ds4-x', display_name: 'DS4 Flash'}})   @ ds4-x
A04-display-name-only @ MI.extractModelIdFromHookInput({model: {display_name: 'DS4 Flash'}})                @ DS4 Flash
A05-model-absent      @ MI.extractModelIdFromHookInput({session_id: 's'})                                   @ null
A06-model-number      @ MI.extractModelIdFromHookInput({model: 42})                                         @ null
A07-input-null        @ MI.extractModelIdFromHookInput(null)                                                @ null
A08-input-not-object  @ MI.extractModelIdFromHookInput('claude-opus-4-8')                                   @ null
A09-empty-id-falls-back @ MI.extractModelIdFromHookInput({model: {id: '', display_name: 'DS4'}})            @ DS4
A10-empty-object      @ MI.extractModelIdFromHookInput({model: {}})                                         @ null
TABLE

# ---------------------------------------------------------------------------
echo ""
echo "=== B: resolveModelId (layer① only) ==="
# ---------------------------------------------------------------------------

resolve() {
    local expr='(function(){ const r = MI.resolveModelId('"$1"'); return r ? (r.id + ":" + r.source) : null; })()'
    shift
    jsn "$expr" "$@"
}

assert_eq "B01-hook-input-wins-source" "claude-opus-4-8:hook-input" \
    "$(resolve "{model: 'claude-opus-4-8'}")"
assert_eq "B04-no-hook-input-is-null" "null" \
    "$(resolve "{session_id: 's'}")"
assert_eq "B06-malformed-input-fail-open" "null" \
    "$(resolve "undefined")"

# ---------------------------------------------------------------------------
echo ""
echo "=== C: recordSessionModel (write-once + verbose_prompt decision) ==="
# ---------------------------------------------------------------------------

record() {
    # record <sid> <model-id> <source> [KEY=VAL ...] → "<recorded>:<verbosePrompt>"
    local sid="$1" mid="$2" src="$3"; shift 3
    local expr='(function(){ const r = SIO.recordSessionModel('"'$sid'"', { modelId: '"'$mid'"', source: '"'$src'"' }); return r ? (String(r.recorded) + ":" + String(r.verbosePrompt)) : null; })()'
    jsn "$expr" "$@"
}

seed_state "sid-c01"
assert_eq "C01-first-write-recorded" "true:false" "$(record sid-c01 claude-opus-4-8 hook-input)"
assert_eq "C01b-id-persisted"     "claude-opus-4-8" "$(state_field sid-c01 session_model.id)"
assert_eq "C01c-source-persisted" "hook-input"      "$(state_field sid-c01 session_model.source)"
assert_ne "C01d-recorded-at-set"  "null"            "$(state_field sid-c01 session_model.recorded_at)"

# write-once: the second (later-layer) record must not overwrite the first.
assert_eq "C02-second-write-refused" "false:false" "$(record sid-c01 deepseek-v4-flash self-report)"
assert_eq "C02b-id-unchanged"        "claude-opus-4-8" "$(state_field sid-c01 session_model.id)"

# readState injects a non-persistent skip_judgment view; writing it back would
# pollute the state file permanently.
if grep -q 'skip_judgment' "$(state_file sid-c01)"; then
    fail "C03-skip-judgment-not-persisted" "skip_judgment leaked into the state file"
else
    pass "C03-skip-judgment-not-persisted"
fi

seed_state "sid-c04"
assert_eq "C04-keyword-hit-sets-flag" "true:true" \
    "$(record sid-c04 deepseek-v4-flash hook-input 'VERBOSE_PROMPT_MODELS=deepseek;qwen')"
assert_eq "C04b-flag-persisted" "true" "$(state_field sid-c04 verbose_prompt)"

seed_state "sid-c05"
assert_eq "C05-keyword-miss-clears-flag" "true:false" \
    "$(record sid-c05 claude-opus-4-8 hook-input 'VERBOSE_PROMPT_MODELS=deepseek;qwen')"
assert_eq "C05b-flag-persisted-false" "false" "$(state_field sid-c05 verbose_prompt)"

seed_state "sid-c06"
assert_eq "C06-feature-unset-no-flag" "true:false" "$(record sid-c06 deepseek-v4-flash hook-input)"
assert_eq "C06b-flag-false" "false" "$(state_field sid-c06 verbose_prompt)"

# no pre-existing state file → the setter creates one (mirrors recordComplexityEvaluation).
rm -f "$(state_file sid-c07)"
assert_eq "C07-creates-missing-state" "true:false" "$(record sid-c07 claude-opus-4-8 env)"
assert_eq "C07b-state-file-written" "claude-opus-4-8" "$(state_field sid-c07 session_model.id)"

# The plan's SessionStart integration passes resolveModelId's own return shape
# ({id, source}) straight into the setter, so that shape must record too.
seed_state "sid-c08"
C08_EXPR='(function(){ const r = SIO.recordSessionModel("sid-c08", { id: "deepseek-v4-flash", source: "hook-input" }); return r ? String(r.recorded) : null; })()'
assert_eq "C08-accepts-resolveModelId-shape" "true" "$(jsn "$C08_EXPR")"
assert_eq "C08b-id-persisted" "deepseek-v4-flash" "$(state_field sid-c08 session_model.id)"
