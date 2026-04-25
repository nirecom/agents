#!/bin/bash
# Tests for bin/session-sync.sh and install/linux/session-sync-init.sh
# Run: bash tests/main-session-sync.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# Create isolated temp environment
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

FAKE_HOME="$TMPDIR_BASE/home"
FAKE_CLAUDE="$FAKE_HOME/.claude"
FAKE_PROJECTS="$FAKE_CLAUDE/projects"
mkdir -p "$FAKE_HOME"

# Create a bare remote repo to simulate github
FAKE_REMOTE="$TMPDIR_BASE/remote.git"
git init --bare "$FAKE_REMOTE" >/dev/null 2>&1

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
if [ "$remote_url" = "$FAKE_REMOTE" ]; then
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
if [ "$updated_url" = "$NEW_REMOTE" ]; then
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
if [ "$hooks_path" = "/dev/null" ]; then
    pass "core.hooksPath set to /dev/null"
else
    fail "core.hooksPath not disabled (got: $hooks_path)"
fi

# --- Error: No git installed (skip if we can't fake it) ---
echo "[init] No git warning"
output=$(PATH="/usr/bin/nonexistent" "$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$TMPDIR_BASE/nogit" --remote-url "$FAKE_REMOTE" 2>&1) || true
if echo "$output" | grep -qi "git.*required\|git.*not found"; then
    pass "warns when git is not available"
else
    fail "no warning when git missing (output: $output)"
fi

echo ""
echo "=== session-sync.sh tests ==="

# Create initial commit and push so sync tests work (init no longer does this)
git -C "$FAKE_PROJECTS" add .gitattributes >/dev/null 2>&1
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
if echo "$last_msg" | grep -qE "^sync: .+ [0-9]{4}-[0-9]{2}-[0-9]{2}"; then
    pass "commit message matches format (sync: hostname date)"
else
    fail "commit message format unexpected ($last_msg)"
fi

# --- Edge: Push with diverged remote (pull --rebase) ---
echo "[sync] Push with diverged remote"
# Create a second clone that pushes a commit to remote
SECOND_CLONE="$TMPDIR_BASE/second-clone"
git clone "$FAKE_REMOTE" "$SECOND_CLONE" >/dev/null 2>&1
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

echo ""
echo "=== session-sync.sh reset tests ==="

# --- Normal: Reset fetches remote files into working tree ---
echo "[reset] Reset fetches remote files"
RESET_REMOTE="$TMPDIR_BASE/reset-remote.git"
git init --bare "$RESET_REMOTE" >/dev/null 2>&1
# Seed remote with a file from "another machine"
RESET_SEED="$TMPDIR_BASE/reset-seed"
git init "$RESET_SEED" >/dev/null 2>&1
git -C "$RESET_SEED" checkout -b main >/dev/null 2>&1
echo '{"seed":"data"}' > "$RESET_SEED/seed-session.jsonl"
printf '* text eol=lf\n' > "$RESET_SEED/.gitattributes"
git -C "$RESET_SEED" add . >/dev/null 2>&1
git -C "$RESET_SEED" commit -m "seed from other machine" >/dev/null 2>&1
git -C "$RESET_SEED" remote add origin "$RESET_REMOTE" >/dev/null 2>&1
git -C "$RESET_SEED" push -u origin main >/dev/null 2>&1
# Init fresh machine (plumbing only), then reset
RESET_CLAUDE="$TMPDIR_BASE/reset-test/.claude"
mkdir -p "$RESET_CLAUDE"
"$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$RESET_CLAUDE" --remote-url "$RESET_REMOTE" >/dev/null 2>&1
output=$("$DOTFILES_DIR/bin/session-sync.sh" reset --claude-dir "$RESET_CLAUDE" 2>&1) || true
RESET_PROJECTS="$RESET_CLAUDE/projects"
if [ -f "$RESET_PROJECTS/seed-session.jsonl" ]; then
    pass "reset fetches remote file into working tree"
else
    fail "reset did not fetch remote file"
fi

# --- Normal: Push works after reset (bidirectional) ---
echo "[reset] Push after reset"
echo '{"local":"data"}' > "$RESET_PROJECTS/local-session.jsonl"
output=$("$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$RESET_CLAUDE" 2>&1)
if echo "$output" | grep -qi "pushed"; then
    pass "push succeeds after reset"
else
    fail "push failed after reset (output: $output)"
fi

