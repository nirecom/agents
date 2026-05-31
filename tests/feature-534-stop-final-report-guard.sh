#!/bin/bash
# tests/feature-534-stop-final-report-guard.sh
# Tests: hooks/stop-final-report-guard.js, bin/worktree-final-report.js, skills/session-close/SKILL.md
# Tags: settings, config, hook, bin, tests
#
# Issue #534 / #626 — Stop hook: stop-final-report-guard.js (flag-based redesign)
#
# Contract after #626 + #700: the hook checks BOTH the env-file.reported flag
# AND that at least one assistant text message in the transcript contains the
# Final Report heading. Fail-open when transcript is unavailable.
#
# G1, G4, G6, G8, I1: UNCHANGED — must PASS against current source.
# G2, G3, G5, G7, G10, G11, G12, G13, G14, G15: written for NEW flag contract.
# G16 (NEW): renderer ran but heading only in tool_result → exit 2 (issue #700).
# G9a–G9e: DELETED (transcript-content section checks no longer applicable).
#
# I1 (settings.json invariant) does NOT need the hook file and always runs.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK_JS="${_AGENTS_DIR_NODE}/hooks/stop-final-report-guard.js"
REPORT_JS="${_AGENTS_DIR_NODE}/bin/worktree-final-report.js"
SETTINGS_JSON="${AGENTS_DIR}/settings.json"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'f534-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else
        "$@"
    fi
}

node_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}

# Guard: skip all G-tests when the hook is not yet implemented.
require_hook() {
    if [ ! -f "$HOOK_JS" ]; then
        skip "$1 (hook not implemented yet)"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# Write a minimal env-file (all not_required, no reported field) to $1.
write_default_env_file() {
    local path="$1"
    cat > "$path" <<'EOF'
{
  "CC_RESTART_REQUIRED": "not_required",
  "CC_RESTART_REASON": "",
  "VSCODE_RELOAD_REQUIRED": "not_required",
  "VSCODE_RELOAD_REASON": "",
  "INSTALLER_RERUN_REQUIRED": "not_required",
  "INSTALLER_RERUN_REASON": "",
  "OS_REBOOT_REQUIRED": "not_required",
  "OS_REBOOT_REASON": ""
}
EOF
}

# Write env-file with reported:true and reportedAt timestamp to $1.
# This is what the renderer writes after successfully emitting the Final Report.
write_env_file_with_flag() {
    local path="$1"
    node -e "
const fs = require('fs');
const obj = {
  CC_RESTART_REQUIRED: 'not_required',
  CC_RESTART_REASON: '',
  VSCODE_RELOAD_REQUIRED: 'not_required',
  VSCODE_RELOAD_REASON: '',
  INSTALLER_RERUN_REQUIRED: 'not_required',
  INSTALLER_RERUN_REASON: '',
  OS_REBOOT_REQUIRED: 'not_required',
  OS_REBOOT_REASON: '',
  reported: true,
  reportedAt: new Date().toISOString()
};
fs.writeFileSync(process.argv[1], JSON.stringify(obj, null, 2));
" -- "$(node_path "$path")" 2>/dev/null
}

# Write a JSONL transcript whose last line is an assistant message containing $2.
# $1 = path to write, $2 = text for the last assistant message content.
write_transcript_with_assistant() {
    local path="$1"
    local text="$2"
    # Escape backslashes and double-quotes in text for JSON embedding.
    local escaped
    escaped="$(printf '%s' "$text" | node -e "
let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
  process.stdout.write(JSON.stringify(s));
});")"
    printf '{"type":"user","message":{"content":"hello"}}\n' > "$path"
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' \
        "$escaped" >> "$path"
}

# Write the full block text that the old hook checked for.
full_block_text() {
    printf '%s\n%s\n%s\n%s\n%s' \
        '### Post-Merge Actions Required' \
        '- Claude Code restart: not_required' \
        '- VS Code reload: not_required' \
        '- Installer rerun: not_required' \
        '- OS reboot: not_required'
}

# Build the full 9-section canonical report text for a given session ID.
full_canonical_report_text() {
    local sid="$1"
    cat <<EOF
## Final Report — ${sid}
### Closed Issues
- (none)
### Merged PR
- PR #(none): (none)
- URL: (none)
- State: (none)
### Worktree
- Branch: (none)
### Backup
- Manifest: (none)
### Closed Issue Outcomes
- (none)
### Post-Merge Actions Required
- Claude Code restart: not_required
- VS Code reload: not_required
- Installer rerun: not_required
- OS reboot: not_required
### Bugs Found
- (none)
### Related Tasks
- (none)
### Next Tasks
- (none)
EOF
}

