# Tests: install/linux/session-sync-init.sh
# Tags: bin, install, git, session-sync, scope:common
# Part of tests/main-session-sync.sh — sourced by that dispatcher, not run alone.

echo "=== session-sync-init.sh tests ==="

# --- Normal: Fresh initialization ---
# The shared fixture origin is attached test-side (#1773): $FAKE_REMOTE is a
# scheme-less local path, which the remote-URL allowlist now refuses. Every
# later part reuses this origin, so the `git remote add` below is load-bearing.
echo "[init] Fresh initialization"
output=$("$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$FAKE_CLAUDE" --no-remote 2>&1)
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

# Subject behaviour: --no-remote must leave origin unset. Asserted before the
# fixture origin is attached, and only once the repo is known to exist so an
# aborted init cannot read as an empty remote list.
if [ -d "$FAKE_PROJECTS/.git" ] && [ -z "$(git -C "$FAKE_PROJECTS" remote 2>/dev/null)" ]; then
    pass "--no-remote leaves origin unset"
else
    fail "--no-remote set an origin, or the repo was never created"
fi
git -C "$FAKE_PROJECTS" remote add origin "$FAKE_REMOTE" >/dev/null 2>&1

has_commits=$(git -C "$FAKE_PROJECTS" rev-list --count HEAD 2>/dev/null || echo 0)
if [ "$has_commits" -eq 0 ]; then
    pass "init does not create commits (sync separated)"
else
    fail "init should not create commits (got $has_commits)"
fi

# --- Edge: Idempotent re-run ---
echo "[init] Idempotent re-run"
output=$("$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$FAKE_CLAUDE" --no-remote 2>&1)
if [ -d "$FAKE_PROJECTS/.git" ]; then
    pass "re-run keeps repo intact"
else
    fail "re-run broke the repo"
fi
# --no-remote skips the remote block entirely, so the fixture origin survives.
if [ -n "$(git -C "$FAKE_PROJECTS" remote 2>/dev/null)" ]; then
    pass "re-run with --no-remote leaves the existing origin alone"
else
    fail "re-run with --no-remote dropped the existing origin"
fi

# --- Edge: Remote already set, updates URL ---
# String-comparison-only case: no fetch happens here, so an allowlist-compliant
# literal replaces the bare local path and exercises the real remote set-url
# path through the script (#1773).
echo "[init] Remote URL update"
NEW_REMOTE_URL="https://example.invalid/remote2.git"
"$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$FAKE_CLAUDE" --remote-url "$NEW_REMOTE_URL" >/dev/null 2>&1
updated_url=$(git -C "$FAKE_PROJECTS" remote get-url origin 2>/dev/null)
if [ "$updated_url" = "$NEW_REMOTE_URL" ]; then
    pass "remote URL updated on re-run"
else
    fail "remote URL not updated (got: $updated_url)"
fi
# Restore the fixture origin directly: the script can no longer be handed the
# scheme-less local path that the rest of the suite pushes and pulls against.
git -C "$FAKE_PROJECTS" remote set-url origin "$FAKE_REMOTE" >/dev/null 2>&1
restored_url=$(git -C "$FAKE_PROJECTS" remote get-url origin 2>/dev/null)
if [ "$(_norm_path "$restored_url")" = "$(_norm_path "$FAKE_REMOTE")" ]; then
    pass "shared fixture origin restored for the later parts"
else
    fail "shared fixture origin NOT restored (got: $restored_url)"
fi

# The old "migrates old git root" case is gone: it created the old repo without
# an origin, which the provenance check now refuses by design. Migration is
# covered by the provenance matrix in tests/main-session-sync/security.sh.

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

# --- Error: No git installed ---
# PATH is narrowed to a shim directory that mirrors the coreutils the script
# needs but deliberately omits git. A wholesale PATH="/nonexistent" would also
# strip realpath/dirname/readlink, which the --claude-dir boundary check (#1773)
# runs BEFORE the git probe — the failure would then say nothing about git.
echo "[init] No git warning"
NOGIT_BIN="$TMPDIR_BASE/nogit-bin"
mkdir -p "$NOGIT_BIN"
for _cmd in sh env dirname basename realpath readlink pwd mkdir rm mv cat grep head cut tr printf ls test expr sed; do
    _src=$(command -v "$_cmd" 2>/dev/null || true)
    [ -n "$_src" ] && ln -sf "$_src" "$NOGIT_BIN/$_cmd" 2>/dev/null || true
done
output=$(PATH="$NOGIT_BIN" "$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$TMPDIR_BASE/nogit" --no-remote 2>&1) || true
if echo "$output" | grep -qi "git.*required\|git.*not found"; then
    pass "warns when git is not available"
else
    fail "no warning when git missing (output: $output)"
fi
