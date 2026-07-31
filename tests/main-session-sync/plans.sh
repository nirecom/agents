# Tests: bin/session-sync.sh, bin/workflow-plans-dir
# Tags: bin, git, session-sync, plans, scope:common
# Part of tests/main-session-sync.sh — sourced by that dispatcher, not run alone.
#
# Plans-source contract (the reason these cases all set WORKFLOW_PLANS_DIR):
#   bin/session-sync.sh resolves its plans source via `bin/workflow-plans-dir`,
#   i.e. $WORKFLOW_PLANS_DIR (default ~/.workflow-plans) — NOT $CLAUDE_DIR/plans.
#   Cases that seeded $CLAUDE_DIR/plans were asserting against a location the
#   script never reads, and silently fell back to the developer's real
#   ~/.workflow-plans, which is what made this suite hang (#1564).

echo ""
echo "=== plans sync tests ==="

# bin/workflow-plans-dir shells out to node. Without node the resolver fails and
# session-sync.sh falls back to the real $HOME/.workflow-plans — which is exactly
# the uncontrolled dependency #1564 was about. Refuse to run rather than sync the
# developer's real plans directory into a fixture.
if ! command -v node >/dev/null 2>&1; then
    pending "plans sync section (node not available; bin/workflow-plans-dir cannot resolve WORKFLOW_PLANS_DIR)"
    return 0
fi

# Independent environment for plans sync tests (PLANS_* prefix to avoid collisions)
PLANS_REMOTE="$TMPDIR_BASE/plans-remote.git"
PLANS_HOME="$TMPDIR_BASE/plans-home"
PLANS_CLAUDE="$PLANS_HOME/.claude"
PLANS_PROJECTS="$PLANS_CLAUDE/projects"
git init --bare "$PLANS_REMOTE" >/dev/null 2>&1
mkdir -p "$PLANS_CLAUDE"
"$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$PLANS_CLAUDE" --remote-url "$PLANS_REMOTE" >/dev/null 2>&1
_git_prepare_repo "$PLANS_PROJECTS"
git -C "$PLANS_PROJECTS" add -A >/dev/null 2>&1
git -C "$PLANS_PROJECTS" commit -m "initial" >/dev/null 2>&1
git -C "$PLANS_PROJECTS" push -u origin main >/dev/null 2>&1

# --- Normal: Push copies plans to projects/plans/ ---
echo "[plans] Push copies plans to projects/plans/"
PLANS_SRC="$TMPDIR_BASE/plans-src"
mkdir -p "$PLANS_SRC"
echo "intent content" > "$PLANS_SRC/abc-intent.md"
output=$(WORKFLOW_PLANS_DIR="$PLANS_SRC" "$DOTFILES_DIR/bin/session-sync.sh" \
    push --claude-dir "$PLANS_CLAUDE" 2>&1) || true
if [ -f "$PLANS_PROJECTS/plans/abc-intent.md" ]; then
    pass "push copies plans/abc-intent.md to projects/plans/"
else
    fail "push did not copy plans/abc-intent.md (output: $output)"
fi