# Run the hook with a given stdin JSON, WORKFLOW_PLANS_DIR env override.
# Prints stdout; returns the hook exit code via global HOOK_EXIT.
HOOK_EXIT=0
run_hook() {
    local stdin_json="$1"
    local plans_dir="$2"
    shift 2
    local out
    out="$(WORKFLOW_PLANS_DIR="$plans_dir" run_with_timeout 120 \
        node "$HOOK_JS" <<< "$stdin_json" 2>/dev/null)"
    HOOK_EXIT=$?
    printf '%s' "$out"
}

run_hook_exit() {
    local stdin_json="$1"
    local plans_dir="$2"
    shift 2
    WORKFLOW_PLANS_DIR="$plans_dir" run_with_timeout 120 \
        node "$HOOK_JS" <<< "$stdin_json" >/dev/null 2>&1
    echo "$?"
}

# ---------------------------------------------------------------------------
# G1: env-file absent → exit 0 (no-op)
# UNCHANGED
# ---------------------------------------------------------------------------
test_G1_envfile_absent() {
    require_hook "G1_envfile_absent" || return

    local plans_dir="$TMPDIR_BASE/g1-plans"
    mkdir -p "$plans_dir"
    local sid="g1-sid"
    # Do NOT create <plans_dir>/<sid>-final-report-env.json

    local transcript="$TMPDIR_BASE/g1-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "Some random text without the block."
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local code
    code="$(run_hook_exit "$stdin_json" "$plans_dir")"

    if [ "$code" = "0" ]; then
        pass "G1: env-file absent → exit 0 (no-op)"
    else
        fail "G1: expected exit 0, got $code"
    fi
}

# ---------------------------------------------------------------------------
# G2: UPDATE — env-file present + reported:true + heading in assistant text → exit 0
# (both flag and paste present)
# ---------------------------------------------------------------------------
test_G2_reported_flag_true_passes() {
    require_hook "G2_reported_flag_true_passes" || return

    local plans_dir="$TMPDIR_BASE/g2-plans"
    mkdir -p "$plans_dir"
    local sid="g2-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_env_file_with_flag "$envfile"

    # Transcript has the Final Report heading in the assistant text.
    local transcript="$TMPDIR_BASE/g2-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "## Final Report — ${sid}
Task complete."
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local code
    code="$(run_hook_exit "$stdin_json" "$(node_path "$plans_dir")")"

    if [ "$code" = "0" ]; then
        pass "G2: env-file present + reported:true + heading in assistant text → exit 0"
    else
        fail "G2: expected exit 0 (flag + paste present), got $code"
    fi
}

# ---------------------------------------------------------------------------
# G3: UPDATE — env-file present + no reported field → exit 2 + decision:block
# ---------------------------------------------------------------------------
test_G3_no_reported_field_blocks() {
    require_hook "G3_no_reported_field_blocks" || return

    local plans_dir="$TMPDIR_BASE/g3-plans"
    mkdir -p "$plans_dir"
    local sid="g3-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    local transcript="$TMPDIR_BASE/g3-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "I completed the task."
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local plans_dir_node; plans_dir_node="$(node_path "$plans_dir")"
    local out
    out="$(WORKFLOW_PLANS_DIR="$plans_dir_node" run_with_timeout 120 \
        node "$HOOK_JS" <<< "$stdin_json" 2>/dev/null)"
    local code=$?

    if [ "$code" = "2" ] && printf '%s' "$out" | node -e "
        let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
          try {
            const obj=JSON.parse(s.trim());
            process.exit(obj.decision==='block'?0:1);
          } catch(e){ process.exit(1); }
        });" 2>/dev/null; then
        pass "G3: env-file present, no reported field → exit 2 + decision:block"
    else
        fail "G3: expected exit 2 + decision:block (no reported field), got code=$code out=$(printf '%s' "$out" | head -c 200)"
    fi
}

