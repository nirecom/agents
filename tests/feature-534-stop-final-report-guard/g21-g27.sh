# tests/feature-534-stop-final-report-guard/g21-g27.sh
# Tests G21, G22, G23, G23b, G24, G25, G26, G27.
# Sourced by feature-534-stop-final-report-guard.sh — no shebang, no runner.

# ---------------------------------------------------------------------------
# G21 (regression): tool_result sentinel after FR → exit 0 (false-positive fix)
# JSONL: user → assistant (full FR) → user (tool_result with sentinel)
# Expected: 0. Unfixed hook exits 2.
# ---------------------------------------------------------------------------
test_G21_tool_result_sentinel_after_report() {
    require_hook "G21_tool_result_sentinel_after_report" || return

    local plans_dir="$TMPDIR_BASE/g21-plans"
    mkdir -p "$plans_dir"
    local sid="g21-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    local transcript="$TMPDIR_BASE/g21-transcript.jsonl"
    local fr_text; fr_text="$(full_canonical_report_text "$sid")"
    local fr_escaped
    fr_escaped="$(printf '%s' "$fr_text" | node -e "
let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
  process.stdout.write(JSON.stringify(s));
});")";

    printf '{"type":"user","message":{"content":"start"}}\n' > "$transcript"
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' \
        "$fr_escaped" >> "$transcript"
    printf '{"type":"user","message":{"content":[{"type":"tool_result","content":"grep result: <<WORKFLOW_ENFORCE_WORKFLOW_OFF>>"}]}}\n' \
        >> "$transcript"

    local transcript_node; transcript_node="$(node_path "$transcript")"
    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local code
    code="$(run_hook_exit "$stdin_json" "$(node_path "$plans_dir")")"

    if [ "$code" = "0" ]; then
        pass "G21: tool_result sentinel after canonical FR → exit 0 (no false-positive)"
    else
        fail "G21: expected exit 0, got $code (false-positive — fix hook)"
    fi
}

# ---------------------------------------------------------------------------
# G22 (regression): <TOKEN> outside FR section in same assistant turn → exit 0
# Expected: 0. Unfixed hook exits 2.
# ---------------------------------------------------------------------------
test_G22_token_outside_final_report_section() {
    require_hook "G22_token_outside_final_report_section" || return

    local plans_dir="$TMPDIR_BASE/g22-plans"
    mkdir -p "$plans_dir"
    local sid="g22-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    local body; body="$(full_canonical_report_text "$sid")
## Discussion
This is <EXAMPLE_TOKEN> outside the report."

    local transcript="$TMPDIR_BASE/g22-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "$body"
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local code
    code="$(run_hook_exit "$stdin_json" "$(node_path "$plans_dir")")"

    if [ "$code" = "0" ]; then
        pass "G22: token in ## Discussion after FR block → exit 0 (not a false-positive)"
    else
        fail "G22: expected exit 0, got $code (false-positive — fix hook)"
    fi
}

# ---------------------------------------------------------------------------
# G23 (regression): FR in earlier assistant turn, latest assistant has no FR
#                   heading but mentions <WORKFLOW_ENFORCE_WORKFLOW_OFF> → exit 0
# JSONL: user → assistant (full FR) → assistant (follow-up with token, no heading)
# Expected: 0. Unfixed hook exits 2.
# ---------------------------------------------------------------------------
test_G23_fr_in_prior_turn_latest_has_no_fr_exit0() {
    require_hook "G23_fr_in_prior_turn_latest_has_no_fr_exit0" || return

    local plans_dir="$TMPDIR_BASE/g23-plans"
    mkdir -p "$plans_dir"
    local sid="g23-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    local transcript="$TMPDIR_BASE/g23-transcript.jsonl"
    local fr_text; fr_text="$(full_canonical_report_text "$sid")"
    local fr_escaped
    fr_escaped="$(printf '%s' "$fr_text" | node -e "
let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
  process.stdout.write(JSON.stringify(s));
});")";

    printf '{"type":"user","message":{"content":"go"}}\n' > "$transcript"
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' \
        "$fr_escaped" >> "$transcript"
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Follow-up: I see <WORKFLOW_ENFORCE_WORKFLOW_OFF> was used earlier."}]}}\n' \
        >> "$transcript"

    local transcript_node; transcript_node="$(node_path "$transcript")"
    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local code
    code="$(run_hook_exit "$stdin_json" "$(node_path "$plans_dir")")"

    if [ "$code" = "0" ]; then
        pass "G23: FR in prior turn, latest assistant cites token (no FR heading) → exit 0"
    else
        fail "G23: expected exit 0, got $code (false-positive — fix hook)"
    fi
}