# --- Fix: Push excludes supervisor-state.json from plans sync (.md-only filter) ---
# WORKFLOW_PLANS_DIR is set explicitly so the plans source is a deterministic,
# test-controlled directory instead of the real ~/.workflow-plans.
echo "[plans] Push excludes supervisor-state.json (session-sync.sh)"
PLANS_FILTER_REMOTE="$TMPDIR_BASE/plans-filter-remote.git"
PLANS_FILTER_CLAUDE="$TMPDIR_BASE/plans-filter/.claude"
PLANS_FILTER_PROJECTS="$PLANS_FILTER_CLAUDE/projects"
PLANS_FILTER_SRC="$TMPDIR_BASE/plans-filter-src"
git init --bare "$PLANS_FILTER_REMOTE" >/dev/null 2>&1
mkdir -p "$PLANS_FILTER_CLAUDE"
"$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$PLANS_FILTER_CLAUDE" --remote-url "$PLANS_FILTER_REMOTE" >/dev/null 2>&1
_git_prepare_repo "$PLANS_FILTER_PROJECTS"
git -C "$PLANS_FILTER_PROJECTS" add -A >/dev/null 2>&1
git -C "$PLANS_FILTER_PROJECTS" commit -m "initial" >/dev/null 2>&1
git -C "$PLANS_FILTER_PROJECTS" push -u origin main >/dev/null 2>&1
mkdir -p "$PLANS_FILTER_SRC"
echo "intent content" > "$PLANS_FILTER_SRC/abc-intent.md"
echo '{"state":"internal"}' > "$PLANS_FILTER_SRC/abc-supervisor-state.json"
WORKFLOW_PLANS_DIR="$PLANS_FILTER_SRC" "$DOTFILES_DIR/bin/session-sync.sh" \
    push --claude-dir "$PLANS_FILTER_CLAUDE" >/dev/null 2>&1 || true
if [ -f "$PLANS_FILTER_PROJECTS/plans/abc-intent.md" ]; then
    pass "push syncs .md plan file"
else
    fail "push did not sync .md plan file"
fi
if [ ! -f "$PLANS_FILTER_PROJECTS/plans/abc-supervisor-state.json" ]; then
    pass "push excludes supervisor-state.json from plans sync"
else
    fail "push copied supervisor-state.json into plans sync (should filter to .md only)"
fi