# ---------------------------------------------------------------------------
# G4: stop_hook_active: true → exit 0 (guard)
# UNCHANGED
# ---------------------------------------------------------------------------
test_G4_stop_hook_active() {
    require_hook "G4_stop_hook_active" || return

    local plans_dir="$TMPDIR_BASE/g4-plans"
    mkdir -p "$plans_dir"
    local sid="g4-sid"
    # Even with an env-file present (no reported flag), stop_hook_active should short-circuit
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    local transcript="$TMPDIR_BASE/g4-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "No block here."
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"stop_hook_active":true,"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local code
    code="$(run_hook_exit "$stdin_json" "$plans_dir")"

    if [ "$code" = "0" ]; then
        pass "G4: stop_hook_active:true → exit 0 (guard, no flag check)"
    else
        fail "G4: expected exit 0 for stop_hook_active:true, got $code"
    fi
}

# ---------------------------------------------------------------------------
# G5: UPDATE — env-file + reported:true + transcript missing → exit 0
# (transcript no longer consulted)
# ---------------------------------------------------------------------------
test_G5_reported_flag_true_transcript_missing() {
    require_hook "G5_reported_flag_true_transcript_missing" || return

    local plans_dir="$TMPDIR_BASE/g5-plans"
    mkdir -p "$plans_dir"
    local sid="g5-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_env_file_with_flag "$envfile"

    # Point to a non-existent transcript
    local bad_transcript
    bad_transcript="$(node_path "$TMPDIR_BASE/g5-NONEXISTENT.jsonl")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$bad_transcript")"

    local code
    code="$(run_hook_exit "$stdin_json" "$(node_path "$plans_dir")")"

    if [ "$code" = "0" ]; then
        pass "G5: env-file + reported:true + missing transcript → exit 0 (transcript no longer consulted)"
    else
        fail "G5: expected exit 0 (reported:true, transcript not checked), got $code"
    fi
}

# ---------------------------------------------------------------------------
# G6: env-file present but malformed JSON → exit 0 (fail-open)
# UNCHANGED
# ---------------------------------------------------------------------------
test_G6_envfile_malformed_json() {
    require_hook "G6_envfile_malformed_json" || return

    local plans_dir="$TMPDIR_BASE/g6-plans"
    mkdir -p "$plans_dir"
    local sid="g6-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    printf 'THIS IS NOT JSON {{{' > "$envfile"

    local transcript="$TMPDIR_BASE/g6-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "No block here either."
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local code
    code="$(run_hook_exit "$stdin_json" "$plans_dir")"

    if [ "$code" = "0" ]; then
        pass "G6: env-file malformed JSON → exit 0 (fail-open)"
    else
        fail "G6: expected exit 0 (fail-open) for malformed env-file, got $code"
    fi
}

# ---------------------------------------------------------------------------
# G7: UPDATE — env-file with reported:false (explicit) → exit 2
# ---------------------------------------------------------------------------
test_G7_reported_flag_false_blocks() {
    require_hook "G7_reported_flag_false_blocks" || return

    local plans_dir="$TMPDIR_BASE/g7-plans"
    mkdir -p "$plans_dir"
    local sid="g7-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    # Explicit reported:false
    node -e "
const fs = require('fs');
const obj = {
  CC_RESTART_REQUIRED: 'not_required',
  CC_RESTART_REASON: '',
  VSCODE_RELOAD_REQUIRED: 'not_required',
  VSCODE_RELOAD_REASON: '',
  INSTALLER_RERUN_REQUIRED: 'not_required',
  INSTALLER_RERUN_REASON: '',
  OS_REBOOT_REQUIRED: 'not_required',
  OS_REBOOT_REASON: '',
  reported: false
};
fs.writeFileSync(process.argv[1], JSON.stringify(obj, null, 2));
" -- "$(node_path "$envfile")" 2>/dev/null

    local transcript="$TMPDIR_BASE/g7-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "Task complete."
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local plans_dir_node; plans_dir_node="$(node_path "$plans_dir")"
    local out
    out="$(WORKFLOW_PLANS_DIR="$plans_dir_node" run_with_timeout 120 \
        node "$HOOK_JS" <<< "$stdin_json" 2>/dev/null)"
    local code=$?

    if [ "$code" = "2" ]; then
        pass "G7: env-file with reported:false (explicit) → exit 2"
    else
        fail "G7: expected exit 2 for reported:false, got $code (out=$(printf '%s' "$out" | head -c 200))"
    fi
}

