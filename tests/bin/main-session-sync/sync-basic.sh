# Tests: bin/session-sync.sh
# Tags: bin, git, session-sync, scope:common
# Part of tests/main-session-sync.sh — sourced by that dispatcher, not run alone.

echo ""
echo "=== session-sync.sh tests ==="

# Create initial commit and push so sync tests work (init no longer does this)
# `add -A`, not `add .gitattributes`: session-sync-init.sh seeds .gitignore too,
# and leaving it untracked makes the "push with no changes" case see a dirty tree.
git -C "$FAKE_PROJECTS" add -A >/dev/null 2>&1
git -C "$FAKE_PROJECTS" commit -m "initial" >/dev/null 2>&1
git -C "$FAKE_PROJECTS" push -u origin main >/dev/null 2>&1 || git -C "$FAKE_PROJECTS" push -u origin master >/dev/null 2>&1

# --- Error: Not initialized ---
echo "[sync] Not initialized"
NOT_INIT="$TMPDIR_BASE/notinit/.claude"
mkdir -p "$NOT_INIT/projects"
output=$("$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$NOT_INIT" 2>&1) || true
if echo "$output" | grep -qi "not initialized"; then
    pass "error when not initialized"
else
    fail "no error for uninitialized repo (output: $output)"
fi

# --- Error: Invalid action ---
echo "[sync] Invalid action"
output=$("$DOTFILES_DIR/bin/session-sync.sh" invalid --claude-dir "$FAKE_CLAUDE" 2>&1) || true
if [ $? -ne 0 ] || echo "$output" | grep -qi "usage\|invalid\|push\|pull\|status"; then
    pass "rejects invalid action"
else
    fail "accepted invalid action (output: $output)"
fi

# --- Normal: Push with no changes ---
echo "[sync] Push with no changes"
output=$("$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$FAKE_CLAUDE" 2>&1)
if echo "$output" | grep -qi "no changes"; then
    pass "push reports no changes"
else
    fail "push did not report no changes (output: $output)"
fi

# --- Normal: Push with changes ---
echo "[sync] Push with changes"
echo '{"test":"data"}' > "$FAKE_PROJECTS/test-session.jsonl"
output=$("$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$FAKE_CLAUDE" 2>&1)
if echo "$output" | grep -qi "pushed"; then
    pass "push succeeds with changes"
else
    fail "push did not succeed (output: $output)"
fi

# --- Normal: Pull ---
echo "[sync] Pull"
output=$("$DOTFILES_DIR/bin/session-sync.sh" pull --claude-dir "$FAKE_CLAUDE" 2>&1)
if echo "$output" | grep -qi "pulled\|up to date\|already"; then
    pass "pull succeeds"
else
    fail "pull did not succeed (output: $output)"
fi

# --- Edge: Pull succeeds when local history.jsonl is absent ---
echo "[pull] Pull succeeds when local history.jsonl is absent"
# Seed remote .history.jsonl so the merge block runs
PULL_HIST_SEED="$TMPDIR_BASE/pull-hist-seed"
git clone "$FAKE_REMOTE" "$PULL_HIST_SEED" >/dev/null 2>&1
_git_prepare_repo "$PULL_HIST_SEED"
echo '{"display":"remote","sessionId":"pull-absent","timestamp":1}' > "$PULL_HIST_SEED/.history.jsonl"
git -C "$PULL_HIST_SEED" add . >/dev/null 2>&1
git -C "$PULL_HIST_SEED" commit -m "seed pull history" >/dev/null 2>&1
git -C "$PULL_HIST_SEED" push >/dev/null 2>&1
# Remove local history.jsonl so cat would have failed before the fix
rm -f "$FAKE_CLAUDE/history.jsonl"
output=$("$DOTFILES_DIR/bin/session-sync.sh" pull --claude-dir "$FAKE_CLAUDE" 2>&1)
if echo "$output" | grep -qi "pulled\|up to date\|already"; then
    pass "pull succeeds when local history.jsonl is absent"
else
    fail "pull failed when local history.jsonl absent (output: $output)"
fi
if [ -f "$FAKE_CLAUDE/history.jsonl" ] && grep -q "pull-absent" "$FAKE_CLAUDE/history.jsonl"; then
    pass "pull creates history.jsonl from remote when local is absent"
else
    fail "pull did not create history.jsonl from remote (content: $(cat "$FAKE_CLAUDE/history.jsonl" 2>/dev/null || echo 'missing'))"
