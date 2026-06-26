# tests/feature-534-stop-final-report-guard/g16-i1.sh
# Tests G16, G17, G18, G19, G20, I1.
# Sourced by feature-534-stop-final-report-guard.sh — no shebang, no runner.

# ---------------------------------------------------------------------------
# G16 (new): env-file + `## Final Report — <sid>` only (no `###` headings) → exit 2
# ---------------------------------------------------------------------------
test_G16_only_header_no_subheadings() {
    require_hook "G16_only_header_no_subheadings" || return

    local plans_dir="$TMPDIR_BASE/g16-plans"
    mkdir -p "$plans_dir"
    local sid="g16-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    local transcript="$TMPDIR_BASE/g16-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "## Final Report — ${sid}
(body without any ### headings)"
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
        pass "G16: header only, no ### headings → exit 2 + decision:block"
    else
        fail "G16: expected exit 2 + decision:block, got code=$code out=$(printf '%s' "$out" | head -c 200)"
    fi
}

# ---------------------------------------------------------------------------
# G17 (new): env-file + header + 11 of 12 `###` headings (missing `### Bugs Found`)
#            → exit 2 + decision:block
# ---------------------------------------------------------------------------
test_G17_nine_of_ten_headings() {
    require_hook "G17_nine_of_ten_headings" || return

    local plans_dir="$TMPDIR_BASE/g17-plans"
    mkdir -p "$plans_dir"
    local sid="g17-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    local transcript="$TMPDIR_BASE/g17-transcript.jsonl"
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
### Related Tasks
- (none)
### Next Tasks
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
        pass "G17: header + 11/12 ### (missing Bugs Found) → exit 2 + decision:block"
    else
        fail "G17: expected exit 2 + decision:block, got code=$code out=$(printf '%s' "$out" | head -c 200)"
    fi
}

# ---------------------------------------------------------------------------
# G18 (new): env-file + all 13 headings in scrambled order → exit 0
# (order-agnostic — only presence matters)
# ---------------------------------------------------------------------------
test_G18_all_ten_reordered() {
    require_hook "G18_all_ten_reordered" || return

    local plans_dir="$TMPDIR_BASE/g18-plans"
    mkdir -p "$plans_dir"
    local sid="g18-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    local transcript="$TMPDIR_BASE/g18-transcript.jsonl"
    # `## Final Report` first, then all 13 headings in scrambled order.
    local report_text
    report_text="$(cat <<EOF
## Final Report — ${sid}
### Next Tasks
- (none)
### Closed Issues
- (none)
### Bugs Found
- (none)
### Merged PR
- PR #(none): (none)
### Worktree
- Branch: (none)
### Related Tasks
- (none)
### Backup
- Manifest: (none)
### Post-Merge Actions Required
- Claude Code restart: not_required
### Closed Issue Outcomes
- (none)
### Supervisor Findings
(no findings)
### Supervisor Alert
(not run)
### Supervisor Audit
(not run)
EOF
)"
    write_transcript_with_assistant "$transcript" "$report_text"
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local code
    code="$(run_hook_exit "$stdin_json" "$(node_path "$plans_dir")")"

    if [ "$code" = "0" ]; then
        pass "G18: all 13 headings in scrambled order → exit 0 (order-agnostic)"
    else
        fail "G18: expected exit 0 (all headings present), got $code"
    fi
}

# ---------------------------------------------------------------------------
# G19 (new): env-file + all 13 headings + residual `<PR_NUMBER>` token in
#            post-header region → exit 2 + decision:block
# Note: uses ‹ (U+2039) for supervisor-findings content so it doesn't trigger
# the token check; the PR_NUMBER token in Merged PR section does.
# ---------------------------------------------------------------------------
test_G19_residual_tokens() {
    require_hook "G19_residual_tokens" || return

    local plans_dir="$TMPDIR_BASE/g19-plans"
    mkdir -p "$plans_dir"
    local sid="g19-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    local transcript="$TMPDIR_BASE/g19-transcript.jsonl"
    # Replace `(none)` for PR number with literal `<PR_NUMBER>` token
    local report_text
    report_text="$(cat <<EOF
## Final Report — ${sid}
### Closed Issues
- (none)
### Merged PR
- PR #<PR_NUMBER>: (none)
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
        pass "G19: all 13 headings + residual <PR_NUMBER> token → exit 2 + decision:block"
    else
        fail "G19: expected exit 2 + decision:block (residual token), got code=$code out=$(printf '%s' "$out" | head -c 200)"
    fi
}

# ---------------------------------------------------------------------------
# G20 (new): env-file present + `## Final Report — <sid>` absent from
#            transcript → exit 0 (guard not yet applicable; report not started)
# ---------------------------------------------------------------------------
test_G20_header_absent_no_block() {
    require_hook "G20_header_absent_no_block" || return

    local plans_dir="$TMPDIR_BASE/g20-plans"
    mkdir -p "$plans_dir"
    local sid="g20-sid"
    local envfile="$plans_dir/${sid}-final-report-env.json"
    write_default_env_file "$envfile"

    local transcript="$TMPDIR_BASE/g20-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "I am still working on the task. No final report yet."
    local transcript_node; transcript_node="$(node_path "$transcript")"

    local stdin_json
    stdin_json="$(printf '{"session_id":"%s","transcript_path":"%s"}' \
        "$sid" "$transcript_node")"

    local code
    code="$(run_hook_exit "$stdin_json" "$(node_path "$plans_dir")")"

    if [ "$code" = "0" ]; then
        pass "G20: env-file + no Final Report header in transcript → exit 0 (guard not applicable)"
    else
        fail "G20: expected exit 0 (header absent), got $code"
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
        skip "I1_settings_json_stop_hook (hook not implemented yet)"
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
