#!/bin/bash
# tests/feature-534-stop-final-report-guard.sh
# Tests: hooks/stop-final-report-guard.js
# Tags: settings, config, hook, bin, tests
#
# Issue #534 — Stop hook: stop-final-report-guard.js
#
# Tests the contract of hooks/stop-final-report-guard.js (not yet implemented —
# all G-tests SKIP gracefully when the hook file is absent).
#
# I1 (settings.json invariant) does NOT need the hook file and always runs.
#
# Test-first: G-tests either SKIP (source missing) or PASS/FAIL once implemented.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK_JS="${_AGENTS_DIR_NODE}/hooks/stop-final-report-guard.js"
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

# Write a minimal env-file (all not_required) to $1.
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

# Write the full block text that the hook should check for.
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

# Run the hook with a given stdin JSON, WORKFLOW_PLANS_DIR env override, and
# optional extra env vars (as "KEY=VALUE" pairs in $3+).
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
# G2: env-file present, all 4 block lines in last assistant message → exit 0
# ---------------------------------------------------------------------------
test_G2_block_present_in_transcript() {
    require_hook "G2_block_present_in_transcript" || return

    local plans_dir="$TMPDIR_BASE/g2-plans"
    mkdir -p "$plans_dir"
    local sid="g2-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    local transcript="$TMPDIR_BASE/g2-transcript.jsonl"
    # Embed the full canonical report in the last assistant message
    local block_text; block_text="$(full_canonical_report_text "$sid")"
    write_transcript_with_assistant "$transcript" "$block_text"
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local code
    code="$(run_hook_exit "$stdin_json" "$plans_dir")"

    if [ "$code" = "0" ]; then
        pass "G2: env-file present, full canonical report in last assistant message → exit 0"
    else
        fail "G2: expected exit 0 (full canonical report present), got $code"
    fi
}

# ---------------------------------------------------------------------------
# G3: env-file present, block missing from last assistant message → exit 2 + decision:block
# ---------------------------------------------------------------------------
test_G3_block_missing_from_transcript() {
    require_hook "G3_block_missing_from_transcript" || return

    local plans_dir="$TMPDIR_BASE/g3-plans"
    mkdir -p "$plans_dir"
    local sid="g3-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    local transcript="$TMPDIR_BASE/g3-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "I completed the task but forgot to include the final report block."
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
        pass "G3: env-file present, block missing → exit 2 + decision:block in stdout"
    else
        fail "G3: expected exit 2 + decision:block, got code=$code out=$(printf '%s' "$out" | head -c 200)"
    fi
}

# ---------------------------------------------------------------------------
# G4: stop_hook_active: true → exit 0 (guard)
# ---------------------------------------------------------------------------
test_G4_stop_hook_active() {
    require_hook "G4_stop_hook_active" || return

    local plans_dir="$TMPDIR_BASE/g4-plans"
    mkdir -p "$plans_dir"
    local sid="g4-sid"
    # Even with an env-file present, stop_hook_active should short-circuit
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
        pass "G4: stop_hook_active:true → exit 0 (guard, no block check)"
    else
        fail "G4: expected exit 0 for stop_hook_active:true, got $code"
    fi
}

# ---------------------------------------------------------------------------
# G5: transcript_path missing/unreadable → exit 0 (fail-open)
# ---------------------------------------------------------------------------
test_G5_transcript_missing() {
    require_hook "G5_transcript_missing" || return

    local plans_dir="$TMPDIR_BASE/g5-plans"
    mkdir -p "$plans_dir"
    local sid="g5-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    # Point to a non-existent transcript
    local bad_transcript
    bad_transcript="$(node_path "$TMPDIR_BASE/g5-NONEXISTENT.jsonl")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$bad_transcript")"

    local code
    code="$(run_hook_exit "$stdin_json" "$plans_dir")"

    if [ "$code" = "0" ]; then
        pass "G5: transcript_path missing → exit 0 (fail-open)"
    else
        fail "G5: expected exit 0 (fail-open) for missing transcript, got $code"
    fi
}

