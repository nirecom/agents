# Sourced by tests/install/feature-1743-wf-init-symlink-static.sh inside a case span.

# Line number (1-based) of the wf-init _link_one call; empty when absent.
sh_wf_init_line() {
    local file="$1"
    grep -nE '_link_one[[:space:]]+.*skills/workflow-init.*skills/wf-init' "$file" \
        | head -n1 | cut -d: -f1
}

# Line number of the `fi` that closes the `if [ -d ~/.claude/.git ]` guard; empty on mismatch.
sh_guard_close_line() {
    local file="$1"
    awk '
        started == 0 {
            if ($0 ~ /^[[:space:]]*if[[:space:]].*\.claude\/\.git/) { started = 1; depth = 1 }
            next
        }
        {
            if ($0 ~ /^[[:space:]]*if[[:space:]]/) depth++
            if ($0 ~ /^[[:space:]]*fi([[:space:]]|$)/) {
                depth--
                if (depth == 0) { print NR; exit }
            }
        }
    ' "$file"
}

# --- L2: POSIX installer entry present (normal case) ---
if has_sh_entry "$SH_FILE"; then
    pass "L2: dotfileslink.sh has a _link_one call skills/workflow-init -> skills/wf-init"
else
    fail "L2: dotfileslink.sh is missing the _link_one skills/workflow-init -> skills/wf-init call"
fi

# --- L3: placement — the wf-init link is OUTSIDE the ~/.claude/.git guard block ---
_wf_line="$(sh_wf_init_line "$SH_FILE")"
_guard_fi_line="$(sh_guard_close_line "$SH_FILE")"
if [ -z "$_wf_line" ]; then
    fail "L3: cannot locate the wf-init _link_one call in dotfileslink.sh"
elif [ -z "$_guard_fi_line" ]; then
    fail "L3: cannot locate the closing fi of the 'if [ -d ~/.claude/.git ]' guard"
elif [ "$_wf_line" -gt "$_guard_fi_line" ]; then
    pass "L3: wf-init _link_one (line $_wf_line) is after the guard's closing fi (line $_guard_fi_line)"
else
    fail "L3: wf-init _link_one (line $_wf_line) is inside the ~/.claude/.git guard (fi at line $_guard_fi_line)"
fi