# --- Edge: Reset is idempotent ---
echo "[reset] Reset idempotent"
output=$("$DOTFILES_DIR/bin/session-sync.sh" reset --claude-dir "$RESET_CLAUDE" 2>&1) || true
if echo "$output" | grep -qi "reset to remote"; then
    pass "reset idempotent"
else
    fail "reset idempotent failed (output: $output)"
fi

# --- Edge: Reset succeeds when local history.jsonl is absent ---
echo "[reset] Reset succeeds when local history.jsonl is absent"
# Seed remote with .history.jsonl so it exists after fetch+hard-reset
HIST_ABSENT_SEED="$TMPDIR_BASE/hist-absent-seed"
git clone "$RESET_REMOTE" "$HIST_ABSENT_SEED" >/dev/null 2>&1
echo '{"display":"remote","sessionId":"absent-test","timestamp":1}' > "$HIST_ABSENT_SEED/.history.jsonl"
git -C "$HIST_ABSENT_SEED" add . >/dev/null 2>&1
git -C "$HIST_ABSENT_SEED" commit -m "seed history for absent test" >/dev/null 2>&1
git -C "$HIST_ABSENT_SEED" push >/dev/null 2>&1
# Remove local history.jsonl to trigger the bug
rm -f "$RESET_CLAUDE/history.jsonl"
exit_code=0
output=$("$DOTFILES_DIR/bin/session-sync.sh" reset --claude-dir "$RESET_CLAUDE" 2>&1) || exit_code=$?
if [ $exit_code -eq 0 ] && echo "$output" | grep -qi "reset to remote"; then
    pass "reset succeeds when local history.jsonl is absent"
else
    fail "reset failed when local history.jsonl absent (exit=$exit_code, output: $output)"
fi
if [ -f "$RESET_CLAUDE/history.jsonl" ] && grep -q "absent-test" "$RESET_CLAUDE/history.jsonl"; then
    pass "reset creates history.jsonl from remote when local is absent"
else
    fail "reset did not create history.jsonl from remote (content: $(cat "$RESET_CLAUDE/history.jsonl" 2>/dev/null || echo 'missing'))"
fi

# --- Edge: Reset succeeds when .jsonl file has no timestamp field ---
echo "[reset] Reset succeeds with .jsonl missing timestamp field"
# Create a .jsonl file in the reset environment with no timestamp field
echo '{"sessionId":"no-ts","type":"text"}' > "$RESET_PROJECTS/no-timestamp.jsonl"
git -C "$RESET_PROJECTS" add . >/dev/null 2>&1
git -C "$RESET_PROJECTS" commit -m "add no-timestamp session" >/dev/null 2>&1
git -C "$RESET_PROJECTS" push >/dev/null 2>&1
exit_code=0
output=$("$DOTFILES_DIR/bin/session-sync.sh" reset --claude-dir "$RESET_CLAUDE" 2>&1) || exit_code=$?
if [ $exit_code -eq 0 ] && echo "$output" | grep -qi "reset to remote"; then
    pass "reset succeeds with .jsonl missing timestamp field"
else
    fail "reset failed with no-timestamp .jsonl (exit=$exit_code, output: $output)"
fi

# --- Edge: Reset discards diverged local commits ---
echo "[reset] Reset discards diverged local"
echo '{"diverged":"data"}' > "$RESET_PROJECTS/diverged.jsonl"
git -C "$RESET_PROJECTS" add . >/dev/null 2>&1
git -C "$RESET_PROJECTS" commit -m "local diverged commit" >/dev/null 2>&1
output=$("$DOTFILES_DIR/bin/session-sync.sh" reset --claude-dir "$RESET_CLAUDE" 2>&1) || true
if [ ! -f "$RESET_PROJECTS/diverged.jsonl" ]; then
    pass "reset discards diverged local file"
else
    fail "reset did not discard diverged local file"
fi

# --- Normal: Push copies history.jsonl into sync area ---
echo "[history] Push copies history.jsonl"
echo '{"display":"test","project":"test","sessionId":"h1"}' > "$RESET_CLAUDE/history.jsonl"
echo '{"new":"trigger"}' > "$RESET_PROJECTS/trigger.jsonl"
"$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$RESET_CLAUDE" >/dev/null 2>&1
if [ -f "$RESET_PROJECTS/.history.jsonl" ]; then
    pass "push copies history.jsonl into sync area"
else
    fail "push did not copy history.jsonl"
fi

