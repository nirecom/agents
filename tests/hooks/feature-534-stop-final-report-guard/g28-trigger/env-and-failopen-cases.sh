# tests/feature-534-stop-final-report-guard/g28-trigger/env-and-failopen-cases.sh
# Tests: hooks/stop-final-report-guard.js, hooks/stop-premature-stop-guard.js, settings.json
# Tags: hook, settings, config, stop-guard, workflow-state, scope:issue-specific, TL2
#
# Sourced by ../g28-trigger.sh — no shebang, no runner. Owns the 系統A side and
# the fail-open contract: G41..G44 (env file present → Final Report shape
# validation, malformed env does NOT fall through to 系統B, stop_hook_active),
# G45/G46 (premature-stop guard delegation), G47 (settings.json Stop timeout)
# and G48..G50 (corrupt state, state without steps, unusable workflow dir → the
# guard fails OPEN rather than blocking on infrastructure trouble).
#
# Depends on ../g28-trigger.sh for: PREMATURE_HOOK_JS, b_mk_state, b_run,
# b_stdin, b_is_block, b_reason_has, B_OUT, B_CODE — and on the grandparent for
# TMPDIR_BASE, HOOK_JS, node_path, require_hook, run_with_timeout, pass, fail,
# skip and the transcript-writing helpers.

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
# (avoids two block decisions in the same turn; CPR-SC separation)
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
# G46 (CPR-ORTH counterpart): any other ACTION=invoke reason still blocks.
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
