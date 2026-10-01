# Sourced by tests/install/feature-1743-wf-init-symlink-static.sh inside a case span.

# .gitignore: a line that is exactly `skills/wf-init` (not a substring of a longer pattern).
has_gitignore_line() {
    local file="$1"
    [ -f "$file" ] || return 1
    grep -qx 'skills/wf-init' "$file"
}

# --- L5: .gitignore carries the exact line ---
if has_gitignore_line "$GITIGNORE_FILE"; then
    pass "L5: .gitignore contains an exact 'skills/wf-init' line"
else
    fail "L5: .gitignore has no exact 'skills/wf-init' line"
fi

# --- L5b: mutation probe — removing the .gitignore line must be detected (symmetric to L4b) ---
_mut_gi="$TMP_DIR/gitignore-no-wf-init"
grep -vx 'skills/wf-init' "$GITIGNORE_FILE" > "$_mut_gi"
_mut_gi_found=0
has_gitignore_line "$_mut_gi" && _mut_gi_found=1
if [ "$_mut_gi_found" = "0" ]; then
    pass "L5b: .gitignore detector reports absent on the mutated copy (found=$_mut_gi_found)"
else
    fail "L5b: .gitignore detector still reports present after removal — false-green risk"
fi
