# Tests: bin/session-sync.sh
# Tags: bin, git, session-sync, conflict, rebase, self-heal, scope:common
# Part of tests/bin/main-session-sync.sh — sourced by that dispatcher, not run alone.
#
# `_git_config_user` now lives in the dispatcher (suite-wide fixture, #1564).
# #2658 / #2291: integration never enters rebase or merge state, so a stuck clone
# recovers in one push and diverged jsonl / history keep both sides.

echo ""
echo "=== conflict and stuck-state recovery tests ==="

# --- Normal: a clone stuck mid-rebase (detached HEAD + rebase-merge + MERGE_HEAD) recovers ---
echo "[conflict] Interrupted rebase-merge state recovery"
REBASE_REMOTE="$TMPDIR_BASE/rebase-interrupted-remote.git"
REBASE_CLAUDE="$TMPDIR_BASE/rebase-interrupted/.claude"
REBASE_PROJECTS="$REBASE_CLAUDE/projects"
git init --bare "$REBASE_REMOTE" >/dev/null 2>&1
"$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$REBASE_CLAUDE" --no-remote >/dev/null 2>&1
# Local-path remotes are no longer accepted by the installer allowlist (#1773);
# the fixture attaches its own origin instead.
git -C "$REBASE_PROJECTS" remote add origin "$REBASE_REMOTE" >/dev/null 2>&1
_git_config_user "$REBASE_PROJECTS"
git -C "$REBASE_PROJECTS" add -A >/dev/null 2>&1
git -C "$REBASE_PROJECTS" commit -m "initial" >/dev/null 2>&1
git -C "$REBASE_PROJECTS" push -u origin main >/dev/null 2>&1
# The shape a stuck `pull --rebase` leaves: HEAD detached, rebase-merge/ and MERGE_HEAD present.
git -C "$REBASE_PROJECTS" checkout -q --detach >/dev/null 2>&1
mkdir -p "$REBASE_PROJECTS/.git/rebase-merge"
echo "fake-sha" > "$REBASE_PROJECTS/.git/rebase-merge/orig-head"
echo "refs/heads/main" > "$REBASE_PROJECTS/.git/rebase-merge/head-name"
git -C "$REBASE_PROJECTS" rev-parse HEAD > "$REBASE_PROJECTS/.git/MERGE_HEAD"
echo '{"sessionId":"rebase-recovery","type":"text"}' > "$REBASE_PROJECTS/rebase-recovery.jsonl"
output=$("$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$REBASE_CLAUDE" 2>&1) || true
if echo "$output" | grep -qi "pushed"; then
    pass "push succeeds from an interrupted rebase-merge state"
else
    fail "push did not succeed from an interrupted rebase-merge state (output: $output)"
fi
_cf_head=$(git -C "$REBASE_PROJECTS" symbolic-ref HEAD 2>/dev/null || echo detached)
if [ ! -d "$REBASE_PROJECTS/.git/rebase-merge" ] && [ ! -f "$REBASE_PROJECTS/.git/MERGE_HEAD" ] \
    && [ "$_cf_head" = "refs/heads/main" ]; then
    pass "self-heal removes rebase-merge / MERGE_HEAD and re-attaches HEAD to main"
else
    fail "self-heal: rebase-merge=$([ -d "$REBASE_PROJECTS/.git/rebase-merge" ] && echo yes || echo no) MERGE_HEAD=$([ -f "$REBASE_PROJECTS/.git/MERGE_HEAD" ] && echo yes || echo no) HEAD=$_cf_head"
fi
if git -C "$REBASE_REMOTE" cat-file -e main:rebase-recovery.jsonl 2>/dev/null \
    && grep -q "rebase-recovery" "$REBASE_PROJECTS/rebase-recovery.jsonl" 2>/dev/null; then
    pass "self-heal keeps the working tree and publishes the pending file"
else
    fail "self-heal lost the pending file (remote has it: $(git -C "$REBASE_REMOTE" cat-file -e main:rebase-recovery.jsonl 2>/dev/null && echo yes || echo no))"
fi