# ---------------------------------------------------------------------------
# G6: env-file present but malformed JSON → exit 0 (fail-open)
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
# G7: partial block (some categories present, some missing) → exit 2
# ---------------------------------------------------------------------------
test_G7_partial_block() {
    require_hook "G7_partial_block" || return

    local plans_dir="$TMPDIR_BASE/g7-plans"
    mkdir -p "$plans_dir"
    local sid="g7-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    # Only the heading + first two categories — missing last two
    local partial_text
    partial_text="$(printf '%s\n%s\n%s' \
        '### Post-Merge Actions Required' \
        '- Claude Code restart: not_required' \
        '- VS Code reload: not_required')"
    local transcript="$TMPDIR_BASE/g7-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "$partial_text"
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
        pass "G7: partial block (only 2 of 4 categories present) → exit 2"
    else
        fail "G7: expected exit 2 for partial block, got $code (out=$(printf '%s' "$out" | head -c 200))"
    fi
}

# ---------------------------------------------------------------------------
# G8: legacy key only (CLAUDE_CODE_RESTART_REQUIRED: "yes") → reason contains
#     "Claude Code restart: required"
# ---------------------------------------------------------------------------
test_G8_legacy_key_yes() {
    require_hook "G8_legacy_key_yes" || return

    local plans_dir="$TMPDIR_BASE/g8-plans"
    mkdir -p "$plans_dir"
    local sid="g8-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    # Use ONLY legacy key; no CC_RESTART_REQUIRED new key
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

    # Transcript has NO block at all → will trigger a block
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
# G9a: header (## Final Report — <sid>) missing → exit 2 + decision:block
# ---------------------------------------------------------------------------
test_G9a_header_missing() {
    require_hook "G9a_header_missing" || return

    local plans_dir="$TMPDIR_BASE/g9a-plans"
    mkdir -p "$plans_dir"
    local sid="g9a-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    # All ### headings present + probes, but ## Final Report header is MISSING
    local text
    text="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
        '### Closed Issues' \
        '- (none)' \
        '### Merged PR' \
        '### Worktree' \
        '### Backup' \
        '### Post-Merge Actions Required' \
        '- Claude Code restart: not_required' \
        '- VS Code reload: not_required' \
        '- Installer rerun: not_required' \
        '- OS reboot: not_required' \
        '### Bugs Found' \
        '### Related Tasks' \
        '### Next Tasks' \
        '- (none)')"

    local transcript="$TMPDIR_BASE/g9a-transcript.jsonl"
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

    if [ "$code" = "2" ] && printf '%s' "$out" | node -e "
        let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
          try {
            const obj=JSON.parse(s.trim());
            process.exit(obj.decision==='block'?0:1);
          } catch(e){ process.exit(1); }
        });" 2>/dev/null; then
        pass "G9a: ## Final Report header missing → exit 2 + decision:block"
    else
        fail "G9a: expected exit 2 + decision:block when header missing, got code=$code out=$(printf '%s' "$out" | head -c 200)"
    fi
}

# ---------------------------------------------------------------------------
# G9b: ### Worktree missing (middle section) → exit 2 + decision:block
# ---------------------------------------------------------------------------
test_G9b_middle_section_missing() {
    require_hook "G9b_middle_section_missing" || return

    local plans_dir="$TMPDIR_BASE/g9b-plans"
    mkdir -p "$plans_dir"
    local sid="g9b-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    # Full canonical report EXCEPT ### Worktree is missing
    local text
    text="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
        '## Final Report — g9b-sid' \
        '### Closed Issues' \
        '- (none)' \
        '### Merged PR' \
        '### Backup' \
        '### Post-Merge Actions Required' \
        '- Claude Code restart: not_required' \
        '- VS Code reload: not_required' \
        '- Installer rerun: not_required' \
        '- OS reboot: not_required' \
        '### Bugs Found' \
        '### Related Tasks' \
        '### Next Tasks')"

    local transcript="$TMPDIR_BASE/g9b-transcript.jsonl"
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

    if [ "$code" = "2" ] && printf '%s' "$out" | node -e "
        let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
          try {
            const obj=JSON.parse(s.trim());
            process.exit(obj.decision==='block'?0:1);
          } catch(e){ process.exit(1); }
        });" 2>/dev/null; then
        pass "G9b: ### Worktree (middle section) missing → exit 2 + decision:block"
    else
        fail "G9b: expected exit 2 + decision:block when ### Worktree missing, got code=$code out=$(printf '%s' "$out" | head -c 200)"
    fi
}

