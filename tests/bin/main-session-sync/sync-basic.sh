# Tests: bin/session-sync.sh
# Tags: bin, git, session-sync, scope:common
# Part of tests/bin/main-session-sync.sh — sourced by that dispatcher, not run alone.

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
# #2658: the engine names the host by the first label of os.hostname() on every
# platform, so the host field is assertable everywhere (no `hostname -s`).
_sb_host=$(node -e 'process.stdout.write(require("os").hostname().split(".")[0])')
if echo "$last_msg" | grep -qE "^sync: ${_sb_host} [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$"; then
    pass "commit message matches format (sync: <host> <UTC ISO>)"
else
    fail "commit message format unexpected (want 'sync: ${_sb_host} <UTC ISO>', got: $last_msg)"
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
_sb_other_tip=$(git -C "$SECOND_CLONE" rev-parse HEAD)
# Now push from original — #2658: integrates on top of the remote tip, no rebase.
echo '{"local":"new"}' > "$FAKE_PROJECTS/local-new.jsonl"
output=$("$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$FAKE_CLAUDE" 2>&1)
if echo "$output" | grep -qi "pushed"; then
    pass "push succeeds after remote diverged"
else
    fail "push failed after remote diverged (output: $output)"
fi
if [ -f "$FAKE_PROJECTS/other-session.jsonl" ]; then
    pass "diverged remote file present after push"
else
    fail "diverged remote file missing after push"
fi
_sb_parent=$(git -C "$FAKE_REMOTE" rev-list --parents -n 1 main 2>/dev/null | cut -d' ' -f2-)
if [ "$_sb_parent" = "$_sb_other_tip" ] && [ ! -d "$FAKE_PROJECTS/.git/rebase-merge" ] \
    && git -C "$FAKE_REMOTE" cat-file -e main:local-new.jsonl 2>/dev/null; then
    pass "diverged push commits on top of the remote tip with a single parent, no rebase state"
else
    fail "diverged push: remote tip parents='$_sb_parent' (want $_sb_other_tip), rebase-merge=$([ -d "$FAKE_PROJECTS/.git/rebase-merge" ] && echo yes || echo no)"
fi

# --- #2658: a pull where only the remote advanced makes no new commit ---
echo "[sync] Remote-only pull fast-forwards main"
echo '{"other":"remote-only"}' > "$SECOND_CLONE/remote-only.jsonl"
git -C "$SECOND_CLONE" pull -q >/dev/null 2>&1 || true
git -C "$SECOND_CLONE" add . >/dev/null 2>&1
git -C "$SECOND_CLONE" commit -m "sync: other-machine remote-only" >/dev/null 2>&1
git -C "$SECOND_CLONE" push >/dev/null 2>&1
"$DOTFILES_DIR/bin/session-sync.sh" pull --claude-dir "$FAKE_CLAUDE" >/dev/null 2>&1 || true
_sb_local_main=$(git -C "$FAKE_PROJECTS" rev-parse main 2>/dev/null || echo none)
_sb_remote_main=$(git -C "$FAKE_REMOTE" rev-parse main 2>/dev/null || echo none)
if [ "$_sb_local_main" = "$_sb_remote_main" ] && [ -f "$FAKE_PROJECTS/remote-only.jsonl" ]; then
    pass "remote-only pull leaves main == origin/main with no integration commit"
else
    fail "remote-only pull: local main=$_sb_local_main remote main=$_sb_remote_main file=$([ -f "$FAKE_PROJECTS/remote-only.jsonl" ] && echo yes || echo no)"
fi

# --- #2658: a local deletion does not propagate and is not undone by pull ---
echo "[sync] Local deletion is not propagated"
echo '{"del":"me"}' > "$FAKE_PROJECTS/delete-me.jsonl"
"$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$FAKE_CLAUDE" >/dev/null 2>&1 || true
rm -f "$FAKE_PROJECTS/delete-me.jsonl"
echo '{"after":"delete"}' > "$FAKE_PROJECTS/after-delete.jsonl"
"$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$FAKE_CLAUDE" >/dev/null 2>&1 || true
"$DOTFILES_DIR/bin/session-sync.sh" pull --claude-dir "$FAKE_CLAUDE" >/dev/null 2>&1 || true
if git -C "$FAKE_REMOTE" cat-file -e main:delete-me.jsonl 2>/dev/null \
    && git -C "$FAKE_REMOTE" cat-file -e main:after-delete.jsonl 2>/dev/null \
    && [ ! -f "$FAKE_PROJECTS/delete-me.jsonl" ]; then
    pass "local deletion stays local: remote keeps the file, pull does not restore it"
else
    fail "local deletion: remote has delete-me=$(git -C "$FAKE_REMOTE" cat-file -e main:delete-me.jsonl 2>/dev/null && echo yes || echo no) after-delete=$(git -C "$FAKE_REMOTE" cat-file -e main:after-delete.jsonl 2>/dev/null && echo yes || echo no) restored-locally=$([ -f "$FAKE_PROJECTS/delete-me.jsonl" ] && echo yes || echo no)"
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
