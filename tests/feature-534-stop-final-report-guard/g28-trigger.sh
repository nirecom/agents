# tests/feature-534-stop-final-report-guard/g28-trigger.sh
# Tests: hooks/stop-final-report-guard.js, hooks/stop-premature-stop-guard.js, bin/workflow/next-step, settings.json
# Tags: hook, settings, config, stop-guard, workflow-state, scope:issue-specific, TL2
#
# Trigger-decoupling tests for issue #1611 (系統B: env-file-independent trigger).
# Sourced by feature-534-stop-final-report-guard.sh — no shebang, no runner.
#
# Function numbering continues at G33 because G28–G32 are already taken by
# g21-g27.sh; the filename follows the plan, the numbering follows the suite.
#
# Contract under test (new):
#   系統A — env file readable+parsable → Final Report shape validation (unchanged).
#   系統B — env file ABSENT and `bin/workflow/next-step --session <sid>` reports
#           ACTION=invoke with REASON='pre_final_report_gate' → the close
#           procedure was never started; block unconditionally (exit 2), WITHOUT
#           scanning the transcript. A hand-written 13-heading report must NOT
#           be accepted.
#   Escape hatches for 系統B: <sid>-session-close-gate.json gate_action:yield,
#           <sid>.workflow-off marker, pre_final_report_gate marked complete.
#   Anything else → exit 0.
#
# These tests also pin the child-process environment inheritance regression:
# next-step is spawned from the hook and must still see CLAUDE_WORKFLOW_DIR.

# ---------------------------------------------------------------------------
# Local fixture helpers (parent-scope: TMPDIR_BASE, HOOK_JS, node_path, ...)
# ---------------------------------------------------------------------------

PREMATURE_HOOK_JS="$(dirname "$HOOK_JS")/stop-premature-stop-guard.js"

# b_mk_state <workflow-dir> <sid> [pending-step ...]
# Writes a workflow state file with every step complete except the listed ones.
b_mk_state() {
    node -e '
const fs = require("fs");
const dir = process.argv[1], sid = process.argv[2];
const pendings = process.argv.slice(3);
const V = ["workflow_init","clarify_intent","research","outline","detail",
           "branching_complete","write_tests","review_tests","run_tests",
           "review_security","docs","user_verification","cleanup",
           "pre_final_report_gate"];
const steps = {};
const now = new Date().toISOString();
for (const s of V) steps[s] = { status: "complete", updated_at: now };
for (const s of pendings) steps[s] = { status: "pending", updated_at: null };
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(dir + "/" + sid + ".json", JSON.stringify(
  { version: 1, session_id: sid, created_at: now, steps, workflow_type: "wf-code" }, null, 2));
' "$@"
}

# b_run <hook-js> <stdin-json> <plans-dir> <workflow-dir>
# Runs a Stop hook with an isolated plans dir + workflow dir.
# Sets B_OUT (stdout) and B_CODE (exit code).
B_OUT=""
B_CODE=0
b_run() {
    local hook="$1" stdin_json="$2" plans_dir="$3" wf_dir="$4"
    B_OUT="$(WORKFLOW_PLANS_DIR="$plans_dir" \
             CLAUDE_WORKFLOW_DIR="$wf_dir" \
             CLAUDE_PROJECT_DIR="$wf_dir" \
             run_with_timeout 120 node "$hook" <<< "$stdin_json" 2>/dev/null)"
    B_CODE=$?
}

# b_stdin <sid> <transcript-path>
b_stdin() {
    printf '{"session_id":"%s","transcript_path":"%s"}' "$1" "$(node_path "$2")"
}

# b_is_block → 0 when B_OUT is a decision:block JSON object.
b_is_block() {
    printf '%s' "$B_OUT" | node -e "
let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
  try { process.exit(JSON.parse(s.trim()).decision === 'block' ? 0 : 1); }
  catch (e) { process.exit(1); }
});" 2>/dev/null
}

# b_reason_has <needle> → 0 when the block reason contains <needle>.
b_reason_has() {
    printf '%s' "$B_OUT" | REASON_NEEDLE="$1" node -e "
let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
  try {
    const r = JSON.parse(s.trim()).reason || '';
    process.exit(r.includes(process.env.REASON_NEEDLE) ? 0 : 1);
  } catch (e) { process.exit(1); }
});" 2>/dev/null
}