# ---------------------------------------------------------------------------
# G8: legacy key only (CLAUDE_CODE_RESTART_REQUIRED: "yes") → reason contains
#     "Claude Code restart: required"
# UNCHANGED — env-file has no reported field; hook still blocks, reason mentions restart
# ---------------------------------------------------------------------------
test_G8_legacy_key_yes() {
    require_hook "G8_legacy_key_yes" || return

    local plans_dir="$TMPDIR_BASE/g8-plans"
    mkdir -p "$plans_dir"
    local sid="g8-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    # Use ONLY legacy key; no reported field
    cat > "$envfile" <<'EOF'
{
  "CLAUDE_CODE_RESTART_REQUIRED": "yes",
  "CC_RESTART_REASON": "",
  "VSCODE_RELOAD_REQUIRED": "not_required",
  "VSCODE_RELOAD_REASON": "",
  "INSTALLER_RERUN_REQUIRED": "not_required",
  "INSTALLER_RERUN_REASON": "",
  "OS_REBOOT_REQUIRED": "not_required",
  "OS_REBOOT_REASON": ""
}
EOF

    # Transcript has no block — irrelevant for new design; no reported field triggers block
    local transcript="$TMPDIR_BASE/g8-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "Task complete."
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local plans_dir_node; plans_dir_node="$(node_path "$plans_dir")"
    local out
    out="$(WORKFLOW_PLANS_DIR="$plans_dir_node" run_with_timeout 120 \
        node "$HOOK_JS" <<< "$stdin_json" 2>/dev/null)"
    local code=$?

    if [ "$code" = "2" ] && printf '%s' "$out" | node -e "
        let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
          try {
            const obj=JSON.parse(s.trim());
            const ok = obj.decision==='block' &&
                       typeof obj.reason === 'string' &&
                       obj.reason.includes('Claude Code restart: required');
            process.exit(ok ? 0 : 1);
          } catch(e){ process.exit(1); }
        });" 2>/dev/null; then
        pass "G8: legacy key CLAUDE_CODE_RESTART_REQUIRED=yes → reason contains 'Claude Code restart: required'"
    else
        fail "G8: expected exit 2 + reason with 'Claude Code restart: required', got code=$code out=$(printf '%s' "$out" | head -c 300)"
    fi
}

# ---------------------------------------------------------------------------
# G10: UPDATE — env-file + reported:true + heading in assistant text → exit 0
# ---------------------------------------------------------------------------
test_G10_reported_flag_true_passes() {
    require_hook "G10_reported_flag_true_passes" || return

    local plans_dir="$TMPDIR_BASE/g10-plans"
    mkdir -p "$plans_dir"
    local sid="g10-test-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_env_file_with_flag "$envfile"

    local transcript="$TMPDIR_BASE/g10-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "## Final Report — ${sid}
Session closed."
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local code
    code="$(run_hook_exit "$stdin_json" "$(node_path "$plans_dir")")"

    if [ "$code" = "0" ]; then
        pass "G10: env-file + reported:true + heading in assistant text → exit 0"
    else
        fail "G10: expected exit 0 (flag + heading in transcript), got $code"
    fi
}

# ---------------------------------------------------------------------------
# G11: UPDATE — env-file + no reported field → exit 2, reason contains
#      "verbatim" AND "reported" (flag-contract phrasing; "## Final Report —" no longer required)
# ---------------------------------------------------------------------------
test_G11_reason_contains_instruction() {
    require_hook "G11_reason_contains_instruction" || return

    local plans_dir="$TMPDIR_BASE/g11-plans"
    mkdir -p "$plans_dir"
    local sid="g11-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    local transcript="$TMPDIR_BASE/g11-transcript.jsonl"
    write_transcript_with_assistant "$transcript" ""
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local plans_dir_node; plans_dir_node="$(node_path "$plans_dir")"
    local out
    out="$(WORKFLOW_PLANS_DIR="$plans_dir_node" run_with_timeout 120 \
        node "$HOOK_JS" <<< "$stdin_json" 2>/dev/null)"
    local code=$?

    if [ "$code" = "2" ] && printf '%s' "$out" | node -e "
        let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
          try {
            const obj=JSON.parse(s.trim());
            const hasVerbatim = typeof obj.reason === 'string' && obj.reason.includes('verbatim');
            const hasReported = typeof obj.reason === 'string' && obj.reason.includes('reported');
            process.exit((obj.decision==='block' && hasVerbatim && hasReported)?0:1);
          } catch(e){ process.exit(1); }
        });" 2>/dev/null; then
        pass "G11: no reported field → exit 2, reason contains 'verbatim' and 'reported'"
    else
        fail "G11: expected exit 2 + reason with 'verbatim' and 'reported', got code=$code out=$(printf '%s' "$out" | head -c 400)"
    fi
}

