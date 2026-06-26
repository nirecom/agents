# tests/feature-534-stop-final-report-guard/g01-g08.sh
# Tests G1, G2, G3, G4, G6, G7, G8.
# Sourced by feature-534-stop-final-report-guard.sh — no shebang, no runner.

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
    write_transcript_with_assistant "$transcript" "Some random text."
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
# G2 (rewritten): env-file + all 13 headings present in transcript after
#                 last `## Final Report — <sid>` → exit 0
# ---------------------------------------------------------------------------
test_G2_all_headings_present_passes() {
    require_hook "G2_all_headings_present_passes" || return

    local plans_dir="$TMPDIR_BASE/g2-plans"
    mkdir -p "$plans_dir"
    local sid="g2-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    # Build a transcript containing the full 13-heading report in assistant text.
    local transcript="$TMPDIR_BASE/g2-transcript.jsonl"
    local report_text; report_text="$(full_canonical_report_text "$sid")"
    write_transcript_with_assistant "$transcript" "$report_text"
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local code
    code="$(run_hook_exit "$stdin_json" "$(node_path "$plans_dir")")"

    if [ "$code" = "0" ]; then
        pass "G2: env-file + all 13 headings in transcript → exit 0"
    else
        fail "G2: expected exit 0 (all headings present), got $code"
    fi
}

# ---------------------------------------------------------------------------
# G3 (replacement): env-file with empty object {} (no `reported` field needed
#                   under new contract, but also no report heading) →
#                   need to test: file exists + parses but transcript lacks header
#                   → exit 0 (header absent = guard not yet applicable per G20).
# This test guards the absent-header path with a minimal env-file.
# ---------------------------------------------------------------------------
test_G3_empty_env_object_no_header() {
    require_hook "G3_empty_env_object_no_header" || return

    local plans_dir="$TMPDIR_BASE/g3-plans"
    mkdir -p "$plans_dir"
    local sid="g3-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    printf '{}' > "$envfile"

    local transcript="$TMPDIR_BASE/g3-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "no header here"
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local code
    code="$(run_hook_exit "$stdin_json" "$(node_path "$plans_dir")")"

    if [ "$code" = "0" ]; then
        pass "G3: empty env-file {} + no header in transcript → exit 0 (guard not applicable)"
    else
        fail "G3: expected exit 0, got $code"
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
        pass "G4: stop_hook_active:true → exit 0 (guard)"
    else
        fail "G4: expected exit 0 for stop_hook_active:true, got $code"
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
# G7 (rewritten): env-file + `## Final Report — <sid>` present + 12 of 13
#                 headings present (missing ### Next Tasks only) → exit 2 + decision:block
# ---------------------------------------------------------------------------
test_G7_header_present_subheading_missing() {
    require_hook "G7_header_present_subheading_missing" || return

    local plans_dir="$TMPDIR_BASE/g7-plans"
    mkdir -p "$plans_dir"
    local sid="g7-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    # Build report with `### Next Tasks` omitted (12 of 13 headings present).
    local transcript="$TMPDIR_BASE/g7-transcript.jsonl"
    local report_text
    report_text="$(cat <<EOF
## Final Report — ${sid}
### Closed Issues
- (none)
### Merged PR
- PR #(none): (none)
### Worktree
- Branch: (none)
### Backup
- Manifest: (none)
### Closed Issue Outcomes
- (none)
### Post-Merge Actions Required
- Claude Code restart: not_required
### Bugs Found
- (none)
### Related Tasks
- (none)
### Supervisor Alert
(not run)
### Supervisor Audit
(not run)
### Supervisor Findings
(no findings)
EOF
)"
    write_transcript_with_assistant "$transcript" "$report_text"
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
        pass "G7: header + 12/13 ### headings (missing Next Tasks) → exit 2 + decision:block"
    else
        fail "G7: expected exit 2 + decision:block, got code=$code out=$(printf '%s' "$out" | head -c 200)"
    fi
}

# ---------------------------------------------------------------------------
# G8 (rewritten): env-file with legacy CLAUDE_CODE_RESTART_REQUIRED:"yes" +
#                 header present + missing `###` heading → exit 2 + reason
#                 includes "Claude Code restart: required"
# ---------------------------------------------------------------------------
test_G8_legacy_key_yes() {
    require_hook "G8_legacy_key_yes" || return

    local plans_dir="$TMPDIR_BASE/g8-plans"
    mkdir -p "$plans_dir"
    local sid="g8-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
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

    # Transcript has header but is missing the required `###` headings.
    local transcript="$TMPDIR_BASE/g8-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "## Final Report — ${sid}
Done."
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
        pass "G8: legacy CLAUDE_CODE_RESTART_REQUIRED=yes + missing headings → reason includes 'Claude Code restart: required'"
    else
        fail "G8: expected exit 2 + reason 'Claude Code restart: required', got code=$code out=$(printf '%s' "$out" | head -c 300)"
    fi
}