# ---------------------------------------------------------------------------
# G9c: ### Next Tasks missing (last section) → exit 2 + decision:block
# ---------------------------------------------------------------------------
test_G9c_last_section_missing() {
    require_hook "G9c_last_section_missing" || return

    local plans_dir="$TMPDIR_BASE/g9c-plans"
    mkdir -p "$plans_dir"
    local sid="g9c-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    # Full canonical report EXCEPT ### Next Tasks is missing
    local text
    text="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
        '## Final Report — g9c-sid' \
        '### Closed Issues' \
        '- (none)' \
        '### Merged PR' \
        '### Worktree' \
        '### Backup' \
        '### Post-Merge Actions Required' \
        '- Claude Code restart: not_required' \
        '- VS Code reload: not_required' \
        '- Installer rerun: not_required' \
        '- OS reboot: not_required' \
        '### Bugs Found' \
        '### Related Tasks')"

    local transcript="$TMPDIR_BASE/g9c-transcript.jsonl"
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

    if [ "$code" = "2" ] && printf '%s' "$out" | node -e "
        let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
          try {
            const obj=JSON.parse(s.trim());
            process.exit(obj.decision==='block'?0:1);
          } catch(e){ process.exit(1); }
        });" 2>/dev/null; then
        pass "G9c: ### Next Tasks (last section) missing → exit 2 + decision:block"
    else
        fail "G9c: expected exit 2 + decision:block when ### Next Tasks missing, got code=$code out=$(printf '%s' "$out" | head -c 200)"
    fi
}

# ---------------------------------------------------------------------------
# G10: full canonical report (all 8 sections + sentinel excluded) → exit 0
# ---------------------------------------------------------------------------
test_G10_full_canonical_report_passes() {
    require_hook "G10_full_canonical_report_passes" || return

    local plans_dir="$TMPDIR_BASE/g10-plans"
    mkdir -p "$plans_dir"
    local sid="g10-test-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    # Full canonical report text — sentinel line excluded (not in assistant message body)
    local text; text="$(full_canonical_report_text "$sid")"

    local transcript="$TMPDIR_BASE/g10-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "$text"
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local code
    code="$(run_hook_exit "$stdin_json" "$(node_path "$plans_dir")")"

    if [ "$code" = "0" ]; then
        pass "G10: full canonical report (all 8 sections, no sentinel) → exit 0"
    else
        fail "G10: expected exit 0 for full canonical report, got $code"
    fi
}

# ---------------------------------------------------------------------------
# G11: empty assistant message → exit 2, reason includes "verbatim" and "## Final Report —"
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
            const hasHeader = typeof obj.reason === 'string' && obj.reason.includes('## Final Report —');
            process.exit((obj.decision==='block' && hasVerbatim && hasHeader)?0:1);
          } catch(e){ process.exit(1); }
        });" 2>/dev/null; then
        pass "G11: empty message → exit 2, reason contains 'verbatim' and '## Final Report —'"
    else
        fail "G11: expected exit 2 + reason with both 'verbatim' and '## Final Report —', got code=$code out=$(printf '%s' "$out" | head -c 400)"
    fi
}

# ---------------------------------------------------------------------------
# G12: only Post-Merge block present (old passing pattern) → now exit 2
# ---------------------------------------------------------------------------
test_G12_only_post_merge_block_no_longer_passes() {
    require_hook "G12_only_post_merge_block_no_longer_passes" || return

    local plans_dir="$TMPDIR_BASE/g12-plans"
    mkdir -p "$plans_dir"
    local sid="g12-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    # Only the Post-Merge block — heading + 4 probes — no other section headings
    # This was the "passing" fixture under old PR #567 hook behavior
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
        pass "G12: Post-Merge block only (no other headings) → exit 2 (regression guard for #534)"
    else
        fail "G12: expected exit 2 when only Post-Merge block present (missing 7 other sections), got $code"
    fi
}