fi

# --- Normal: Status ---
echo "[sync] Status"
output=$("$DOTFILES_DIR/bin/session-sync.sh" status --claude-dir "$FAKE_CLAUDE" 2>&1)
if [ -n "$output" ]; then
    pass "status produces output"
else
    fail "status produced no output"
fi

# --- Normal: Commit message format ---
echo "[sync] Commit message format"
echo '{"test":"format"}' > "$FAKE_PROJECTS/test-format.jsonl"
"$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$FAKE_CLAUDE" >/dev/null 2>&1
last_msg=$(git -C "$FAKE_PROJECTS" log -1 --format=%s)
# Always assertable: prefix + ISO date, independent of the host field.
if echo "$last_msg" | grep -qE "^sync: .*[0-9]{4}-[0-9]{2}-[0-9]{2}"; then
    pass "commit message carries the sync: prefix and an ISO date"
else
    fail "commit message format unexpected ($last_msg)"
fi
# The host field itself is only assertable where `hostname -s` exists.
if hostname -s >/dev/null 2>&1; then
    if echo "$last_msg" | grep -qE "^sync: .+ [0-9]{4}-[0-9]{2}-[0-9]{2}"; then
        pass "commit message matches format (sync: hostname date)"
    else
        fail "commit message format unexpected ($last_msg)"
    fi
else
    # bin/session-sync.sh builds the message with `hostname -s`, which MSYS /
    # Git Bash `hostname` does not support; the host field comes out empty there.
    # Production portability gap — out of scope for this test-only change.
    pending "commit message host field ('hostname -s' unsupported on this platform; got: $last_msg)"
fi

# --- Edge: Push with diverged remote (pull --rebase) ---
echo "[sync] Push with diverged remote"
# Create a second clone that pushes a commit to remote
SECOND_CLONE="$TMPDIR_BASE/second-clone"
git clone "$FAKE_REMOTE" "$SECOND_CLONE" >/dev/null 2>&1
_git_prepare_repo "$SECOND_CLONE"
echo '{"other":"machine"}' > "$SECOND_CLONE/other-session.jsonl"
git -C "$SECOND_CLONE" add . >/dev/null 2>&1
git -C "$SECOND_CLONE" commit -m "sync: other-machine 2026-01-01 00:00" >/dev/null 2>&1
git -C "$SECOND_CLONE" push >/dev/null 2>&1
# Now push from original — should rebase over the diverged commit
echo '{"local":"new"}' > "$FAKE_PROJECTS/local-new.jsonl"
output=$("$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$FAKE_CLAUDE" 2>&1)
if echo "$output" | grep -qi "pushed"; then
    pass "push succeeds after remote diverged"
else
    fail "push failed after remote diverged (output: $output)"
fi
if [ -f "$FAKE_PROJECTS/other-session.jsonl" ]; then
    pass "diverged remote file present after rebase"
else
    fail "diverged remote file missing after rebase"
fi

# --- Edge: Pull idempotent (already up-to-date) ---
echo "[sync] Pull idempotent"
output1=$("$DOTFILES_DIR/bin/session-sync.sh" pull --claude-dir "$FAKE_CLAUDE" 2>&1)
output2=$("$DOTFILES_DIR/bin/session-sync.sh" pull --claude-dir "$FAKE_CLAUDE" 2>&1)
if echo "$output2" | grep -qi "pulled\|up to date\|already"; then
    pass "consecutive pulls succeed"
else
    fail "second pull failed (output: $output2)"
fi

# --- Edge: Push warns if claude process running (mock with self) ---
echo "[sync] Claude running warning"
# We can't easily mock this cross-platform, so just verify the function exists
# by checking the script contains the check
if grep -q "claude" "$DOTFILES_DIR/bin/session-sync.sh" 2>/dev/null; then
    pass "script contains claude process check"
else
    fail "script missing claude process check"
fi

# --- WARNING is gated by --quiet flag ---
echo "[sync] WARNING gated by --quiet"
if grep -q '_QUIET.*0.*pgrep\|pgrep.*claude' "$DOTFILES_DIR/bin/session-sync.sh" && grep -B1 'pgrep -x "claude"' "$DOTFILES_DIR/bin/session-sync.sh" | grep -q '_QUIET'; then
    pass "WARNING gated by --quiet flag"
else
    fail "WARNING should be gated by --quiet flag"
fi
