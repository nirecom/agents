# Tests: bin/session-sync.sh
# Tags: bin, git, session-sync, conflict, rebase, scope:common
# Part of tests/main-session-sync.sh — sourced by that dispatcher, not run alone.
#
# `_git_config_user` now lives in the dispatcher (suite-wide fixture, #1564).

echo ""
echo "=== conflict rebase resolution tests ==="

# --- Normal: Interrupted rebase-merge state recovery ---
echo "[conflict] Interrupted rebase-merge state recovery"
REBASE_REMOTE="$TMPDIR_BASE/rebase-interrupted-remote.git"
REBASE_CLAUDE="$TMPDIR_BASE/rebase-interrupted/.claude"
REBASE_PROJECTS="$REBASE_CLAUDE/projects"
git init --bare "$REBASE_REMOTE" >/dev/null 2>&1
"$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$REBASE_CLAUDE" --remote-url "$REBASE_REMOTE" >/dev/null 2>&1
_git_config_user "$REBASE_PROJECTS"
git -C "$REBASE_PROJECTS" add -A >/dev/null 2>&1
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