# ---------------------------------------------------------------------------
# G23b: no FR heading anywhere → fail-open (exit 0)
# Expected: 0 on both unfixed and fixed hook.
# ---------------------------------------------------------------------------
test_G23b_no_fr_anywhere_exit0() {
    require_hook "G23b_no_fr_anywhere_exit0" || return

    local plans_dir="$TMPDIR_BASE/g23b-plans"
    mkdir -p "$plans_dir"
    local sid="g23b-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    local transcript="$TMPDIR_BASE/g23b-transcript.jsonl"
    write_transcript_with_assistant "$transcript" \
        "Working on the task, no final report yet. Saw <WORKFLOW_ENFORCE_WORKFLOW_OFF> in docs."
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local code
    code="$(run_hook_exit "$stdin_json" "$(node_path "$plans_dir")")"

    if [ "$code" = "0" ]; then
        pass "G23b: no FR heading in transcript → exit 0 (guard not applicable)"
    else
        fail "G23b: expected exit 0 (no FR heading), got $code"
    fi
}

# ---------------------------------------------------------------------------
# G24: token BEFORE FR heading in same assistant turn → exit 0
# The token appears before `## Final Report — <sid>`, so it is outside
# finalReportBody (pre-header region is excluded). Expected: 0 on both
# unfixed and fixed hook.
# ---------------------------------------------------------------------------
test_G24_token_before_fr_heading_exit0() {
    require_hook "G24_token_before_fr_heading_exit0" || return

    local plans_dir="$TMPDIR_BASE/g24-plans"
    mkdir -p "$plans_dir"
    local sid="g24-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    local body; body="<BEFORE_TOKEN> mentioned earlier.
$(full_canonical_report_text "$sid")"

    local transcript="$TMPDIR_BASE/g24-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "$body"
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local code
    code="$(run_hook_exit "$stdin_json" "$(node_path "$plans_dir")")"

    if [ "$code" = "0" ]; then
        pass "G24: token before FR heading in same turn → exit 0 (pre-header token excluded)"
    else
        fail "G24: expected exit 0 (token is before heading boundary), got $code"
    fi
}

# ---------------------------------------------------------------------------
# G25: transcript file missing → exit 0 (fail-open)
# env-file is present but transcript_path points to a nonexistent file.
# Expected: 0 on both unfixed and fixed hook.
# ---------------------------------------------------------------------------
test_G25_transcript_missing_exit0() {
    require_hook "G25_transcript_missing_exit0" || return

    local plans_dir="$TMPDIR_BASE/g25-plans"
    mkdir -p "$plans_dir"
    local sid="g25-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    local nonexistent; nonexistent="$(node_path "$TMPDIR_BASE/g25-nonexistent.jsonl")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$nonexistent")"

    local code
    code="$(run_hook_exit "$stdin_json" "$(node_path "$plans_dir")")"

    if [ "$code" = "0" ]; then
        pass "G25: transcript file missing → exit 0 (fail-open on read error)"
    else
        fail "G25: expected exit 0 (fail-open), got $code"
    fi
}