# --- Normal: .history.jsonl diverged between two machines keeps both entries ---
echo "[conflict] .history.jsonl diverge keeps both sides"
HIST_CONFLICT_REMOTE="$TMPDIR_BASE/hist-conflict-remote.git"
git init --bare "$HIST_CONFLICT_REMOTE" >/dev/null 2>&1
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
HIST_SEED_SHA=$(git -C "$HIST_SEED_CLONE" rev-list --max-parents=0 HEAD)
# Clone A pushes machine-a's entry.
HIST_CLONE_A="$TMPDIR_BASE/hist-clone-a"
git clone "$HIST_CONFLICT_REMOTE" "$HIST_CLONE_A" >/dev/null 2>&1
_git_config_user "$HIST_CLONE_A"
echo '{"display":"machine-a","sessionId":"a1","timestamp":2}' >> "$HIST_CLONE_A/.history.jsonl"
git -C "$HIST_CLONE_A" add . >/dev/null 2>&1
git -C "$HIST_CLONE_A" commit -m "sync: machine-a 2026-01-01 00:00" >/dev/null 2>&1
git -C "$HIST_CLONE_A" push >/dev/null 2>&1
# Clone B sits on the seed with its own unpushed machine-b commit (diverged).
HIST_CLONE_B_CLAUDE="$TMPDIR_BASE/hist-clone-b/.claude"
HIST_CLONE_B_PROJECTS="$HIST_CLONE_B_CLAUDE/projects"
git clone "$HIST_CONFLICT_REMOTE" "$HIST_CLONE_B_PROJECTS" >/dev/null 2>&1
_git_config_user "$HIST_CLONE_B_PROJECTS"
git -C "$HIST_CLONE_B_PROJECTS" config core.hooksPath /dev/null >/dev/null 2>&1
git -C "$HIST_CLONE_B_PROJECTS" reset -q --hard "$HIST_SEED_SHA" >/dev/null 2>&1 || true
echo '{"display":"machine-b","sessionId":"b1","timestamp":3}' >> "$HIST_CLONE_B_PROJECTS/.history.jsonl"
git -C "$HIST_CLONE_B_PROJECTS" add . >/dev/null 2>&1
git -C "$HIST_CLONE_B_PROJECTS" commit -m "sync: machine-b 2026-01-01 00:01" >/dev/null 2>&1
# The live history file is what the projects copy mirrors.
cp "$HIST_CLONE_B_PROJECTS/.history.jsonl" "$HIST_CLONE_B_CLAUDE/history.jsonl"
output=$("$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$HIST_CLONE_B_CLAUDE" 2>&1) || true
_cf_remote_hist=$(git -C "$HIST_CONFLICT_REMOTE" show main:.history.jsonl 2>/dev/null || true)
if echo "$output" | grep -qi "pushed"; then
    pass ".history.jsonl diverge: push succeeds"
else
    fail ".history.jsonl diverge: push did not succeed (output: $output)"
fi
if echo "$_cf_remote_hist" | grep -q '"a1"' && echo "$_cf_remote_hist" | grep -q '"b1"' \
    && grep -q '"a1"' "$HIST_CLONE_B_CLAUDE/history.jsonl" 2>/dev/null; then
    pass ".history.jsonl diverge: remote and local history hold both a1 and b1"
else
    fail ".history.jsonl diverge: remote=[$_cf_remote_hist] local=[$(cat "$HIST_CLONE_B_CLAUDE/history.jsonl" 2>/dev/null)]"
fi

