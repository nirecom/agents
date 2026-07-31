# Tests: install/linux/session-sync-init.sh
# Tags: bin, install, git, session-sync, scope:common
# Part of tests/main-session-sync.sh — sourced by that dispatcher, not run alone.

echo "=== session-sync-init.sh tests ==="

# --- Normal: Fresh initialization ---
echo "[init] Fresh initialization"
output=$("$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$FAKE_CLAUDE" --remote-url "$FAKE_REMOTE" 2>&1)
if [ -d "$FAKE_PROJECTS/.git" ]; then
    pass "git repo created in projects dir"
else
    fail "git repo not created in projects dir"
fi

if [ -f "$FAKE_PROJECTS/.gitattributes" ]; then
    pass ".gitattributes created"
else
    fail ".gitattributes not created"
fi

remote_url=$(git -C "$FAKE_PROJECTS" remote get-url origin 2>/dev/null)
# Compare in normalized form: on Windows/MSYS the shell hands git an /tmp/... path
# but git stores and echoes back the native C:/Users/... form. See _norm_path().
if [ "$(_norm_path "$remote_url")" = "$(_norm_path "$FAKE_REMOTE")" ]; then
    pass "remote set correctly"
else
    fail "remote not set correctly (got: $remote_url)"
fi

has_commits=$(git -C "$FAKE_PROJECTS" rev-list --count HEAD 2>/dev/null || echo 0)
if [ "$has_commits" -eq 0 ]; then
    pass "init does not create commits (sync separated)"
else
    fail "init should not create commits (got $has_commits)"
fi

# --- Edge: Idempotent re-run ---
echo "[init] Idempotent re-run"
output=$("$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$FAKE_CLAUDE" --remote-url "$FAKE_REMOTE" 2>&1)
if [ -d "$FAKE_PROJECTS/.git" ]; then
    pass "re-run keeps repo intact"
else
    fail "re-run broke the repo"
fi

# --- Edge: Remote already set, updates URL ---
echo "[init] Remote URL update"
NEW_REMOTE="$TMPDIR_BASE/remote2.git"
git init --bare "$NEW_REMOTE" >/dev/null 2>&1
"$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$FAKE_CLAUDE" --remote-url "$NEW_REMOTE" >/dev/null 2>&1
updated_url=$(git -C "$FAKE_PROJECTS" remote get-url origin 2>/dev/null)
if [ "$(_norm_path "$updated_url")" = "$(_norm_path "$NEW_REMOTE")" ]; then
    pass "remote URL updated on re-run"
else
    fail "remote URL not updated (got: $updated_url)"
fi
# Restore original remote for subsequent tests
"$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$FAKE_CLAUDE" --remote-url "$FAKE_REMOTE" >/dev/null 2>&1

# --- Edge: Old .git in ~/.claude/ gets migrated ---
echo "[init] Migration of old git root"
MIGRATE_HOME="$TMPDIR_BASE/migrate"
MIGRATE_CLAUDE="$MIGRATE_HOME/.claude"
mkdir -p "$MIGRATE_CLAUDE/projects"
git init "$MIGRATE_CLAUDE" >/dev/null 2>&1
touch "$MIGRATE_CLAUDE/.gitignore"
MIGRATE_REMOTE="$TMPDIR_BASE/migrate-remote.git"
git init --bare "$MIGRATE_REMOTE" >/dev/null 2>&1
"$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$MIGRATE_CLAUDE" --remote-url "$MIGRATE_REMOTE" >/dev/null 2>&1
if [ ! -d "$MIGRATE_CLAUDE/.git" ] && [ -d "$MIGRATE_CLAUDE/projects/.git" ]; then
    pass "old .git migrated from claude dir to projects dir"
else
    fail "migration did not work"
fi

# --- Normal: --no-remote flag ---
echo "[init] --no-remote flag"
NOREMOTE_CLAUDE="$TMPDIR_BASE/noremote/.claude"
mkdir -p "$NOREMOTE_CLAUDE"
"$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$NOREMOTE_CLAUDE" --no-remote >/dev/null 2>&1
if [ -d "$NOREMOTE_CLAUDE/projects/.git" ]; then
    noremote_remotes=$(git -C "$NOREMOTE_CLAUDE/projects" remote 2>/dev/null)
    if [ -z "$noremote_remotes" ]; then
        pass "--no-remote: repo created without remote"
    else
        fail "--no-remote: remote was set ($noremote_remotes)"
    fi
else
    fail "--no-remote: git repo not created"
fi

# --- Normal: .gitattributes content ---
echo "[init] .gitattributes content"
if grep -q "eol=lf" "$FAKE_PROJECTS/.gitattributes" 2>/dev/null; then
    pass ".gitattributes contains eol=lf"
else
    fail ".gitattributes missing eol=lf"
fi

# --- Normal: core.hooksPath disabled ---
echo "[init] core.hooksPath disabled"
hooks_path=$(git -C "$FAKE_PROJECTS" config core.hooksPath 2>/dev/null || true)
# The value is the platform's null device: /dev/null on POSIX, NUL on Windows.
# Git Bash/MSYS additionally rewrites a literal "/dev/null" argument to "nul"
# during path conversion, so all three spellings are the same intent.
case "$hooks_path" in
    /dev/null|nul|NUL)
        pass "core.hooksPath disabled (got: $hooks_path)" ;;
    *)
        fail "core.hooksPath not disabled (got: $hooks_path)" ;;
esac

# --- Error: No git installed (skip if we can't fake it) ---
echo "[init] No git warning"
output=$(PATH="/usr/bin/nonexistent" "$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$TMPDIR_BASE/nogit" --remote-url "$FAKE_REMOTE" 2>&1) || true
if echo "$output" | grep -qi "git.*required\|git.*not found"; then
    pass "warns when git is not available"
else
    fail "no warning when git missing (output: $output)"
fi