# ---------------------------------------------------------------------------
# G12: UPDATE — env-file + no reported field → exit 2
# (regression guard: previously only Post-Merge block was sufficient; now flag required)
# ---------------------------------------------------------------------------
test_G12_no_reported_field_blocks() {
    require_hook "G12_no_reported_field_blocks" || return

    local plans_dir="$TMPDIR_BASE/g12-plans"
    mkdir -p "$plans_dir"
    local sid="g12-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    # Transcript has full Post-Merge block — but no reported flag in env-file
    local text
    text="$(full_block_text)"

    local transcript="$TMPDIR_BASE/g12-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "$text"
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local plans_dir_node; plans_dir_node="$(node_path "$plans_dir")"
    local out
    out="$(WORKFLOW_PLANS_DIR="$plans_dir_node" run_with_timeout 120 \
        node "$HOOK_JS" <<< "$stdin_json" 2>/dev/null)"
    local code=$?

    if [ "$code" = "2" ]; then
        pass "G12: env-file with no reported field → exit 2 (transcript content no longer sufficient)"
    else
        fail "G12: expected exit 2 (no reported flag), got $code"
    fi
}

# ---------------------------------------------------------------------------
# G13 NEW: extra-turn regression — env-file has reported:true, transcript has
#          additional assistant message AFTER Final Report → exit 0.
# This is the regression test for the original #626 silent-pass bug: the old
# transcript scan would pass on the Final Report turn but fail on any
# subsequent turn (the extra message displaced the Final Report). With
# flag-based design, reported:true always passes regardless of transcript.
# ---------------------------------------------------------------------------
test_G13_extra_turn_after_final_report() {
    require_hook "G13_extra_turn_after_final_report" || return

    local plans_dir="$TMPDIR_BASE/g13-plans"
    mkdir -p "$plans_dir"
    local sid="g13-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_env_file_with_flag "$envfile"

    # Build transcript: first assistant message has the Final Report;
    # second assistant message is unrelated (the extra turn that caused #626)
    local transcript="$TMPDIR_BASE/g13-transcript.jsonl"
    local report_text; report_text="$(full_canonical_report_text "$sid")"
    local report_escaped
    report_escaped="$(printf '%s' "$report_text" | node -e "
let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
  process.stdout.write(JSON.stringify(s));
});")"
    local extra_text="All done! Let me know if you need anything else."
    local extra_escaped
    extra_escaped="$(printf '%s' "$extra_text" | node -e "
let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
  process.stdout.write(JSON.stringify(s));
});")"

    {
        printf '{"type":"user","message":{"content":"run final report"}}\n'
        printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' \
            "$report_escaped"
        printf '{"type":"user","message":{"content":"thanks"}}\n'
        printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' \
            "$extra_escaped"
    } > "$transcript"

    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local code
    code="$(run_hook_exit "$stdin_json" "$(node_path "$plans_dir")")"

    if [ "$code" = "0" ]; then
        pass "G13: extra-turn after Final Report + reported:true → exit 0 (regression guard for #626)"
    else
        fail "G13: expected exit 0 (reported:true, extra turn irrelevant), got $code"
    fi
}

