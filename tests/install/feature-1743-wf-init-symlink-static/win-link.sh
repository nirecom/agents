# Sourced by tests/install/feature-1743-wf-init-symlink-static.sh inside a case span.

# Windows: the wf-init entry must declare IsDir = $true (directory symlink, not a file).
has_win_isdir_true() {
    local file="$1"
    [ -f "$file" ] || return 1
    grep -Eq 'Source[[:space:]]*=[[:space:]]*"skills[\\/]workflow-init"[^#]*IsDir[[:space:]]*=[[:space:]]*\$true' "$file"
}

# --- L1: Windows installer entry present (normal case) ---
if has_win_entry "$PS_FILE"; then
    pass "L1: dotfileslink.ps1 has a \$links entry skills\\workflow-init -> skills\\wf-init"
else
    fail "L1: dotfileslink.ps1 is missing the skills\\workflow-init -> skills\\wf-init entry"
fi

# --- L1b: Windows Dest is anchored under $SCRIPT_CHECKOUT_ROOT, not under $ClaudeDir ---
if ! has_win_dest_under_agents_root "$PS_FILE"; then
    fail "L1b: wf-init entry Dest is not anchored to \$SCRIPT_CHECKOUT_ROOT\\skills\\wf-init"
elif has_win_dest_under_claude_dir "$PS_FILE"; then
    fail "L1b: wf-init entry Dest points under \$ClaudeDir (must stay repo-internal)"
else
    pass "L1b: wf-init entry Dest is \$SCRIPT_CHECKOUT_ROOT\\skills\\wf-init (repo-internal, not \$ClaudeDir)"
fi

# --- L1c: IsDir flag — this alias is a directory symlink, not a file symlink ---
if has_win_isdir_true "$PS_FILE"; then
    pass "L1c: wf-init entry declares IsDir = \$true"
else
    fail "L1c: wf-init entry does not declare IsDir = \$true"
fi
