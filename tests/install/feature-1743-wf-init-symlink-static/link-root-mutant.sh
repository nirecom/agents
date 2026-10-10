# Sourced by tests/install/feature-1743-wf-init-symlink-static.sh inside a case span.

# --- L4c: mutation probe — a wrong-root Dest must be detected, not silently green ---
_mut_root="$TMP_DIR/dotfileslink-wrong-root.ps1"
sed 's|\$SCRIPT_CHECKOUT_ROOT\\skills\\wf-init|$ClaudeDir\\skills\\wf-init|' "$PS_FILE" > "$_mut_root"
_mut_anchor=0; _mut_wrong=0
has_win_dest_under_agents_root "$_mut_root" && _mut_anchor=1
has_win_dest_under_claude_dir "$_mut_root" && _mut_wrong=1
if [ "$_mut_anchor" = "0" ] && [ "$_mut_wrong" = "1" ]; then
    pass "L4c: anchor detector rejects a \$ClaudeDir-rooted Dest (anchored=$_mut_anchor, wrong=$_mut_wrong)"
else
    fail "L4c: anchor detector is false-green on a \$ClaudeDir-rooted Dest (anchored=$_mut_anchor, wrong=$_mut_wrong)"
fi