# ---------------------------------------------------------------------------
# G33: 系統B core — no env file + gate reached + no FR heading → exit 2 + block
# ---------------------------------------------------------------------------
test_G33_no_env_gate_reached_no_report_blocks() {
    require_hook "G33_no_env_gate_reached_no_report_blocks" || return
    local sid="g33-sid"
    local plans_dir="$TMPDIR_BASE/g33-plans" wf_dir="$TMPDIR_BASE/g33-wf"
    mkdir -p "$plans_dir" "$wf_dir"
    b_mk_state "$wf_dir" "$sid" pre_final_report_gate

    local transcript="$TMPDIR_BASE/g33-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "All done, wrapping up here."

    b_run "$HOOK_JS" "$(b_stdin "$sid" "$transcript")" \
        "$(node_path "$plans_dir")" "$(node_path "$wf_dir")"

    if [ "$B_CODE" = "2" ] && b_is_block && b_reason_has "session-close"; then
        pass "G33: no env-file + pre_final_report_gate reached → exit 2 + block pointing at /session-close"
    else
        fail "G33: expected exit 2 + decision:block mentioning session-close, got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}

# ---------------------------------------------------------------------------
# G34 (core case of #1611): no env file + gate reached + a COMPLETE hand-written
# 13-heading Final Report in the transcript → still exit 2.
# The close procedure never ran, so the report cannot be genuine.
# ---------------------------------------------------------------------------
test_G34_no_env_handwritten_full_report_still_blocks() {
    require_hook "G34_no_env_handwritten_full_report_still_blocks" || return
    local sid="g34-sid"
    local plans_dir="$TMPDIR_BASE/g34-plans" wf_dir="$TMPDIR_BASE/g34-wf"
    mkdir -p "$plans_dir" "$wf_dir"
    b_mk_state "$wf_dir" "$sid" pre_final_report_gate

    local transcript="$TMPDIR_BASE/g34-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "$(full_canonical_report_text "$sid")"

    b_run "$HOOK_JS" "$(b_stdin "$sid" "$transcript")" \
        "$(node_path "$plans_dir")" "$(node_path "$wf_dir")"

    if [ "$B_CODE" = "2" ] && b_is_block; then
        pass "G34: hand-written 13-heading report without /session-close → exit 2 (not accepted)"
    else
        fail "G34: expected exit 2 + decision:block, got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}

# ---------------------------------------------------------------------------
# G35: no env file + workflow still mid-flight (docs pending) → exit 0
# (preserves the pre-#1611 no-op behaviour on ordinary turns)
# ---------------------------------------------------------------------------
test_G35_no_env_midworkflow_exit0() {
    require_hook "G35_no_env_midworkflow_exit0" || return
    local sid="g35-sid"
    local plans_dir="$TMPDIR_BASE/g35-plans" wf_dir="$TMPDIR_BASE/g35-wf"
    mkdir -p "$plans_dir" "$wf_dir"
    b_mk_state "$wf_dir" "$sid" docs user_verification cleanup pre_final_report_gate

    local transcript="$TMPDIR_BASE/g35-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "Still working on the docs step."

    b_run "$HOOK_JS" "$(b_stdin "$sid" "$transcript")" \
        "$(node_path "$plans_dir")" "$(node_path "$wf_dir")"

    if [ "$B_CODE" = "0" ]; then
        pass "G35: no env-file + mid-workflow (docs pending) → exit 0"
    else
        fail "G35: expected exit 0, got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}

# ---------------------------------------------------------------------------
# G36: no env file + no workflow state file at all → exit 0
# ---------------------------------------------------------------------------
test_G36_no_env_no_state_exit0() {
    require_hook "G36_no_env_no_state_exit0" || return
    local sid="g36-sid"
    local plans_dir="$TMPDIR_BASE/g36-plans" wf_dir="$TMPDIR_BASE/g36-wf"
    mkdir -p "$plans_dir" "$wf_dir"

    local transcript="$TMPDIR_BASE/g36-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "Non-workflow session, just chatting."

    b_run "$HOOK_JS" "$(b_stdin "$sid" "$transcript")" \
        "$(node_path "$plans_dir")" "$(node_path "$wf_dir")"

    if [ "$B_CODE" = "0" ]; then
        pass "G36: no env-file + no workflow state → exit 0"
    else
        fail "G36: expected exit 0, got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}

# ---------------------------------------------------------------------------
# G37: 系統B escape hatch (a) — session-close gate says yield → exit 0
# ---------------------------------------------------------------------------
test_G37_no_env_gate_yield_exit0() {
    require_hook "G37_no_env_gate_yield_exit0" || return
    local sid="g37-sid"
    local plans_dir="$TMPDIR_BASE/g37-plans" wf_dir="$TMPDIR_BASE/g37-wf"
    mkdir -p "$plans_dir" "$wf_dir"
    b_mk_state "$wf_dir" "$sid" pre_final_report_gate
    printf '{"gate_action":"yield"}' > "$plans_dir/${sid}-session-close-gate.json"

    local transcript="$TMPDIR_BASE/g37-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "Supervisor yielded; stopping here."

    b_run "$HOOK_JS" "$(b_stdin "$sid" "$transcript")" \
        "$(node_path "$plans_dir")" "$(node_path "$wf_dir")"

    if [ "$B_CODE" = "0" ]; then
        pass "G37: 系統B + gate_action:yield → exit 0 (escape hatch a)"
    else
        fail "G37: expected exit 0, got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}

# ---------------------------------------------------------------------------
# G38: 系統B escape hatch (b) — <sid>.workflow-off marker → exit 0
# ---------------------------------------------------------------------------
test_G38_no_env_workflow_off_exit0() {
    require_hook "G38_no_env_workflow_off_exit0" || return
    local sid="g38-sid"
    local plans_dir="$TMPDIR_BASE/g38-plans" wf_dir="$TMPDIR_BASE/g38-wf"
    mkdir -p "$plans_dir" "$wf_dir"
    b_mk_state "$wf_dir" "$sid" pre_final_report_gate
    printf 'off' > "$wf_dir/${sid}.workflow-off"

    local transcript="$TMPDIR_BASE/g38-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "Workflow enforcement is off for this session."

    b_run "$HOOK_JS" "$(b_stdin "$sid" "$transcript")" \
        "$(node_path "$plans_dir")" "$(node_path "$wf_dir")"

    if [ "$B_CODE" = "0" ]; then
        pass "G38: 系統B + workflow-off marker → exit 0 (escape hatch b)"
    else
        fail "G38: expected exit 0, got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}

# ---------------------------------------------------------------------------
# G39: 系統B escape hatch (c) — pre_final_report_gate manually complete → exit 0
# ---------------------------------------------------------------------------
test_G39_no_env_gate_complete_exit0() {
    require_hook "G39_no_env_gate_complete_exit0" || return
    local sid="g39-sid"
    local plans_dir="$TMPDIR_BASE/g39-plans" wf_dir="$TMPDIR_BASE/g39-wf"
    mkdir -p "$plans_dir" "$wf_dir"
    b_mk_state "$wf_dir" "$sid"   # every step complete, gate included

    local transcript="$TMPDIR_BASE/g39-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "Gate was marked complete by hand."

    b_run "$HOOK_JS" "$(b_stdin "$sid" "$transcript")" \
        "$(node_path "$plans_dir")" "$(node_path "$wf_dir")"

    if [ "$B_CODE" = "0" ]; then
        pass "G39: 系統B + pre_final_report_gate complete → exit 0 (escape hatch c)"
    else
        fail "G39: expected exit 0, got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}

# ---------------------------------------------------------------------------
# G40 (regression): the spawned next-step must inherit CLAUDE_WORKFLOW_DIR.
# The state lives ONLY in a non-default nested temp dir; if the hook spawns
# next-step with a scrubbed env, the state is invisible and the hook exits 0.
# ---------------------------------------------------------------------------
test_G40_nondefault_workflow_dir_env_inheritance() {
    require_hook "G40_nondefault_workflow_dir_env_inheritance" || return
    local sid="g40-sid"
    local plans_dir="$TMPDIR_BASE/g40-plans"
    local wf_dir="$TMPDIR_BASE/g40-nested/deeper/wf"
    mkdir -p "$plans_dir" "$wf_dir"
    b_mk_state "$wf_dir" "$sid" pre_final_report_gate

    local transcript="$TMPDIR_BASE/g40-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "Done; state lives in a non-default workflow dir."

    b_run "$HOOK_JS" "$(b_stdin "$sid" "$transcript")" \
        "$(node_path "$plans_dir")" "$(node_path "$wf_dir")"

    if [ "$B_CODE" = "2" ] && b_is_block; then
        pass "G40: non-default CLAUDE_WORKFLOW_DIR still reaches 系統B → exit 2 (env inherited by next-step)"
    else
        fail "G40: expected exit 2 + block (env inheritance regression), got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}

# ---------------------------------------------------------------------------
# G41 (系統A preserved): env file present + complete 13-heading report → exit 0
# ---------------------------------------------------------------------------
test_G41_env_present_full_report_exit0() {
    require_hook "G41_env_present_full_report_exit0" || return
    local sid="g41-sid"
    local plans_dir="$TMPDIR_BASE/g41-plans" wf_dir="$TMPDIR_BASE/g41-wf"
    mkdir -p "$plans_dir" "$wf_dir"
    write_default_env_file "$plans_dir/${sid}-final-report-env.json"
    b_mk_state "$wf_dir" "$sid" pre_final_report_gate

    local transcript="$TMPDIR_BASE/g41-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "$(full_canonical_report_text "$sid")"

    b_run "$HOOK_JS" "$(b_stdin "$sid" "$transcript")" \
        "$(node_path "$plans_dir")" "$(node_path "$wf_dir")"

    if [ "$B_CODE" = "0" ]; then
        pass "G41: 系統A preserved — env-file + all 13 headings → exit 0"
    else
        fail "G41: expected exit 0, got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}

# ---------------------------------------------------------------------------
# G42 (系統A preserved): env file present + `### Bugs Found` missing → exit 2
# ---------------------------------------------------------------------------
test_G42_env_present_missing_heading_blocks() {
    require_hook "G42_env_present_missing_heading_blocks" || return
    local sid="g42-sid"
    local plans_dir="$TMPDIR_BASE/g42-plans" wf_dir="$TMPDIR_BASE/g42-wf"
    mkdir -p "$plans_dir" "$wf_dir"
    write_default_env_file "$plans_dir/${sid}-final-report-env.json"
    b_mk_state "$wf_dir" "$sid" pre_final_report_gate

    local transcript="$TMPDIR_BASE/g42-transcript.jsonl"
    local body
    body="$(full_canonical_report_text "$sid" | grep -v '^### Bugs Found$')"
    write_transcript_with_assistant "$transcript" "$body"

    b_run "$HOOK_JS" "$(b_stdin "$sid" "$transcript")" \
        "$(node_path "$plans_dir")" "$(node_path "$wf_dir")"

    if [ "$B_CODE" = "2" ] && b_is_block && b_reason_has "### Bugs Found"; then
        pass "G42: 系統A preserved — env-file + missing '### Bugs Found' → exit 2 + block"
    else
        fail "G42: expected exit 2 + block naming '### Bugs Found', got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}

# ---------------------------------------------------------------------------
# G43: malformed env file must stay fail-open (exit 0) and must NOT fall
# through to 系統B — a broken env file is evidence that /session-close DID run.
# ---------------------------------------------------------------------------
test_G43_env_malformed_does_not_fall_through_to_B() {
    require_hook "G43_env_malformed_does_not_fall_through_to_B" || return
    local sid="g43-sid"
    local plans_dir="$TMPDIR_BASE/g43-plans" wf_dir="$TMPDIR_BASE/g43-wf"
    mkdir -p "$plans_dir" "$wf_dir"
    printf '{ this is not json' > "$plans_dir/${sid}-final-report-env.json"
    b_mk_state "$wf_dir" "$sid" pre_final_report_gate

    local transcript="$TMPDIR_BASE/g43-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "No report; env file is corrupt."

    b_run "$HOOK_JS" "$(b_stdin "$sid" "$transcript")" \
        "$(node_path "$plans_dir")" "$(node_path "$wf_dir")"

    if [ "$B_CODE" = "0" ]; then
        pass "G43: malformed env-file → exit 0 (fail-open, no 系統B fall-through)"
    else
        fail "G43: expected exit 0, got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}

# ---------------------------------------------------------------------------
# G44: stop_hook_active:true short-circuits 系統B too (loop prevention).
# ---------------------------------------------------------------------------
test_G44_stop_hook_active_exit0() {
    require_hook "G44_stop_hook_active_exit0" || return
    local sid="g44-sid"
    local plans_dir="$TMPDIR_BASE/g44-plans" wf_dir="$TMPDIR_BASE/g44-wf"
    mkdir -p "$plans_dir" "$wf_dir"
    b_mk_state "$wf_dir" "$sid" pre_final_report_gate

    local transcript="$TMPDIR_BASE/g44-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "Re-entered after a block."

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":true}' \
        "$sid" "$(node_path "$transcript")")"
    b_run "$HOOK_JS" "$stdin_json" "$(node_path "$plans_dir")" "$(node_path "$wf_dir")"

    if [ "$B_CODE" = "0" ]; then
        pass "G44: stop_hook_active:true → exit 0 even when 系統B would fire"
    else
        fail "G44: expected exit 0, got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}

# ---------------------------------------------------------------------------
# G45: stop-premature-stop-guard delegates pre_final_report_gate → exit 0
# (avoids two block decisions in the same turn; CPR-3 separation)
# ---------------------------------------------------------------------------
test_G45_premature_guard_delegates_gate_reason() {
    if [ ! -f "$PREMATURE_HOOK_JS" ]; then
        skip "G45_premature_guard_delegates_gate_reason (hook not found)"
        return
    fi
    local sid="g45-sid"
    local plans_dir="$TMPDIR_BASE/g45-plans" wf_dir="$TMPDIR_BASE/g45-wf"
    mkdir -p "$plans_dir" "$wf_dir"
    b_mk_state "$wf_dir" "$sid" pre_final_report_gate

    local transcript="$TMPDIR_BASE/g45-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "Stopping before session-close."

    b_run "$PREMATURE_HOOK_JS" "$(b_stdin "$sid" "$transcript")" \
        "$(node_path "$plans_dir")" "$(node_path "$wf_dir")"

    if [ "$B_CODE" = "0" ]; then
        pass "G45: premature-stop guard delegates REASON='pre_final_report_gate' → exit 0"
    else
        fail "G45: expected exit 0 (delegated to stop-final-report-guard), got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}

# ---------------------------------------------------------------------------
# G46 (CPR-5 counterpart): any other ACTION=invoke reason still blocks.
# ---------------------------------------------------------------------------
test_G46_premature_guard_other_invoke_still_blocks() {
    if [ ! -f "$PREMATURE_HOOK_JS" ]; then
        skip "G46_premature_guard_other_invoke_still_blocks (hook not found)"
        return
    fi
    local sid="g46-sid"
    local plans_dir="$TMPDIR_BASE/g46-plans" wf_dir="$TMPDIR_BASE/g46-wf"
    mkdir -p "$plans_dir" "$wf_dir"
    b_mk_state "$wf_dir" "$sid" docs user_verification cleanup pre_final_report_gate

    local transcript="$TMPDIR_BASE/g46-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "Stopping while docs is still pending."

    b_run "$PREMATURE_HOOK_JS" "$(b_stdin "$sid" "$transcript")" \
        "$(node_path "$plans_dir")" "$(node_path "$wf_dir")"

    if [ "$B_CODE" = "2" ] && b_is_block; then
        pass "G46: premature-stop guard still blocks non-delegated ACTION=invoke (docs)"
    else
        fail "G46: expected exit 2 + block, got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}

# ---------------------------------------------------------------------------
# G47: settings.json — the 系統B path spawns `next-step` (3s budget), so the
# Stop registration for this hook must carry timeout 10, not the old 5.
# Registration count is asserted too: two competing entries would make the
# effective timeout ambiguous.
# ---------------------------------------------------------------------------
test_G47_settings_stop_timeout_is_10() {
    local settings_json
    settings_json="$(cd "$(dirname "$HOOK_JS")/.." && pwd)/settings.json"
    if [ ! -f "$settings_json" ]; then
        skip "G47_settings_stop_timeout_is_10 (settings.json not found)"
        return
    fi

    local got
    got="$(node -e '
const fs = require("fs");
try {
  const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const groups = (s.hooks && s.hooks.Stop) || [];
  const found = [];
  for (const g of groups) {
    for (const h of (g.hooks || [])) {
      if (String((h && h.command) || "").includes("stop-final-report-guard.js")) {
        found.push(h.timeout === undefined ? "unset" : String(h.timeout));
      }
    }
  }
  process.stdout.write(found.length + ":" + found.join(","));
} catch (e) { process.stdout.write("ERR"); }
' "$settings_json" 2>/dev/null)"

    if [ "$got" = "1:10" ]; then
        pass "G47: stop-final-report-guard.js registered exactly once with timeout 10"
    else
        fail "G47: want exactly one Stop registration with timeout 10, got count:timeouts=$got"
    fi
}

# ---------------------------------------------------------------------------
# G48/G49: 系統B spawns a child process. Any child failure — non-zero exit,
# unparsable stdout, or a state file the tool cannot digest — must fail OPEN
# (exit 0), never block the user on infrastructure trouble.
# ---------------------------------------------------------------------------
test_G48_corrupt_state_fails_open() {
    local sid="g48-sid"
    local plans_dir="$TMPDIR_BASE/g48-plans" wf_dir="$TMPDIR_BASE/g48-wf"
    mkdir -p "$plans_dir" "$wf_dir"
    printf 'this is not json {{{' > "$wf_dir/$sid.json"

    local transcript="$TMPDIR_BASE/g48-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "Done."

    b_run "$HOOK_JS" "$(b_stdin "$sid" "$transcript")" \
        "$(node_path "$plans_dir")" "$(node_path "$wf_dir")"

    if [ "$B_CODE" = "0" ]; then
        pass "G48: corrupt state file → next-step cannot classify → exit 0 (fail-open)"
    else
        fail "G48: expected exit 0, got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}

test_G49_state_without_steps_fails_open() {
    local sid="g49-sid"
    local plans_dir="$TMPDIR_BASE/g49-plans" wf_dir="$TMPDIR_BASE/g49-wf"
    mkdir -p "$plans_dir" "$wf_dir"
    printf '{"version":1,"session_id":"%s"}' "$sid" > "$wf_dir/$sid.json"

    local transcript="$TMPDIR_BASE/g49-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "Done."

    b_run "$HOOK_JS" "$(b_stdin "$sid" "$transcript")" \
        "$(node_path "$plans_dir")" "$(node_path "$wf_dir")"

    if [ "$B_CODE" = "0" ]; then
        pass "G49: state without steps → exit 0 (fail-open)"
    else
        fail "G49: expected exit 0, got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}

# ---------------------------------------------------------------------------
# G50: the workflow dir is unusable (a regular file, so every state read and
# every child-process lookup underneath it fails). The guard must still exit 0
# and must not emit a malformed stdout payload.
# ---------------------------------------------------------------------------
test_G50_unusable_workflow_dir_fails_open() {
    local sid="g50-sid"
    local plans_dir="$TMPDIR_BASE/g50-plans"
    mkdir -p "$plans_dir"
    local bogus_dir="$TMPDIR_BASE/g50-not-a-dir"
    printf 'not a directory\n' > "$bogus_dir"

    local transcript="$TMPDIR_BASE/g50-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "Done."

    b_run "$HOOK_JS" "$(b_stdin "$sid" "$transcript")" \
        "$(node_path "$plans_dir")" "$(node_path "$bogus_dir")"

    if [ "$B_CODE" = "0" ] && [ -z "$(printf '%s' "$B_OUT" | tr -d '[:space:]')" ]; then
        pass "G50: unusable CLAUDE_WORKFLOW_DIR → exit 0, no output (fail-open)"
    else
        fail "G50: expected exit 0 with empty stdout, got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}
