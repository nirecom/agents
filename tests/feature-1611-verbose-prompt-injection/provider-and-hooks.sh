#!/usr/bin/env bash
# tests/feature-1611-verbose-prompt-injection/provider-and-hooks.sh
# Tests: hooks/lib/verbose-prompt.js, hooks/session-start.js, hooks/post-compact.js
# Tags: hook, model-detection, session-state, prompt-injection, scope:issue-specific, TL2
#
# Fragment of tests/feature-1611-verbose-prompt-injection.sh — sourced by the
# parent, not run directly; cases run at source time. Owns groups D
# (getVerbosePromptInjection, the read-only provider), G (SessionStart
# integration) and H (PostCompact integration).
#
# Defines VP_TEXT / VP_TEXT_OK and the inject/hook_out/contains helpers that the
# later fragments reuse, so it must be sourced before adversarial-and-hygiene.sh.
# Depends on the parent for: WFDIR, SESSION_START_JS, POST_COMPACT_JS, jsn,
# seed_state, state_hash, state_field, run_with_timeout, assert_eq, pass, fail.

# ---------------------------------------------------------------------------
echo ""
echo "=== D: getVerbosePromptInjection (read-only provider) ==="
# ---------------------------------------------------------------------------

vp_text() { local e='VP.VERBOSE_PROMPT_TEXT'; jsn "$e"; }
VP_TEXT="$(vp_text)"

VP_TEXT_OK=1
case "$VP_TEXT" in
    ""|EMPTY|THREW|null)
        fail "D00-text-constant-exported" "VERBOSE_PROMPT_TEXT is not exported (module not implemented yet)"
        # Sentinel that can never equal a real result — keeps every downstream
        # comparison honestly red instead of accidentally matching "THREW".
        VP_TEXT="<<VERBOSE_PROMPT_TEXT-UNAVAILABLE>>"
        VP_TEXT_OK=0
        ;;
    *)  pass "D00-text-constant-exported" ;;
esac

inject() {
    local e="VP.getVerbosePromptInjection('$1')"; shift
    jsn "$e" "$@"
}

seed_state "sid-d01" '{"verbose_prompt":true}'
assert_eq "D01-flag-true-returns-text" "$VP_TEXT" "$(inject sid-d01)"

seed_state "sid-d02" '{"verbose_prompt":false}'
assert_eq "D02-flag-false-returns-null" "null" "$(inject sid-d02)"

seed_state "sid-d03"
assert_eq "D03-flag-absent-returns-null" "null" "$(inject sid-d03)"

assert_eq "D04-no-state-file-returns-null" "null" "$(inject sid-d04-never-created)"

printf 'not json {{{' > "$WFDIR/sid-d05.json"
assert_eq "D05-corrupt-state-returns-null" "null" "$(inject sid-d05)"

D06_EXPR='VP.getVerbosePromptInjection("../../etc/passwd")'
assert_eq "D06-invalid-sid-returns-null" "null" "$(jsn "$D06_EXPR")"

D07_EXPR='VP.getVerbosePromptInjection(null)'
assert_eq "D07-null-sid-returns-null" "null" "$(jsn "$D07_EXPR")"

# The provider is pure: reading must not mutate the state file.
D08_BEFORE="$(state_hash sid-d01)"
inject sid-d01 >/dev/null
assert_eq "D08-provider-has-no-side-effect" "$D08_BEFORE" "$(state_hash sid-d01)"

# ---------------------------------------------------------------------------
echo ""
echo "=== G: SessionStart integration ==="
# ---------------------------------------------------------------------------

# hook_out <hook-js> <stdin-json> [KEY=VAL ...] → raw stdout
hook_out() {
    local hook="$1" stdin_json="$2"; shift 2
    printf '%s' "$stdin_json" | run_with_timeout 60 env \
        -u VERBOSE_PROMPT_MODELS -u CLAUDE_ENV_FILE \
        CLAUDE_WORKFLOW_DIR="$WFDIR_N" \
        WORKFLOW_PLANS_DIR="$PLANSDIR_N" \
        AGENTS_CONFIG_DIR="$CFGDIR_N" \
        CLAUDE_PROJECT_DIR="$PROJDIR_N" \
        "$@" \
        node "$hook" 2>/dev/null
}

contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

