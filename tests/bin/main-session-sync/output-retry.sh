# Tests: bin/session-sync.sh
# Tags: bin, git, session-sync, output, retry, scope:common
# Part of tests/bin/main-session-sync.sh — sourced by that dispatcher, not run alone.

echo ""
echo "=== session-sync.sh output and notification tests ==="

# --- commit -q suppresses create/delete mode ---
echo "[output] Push does not show create/delete mode"
echo '{"test":"output"}' > "$FAKE_PROJECTS/output-test.jsonl"
output=$("$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$FAKE_CLAUDE" 2>&1)
if echo "$output" | grep -qi "create mode\|delete mode"; then
    fail "push output contains create/delete mode messages"
else
    pass "push output suppresses create/delete mode"
fi

# --- toast function exists ---
echo "[output] Toast function exists in script"
if grep -q '_toast()' "$DOTFILES_DIR/bin/session-sync.sh"; then
    pass "toast function defined in script"
else
    fail "toast function not found in script"
fi

# --- push flow does not emit a pushing toast ---
# Only a single completion toast should fire per push — the legacy "pushing..." start toast was removed.
echo "[output] Push flow does not call _toast \"pushing...\""
if grep -q '_toast "pushing' "$DOTFILES_DIR/bin/session-sync.sh"; then
    fail "legacy pushing toast should have been removed"
else
    pass "no pushing toast call in script"
fi

# --- --toast flag controls notification ---
echo "[output] --toast flag parsed and controls toast"
if grep -q '_TOAST=1' "$DOTFILES_DIR/bin/session-sync.sh"; then
    pass "--toast flag sets _TOAST"
else
    fail "--toast flag not found in script"
fi

if grep -q '\[ "\$_TOAST" = "1" \] && _toast' "$DOTFILES_DIR/bin/session-sync.sh"; then
    pass "toast gated on _TOAST flag"
else
    fail "toast should be gated on _TOAST flag"
fi

# --- osascript branch exists ---
echo "[output] osascript macOS notification branch exists"
if grep -q 'osascript' "$DOTFILES_DIR/bin/session-sync.sh"; then
    pass "osascript branch found in script"
else
    fail "osascript branch not found in script"
fi

# --- osascript comes before notify-send ---
echo "[output] osascript branch appears before notify-send"
osascript_line=$(grep -n 'osascript' "$DOTFILES_DIR/bin/session-sync.sh" | head -1 | cut -d: -f1)
notify_send_line=$(grep -n 'notify-send' "$DOTFILES_DIR/bin/session-sync.sh" | head -1 | cut -d: -f1)
if [ -n "$osascript_line" ] && [ -n "$notify_send_line" ] && [ "$osascript_line" -lt "$notify_send_line" ]; then
    pass "osascript (line $osascript_line) appears before notify-send (line $notify_send_line)"
else
    fail "osascript should appear before notify-send (osascript=$osascript_line, notify-send=$notify_send_line)"
fi

# --- quiet push suppresses stdout ---
echo "[output] Quiet push suppresses normal stdout"
echo '{"test":"quiet"}' > "$FAKE_PROJECTS/quiet-test.jsonl"
output=$("$DOTFILES_DIR/bin/session-sync.sh" push --quiet --claude-dir "$FAKE_CLAUDE" 2>&1)
if echo "$output" | grep -qi "Pushed session data"; then
    fail "quiet push shows stdout message"
else
    pass "quiet push suppresses stdout message"
fi

echo ""
echo "=== push retry loop tests ==="

# --- Static (#2658): the entry delegates integration (and its retry) to the engine ---
echo "[retry] Push integration is delegated to session-sync-engine"
if grep -q 'session-sync-engine' "$DOTFILES_DIR/bin/session-sync.sh" \
    && ! grep -Eq '^[^#]*git[^#]*(rebase|reset --hard)' "$DOTFILES_DIR/bin/session-sync.sh"; then
    pass "session-sync.sh delegates to session-sync-engine and carries no rebase / reset --hard"
else
    fail "session-sync.sh must delegate to bin/session-sync-engine and keep no rebase / reset --hard of its own"
fi

# --- Normal: Push recovers from pre-diverged state with unstaged changes ---
echo "[retry] Push recovers from pre-diverged state with unstaged changes"
RETRY_REMOTE="$TMPDIR_BASE/retry-remote.git"
RETRY_CLAUDE="$TMPDIR_BASE/retry-claude"
RETRY_PROJECTS="$RETRY_CLAUDE/projects"
git init --bare "$RETRY_REMOTE" >/dev/null 2>&1
"$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$RETRY_CLAUDE" --no-remote >/dev/null 2>&1
# Local-path remotes are no longer accepted by the installer allowlist (#1773).
git -C "$RETRY_PROJECTS" remote add origin "$RETRY_REMOTE" >/dev/null 2>&1
git -C "$RETRY_PROJECTS" add -A >/dev/null 2>&1
git -C "$RETRY_PROJECTS" commit -m "initial" >/dev/null 2>&1
git -C "$RETRY_PROJECTS" push -u origin main >/dev/null 2>&1
# Other machine pushes to remote (creates diverged state)
RETRY_OTHER="$TMPDIR_BASE/retry-other"
git clone "$RETRY_REMOTE" "$RETRY_OTHER" >/dev/null 2>&1
_git_prepare_repo "$RETRY_OTHER"
echo '{"other":"machine"}' > "$RETRY_OTHER/other-session.jsonl"
git -C "$RETRY_OTHER" add . >/dev/null 2>&1
git -C "$RETRY_OTHER" commit -m "sync: other 2026-01-01 00:00" >/dev/null 2>&1
git -C "$RETRY_OTHER" push >/dev/null 2>&1
# Local also commits (now diverged from remote)
echo '{"local":"committed"}' > "$RETRY_PROJECTS/local-committed.jsonl"
git -C "$RETRY_PROJECTS" add . >/dev/null 2>&1
git -C "$RETRY_PROJECTS" commit -m "sync: local 2026-01-01 00:01" >/dev/null 2>&1
# Add untracked file to working tree (simulates Claude writing new session data)
echo '{"local":"unstaged"}' > "$RETRY_PROJECTS/local-unstaged.jsonl"
# Push should recover via retry loop
output=$("$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$RETRY_CLAUDE" 2>&1)
if echo "$output" | grep -qi "pushed"; then
    pass "push recovers from pre-diverged state with unstaged changes"