# ---------------------------------------------------------------------------
# G26: two assistant turns, latest has INCOMPLETE FR, earlier has COMPLETE FR
#      → exit 2 + decision:block
# JSONL: user → assistant (complete FR) → assistant (incomplete FR, no ### Next Tasks)
# Backward scan finds latest entry → FR heading present → body missing ### Next Tasks
# → exit 2 + decision:block.
# Expected: exit 2 on both unfixed and fixed hook (latest turn has incomplete FR).
# ---------------------------------------------------------------------------
test_G26_latest_turn_incomplete_fr_blocks() {
    require_hook "G26_latest_turn_incomplete_fr_blocks" || return

    local plans_dir="$TMPDIR_BASE/g26-plans"
    mkdir -p "$plans_dir"
    local sid="g26-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    local transcript="$TMPDIR_BASE/g26-transcript.jsonl"

    # entry2: complete canonical FR
    local fr_text; fr_text="$(full_canonical_report_text "$sid")"
    local fr_escaped
    fr_escaped="$(printf '%s' "$fr_text" | node -e "
let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
  process.stdout.write(JSON.stringify(s));
});")";

    # entry3: incomplete FR — missing ### Next Tasks
    local incomplete_text
    incomplete_text="$(cat <<EOF
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
EOF
)"
    local incomplete_escaped
    incomplete_escaped="$(printf '%s' "$incomplete_text" | node -e "
let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
  process.stdout.write(JSON.stringify(s));
});")";

    printf '{"type":"user","message":{"content":"start"}}\n' > "$transcript"
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' \
        "$fr_escaped" >> "$transcript"
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' \
        "$incomplete_escaped" >> "$transcript"

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
        pass "G26: latest turn has incomplete FR (missing Next Tasks) → exit 2 + decision:block"
    else
        fail "G26: expected exit 2 + decision:block, got code=$code out=$(printf '%s' "$out" | head -c 200)"
    fi
}

# ---------------------------------------------------------------------------
# G27: FR heading found but body is empty (heading immediately followed by \n##)
#      → headingFound=true, finalReportBody="" → missing-heading check fires → exit 2
# ---------------------------------------------------------------------------
test_G27_heading_found_empty_body_blocks() {
    require_hook "G27_heading_found_empty_body_blocks" || return

    local plans_dir="$TMPDIR_BASE/g27-plans"
    mkdir -p "$plans_dir"
    local sid="g27-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    # FR heading immediately followed by another ## section (no body between).
    local transcript="$TMPDIR_BASE/g27-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "## Final Report — ${sid}
## Post-Report Discussion
Some follow-up text here."
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
        pass "G27: FR heading found but body empty (next ## immediately) → exit 2 + decision:block"
    else
        fail "G27: expected exit 2 + decision:block (empty body), got code=$code out=$(printf '%s' "$out" | head -c 200)"
    fi
}

# ---------------------------------------------------------------------------
# G28: invalid session_id (path-traversal) → exit 0 (sid guard fires first)
# ---------------------------------------------------------------------------
test_G28_invalid_sid_exit0() {
    require_hook "G28_invalid_sid_exit0" || return

    local plans_dir="$TMPDIR_BASE/g28-plans"
    mkdir -p "$plans_dir"

    local transcript="$TMPDIR_BASE/g28-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "no final report here"
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json='{"session_id":"../../../etc/passwd","transcript_path":"'"$transcript_node"'"}'

    local code
    code="$(run_hook_exit "$stdin_json" "$(node_path "$plans_dir")")"

    if [ "$code" = "0" ]; then
        pass "G28: invalid session_id (path-traversal) → exit 0 (sid guard rejects)"
    else
        fail "G28: expected exit 0 for invalid sid, got $code"
    fi
}

# ---------------------------------------------------------------------------
# G29: transcript_path key absent from stdin → exit 0 (fail-open)
# ---------------------------------------------------------------------------
test_G29_transcript_path_absent_exit0() {
    require_hook "G29_transcript_path_absent_exit0" || return

    local plans_dir="$TMPDIR_BASE/g29-plans"
    mkdir -p "$plans_dir"
    local sid="g29-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s"}' "$sid")"

    local code
    code="$(run_hook_exit "$stdin_json" "$(node_path "$plans_dir")")"

    if [ "$code" = "0" ]; then
        pass "G29: transcript_path absent from stdin → exit 0 (fail-open)"
    else
        fail "G29: expected exit 0 for absent transcript_path, got $code"
    fi
}