# --- Normal: a transcript diverged between two machines keeps both sides, no markers ---
echo "[conflict] JSONL session file diverge keeps both sides"
SESSION_CONFLICT_REMOTE="$TMPDIR_BASE/session-conflict-remote.git"
git init --bare "$SESSION_CONFLICT_REMOTE" >/dev/null 2>&1
SESSION_SEED_PLAIN="$TMPDIR_BASE/session-conflict-seed"
git init "$SESSION_SEED_PLAIN" >/dev/null 2>&1
git -C "$SESSION_SEED_PLAIN" checkout -b main >/dev/null 2>&1 || true
_git_config_user "$SESSION_SEED_PLAIN"
printf '* text eol=lf\n' > "$SESSION_SEED_PLAIN/.gitattributes"
echo '{"uuid":"base","sessionId":"shared","type":"base","timestamp":1}' > "$SESSION_SEED_PLAIN/shared-session.jsonl"
git -C "$SESSION_SEED_PLAIN" add . >/dev/null 2>&1
git -C "$SESSION_SEED_PLAIN" commit -m "initial seed" >/dev/null 2>&1
git -C "$SESSION_SEED_PLAIN" remote add origin "$SESSION_CONFLICT_REMOTE" >/dev/null 2>&1
git -C "$SESSION_SEED_PLAIN" push -u origin main >/dev/null 2>&1
SESSION_SEED_SHA=$(git -C "$SESSION_SEED_PLAIN" rev-list --max-parents=0 HEAD)
SESSION_CLONE_A="$TMPDIR_BASE/session-clone-a"
git clone "$SESSION_CONFLICT_REMOTE" "$SESSION_CLONE_A" >/dev/null 2>&1
_git_config_user "$SESSION_CLONE_A"
echo '{"uuid":"a1","sessionId":"shared","type":"from-a","timestamp":2}' >> "$SESSION_CLONE_A/shared-session.jsonl"
git -C "$SESSION_CLONE_A" add . >/dev/null 2>&1
git -C "$SESSION_CLONE_A" commit -m "sync: clone-a" >/dev/null 2>&1
git -C "$SESSION_CLONE_A" push >/dev/null 2>&1
SESSION_CLONE_B_CLAUDE="$TMPDIR_BASE/session-clone-b/.claude"
SESSION_CLONE_B_PROJECTS="$SESSION_CLONE_B_CLAUDE/projects"
git clone "$SESSION_CONFLICT_REMOTE" "$SESSION_CLONE_B_PROJECTS" >/dev/null 2>&1
_git_config_user "$SESSION_CLONE_B_PROJECTS"
git -C "$SESSION_CLONE_B_PROJECTS" config core.hooksPath /dev/null >/dev/null 2>&1
git -C "$SESSION_CLONE_B_PROJECTS" reset -q --hard "$SESSION_SEED_SHA" >/dev/null 2>&1 || true
echo '{"uuid":"b1","sessionId":"shared","type":"from-b","timestamp":3}' >> "$SESSION_CLONE_B_PROJECTS/shared-session.jsonl"
git -C "$SESSION_CLONE_B_PROJECTS" add . >/dev/null 2>&1
git -C "$SESSION_CLONE_B_PROJECTS" commit -m "sync: clone-b" >/dev/null 2>&1
output=$("$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$SESSION_CLONE_B_CLAUDE" 2>&1) || true
_cf_remote_s=$(git -C "$SESSION_CONFLICT_REMOTE" show main:shared-session.jsonl 2>/dev/null || true)
if echo "$output" | grep -qi "pushed"; then
    pass "JSONL session diverge: push succeeds"
else
    fail "JSONL session diverge: push did not succeed (output: $output)"
fi
if echo "$_cf_remote_s" | grep -q "from-a" && echo "$_cf_remote_s" | grep -q "from-b" \
    && ! echo "$_cf_remote_s" | grep -q '^<<<<<<<\|^=======\|^>>>>>>>' \
    && grep -q "from-a" "$SESSION_CLONE_B_PROJECTS/shared-session.jsonl"; then
    pass "JSONL session diverge: remote and B's working tree hold both sides, no conflict markers"
else
    fail "JSONL session diverge: remote=[$_cf_remote_s] local=[$(cat "$SESSION_CLONE_B_PROJECTS/shared-session.jsonl")]"
fi

# --- Idempotency: the converged clone has nothing left to push ---
echo "[conflict] Idempotency: no duplicate commit after the diverge is integrated"
output2=$("$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$SESSION_CLONE_B_CLAUDE" 2>&1) || true
if echo "$output2" | grep -qi "no changes"; then
    pass "idempotency: second push reports no changes"
else
    fail "idempotency: second push did not report no changes (output: $output2)"
fi

# --- Conflict-marker lines a past rebase left inside a transcript are dropped ---
echo "[conflict] Leftover conflict-marker lines are dropped from a transcript"
git -C "$SESSION_CLONE_A" pull -q >/dev/null 2>&1 || true
echo '{"uuid":"a2","sessionId":"shared","type":"from-a2","timestamp":4}' >> "$SESSION_CLONE_A/shared-session.jsonl"
git -C "$SESSION_CLONE_A" commit -qam "sync: clone-a 2" >/dev/null 2>&1
git -C "$SESSION_CLONE_A" push -q >/dev/null 2>&1
printf '%s\n' '<<<<<<< HEAD' '{"uuid":"b2","sessionId":"shared","type":"from-b2","timestamp":5}' '=======' '>>>>>>> 0123abc (sync: old)' \
    >> "$SESSION_CLONE_B_PROJECTS/shared-session.jsonl"
"$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$SESSION_CLONE_B_CLAUDE" >/dev/null 2>&1 || true
_cf_remote_m=$(git -C "$SESSION_CONFLICT_REMOTE" show main:shared-session.jsonl 2>/dev/null || true)
if echo "$_cf_remote_m" | grep -q "from-a2" && echo "$_cf_remote_m" | grep -q "from-b2" \
    && ! echo "$_cf_remote_m" | grep -q '^<<<<<<<\|^=======\|^>>>>>>>'; then
    pass "marker lines are dropped while both sides' entries are kept"
else
    fail "marker lines: remote=[$_cf_remote_m]"
fi