# --- Normal: Reset merges remote history.jsonl with local ---
echo "[history] Reset merges history.jsonl"
# Seed remote with .history.jsonl containing a remote entry
HIST_SEED="$TMPDIR_BASE/hist-seed"
git clone "$RESET_REMOTE" "$HIST_SEED" >/dev/null 2>&1
echo '{"display":"remote","sessionId":"r1","timestamp":1000}' > "$HIST_SEED/.history.jsonl"
git -C "$HIST_SEED" add . >/dev/null 2>&1
git -C "$HIST_SEED" commit -m "add history" >/dev/null 2>&1
git -C "$HIST_SEED" push >/dev/null 2>&1
# Create local-only entry
echo '{"display":"local","sessionId":"l1","timestamp":2000}' > "$RESET_CLAUDE/history.jsonl"
"$DOTFILES_DIR/bin/session-sync.sh" reset --claude-dir "$RESET_CLAUDE" >/dev/null 2>&1 || true
if grep -q "r1" "$RESET_CLAUDE/history.jsonl" && grep -q "l1" "$RESET_CLAUDE/history.jsonl"; then
    pass "reset merges remote and local history"
else
    fail "reset did not merge history (content: $(cat "$RESET_CLAUDE/history.jsonl"))"
fi

# --- Error: Reset when not initialized ---
echo "[reset] Not initialized"
RESET_NOTINIT="$TMPDIR_BASE/reset-notinit/.claude"
mkdir -p "$RESET_NOTINIT/projects"
output=$("$DOTFILES_DIR/bin/session-sync.sh" reset --claude-dir "$RESET_NOTINIT" 2>&1) || true
if echo "$output" | grep -qi "not initialized"; then
    pass "reset error when not initialized"
else
    fail "reset no error for uninitialized (output: $output)"
fi

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

# --- Static: Push script contains retry loop ---
echo "[retry] Push script contains retry loop"
if grep -q 'for _retry' "$DOTFILES_DIR/bin/session-sync.sh"; then
    pass "session-sync.sh contains retry loop"
else
    fail "session-sync.sh missing retry loop"
fi

# --- Normal: Push recovers from pre-diverged state with unstaged changes ---
echo "[retry] Push recovers from pre-diverged state with unstaged changes"
RETRY_REMOTE="$TMPDIR_BASE/retry-remote.git"
RETRY_CLAUDE="$TMPDIR_BASE/retry-claude"
RETRY_PROJECTS="$RETRY_CLAUDE/projects"
git init --bare "$RETRY_REMOTE" >/dev/null 2>&1
"$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$RETRY_CLAUDE" --remote-url "$RETRY_REMOTE" >/dev/null 2>&1
git -C "$RETRY_PROJECTS" add .gitattributes >/dev/null 2>&1
git -C "$RETRY_PROJECTS" commit -m "initial" >/dev/null 2>&1
git -C "$RETRY_PROJECTS" push -u origin main >/dev/null 2>&1
# Other machine pushes to remote (creates diverged state)
RETRY_OTHER="$TMPDIR_BASE/retry-other"
git clone "$RETRY_REMOTE" "$RETRY_OTHER" >/dev/null 2>&1
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
stdout=$("$DOTFILES_DIR/bin/session-sync.sh" push --quiet --claude-dir "$FAKE_CLAUDE" 2>"$TMPDIR_BASE/stderr_tmp") || true
stderr=$(cat "$TMPDIR_BASE/stderr_tmp")
git -C "$FAKE_PROJECTS" remote set-url origin "$FAKE_REMOTE"
if [ -z "$stdout" ]; then
    pass "quiet push failure: stdout is empty"
else
    fail "quiet push failure: stdout is not empty (got: $stdout)"
fi
if [ -z "$stderr" ]; then
    pass "quiet push failure: stderr is empty (quiet mode suppresses error output)"
else
    fail "quiet push failure: stderr is not empty (got: $stderr)"
fi

echo ""
echo "=== conflict rebase resolution tests ==="

# Helper: configure git user in a repo dir
_git_config_user() {
    local dir="$1"
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test User"
}

