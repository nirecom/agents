# Tests: bin/session-sync.sh
# Tags: bin, git, session-sync, toggle, scope:issue-specific
# Part of tests/main-session-sync.sh — sourced by that dispatcher, not run alone.
#
# Contract under test: the SESSION_SYNC toggle gates ONLY the six *automatic*
# call sites (profile-snippet.sh/.ps1 startup fetch, profile-snippet.sh/.ps1
# codes() auto-push, install.sh/.ps1 auto-init). The manual CLI —
# `bin/session-sync.sh push|pull|status|reset` — stays ungated by design: a user
# who types the command has already expressed intent.
#
# These cases must PASS both before and after the gate lands. If one of them
# ever goes red, the gate has leaked into the manual path.

echo ""
echo "=== SESSION_SYNC independence of the manual CLI ==="

SSI_REMOTE="$TMPDIR_BASE/ssi-remote.git"
SSI_CLAUDE="$TMPDIR_BASE/ssi/.claude"
SSI_PROJECTS="$SSI_CLAUDE/projects"
git init --bare "$SSI_REMOTE" >/dev/null 2>&1
mkdir -p "$SSI_CLAUDE"
"$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$SSI_CLAUDE" --remote-url "$SSI_REMOTE" >/dev/null 2>&1
_git_prepare_repo "$SSI_PROJECTS"
git -C "$SSI_PROJECTS" add -A >/dev/null 2>&1
git -C "$SSI_PROJECTS" commit -m "initial" >/dev/null 2>&1
git -C "$SSI_PROJECTS" push -u origin main >/dev/null 2>&1

# --- Normal: explicit off does not disable a manual push ---
echo "[session-sync-toggle] SESSION_SYNC=off still runs a manual push"
echo '{"test":"ssi-off"}' > "$SSI_PROJECTS/ssi-off.jsonl"
output=$(SESSION_SYNC=off "$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$SSI_CLAUDE" 2>&1) || true
if echo "$output" | grep -qi "pushed"; then
    pass "SESSION_SYNC=off: manual push still pushes"
else
    fail "SESSION_SYNC=off suppressed a manual push (output: $output)"
fi

# --- Normal: explicit off does not disable a manual pull ---
echo "[session-sync-toggle] SESSION_SYNC=off still runs a manual pull"
output=$(SESSION_SYNC=off "$DOTFILES_DIR/bin/session-sync.sh" pull --claude-dir "$SSI_CLAUDE" 2>&1) || true
if echo "$output" | grep -qi "pulled\|up to date\|already"; then
    pass "SESSION_SYNC=off: manual pull still pulls"
else
    fail "SESSION_SYNC=off suppressed a manual pull (output: $output)"
fi

# --- Normal: explicit off does not disable a manual status ---
echo "[session-sync-toggle] SESSION_SYNC=off still runs a manual status"
output=$(SESSION_SYNC=off "$DOTFILES_DIR/bin/session-sync.sh" status --claude-dir "$SSI_CLAUDE" 2>&1) || true
if [ -n "$output" ]; then
    pass "SESSION_SYNC=off: manual status still reports"
else
    fail "SESSION_SYNC=off suppressed manual status output"
fi

# --- Normal: explicit off does not disable a manual reset ---
echo "[session-sync-toggle] SESSION_SYNC=off still runs a manual reset"
output=$(SESSION_SYNC=off "$DOTFILES_DIR/bin/session-sync.sh" reset --claude-dir "$SSI_CLAUDE" 2>&1) || true
if echo "$output" | grep -qi "reset to remote"; then
    pass "SESSION_SYNC=off: manual reset still resets"
else
    fail "SESSION_SYNC=off suppressed a manual reset (output: $output)"
fi

# --- Boundary: unset (the shipped default is off) behaves identically ---
echo "[session-sync-toggle] Unset SESSION_SYNC still runs a manual push"
echo '{"test":"ssi-unset"}' > "$SSI_PROJECTS/ssi-unset.jsonl"
output=$(env -u SESSION_SYNC "$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$SSI_CLAUDE" 2>&1) || true
if echo "$output" | grep -qi "pushed"; then
    pass "SESSION_SYNC unset: manual push still pushes"
else
    fail "SESSION_SYNC unset suppressed a manual push (output: $output)"
fi

# --- Boundary: an unrecognized value must not change the manual path either ---
echo "[session-sync-toggle] Unrecognized SESSION_SYNC value still runs a manual push"
echo '{"test":"ssi-garbage"}' > "$SSI_PROJECTS/ssi-garbage.jsonl"
output=$(SESSION_SYNC=maybe "$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$SSI_CLAUDE" 2>&1) || true
if echo "$output" | grep -qi "pushed"; then
    pass "SESSION_SYNC=maybe: manual push still pushes"
else
    fail "SESSION_SYNC=maybe suppressed a manual push (output: $output)"
fi

# --- Normal: on behaves the same as every other value on the manual path ---
echo "[session-sync-toggle] SESSION_SYNC=on still runs a manual push"
echo '{"test":"ssi-on"}' > "$SSI_PROJECTS/ssi-on.jsonl"
output=$(SESSION_SYNC=on "$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$SSI_CLAUDE" 2>&1) || true
if echo "$output" | grep -qi "pushed"; then
    pass "SESSION_SYNC=on: manual push still pushes"
else
    fail "SESSION_SYNC=on suppressed a manual push (output: $output)"
fi

# --- Contract: the manual CLI must not consult the toggle at all ---
echo "[session-sync-toggle] bin/session-sync.sh does not reference SESSION_SYNC"
if grep -q "SESSION_SYNC" "$DOTFILES_DIR/bin/session-sync.sh" 2>/dev/null; then
    fail "bin/session-sync.sh references SESSION_SYNC — the manual path must stay ungated"
else
    pass "bin/session-sync.sh contains no SESSION_SYNC reference (manual path ungated)"
fi