else
    fail "push did not recover from pre-diverged state (output: $output)"
fi
# All files should be on remote
RETRY_CHECK="$TMPDIR_BASE/retry-check"
git clone "$RETRY_REMOTE" "$RETRY_CHECK" >/dev/null 2>&1
if [ -f "$RETRY_CHECK/other-session.jsonl" ] && \
   [ -f "$RETRY_CHECK/local-committed.jsonl" ] && \
   [ -f "$RETRY_CHECK/local-unstaged.jsonl" ]; then
    pass "all files present in remote after recovery"
else
    fail "missing files after recovery (other=$(ls "$RETRY_CHECK/other-session.jsonl" 2>/dev/null || echo MISSING), local=$(ls "$RETRY_CHECK/local-committed.jsonl" 2>/dev/null || echo MISSING), unstaged=$(ls "$RETRY_CHECK/local-unstaged.jsonl" 2>/dev/null || echo MISSING))"
fi

echo ""
echo "=== quiet push stdout/stderr separation tests ==="

# --- quiet push success: no "Pushed session data" on stdout ---
echo "[quiet-push] Quiet push success does not print 'Pushed session data' on stdout"
echo '{"test":"quiet-stdout-success"}' > "$FAKE_PROJECTS/quiet-stdout-success.jsonl"
stdout=$("$DOTFILES_DIR/bin/session-sync.sh" push --quiet --claude-dir "$FAKE_CLAUDE" 2>"$TMPDIR_BASE/stderr_tmp")
quiet_exit=$?
stderr=$(cat "$TMPDIR_BASE/stderr_tmp")
if echo "$stdout" | grep -qi "Pushed session data"; then
    fail "quiet push success: 'Pushed session data' appeared on stdout"
else
    pass "quiet push success: 'Pushed session data' not on stdout"
fi
if [ "$quiet_exit" -eq 0 ]; then
    pass "quiet push success: exit code is 0"
else
    fail "quiet push success: exit code is $quiet_exit (expected 0)"
fi

# --- quiet push failure: completely silent (no stdout, no stderr) ---
echo "[quiet-push] Quiet push failure is completely silent (stdout and stderr both empty)"
git -C "$FAKE_PROJECTS" remote set-url origin /nonexistent/path
echo '{"test":"quiet-stdout-failure"}' > "$FAKE_PROJECTS/quiet-stdout-failure.jsonl"
quiet_fail_exit=0
stdout=$("$DOTFILES_DIR/bin/session-sync.sh" push --quiet --claude-dir "$FAKE_CLAUDE" 2>"$TMPDIR_BASE/stderr_tmp") || quiet_fail_exit=$?
stderr=$(cat "$TMPDIR_BASE/stderr_tmp")
# --- #2658: a non-quiet failure exits 1 and explains itself on stderr ---
loud_fail_exit=0
"$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$FAKE_CLAUDE" >/dev/null 2>"$TMPDIR_BASE/stderr_loud" || loud_fail_exit=$?
git -C "$FAKE_PROJECTS" remote set-url origin "$FAKE_REMOTE"
if [ -z "$stdout" ]; then
    pass "quiet push failure: stdout is empty"
else
    fail "quiet push failure: stdout is not empty (got: $stdout)"
fi
# #2658: the host name comes from the engine (os.hostname), so no shell
# `hostname -s` diagnostic can leak; silence is asserted on every platform.
if [ -z "$stderr" ] && [ "$quiet_fail_exit" -eq 0 ]; then
    pass "quiet push failure: stderr is empty and exit is 0"
else
    fail "quiet push failure: exit=$quiet_fail_exit (want 0), stderr: $stderr"
fi
if [ "$loud_fail_exit" -eq 1 ] && [ -s "$TMPDIR_BASE/stderr_loud" ]; then
    pass "non-quiet push failure: exit 1 with a message on stderr"
else
    fail "non-quiet push failure: exit=$loud_fail_exit (want 1), stderr: $(cat "$TMPDIR_BASE/stderr_loud")"
fi

# --- #2658: the entry validates arguments before calling the engine ---
echo "[args] Unknown action exits 1, unknown option exits 2"
bad_action_exit=0
bad_action_out=$("$DOTFILES_DIR/bin/session-sync.sh" frobnicate --claude-dir "$FAKE_CLAUDE" 2>&1) || bad_action_exit=$?
bad_opt_exit=0
"$DOTFILES_DIR/bin/session-sync.sh" push --no-such-option --claude-dir "$FAKE_CLAUDE" >/dev/null 2>&1 || bad_opt_exit=$?
if [ "$bad_action_exit" -eq 1 ] && echo "$bad_action_out" | grep -qi "usage"; then
    pass "unknown action prints usage and exits 1"
else
    fail "unknown action: exit=$bad_action_exit (want 1), output: $bad_action_out"
fi
if [ "$bad_opt_exit" -eq 2 ]; then
    pass "unknown option exits 2"
else
    fail "unknown option: exit=$bad_opt_exit (want 2)"
fi