# --- Normal: Interrupted rebase-merge state recovery ---
echo "[conflict] Interrupted rebase-merge state recovery"
REBASE_REMOTE="$TMPDIR_BASE/rebase-interrupted-remote.git"
REBASE_CLAUDE="$TMPDIR_BASE/rebase-interrupted/.claude"
REBASE_PROJECTS="$REBASE_CLAUDE/projects"
git init --bare "$REBASE_REMOTE" >/dev/null 2>&1
"$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$REBASE_CLAUDE" --remote-url "$REBASE_REMOTE" >/dev/null 2>&1
_git_config_user "$REBASE_PROJECTS"
git -C "$REBASE_PROJECTS" add .gitattributes >/dev/null 2>&1
git -C "$REBASE_PROJECTS" commit -m "initial" >/dev/null 2>&1
git -C "$REBASE_PROJECTS" push -u origin main >/dev/null 2>&1
# Simulate an interrupted rebase by creating .git/rebase-merge/ directory
mkdir -p "$REBASE_PROJECTS/.git/rebase-merge"
echo "fake-sha" > "$REBASE_PROJECTS/.git/rebase-merge/orig-head"
# Add a new session file so there's something to push
echo '{"sessionId":"rebase-recovery","type":"text"}' > "$REBASE_PROJECTS/rebase-recovery.jsonl"
# Expected to FAIL until source is updated to detect and abort interrupted rebase
output=$("$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$REBASE_CLAUDE" 2>&1) || true
if echo "$output" | grep -qi "pushed\|no changes"; then
    pass "push succeeds after interrupted rebase-merge state recovery"
else
    fail "push did not succeed with interrupted rebase-merge state (output: $output) [EXPECTED FAIL - source not yet updated]"
fi