# ---------------------------------------------------------------------------
# G14 NEW: renderer invocation writes reported:true flag to env-file.
# Create minimal fixture env-file (no reported field), invoke the renderer,
# re-read the env-file, assert reported===true and reportedAt is parseable ISO string.
# ---------------------------------------------------------------------------
test_G14_renderer_writes_flag() {
    if [ ! -f "$REPORT_JS" ]; then
        skip "G14_renderer_writes_flag (bin/worktree-final-report.js not found)"
        return
    fi

    local sid="g14-sid"
    local envfile="$TMPDIR_BASE/${sid}-final-report-env.json"
    local intent="$TMPDIR_BASE/g14-intent.md"

    # Minimal intent with no closes_issues
    cat > "$intent" <<'INTENTEOF'
# Intent

## closes_issues
(empty)
INTENTEOF

    # env-file with env data but NO reported field
    write_default_env_file "$envfile"

    local envfile_node; envfile_node="$(node_path "$envfile")"
    local intent_node; intent_node="$(node_path "$intent")"
    local report_node; report_node="$REPORT_JS"

    # Run the renderer: intent notes="" sid --env-file <envfile>
    run_with_timeout 120 node "$report_node" "$intent_node" "" "$sid" -- --env-file "$envfile_node" >/dev/null 2>/dev/null
    local render_code=$?

    if [ "$render_code" != "0" ]; then
        fail "G14: renderer exited $render_code (expected 0)"
        return
    fi

    # Now read the env-file and check for reported:true and parseable reportedAt
    local result
    result="$(node -e "
const fs = require('fs');
let obj;
try {
  obj = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
} catch(e) {
  process.stdout.write('FAIL:parse:' + e.message);
  process.exit(0);
}
if (obj.reported !== true) {
  process.stdout.write('FAIL:reported=' + JSON.stringify(obj.reported));
  process.exit(0);
}
if (typeof obj.reportedAt !== 'string') {
  process.stdout.write('FAIL:reportedAt not string');
  process.exit(0);
}
const d = new Date(obj.reportedAt);
if (isNaN(d.getTime())) {
  process.stdout.write('FAIL:reportedAt not ISO:' + obj.reportedAt);
  process.exit(0);
}
process.stdout.write('PASS');
" -- "$envfile_node" 2>/dev/null)"

    if [ "$result" = "PASS" ]; then
        pass "G14: renderer exit 0 + env-file has reported:true + parseable reportedAt ISO string"
    else
        fail "G14: $result"
    fi
}

# ---------------------------------------------------------------------------
# G15 NEW: renderer idempotency — invoke renderer twice; both times env-file
#          must remain valid JSON with reported===true.
# ---------------------------------------------------------------------------
test_G15_renderer_idempotent() {
    if [ ! -f "$REPORT_JS" ]; then
        skip "G15_renderer_idempotent (bin/worktree-final-report.js not found)"
        return
    fi

    local sid="g15-sid"
    local envfile="$TMPDIR_BASE/${sid}-final-report-env.json"
    local intent="$TMPDIR_BASE/g15-intent.md"

    cat > "$intent" <<'INTENTEOF'
# Intent

## closes_issues
(empty)
INTENTEOF

    write_default_env_file "$envfile"

    local envfile_node; envfile_node="$(node_path "$envfile")"
    local intent_node; intent_node="$(node_path "$intent")"
    local report_node; report_node="$REPORT_JS"

    # First invocation
    run_with_timeout 120 node "$report_node" "$intent_node" "" "$sid" -- --env-file "$envfile_node" >/dev/null 2>/dev/null
    local code1=$?

    # Second invocation (idempotency check)
    run_with_timeout 120 node "$report_node" "$intent_node" "" "$sid" -- --env-file "$envfile_node" >/dev/null 2>/dev/null
    local code2=$?

    if [ "$code1" != "0" ] || [ "$code2" != "0" ]; then
        fail "G15: renderer non-zero exit (code1=$code1 code2=$code2)"
        return
    fi

    # After both invocations, env-file must still have reported:true
    local result
    result="$(node -e "
const fs = require('fs');
let obj;
try {
  obj = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
} catch(e) {
  process.stdout.write('FAIL:parse:' + e.message);
  process.exit(0);
}
if (obj.reported !== true) {
  process.stdout.write('FAIL:reported=' + JSON.stringify(obj.reported));
  process.exit(0);
}
process.stdout.write('PASS');
" -- "$envfile_node" 2>/dev/null)"

    if [ "$result" = "PASS" ]; then
        pass "G15: renderer idempotent — env-file valid JSON with reported:true after two invocations"
    else
        fail "G15: idempotency check failed: $result"
    fi
}