# --- Edge: Push when plans dir absent ---
echo "[plans] Push when plans dir absent"
PLANS_NOPLANS_REMOTE="$TMPDIR_BASE/plans-noplans-remote.git"
PLANS_NOPLANS_CLAUDE="$TMPDIR_BASE/plans-noplans/.claude"
PLANS_NOPLANS_PROJECTS="$PLANS_NOPLANS_CLAUDE/projects"
git init --bare "$PLANS_NOPLANS_REMOTE" >/dev/null 2>&1
mkdir -p "$PLANS_NOPLANS_CLAUDE"
"$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$PLANS_NOPLANS_CLAUDE" --remote-url "$PLANS_NOPLANS_REMOTE" >/dev/null 2>&1
_git_prepare_repo "$PLANS_NOPLANS_PROJECTS"
git -C "$PLANS_NOPLANS_PROJECTS" add -A >/dev/null 2>&1
git -C "$PLANS_NOPLANS_PROJECTS" commit -m "initial" >/dev/null 2>&1
git -C "$PLANS_NOPLANS_PROJECTS" push -u origin main >/dev/null 2>&1
# Add a file so push has something to do
echo '{"trigger":"push"}' > "$PLANS_NOPLANS_PROJECTS/trigger.jsonl"
exit_code=0
output=$(WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans-does-not-exist" \
    "$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$PLANS_NOPLANS_CLAUDE" 2>&1) || exit_code=$?
if [ $exit_code -eq 0 ]; then
    pass "push without plans dir succeeds (no error)"
else
    fail "push without plans dir returned non-zero exit ($exit_code, output: $output)"
fi
if [ ! -d "$PLANS_NOPLANS_PROJECTS/plans" ]; then
    pass "push without plans dir does not create an empty projects/plans/"
else
    fail "push created projects/plans/ even though the plans source was absent"
fi

# --- Normal: Pull merges plans into ~/.workflow-plans/ ---
echo "[plans] Pull merges plans into ~/.workflow-plans/"
PLANS_PULL_REMOTE="$TMPDIR_BASE/plans-pull-remote.git"
PLANS_PULL_CLAUDE="$TMPDIR_BASE/plans-pull/.claude"
PLANS_PULL_PROJECTS="$PLANS_PULL_CLAUDE/projects"
PLANS_PULL_LOCAL="$TMPDIR_BASE/plans-pull-local"
git init --bare "$PLANS_PULL_REMOTE" >/dev/null 2>&1
# Seed remote with plans/remote-plan.md
PLANS_PULL_SEED="$TMPDIR_BASE/plans-pull-seed"
git clone "$PLANS_PULL_REMOTE" "$PLANS_PULL_SEED" >/dev/null 2>&1
_git_prepare_repo "$PLANS_PULL_SEED"
git -C "$PLANS_PULL_SEED" checkout -b main >/dev/null 2>&1 || true
printf '* text eol=lf\n' > "$PLANS_PULL_SEED/.gitattributes"
mkdir -p "$PLANS_PULL_SEED/plans"
echo "remote plan content" > "$PLANS_PULL_SEED/plans/remote-plan.md"
git -C "$PLANS_PULL_SEED" add . >/dev/null 2>&1
git -C "$PLANS_PULL_SEED" commit -m "seed plans" >/dev/null 2>&1
git -C "$PLANS_PULL_SEED" push -u origin main >/dev/null 2>&1
# Init local as clone from seeded remote (provides tracking info for git pull --rebase)
mkdir -p "$PLANS_PULL_CLAUDE"
git clone "$PLANS_PULL_REMOTE" "$PLANS_PULL_PROJECTS" >/dev/null 2>&1
_git_prepare_repo "$PLANS_PULL_PROJECTS"
git -C "$PLANS_PULL_PROJECTS" config core.hooksPath /dev/null >/dev/null 2>&1
mkdir -p "$PLANS_PULL_LOCAL"
echo "local plan content" > "$PLANS_PULL_LOCAL/local-plan.md"
output=$(WORKFLOW_PLANS_DIR="$PLANS_PULL_LOCAL" "$DOTFILES_DIR/bin/session-sync.sh" \
    pull --claude-dir "$PLANS_PULL_CLAUDE" 2>&1) || true
if [ -f "$PLANS_PULL_LOCAL/remote-plan.md" ]; then
    pass "pull merges remote plan into local plans/"
else
    fail "pull did not place remote plan in local plans/ (output: $output)"
fi
if [ -f "$PLANS_PULL_LOCAL/local-plan.md" ]; then
    pass "pull preserves local-only plan"
else
    fail "pull removed local-only plan"
fi

# --- Edge: Pull when local plans dir absent ---
echo "[plans] Pull when local plans dir absent"
PLANS_PULL2_REMOTE="$TMPDIR_BASE/plans-pull2-remote.git"
PLANS_PULL2_CLAUDE="$TMPDIR_BASE/plans-pull2/.claude"
PLANS_PULL2_PROJECTS="$PLANS_PULL2_CLAUDE/projects"
PLANS_PULL2_LOCAL="$TMPDIR_BASE/plans-pull2-local"
git init --bare "$PLANS_PULL2_REMOTE" >/dev/null 2>&1
PLANS_PULL2_SEED="$TMPDIR_BASE/plans-pull2-seed"
git clone "$PLANS_PULL2_REMOTE" "$PLANS_PULL2_SEED" >/dev/null 2>&1
_git_prepare_repo "$PLANS_PULL2_SEED"
git -C "$PLANS_PULL2_SEED" checkout -b main >/dev/null 2>&1 || true
printf '* text eol=lf\n' > "$PLANS_PULL2_SEED/.gitattributes"
mkdir -p "$PLANS_PULL2_SEED/plans"
echo "remote only plan" > "$PLANS_PULL2_SEED/plans/remote-only.md"
git -C "$PLANS_PULL2_SEED" add . >/dev/null 2>&1
git -C "$PLANS_PULL2_SEED" commit -m "seed plans" >/dev/null 2>&1
git -C "$PLANS_PULL2_SEED" push -u origin main >/dev/null 2>&1
# Init local as clone from seeded remote (provides tracking info for git pull --rebase)
mkdir -p "$PLANS_PULL2_CLAUDE"
git clone "$PLANS_PULL2_REMOTE" "$PLANS_PULL2_PROJECTS" >/dev/null 2>&1
_git_prepare_repo "$PLANS_PULL2_PROJECTS"
git -C "$PLANS_PULL2_PROJECTS" config core.hooksPath /dev/null >/dev/null 2>&1
# Make sure local plans dir does NOT exist
rm -rf "$PLANS_PULL2_LOCAL"
output=$(WORKFLOW_PLANS_DIR="$PLANS_PULL2_LOCAL" "$DOTFILES_DIR/bin/session-sync.sh" \
    pull --claude-dir "$PLANS_PULL2_CLAUDE" 2>&1) || true
if [ -f "$PLANS_PULL2_LOCAL/remote-only.md" ]; then
    pass "pull creates local plans/ from remote when absent"
else
    fail "pull did not create local plans/ from remote (output: $output)"
fi

# --- Edge: Pull when remote has no plans ---
echo "[plans] Pull when remote has no plans"
PLANS_PULL3_REMOTE="$TMPDIR_BASE/plans-pull3-remote.git"
PLANS_PULL3_CLAUDE="$TMPDIR_BASE/plans-pull3/.claude"
PLANS_PULL3_PROJECTS="$PLANS_PULL3_CLAUDE/projects"
PLANS_PULL3_LOCAL="$TMPDIR_BASE/plans-pull3-local"
git init --bare "$PLANS_PULL3_REMOTE" >/dev/null 2>&1
mkdir -p "$PLANS_PULL3_CLAUDE"
"$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$PLANS_PULL3_CLAUDE" --remote-url "$PLANS_PULL3_REMOTE" >/dev/null 2>&1
_git_prepare_repo "$PLANS_PULL3_PROJECTS"
git -C "$PLANS_PULL3_PROJECTS" add -A >/dev/null 2>&1
git -C "$PLANS_PULL3_PROJECTS" commit -m "initial" >/dev/null 2>&1
git -C "$PLANS_PULL3_PROJECTS" push -u origin main >/dev/null 2>&1
mkdir -p "$PLANS_PULL3_LOCAL"
echo "local only" > "$PLANS_PULL3_LOCAL/local-only.md"
exit_code=0
output=$(WORKFLOW_PLANS_DIR="$PLANS_PULL3_LOCAL" "$DOTFILES_DIR/bin/session-sync.sh" \
    pull --claude-dir "$PLANS_PULL3_CLAUDE" 2>&1) || exit_code=$?
if [ $exit_code -eq 0 ]; then
    pass "pull without remote plans succeeds"
else
    fail "pull without remote plans returned non-zero exit ($exit_code, output: $output)"
fi
if [ -f "$PLANS_PULL3_LOCAL/local-only.md" ]; then
    pass "pull preserves local-only plan when remote has no plans"
else
    fail "pull removed local-only plan when remote has no plans"
fi

# --- Normal: Reset merges plans ---
echo "[plans] Reset merges plans"
PLANS_RESET_REMOTE="$TMPDIR_BASE/plans-reset-remote.git"
PLANS_RESET_CLAUDE="$TMPDIR_BASE/plans-reset/.claude"
PLANS_RESET_PROJECTS="$PLANS_RESET_CLAUDE/projects"
PLANS_RESET_LOCAL="$TMPDIR_BASE/plans-reset-local"
git init --bare "$PLANS_RESET_REMOTE" >/dev/null 2>&1
PLANS_RESET_SEED="$TMPDIR_BASE/plans-reset-seed"
git clone "$PLANS_RESET_REMOTE" "$PLANS_RESET_SEED" >/dev/null 2>&1
_git_prepare_repo "$PLANS_RESET_SEED"
git -C "$PLANS_RESET_SEED" checkout -b main >/dev/null 2>&1 || true
printf '* text eol=lf\n' > "$PLANS_RESET_SEED/.gitattributes"
mkdir -p "$PLANS_RESET_SEED/plans"
echo "seed plan" > "$PLANS_RESET_SEED/plans/seed.md"
git -C "$PLANS_RESET_SEED" add . >/dev/null 2>&1
git -C "$PLANS_RESET_SEED" commit -m "seed plans" >/dev/null 2>&1
git -C "$PLANS_RESET_SEED" push -u origin main >/dev/null 2>&1
mkdir -p "$PLANS_RESET_CLAUDE"
"$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$PLANS_RESET_CLAUDE" --remote-url "$PLANS_RESET_REMOTE" >/dev/null 2>&1
_git_prepare_repo "$PLANS_RESET_PROJECTS"
output=$(WORKFLOW_PLANS_DIR="$PLANS_RESET_LOCAL" "$DOTFILES_DIR/bin/session-sync.sh" \
    reset --claude-dir "$PLANS_RESET_CLAUDE" 2>&1) || true
if [ -f "$PLANS_RESET_LOCAL/seed.md" ]; then
    pass "reset merges remote plan into local plans/"
else
    fail "reset did not merge remote plan (output: $output)"
fi

# --- Normal: Push includes plans in git commit ---
echo "[plans] Push includes plans in git commit"
PLANS_COMMIT_REMOTE="$TMPDIR_BASE/plans-commit-remote.git"
PLANS_COMMIT_CLAUDE="$TMPDIR_BASE/plans-commit/.claude"
PLANS_COMMIT_PROJECTS="$PLANS_COMMIT_CLAUDE/projects"
PLANS_COMMIT_SRC="$TMPDIR_BASE/plans-commit-src"
git init --bare "$PLANS_COMMIT_REMOTE" >/dev/null 2>&1
mkdir -p "$PLANS_COMMIT_CLAUDE"
"$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$PLANS_COMMIT_CLAUDE" --remote-url "$PLANS_COMMIT_REMOTE" >/dev/null 2>&1
_git_prepare_repo "$PLANS_COMMIT_PROJECTS"
git -C "$PLANS_COMMIT_PROJECTS" add -A >/dev/null 2>&1
git -C "$PLANS_COMMIT_PROJECTS" commit -m "initial" >/dev/null 2>&1
git -C "$PLANS_COMMIT_PROJECTS" push -u origin main >/dev/null 2>&1
mkdir -p "$PLANS_COMMIT_SRC"
echo "commit plan content" > "$PLANS_COMMIT_SRC/commit-plan.md"
WORKFLOW_PLANS_DIR="$PLANS_COMMIT_SRC" "$DOTFILES_DIR/bin/session-sync.sh" \
    push --claude-dir "$PLANS_COMMIT_CLAUDE" >/dev/null 2>&1 || true
last_files=$(git -C "$PLANS_COMMIT_PROJECTS" log -1 --name-only --pretty=format: 2>/dev/null | grep -v '^$' || true)
if echo "$last_files" | grep -q "plans/commit-plan.md"; then
    pass "push includes plans/commit-plan.md in commit"
else
    fail "push commit does not include plans file (files: $last_files)"
fi

# --- Idempotency: Push twice reports no changes ---
echo "[plans] Push twice reports no changes"
PLANS_IDEM_REMOTE="$TMPDIR_BASE/plans-idem-remote.git"
PLANS_IDEM_CLAUDE="$TMPDIR_BASE/plans-idem/.claude"
PLANS_IDEM_PROJECTS="$PLANS_IDEM_CLAUDE/projects"
PLANS_IDEM_SRC="$TMPDIR_BASE/plans-idem-src"
git init --bare "$PLANS_IDEM_REMOTE" >/dev/null 2>&1
mkdir -p "$PLANS_IDEM_CLAUDE"
"$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$PLANS_IDEM_CLAUDE" --remote-url "$PLANS_IDEM_REMOTE" >/dev/null 2>&1
_git_prepare_repo "$PLANS_IDEM_PROJECTS"
git -C "$PLANS_IDEM_PROJECTS" add -A >/dev/null 2>&1
git -C "$PLANS_IDEM_PROJECTS" commit -m "initial" >/dev/null 2>&1
git -C "$PLANS_IDEM_PROJECTS" push -u origin main >/dev/null 2>&1
mkdir -p "$PLANS_IDEM_SRC"
echo "stable plan" > "$PLANS_IDEM_SRC/idem-plan.md"
WORKFLOW_PLANS_DIR="$PLANS_IDEM_SRC" "$DOTFILES_DIR/bin/session-sync.sh" \
    push --claude-dir "$PLANS_IDEM_CLAUDE" >/dev/null 2>&1 || true
output2=$(WORKFLOW_PLANS_DIR="$PLANS_IDEM_SRC" "$DOTFILES_DIR/bin/session-sync.sh" \
    push --claude-dir "$PLANS_IDEM_CLAUDE" 2>&1) || true
if echo "$output2" | grep -qi "no changes"; then
    pass "second push with unchanged plans reports no changes"
else
    fail "second push with unchanged plans did not report no changes (output: $output2)"
fi

# --- Regression: WORKFLOW_PLANS_DIR override is honored ---
# When WORKFLOW_PLANS_DIR is set, session-sync should source plans from
# that directory rather than the default. This is a regression guard for
# the .claude/plans → .workflow-plans migration.
#
# The support is indirect: session-sync.sh never names WORKFLOW_PLANS_DIR, it
# delegates to bin/workflow-plans-dir, which reads the env var. Grepping
# session-sync.sh for the variable name therefore reports a false negative —
# the guard below checks for the delegation instead.
echo "[plans] WORKFLOW_PLANS_DIR override is honored"
WPD_REMOTE="$TMPDIR_BASE/wpd-remote.git"
WPD_CLAUDE="$TMPDIR_BASE/wpd/.claude"
WPD_PROJECTS="$WPD_CLAUDE/projects"
WPD_CUSTOM="$TMPDIR_BASE/test-custom-plans"
git init --bare "$WPD_REMOTE" >/dev/null 2>&1
mkdir -p "$WPD_CLAUDE"
"$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$WPD_CLAUDE" --remote-url "$WPD_REMOTE" >/dev/null 2>&1
_git_prepare_repo "$WPD_PROJECTS"
git -C "$WPD_PROJECTS" add -A >/dev/null 2>&1
git -C "$WPD_PROJECTS" commit -m "initial" >/dev/null 2>&1
git -C "$WPD_PROJECTS" push -u origin main >/dev/null 2>&1
# Seed the custom plans dir (NOT the default location)
mkdir -p "$WPD_CUSTOM"
echo "custom-dir plan content" > "$WPD_CUSTOM/custom-plan.md"
if grep -q "workflow-plans-dir" "$DOTFILES_DIR/bin/session-sync.sh" 2>/dev/null; then
    output=$(WORKFLOW_PLANS_DIR="$WPD_CUSTOM" "$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$WPD_CLAUDE" 2>&1) || true
    last_files=$(git -C "$WPD_PROJECTS" log -1 --name-only --pretty=format: 2>/dev/null | grep -v '^$' || true)
    if echo "$last_files" | grep -q "custom-plan.md"; then
        pass "WORKFLOW_PLANS_DIR honored — custom-plan.md included in push"
    else
        fail "WORKFLOW_PLANS_DIR override not honored (files: $last_files; output: $output)"
    fi
else
    pending "WORKFLOW_PLANS_DIR support not yet implemented in bin/session-sync.sh"
fi

# --- Error: relative WORKFLOW_PLANS_DIR is rejected by the resolver ---
# Boundary case for the resolver contract: a non-absolute value must not be
# silently accepted (it would resolve against an arbitrary CWD).
echo "[plans] Relative WORKFLOW_PLANS_DIR is rejected"
rel_exit=0
WORKFLOW_PLANS_DIR="relative/plans" "$DOTFILES_DIR/bin/workflow-plans-dir" >/dev/null 2>&1 || rel_exit=$?
if [ "$rel_exit" -ne 0 ]; then
    pass "workflow-plans-dir rejects a relative WORKFLOW_PLANS_DIR (exit $rel_exit)"
else
    fail "workflow-plans-dir accepted a relative WORKFLOW_PLANS_DIR"
fi