# ---------------------------------------------------------------------------
# G9d: ### Closed Issue Outcomes heading entirely missing → exit 2 + decision:block
# ---------------------------------------------------------------------------
test_G9d_closed_issue_outcomes_section_missing() {
    require_hook "G9d_closed_issue_outcomes_section_missing" || return

    local plans_dir="$TMPDIR_BASE/g9d-plans"
    mkdir -p "$plans_dir"
    local sid="g9d-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    # Full canonical report EXCEPT ### Closed Issue Outcomes heading is missing
    local text
    text="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
        "## Final Report — ${sid}" \
        '### Closed Issues' \
        '- (none)' \
        '### Merged PR' \
        '### Worktree' \
        '### Backup' \
        '### Post-Merge Actions Required' \
        '- Claude Code restart: not_required' \
        '- VS Code reload: not_required' \
        '- Installer rerun: not_required' \
        '- OS reboot: not_required' \
        '### Bugs Found' \
        '### Related Tasks' \
        '### Next Tasks')"

    local transcript="$TMPDIR_BASE/g9d-transcript.jsonl"
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

    if [ "$code" = "2" ] && printf '%s' "$out" | node -e "
        let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
          try {
            const obj=JSON.parse(s.trim());
            process.exit(obj.decision==='block'?0:1);
          } catch(e){ process.exit(1); }
        });" 2>/dev/null; then
        pass "G9d: ### Closed Issue Outcomes heading missing → exit 2 + decision:block"
    else
        fail "G9d: expected exit 2 + decision:block when section heading missing, got code=$code out=$(printf '%s' "$out" | head -c 200)"
    fi
}

# ---------------------------------------------------------------------------
# G9e: ### Closed Issue Outcomes heading present, but no bullet content → exit 2
# ---------------------------------------------------------------------------
test_G9e_closed_issue_outcomes_content_missing() {
    require_hook "G9e_closed_issue_outcomes_content_missing" || return

    local plans_dir="$TMPDIR_BASE/g9e-plans"
    mkdir -p "$plans_dir"
    local sid="g9e-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    # Full canonical report EXCEPT ### Closed Issue Outcomes has no bullet line
    local text
    text="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
        "## Final Report — ${sid}" \
        '### Closed Issues' \
        '- (none)' \
        '### Merged PR' \
        '### Worktree' \
        '### Backup' \
        '### Closed Issue Outcomes' \
        '### Post-Merge Actions Required' \
        '- Claude Code restart: not_required' \
        '- VS Code reload: not_required' \
        '- Installer rerun: not_required' \
        '- OS reboot: not_required' \
        '### Bugs Found' \
        '### Related Tasks' \
        '### Next Tasks')"

    local transcript="$TMPDIR_BASE/g9e-transcript.jsonl"
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

    if [ "$code" = "2" ] && printf '%s' "$out" | node -e "
        let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
          try {
            const obj=JSON.parse(s.trim());
            process.exit(obj.decision==='block'?0:1);
          } catch(e){ process.exit(1); }
        });" 2>/dev/null; then
        pass "G9e: ### Closed Issue Outcomes heading present but no bullet → exit 2 + decision:block"
    else
        fail "G9e: expected exit 2 + decision:block when section content missing, got code=$code out=$(printf '%s' "$out" | head -c 200)"
    fi
}

# ---------------------------------------------------------------------------
# I1: settings.json Stop hooks array contains stop-final-report-guard.js
# Note: this test does not require the hook file itself, but skips when the
# hook file is absent (the settings.json entry is added alongside the impl).
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
test_G2_block_present_in_transcript
test_G3_block_missing_from_transcript
test_G4_stop_hook_active
test_G5_transcript_missing
test_G6_envfile_malformed_json
test_G7_partial_block
test_G8_legacy_key_yes
test_I1_settings_json_stop_hook
test_G9a_header_missing
test_G9b_middle_section_missing
test_G9c_last_section_missing
test_G10_full_canonical_report_passes
test_G11_reason_contains_instruction
test_G12_only_post_merge_block_no_longer_passes
test_G9d_closed_issue_outcomes_section_missing
test_G9e_closed_issue_outcomes_content_missing

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

exit $FAIL