seed_state "sid-g01" '{"verbose_prompt":true}'
G01="$(hook_out "$SESSION_START_JS" '{"session_id":"sid-g01"}')"
if contains "$VP_TEXT" "$G01"; then pass "G01-flag-true-injects-line"
else fail "G01-flag-true-injects-line" "additionalContext lacks the hardening line"; fi

seed_state "sid-g02" '{"verbose_prompt":false}'
G02="$(hook_out "$SESSION_START_JS" '{"session_id":"sid-g02"}')"
if contains "$VP_TEXT" "$G02"; then fail "G02-flag-false-omits-line" "hardening line injected despite verbose_prompt:false"
else pass "G02-flag-false-omits-line"; fi

# Record-then-inject in one run: stdin carries `model`, the flag is decided and
# the line must already appear in this very SessionStart's additionalContext.
seed_state "sid-g03"
G03="$(hook_out "$SESSION_START_JS" '{"session_id":"sid-g03","model":{"id":"deepseek-v4-flash","display_name":"DS4"}}' 'VERBOSE_PROMPT_MODELS=deepseek;qwen')"
if contains "$VP_TEXT" "$G03"; then pass "G03-layer1-record-then-inject"
else fail "G03-layer1-record-then-inject" "hardening line absent on the recording turn"; fi
assert_eq "G03b-source-is-hook-input" "hook-input" "$(state_field sid-g03 session_model.source)"

# No model in stdin, feature enabled → nothing to key off of: no flag armed,
# no hardening line, and no session_model recorded.
seed_state "sid-g04"
G04="$(hook_out "$SESSION_START_JS" '{"session_id":"sid-g04"}' 'VERBOSE_PROMPT_MODELS=deepseek;qwen')"
if contains "$VP_TEXT" "$G04"; then fail "G04-no-model-no-injection" "hardening line injected without a hook-input model"
else pass "G04-no-model-no-injection"; fi
assert_eq "G04b-nothing-recorded" "null" "$(state_field sid-g04 session_model.id)"

# Feature disabled → zero context growth.
seed_state "sid-g05"
G05="$(hook_out "$SESSION_START_JS" '{"session_id":"sid-g05","model":"claude-opus-4-8"}')"
if contains "$VP_TEXT" "$G05"; then fail "G05-feature-off-adds-nothing" "hardening line injected with the feature disabled"
else pass "G05-feature-off-adds-nothing"; fi

# The hook must still emit valid JSON on the record-then-inject path.
G07="$(printf '%s' "$G03" | run_with_timeout 30 node -e '
let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
  try { JSON.parse(s); process.stdout.write("ok"); } catch (e) { process.stdout.write("bad"); }
});' 2>/dev/null)"
assert_eq "G07-output-is-valid-json" "ok" "$G07"

# ---------------------------------------------------------------------------
echo ""
echo "=== H: PostCompact integration (read-only consumer) ==="
# ---------------------------------------------------------------------------

seed_state "sid-h01" '{"verbose_prompt":true}'
H01_BEFORE="$(state_hash sid-h01)"
H01="$(hook_out "$POST_COMPACT_JS" '{"session_id":"sid-h01"}')"
if contains "$VP_TEXT" "$H01"; then pass "H01-flag-true-injects-line"
else fail "H01-flag-true-injects-line" "additionalContext lacks the hardening line"; fi
assert_eq "H01b-state-file-unchanged" "$H01_BEFORE" "$(state_hash sid-h01)"

seed_state "sid-h02" '{"verbose_prompt":false}'
H02="$(hook_out "$POST_COMPACT_JS" '{"session_id":"sid-h02"}')"
if contains "$VP_TEXT" "$H02"; then fail "H02-flag-false-omits-line" "hardening line injected despite verbose_prompt:false"
else pass "H02-flag-false-omits-line"; fi

# PostCompact must neither resolve nor persist: a `model` in stdin changes nothing.
seed_state "sid-h03"
H03_BEFORE="$(state_hash sid-h03)"
H03="$(hook_out "$POST_COMPACT_JS" '{"session_id":"sid-h03","model":{"id":"deepseek-v4-flash"}}' 'VERBOSE_PROMPT_MODELS=deepseek')"
assert_eq "H03-no-persistence-on-compaction" "$H03_BEFORE" "$(state_hash sid-h03)"
if contains "$VP_TEXT" "$H03"; then fail "H03b-no-injection-without-flag" "injected without a recorded flag"
else pass "H03b-no-injection-without-flag"; fi