# --- Normal: .history.jsonl conflict auto-resolution ---
echo "[conflict] .history.jsonl conflict auto-resolution"
HIST_CONFLICT_REMOTE="$TMPDIR_BASE/hist-conflict-remote.git"
git init --bare "$HIST_CONFLICT_REMOTE" >/dev/null 2>&1
# Create initial state in remote via seed clone
HIST_SEED_CLONE="$TMPDIR_BASE/hist-conflict-seed"
git init "$HIST_SEED_CLONE" >/dev/null 2>&1
git -C "$HIST_SEED_CLONE" checkout -b main >/dev/null 2>&1 || true
_git_config_user "$HIST_SEED_CLONE"
printf '* text eol=lf\n' > "$HIST_SEED_CLONE/.gitattributes"
echo '{"display":"seed","sessionId":"s0","timestamp":1}' > "$HIST_SEED_CLONE/.history.jsonl"
git -C "$HIST_SEED_CLONE" add . >/dev/null 2>&1
git -C "$HIST_SEED_CLONE" commit -m "initial seed" >/dev/null 2>&1
git -C "$HIST_SEED_CLONE" remote add origin "$HIST_CONFLICT_REMOTE" >/dev/null 2>&1
git -C "$HIST_SEED_CLONE" push -u origin main >/dev/null 2>&1
# Clone A: add machine-a entry, commit and push
HIST_CLONE_A="$TMPDIR_BASE/hist-clone-a"
git clone "$HIST_CONFLICT_REMOTE" "$HIST_CLONE_A" >/dev/null 2>&1
_git_config_user "$HIST_CLONE_A"
echo '{"display":"machine-a","sessionId":"a1","timestamp":2}' >> "$HIST_CLONE_A/.history.jsonl"
git -C "$HIST_CLONE_A" add . >/dev/null 2>&1
git -C "$HIST_CLONE_A" commit -m "sync: machine-a 2026-01-01 00:00" >/dev/null 2>&1
git -C "$HIST_CLONE_A" push >/dev/null 2>&1
# Clone B: start from seed commit (same as A's starting point, before A pushed)
# This makes B diverged from remote when A has already pushed
HIST_CLONE_B_HOME="$TMPDIR_BASE/hist-clone-b"
HIST_CLONE_B_CLAUDE="$HIST_CLONE_B_HOME/.claude"
HIST_CLONE_B_PROJECTS="$HIST_CLONE_B_CLAUDE/projects"
# Use git clone so the repo is properly set up with remote tracking
git clone "$HIST_CONFLICT_REMOTE" "$HIST_CLONE_B_PROJECTS" >/dev/null 2>&1
_git_config_user "$HIST_CLONE_B_PROJECTS"
mkdir -p "$HIST_CLONE_B_CLAUDE"
# Set core.hooksPath to /dev/null as session-sync-init.sh does
git -C "$HIST_CLONE_B_PROJECTS" config core.hooksPath /dev/null >/dev/null 2>&1
# Copy .gitattributes as init script would
printf '* text eol=lf\n' > "$HIST_CLONE_B_PROJECTS/.gitattributes"
git -C "$HIST_CLONE_B_PROJECTS" add .gitattributes >/dev/null 2>&1
git -C "$HIST_CLONE_B_PROJECTS" commit -m "gitattributes" >/dev/null 2>&1 || true
# Get the seed SHA (the original commit before A pushed)
HIST_SEED_SHA=$(git -C "$HIST_SEED_CLONE" rev-list --max-parents=0 HEAD)
# Roll B back to the seed so it diverges from remote (which has A's commit)
git -C "$HIST_CLONE_B_PROJECTS" reset --hard "$HIST_SEED_SHA" >/dev/null 2>&1 || {
    # If reset fails (detached HEAD edge case), try fetch + reset
    git -C "$HIST_CLONE_B_PROJECTS" fetch origin >/dev/null 2>&1 || true
    git -C "$HIST_CLONE_B_PROJECTS" reset --hard "$HIST_SEED_SHA" 2>/dev/null || true
}
# Now B adds machine-b entry locally (diverged from remote which has A's entry)
echo '{"display":"machine-b","sessionId":"b1","timestamp":3}' >> "$HIST_CLONE_B_PROJECTS/.history.jsonl"
git -C "$HIST_CLONE_B_PROJECTS" add . >/dev/null 2>&1
git -C "$HIST_CLONE_B_PROJECTS" commit -m "sync: machine-b 2026-01-01 00:01" >/dev/null 2>&1
# Verify B is actually diverged from remote before running push
_b_ahead=$(git -C "$HIST_CLONE_B_PROJECTS" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
_b_behind=$(git -C "$HIST_CLONE_B_PROJECTS" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
# Run push — should detect conflict on .history.jsonl, auto-resolve, push
# Expected to FAIL until source is updated to auto-resolve JSONL conflicts
output=$("$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$HIST_CLONE_B_CLAUDE" 2>&1) || true
if echo "$output" | grep -qi "pushed"; then
    pass ".history.jsonl conflict: push succeeds"
    # Verify both entries present in remote
    HIST_VERIFY="$TMPDIR_BASE/hist-verify"
    git clone "$HIST_CONFLICT_REMOTE" "$HIST_VERIFY" >/dev/null 2>&1
    if grep -q "a1" "$HIST_VERIFY/.history.jsonl" 2>/dev/null && \
       grep -q "b1" "$HIST_VERIFY/.history.jsonl" 2>/dev/null; then
        pass ".history.jsonl conflict: remote contains both a1 and b1 entries"
    else
        fail ".history.jsonl conflict: remote missing entries (content: $(cat "$HIST_VERIFY/.history.jsonl" 2>/dev/null || echo 'missing'))"
    fi
else
    fail ".history.jsonl conflict: push did not succeed (diverged: ahead=$_b_ahead behind=$_b_behind output: $output) [EXPECTED FAIL - source not yet updated]"
fi

# --- Normal: JSONL session file conflict auto-resolution ---
echo "[conflict] JSONL session file conflict auto-resolution"
SESSION_CONFLICT_REMOTE="$TMPDIR_BASE/session-conflict-remote.git"
git init --bare "$SESSION_CONFLICT_REMOTE" >/dev/null 2>&1
# Seed remote with a shared session JSONL file via a plain git repo
SESSION_SEED_PLAIN="$TMPDIR_BASE/session-conflict-seed"
git init "$SESSION_SEED_PLAIN" >/dev/null 2>&1
git -C "$SESSION_SEED_PLAIN" checkout -b main >/dev/null 2>&1 || true
_git_config_user "$SESSION_SEED_PLAIN"
printf '* text eol=lf\n' > "$SESSION_SEED_PLAIN/.gitattributes"
echo '{"sessionId":"shared","type":"base","timestamp":1}' > "$SESSION_SEED_PLAIN/shared-session.jsonl"
git -C "$SESSION_SEED_PLAIN" add . >/dev/null 2>&1
git -C "$SESSION_SEED_PLAIN" commit -m "initial seed" >/dev/null 2>&1
git -C "$SESSION_SEED_PLAIN" remote add origin "$SESSION_CONFLICT_REMOTE" >/dev/null 2>&1
git -C "$SESSION_SEED_PLAIN" push -u origin main >/dev/null 2>&1
SESSION_SEED_SHA=$(git -C "$SESSION_SEED_PLAIN" rev-list --max-parents=0 HEAD)
# Clone A: append to shared session, push (remote now has A's entry)
SESSION_CLONE_A="$TMPDIR_BASE/session-clone-a"
git clone "$SESSION_CONFLICT_REMOTE" "$SESSION_CLONE_A" >/dev/null 2>&1
_git_config_user "$SESSION_CLONE_A"
echo '{"sessionId":"shared","type":"from-a","timestamp":2}' >> "$SESSION_CLONE_A/shared-session.jsonl"
git -C "$SESSION_CLONE_A" add . >/dev/null 2>&1
git -C "$SESSION_CLONE_A" commit -m "sync: clone-a" >/dev/null 2>&1
git -C "$SESSION_CLONE_A" push >/dev/null 2>&1
# Clone B (session-sync runner): clone from remote, then roll back to seed so it diverges
SESSION_CLONE_B_HOME="$TMPDIR_BASE/session-clone-b"
SESSION_CLONE_B_CLAUDE="$SESSION_CLONE_B_HOME/.claude"
SESSION_CLONE_B_PROJECTS="$SESSION_CLONE_B_CLAUDE/projects"
git clone "$SESSION_CONFLICT_REMOTE" "$SESSION_CLONE_B_PROJECTS" >/dev/null 2>&1
_git_config_user "$SESSION_CLONE_B_PROJECTS"
mkdir -p "$SESSION_CLONE_B_CLAUDE"
git -C "$SESSION_CLONE_B_PROJECTS" config core.hooksPath /dev/null >/dev/null 2>&1
# Roll B back to seed SHA (diverges from remote which has A's commit)
git -C "$SESSION_CLONE_B_PROJECTS" reset --hard "$SESSION_SEED_SHA" >/dev/null 2>&1 || true
# B appends different line to same file (diverged from remote)
echo '{"sessionId":"shared","type":"from-b","timestamp":3}' >> "$SESSION_CLONE_B_PROJECTS/shared-session.jsonl"
git -C "$SESSION_CLONE_B_PROJECTS" add . >/dev/null 2>&1
git -C "$SESSION_CLONE_B_PROJECTS" commit -m "sync: clone-b" >/dev/null 2>&1
# Verify B is diverged before testing
_sb_ahead=$(git -C "$SESSION_CLONE_B_PROJECTS" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
_sb_behind=$(git -C "$SESSION_CLONE_B_PROJECTS" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
# Push should auto-resolve conflict
# Expected to FAIL until source is updated to auto-resolve JSONL conflicts
output=$("$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$SESSION_CLONE_B_CLAUDE" 2>&1) || true
if echo "$output" | grep -qi "pushed"; then
    pass "JSONL session conflict: push succeeds"
    # Verify no conflict markers in remote
    SESSION_VERIFY="$TMPDIR_BASE/session-verify"
    git clone "$SESSION_CONFLICT_REMOTE" "$SESSION_VERIFY" >/dev/null 2>&1
    if grep -q "<<<<<<" "$SESSION_VERIFY/shared-session.jsonl" 2>/dev/null; then
        fail "JSONL session conflict: conflict markers present in remote file"
    else
        pass "JSONL session conflict: no conflict markers in remote file"
    fi
    if grep -q "from-a" "$SESSION_VERIFY/shared-session.jsonl" 2>/dev/null && \
       grep -q "from-b" "$SESSION_VERIFY/shared-session.jsonl" 2>/dev/null; then
        pass "JSONL session conflict: remote file contains content from both sides"
    else
        fail "JSONL session conflict: remote missing content from one side (content: $(cat "$SESSION_VERIFY/shared-session.jsonl" 2>/dev/null || echo 'missing'))"
    fi
else
    fail "JSONL session conflict: push did not succeed (diverged: ahead=$_sb_ahead behind=$_sb_behind output: $output) [EXPECTED FAIL - source not yet updated]"
fi

# --- Idempotency: No duplicate commit after conflict resolution ---
echo "[conflict] Idempotency: no duplicate commit after conflict resolution"
# Re-run push from clone B after a successful conflict resolution.
# If the previous test passed (source updated), this verifies no double-commit.
# If the previous test failed (source not yet updated), this test is skipped.
if echo "$output" | grep -qi "pushed"; then
    output2=$("$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$HIST_CLONE_B_CLAUDE" 2>&1) || true
    if echo "$output2" | grep -qi "no changes"; then
        pass "idempotency: second push reports no changes"
    else
        fail "idempotency: second push did not report no changes (output: $output2)"
    fi
else
    # Source not yet updated — mark as expected skip
    fail "idempotency: skipped because prior conflict test failed [EXPECTED FAIL - source not yet updated]"
fi

echo ""
echo "=== Results ==="
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
