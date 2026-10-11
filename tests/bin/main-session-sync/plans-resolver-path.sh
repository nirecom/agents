# Tests: bin/session-sync.sh
# Tags: bin, session-sync, workflow-plans-dir, checkout-root, scope:issue-specific
# Part of tests/bin/main-session-sync.sh — sourced by that dispatcher, not run alone.
# #2561: session-sync.sh resolves bin/workflow-plans-dir from its own checkout root
# (symlink-resolved), and warns on stderr when that checkout has no such helper
# instead of silently falling back to $HOME/.workflow-plans.

echo ""
echo "=== workflow-plans-dir resolution from the script's checkout ==="

PRP_REMOTE="$TMPDIR_BASE/prp-remote.git"
PRP_CLAUDE="$TMPDIR_BASE/prp/.claude"
PRP_PROJECTS="$PRP_CLAUDE/projects"
PRP_PLANS="$TMPDIR_BASE/prp-plans"
git init --bare "$PRP_REMOTE" >/dev/null 2>&1
mkdir -p "$PRP_CLAUDE" "$PRP_PLANS"
"$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$PRP_CLAUDE" --no-remote >/dev/null 2>&1
git -C "$PRP_PROJECTS" remote add origin "$PRP_REMOTE" >/dev/null 2>&1
_git_prepare_repo "$PRP_PROJECTS"
git -C "$PRP_PROJECTS" add -A >/dev/null 2>&1
git -C "$PRP_PROJECTS" commit -m "initial" >/dev/null 2>&1
git -C "$PRP_PROJECTS" push -u origin main >/dev/null 2>&1

# --- A symlink to session-sync.sh in a directory without workflow-plans-dir ---
echo "[plans-resolver] push through a symlink still finds the checkout's workflow-plans-dir"
PRP_LINKDIR="$TMPDIR_BASE/prp-linkdir"
mkdir -p "$PRP_LINKDIR"
echo "# prp symlink plan" > "$PRP_PLANS/prp-symlink-plan.md"
ln -s "$DOTFILES_DIR/bin/session-sync.sh" "$PRP_LINKDIR/session-sync.sh" 2>/dev/null || true
if [ ! -L "$PRP_LINKDIR/session-sync.sh" ]; then
    pending "plans-resolver symlink: ln -s did not create a symlink on this platform"
else
    WORKFLOW_PLANS_DIR="$PRP_PLANS" bash "$PRP_LINKDIR/session-sync.sh" push --claude-dir "$PRP_CLAUDE" >/dev/null 2>&1 || true
    if git -C "$PRP_REMOTE" show main:plans/prp-symlink-plan.md >/dev/null 2>&1; then
        pass "plans-resolver symlink: the WORKFLOW_PLANS_DIR plan reached the remote"
    else
        fail "plans-resolver symlink: plans/prp-symlink-plan.md missing on the remote (workflow-plans-dir not found via the link target)"
    fi
fi

# --- A checkout copy lacking bin/workflow-plans-dir warns on stderr ---
echo "[plans-resolver] a checkout without bin/workflow-plans-dir warns instead of silently falling back"
PRP_CO="$TMPDIR_BASE/prp-co"
mkdir -p "$PRP_CO/bin"
cp "$DOTFILES_DIR/bin/session-sync.sh" "$PRP_CO/bin/session-sync.sh"
echo "# prp missing-helper plan" > "$PRP_PLANS/prp-missing-helper.md"
prp_err=$(WORKFLOW_PLANS_DIR="$PRP_PLANS" bash "$PRP_CO/bin/session-sync.sh" push --claude-dir "$PRP_CLAUDE" 2>&1 >/dev/null) || true
if printf '%s' "$prp_err" | grep -q 'workflow-plans-dir'; then
    pass "plans-resolver missing helper: stderr names workflow-plans-dir"
else
    fail "plans-resolver missing helper: no stderr warning naming workflow-plans-dir (got: $prp_err)"
fi
