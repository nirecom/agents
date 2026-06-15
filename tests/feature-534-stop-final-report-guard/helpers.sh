# tests/feature-534-stop-final-report-guard/helpers.sh
# Fixture helpers sourced by feature-534-stop-final-report-guard.sh.
# No shebang — sourced only, not executed directly.
# Variables PASS, FAIL, SKIP, pass(), fail(), skip(), HOOK_JS, TMPDIR_BASE,
# run_with_timeout(), node_path() are all defined in the parent file.

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
    local escaped
    escaped="$(printf '%s' "$text" | node -e "
let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
  process.stdout.write(JSON.stringify(s));
});")"
    printf '{"type":"user","message":{"content":"hello"}}\n' > "$path"
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' \
        "$escaped" >> "$path"
}

# Build the full 10-heading canonical report text (1 ## + 9 ###) for given sid.
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

HOOK_EXIT=0
run_hook_exit() {
    local stdin_json="$1"
    local plans_dir="$2"
    WORKFLOW_PLANS_DIR="$plans_dir" run_with_timeout 120 \
        node "$HOOK_JS" <<< "$stdin_json" >/dev/null 2>&1
    echo "$?"
}