# ---------------------------------------------------------------------------
# G16 NEW: renderer ran (reported:true) but Final Report heading only in
#          Bash tool result, NOT in any assistant text → exit 2 (issue #700).
# Transcript structure: assistant tool_use → user tool_result with heading →
# assistant text "The renderer completed." (no heading in assistant text).
# ---------------------------------------------------------------------------
test_G16_heading_only_in_tool_result_blocks() {
    require_hook "G16_heading_only_in_tool_result_blocks" || return

    local plans_dir="$TMPDIR_BASE/g16-plans"
    mkdir -p "$plans_dir"
    local sid="g16-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_env_file_with_flag "$envfile"

    local transcript="$TMPDIR_BASE/g16-transcript.jsonl"

    # Build a transcript that simulates: Claude ran the renderer via Bash tool;
    # output (with heading) appears in the tool_result (user message);
    # the subsequent assistant text does NOT contain the heading.
    local report_text; report_text="$(full_canonical_report_text "$sid")"
    local report_escaped
    report_escaped="$(printf '%s' "$report_text" | node -e "
let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
  process.stdout.write(JSON.stringify(s));
});")"

    {
        # Assistant turn: calls Bash tool (no text content with heading)
        printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"node bin/worktree-final-report.js"}}]}}\n'
        # User turn: tool_result containing the Final Report output
        printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":%s}]}]}}\n' \
            "$report_escaped"
        # Assistant turn: response text WITHOUT the Final Report heading
        printf '{"type":"assistant","message":{"content":[{"type":"text","text":"The renderer completed successfully."}]}}\n'
    } > "$transcript"

    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local plans_dir_node; plans_dir_node="$(node_path "$plans_dir")"
    local out
    out="$(WORKFLOW_PLANS_DIR="$plans_dir_node" run_with_timeout 120 \
        node "$HOOK_JS" <<< "$stdin_json" 2>/dev/null)"
    local code=$?

    if [ "$code" = "2" ] && printf '%s' "$out" | node -e "
        let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
          try {
            const obj=JSON.parse(s.trim());
            const ok = obj.decision==='block' &&
                       typeof obj.reason === 'string' &&
                       obj.reason.includes('verbatim') &&
                       obj.reason.includes('reported');
            process.exit(ok ? 0 : 1);
          } catch(e){ process.exit(1); }
        });" 2>/dev/null; then
        pass "G16: reported:true but heading only in tool_result → exit 2 (issue #700 regression guard)"
    else
        fail "G16: expected exit 2 + decision:block (heading only in tool_result), got code=$code out=$(printf '%s' "$out" | head -c 300)"
    fi
}

# ---------------------------------------------------------------------------
# I1: settings.json Stop hooks array contains stop-final-report-guard.js
# UNCHANGED
# ---------------------------------------------------------------------------
test_I1_settings_json_stop_hook() {
    if [ ! -f "$SETTINGS_JSON" ]; then
        skip "I1_settings_json_stop_hook (settings.json not found at $SETTINGS_JSON)"
        return
    fi
    if [ ! -f "$HOOK_JS" ]; then
        skip "I1_settings_json_stop_hook (hook not implemented yet — settings.json entry added alongside impl)"
        return
    fi

    local settings_node; settings_node="$(node_path "$SETTINGS_JSON")"
    local found
    found="$(node -e "
        const path=require('path');
        const s = require(path.resolve(process.argv[1]));
        const hooks = (s.hooks && s.hooks.Stop) || [];
        let found = false;
        for (const group of hooks) {
            for (const h of (group.hooks || [])) {
                if (h.command && h.command.includes('stop-final-report-guard.js')) {
                    found = true;
                }
            }
        }
        process.stdout.write(found ? 'yes' : 'no');
    " -- "$settings_node" 2>/dev/null)"

    if [ "$found" = "yes" ]; then
        pass "I1: settings.json Stop hooks array contains stop-final-report-guard.js"
    else
        fail "I1: settings.json Stop hooks does NOT contain stop-final-report-guard.js"
    fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

test_G1_envfile_absent
test_G2_reported_flag_true_passes
test_G3_no_reported_field_blocks
test_G4_stop_hook_active
test_G5_reported_flag_true_transcript_missing
test_G6_envfile_malformed_json
test_G7_reported_flag_false_blocks
test_G8_legacy_key_yes
test_I1_settings_json_stop_hook
test_G10_reported_flag_true_passes
test_G11_reason_contains_instruction
test_G12_no_reported_field_blocks
test_G13_extra_turn_after_final_report
test_G14_renderer_writes_flag
test_G15_renderer_idempotent
test_G16_heading_only_in_tool_result_blocks

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

exit $FAIL
