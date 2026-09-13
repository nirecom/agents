# Tests: install/linux/session-sync-init.sh
# Tags: bin, install, git, session-sync, security, installer, scope:issue-specific
# Part of tests/main-session-sync.sh; sourced after security.sh, whose _sec_run /
# _sec_old_root / _sec_temp_leftovers helpers it reuses.

# TL3 gap (skills/_shared/test-design.md): TL2 — every case here needs a real
# symbolic link. MSYS/Git-Bash on Windows creates none, so those cases report
# pending rather than passing vacuously; the NTFS junction half of the same
# contract is covered by the PowerShell suite.
# Mitigation: checked at WORKFLOW_USER_VERIFIED preflight, category installer.

echo ""
echo "=== session-sync-init.sh \$PROJECTS_DIR containment (#1773) ==="

# The second boundary: security.sh pins $CLAUDE_DIR inside $HOME, this file pins
# $PROJECTS_DIR strictly inside $CLAUDE_DIR. A link at $CLAUDE_DIR/projects
# redirects every write — mkdir, git init, the migration's rm/rename of .git —
# and the outer $HOME check cannot see it, $CLAUDE_DIR itself being legitimate.

# _sec_cont_case <name> <link-target> — attack-scenario shape
# (protection-fix-tests.md Pattern 2): plant `projects` as a symlink to
# <link-target> over a $CLAUDE_DIR that already has a git root, then assert what
# the exploit must not have achieved.
_sec_cont_case() {
    sec_name="$1"
    sec_target="$2"
    sec_claude="$TMPDIR_BASE/cont-$sec_name/.claude"

    _sec_old_root "$sec_claude" ""
    sec_git_before="$_SEC_OLD_HEAD"
    sec_canary="$sec_target/canary.txt"
    mkdir -p "$sec_target"
    printf 'untouched\n' > "$sec_canary"
    sec_before=$(ls -A "$sec_target" 2>/dev/null | sort | tr '\n' ' ' || true)

    ln -s "$sec_target" "$sec_claude/projects" 2>/dev/null || true
    if [ ! -L "$sec_claude/projects" ]; then
        pending "containment/$sec_name: this platform did not create a symlink (ln -s unsupported)"
        return 0
    fi

    # Snapshot AFTER planting the link: the link itself is untracked residue the
    # attack scenario puts there, so the comparable baseline is the armed state.
    # HEAD alone cannot see an uncommitted overwrite of the working tree, so the
    # tracked bytes and `status --porcelain` are what carry "untouched".
    sec_snap_before=$(_sec_tracked_snapshot "$sec_claude")
    sec_status_before=$(_sec_worktree_status "$sec_claude")

    _sec_run --claude-dir "$sec_claude" --no-remote

    sec_after=$(ls -A "$sec_target" 2>/dev/null | sort | tr '\n' ' ' || true)
    sec_git_after=$(git -C "$sec_claude" rev-parse --verify HEAD 2>/dev/null || echo "none")
    sec_canary_now=$(cat "$sec_canary" 2>/dev/null || echo "GONE")
    sec_snap_after=$(_sec_tracked_snapshot "$sec_claude")
    sec_status_after=$(_sec_worktree_status "$sec_claude")
    sec_leftover="$(_sec_temp_leftovers "$sec_target")$(_sec_temp_leftovers "$sec_claude")"

    if [ "$_SEC_RC" -eq 0 ]; then
        fail "containment/$sec_name: installer accepted a projects link leaving \$CLAUDE_DIR"
    elif [ "$sec_canary_now" != "untouched" ]; then
        fail "containment/$sec_name: link target file was modified or deleted ($sec_canary_now)"
    elif [ "$sec_after" != "$sec_before" ]; then
        fail "containment/$sec_name: link target contents changed [$sec_before] -> [$sec_after]"
    elif [ "$sec_git_after" != "$sec_git_before" ] || [ ! -d "$sec_claude/.git" ]; then
        fail "containment/$sec_name: pre-existing \$CLAUDE_DIR/.git was migrated or destroyed"
    elif [ ! -f "$sec_claude/.gitignore" ] || [ ! -f "$sec_claude/.gitattributes" ]; then
        fail "containment/$sec_name: the seed files were removed by a rejected run"
    elif [ "$sec_snap_after" != "$sec_snap_before" ]; then
        fail "containment/$sec_name: the tracked working tree changed under a rejected run"
    elif [ "$sec_status_after" != "$sec_status_before" ]; then
        fail "containment/$sec_name: a rejected run changed the working-tree state ($sec_status_after)"
    elif [ -n "$sec_leftover" ]; then
        fail "containment/$sec_name: transaction artifact left behind: $sec_leftover"
    else
        pass "containment/$sec_name: refused, link target and \$CLAUDE_DIR byte-identical"
    fi
}

# (a) Fully outside $HOME — the classic escape.
_sec_cont_case "outside-home" "$(dirname "$TMPDIR_BASE")/cont-outside-$$"

# (b) Inside $HOME but outside $CLAUDE_DIR — the case an $HOME-only check passes.
# The target is a legitimate part of the user's home and the installer would
# still rm -rf a .git there, so containment is measured against $CLAUDE_DIR.
_sec_cont_case "inside-home-outside-claude" "$HOME/cont-sibling-$$"

# (c) Self-referential: projects -> $CLAUDE_DIR, so $PROJECTS_DIR == $CLAUDE_DIR
# and the migration would move $CLAUDE_DIR/.git onto itself. Equality is a
# rejection here, not a boundary pass.
echo "[security] projects link pointing at \$CLAUDE_DIR itself"
SEC_SELF="$TMPDIR_BASE/cont-self/.claude"
_sec_old_root "$SEC_SELF" ""
SEC_SELF_HEAD="$_SEC_OLD_HEAD"
ln -s "$SEC_SELF" "$SEC_SELF/projects" 2>/dev/null || true
if [ ! -L "$SEC_SELF/projects" ]; then
    pending "containment/self-reference: this platform did not create a symlink"
else
    # Baseline taken with the link already planted, for the same reason as
    # _sec_cont_case: the link is part of the attack, not of the damage.
    SEC_SELF_SNAP=$(_sec_tracked_snapshot "$SEC_SELF")
    SEC_SELF_STATUS=$(_sec_worktree_status "$SEC_SELF")
    _sec_run --claude-dir "$SEC_SELF" --no-remote
    sec_self_head_after=$(git -C "$SEC_SELF" rev-parse --verify HEAD 2>/dev/null || echo "none")
    sec_self_snap_after=$(_sec_tracked_snapshot "$SEC_SELF")
    sec_self_status_after=$(_sec_worktree_status "$SEC_SELF")
    sec_self_leftover=$(_sec_temp_leftovers "$SEC_SELF")
    if [ "$_SEC_RC" -eq 0 ]; then
        fail "containment/self-reference: installer accepted projects == \$CLAUDE_DIR"
    elif [ ! -d "$SEC_SELF/.git" ] || [ "$sec_self_head_after" != "$SEC_SELF_HEAD" ]; then
        fail "containment/self-reference: the repo it pointed at was migrated or destroyed"
    elif [ ! -f "$SEC_SELF/old-session.jsonl" ] || [ ! -f "$SEC_SELF/.gitignore" ] || [ ! -f "$SEC_SELF/.gitattributes" ]; then
        fail "containment/self-reference: pre-existing session or seed data disappeared"
    elif [ "$sec_self_snap_after" != "$SEC_SELF_SNAP" ]; then
        fail "containment/self-reference: the tracked working tree changed under a rejected run"
    elif [ "$sec_self_status_after" != "$SEC_SELF_STATUS" ]; then
        fail "containment/self-reference: a rejected run changed the working-tree state ($sec_self_status_after)"
    elif [ -n "$sec_self_leftover" ]; then
        fail "containment/self-reference: transaction artifact left behind: $sec_self_leftover"
    else
        pass "containment/self-reference: refused with the repo byte-identical"
    fi
fi

# Real directory, correctly placed: the same guard must not refuse the ordinary
# layout it exists to protect (classifier both-direction, Pattern 4).
echo "[security] a real \$CLAUDE_DIR/projects directory is still accepted"
SEC_OK="$TMPDIR_BASE/cont-ok/.claude"
mkdir -p "$SEC_OK/projects"
_sec_run --claude-dir "$SEC_OK" --no-remote
if [ "$_SEC_RC" -eq 0 ] && [ -d "$SEC_OK/projects/.git" ]; then
    pass "containment guard leaves the legitimate layout alone"
else
    fail "containment guard refused the legitimate layout (rc=$_SEC_RC, output: $_SEC_OUT)"
fi

# --- Normalized `..` traversal in the --claude-dir argument itself -----------
# Every case above escapes through a link. This one escapes through the literal
# argument: "$HOME/inside/../../outside/.claude" starts with "$HOME/" as a
# string and resolves outside $HOME, so a `case "$p" in "$HOME"/*)` prefix check
# accepts it and the run proceeds to rm -rf a repo that is not in the profile at
# all. Only real resolution (_resolve_realpath) can tell the two apart, and the
# payoff is measured, not just the verdict: a committed repo is planted at the
# resolved location first.
echo "[security] normalized .. traversal escaping \$HOME"
SEC_TRAV_ORIGIN="https://example.invalid/traverse.git"
SEC_TRAV_ROOT="$(dirname "$TMPDIR_BASE")/cont-traverse-$$"
SEC_TRAV_TARGET="$SEC_TRAV_ROOT/.claude"
SEC_TRAV_ARG="$HOME/inside/../../cont-traverse-$$/.claude"
mkdir -p "$HOME/inside"
_sec_old_root "$SEC_TRAV_TARGET" "$SEC_TRAV_ORIGIN"
SEC_TRAV_HEAD="$_SEC_OLD_HEAD"
# Content, not just HEAD: an uncommitted overwrite of the working tree would
# leave HEAD untouched, so the bytes and a clean status carry the claim.
SEC_TRAV_SNAP=$(_sec_tracked_snapshot "$SEC_TRAV_TARGET")
SEC_TRAV_STATUS=$(_sec_worktree_status "$SEC_TRAV_TARGET")
printf 'untouched\n' > "$SEC_TRAV_ROOT/canary.txt"

# A matching --expected-origin removes provenance as a possible reason for the
# refusal: if containment were naive, this run would migrate for real.
_sec_run --claude-dir "$SEC_TRAV_ARG" --expected-origin "$SEC_TRAV_ORIGIN" --no-remote

SEC_TRAV_HEAD_AFTER=$(git -C "$SEC_TRAV_TARGET" rev-parse --verify HEAD 2>/dev/null || echo "none")
SEC_TRAV_CANARY=$(cat "$SEC_TRAV_ROOT/canary.txt" 2>/dev/null || echo "GONE")
SEC_TRAV_SNAP_AFTER=$(_sec_tracked_snapshot "$SEC_TRAV_TARGET")
SEC_TRAV_STATUS_AFTER=$(_sec_worktree_status "$SEC_TRAV_TARGET")
SEC_TRAV_LEFT="$(_sec_temp_leftovers "$SEC_TRAV_TARGET")$(_sec_temp_leftovers "$SEC_TRAV_ROOT")"
if [ -n "$SEC_TRAV_STATUS" ]; then
    fail "containment/traversal: the fixture was already dirty before the run ($SEC_TRAV_STATUS)"
elif [ "$_SEC_RC" -eq 0 ]; then
    fail "containment/traversal: a normalized \`..\` escape out of \$HOME was accepted"
elif [ "$SEC_TRAV_CANARY" != "untouched" ]; then
    fail "containment/traversal: the canary outside \$HOME was modified ($SEC_TRAV_CANARY)"
elif [ ! -d "$SEC_TRAV_TARGET/.git" ] || [ "$SEC_TRAV_HEAD_AFTER" != "$SEC_TRAV_HEAD" ]; then
    fail "containment/traversal: the repo at the resolved path was migrated or destroyed"
elif [ ! -f "$SEC_TRAV_TARGET/old-session.jsonl" ] || [ ! -f "$SEC_TRAV_TARGET/.gitignore" ] || [ ! -f "$SEC_TRAV_TARGET/.gitattributes" ]; then
    fail "containment/traversal: the resolved path lost tracked or seed files"
elif [ "$SEC_TRAV_SNAP_AFTER" != "$SEC_TRAV_SNAP" ]; then
    fail "containment/traversal: the tracked working tree outside \$HOME was rewritten"
elif [ -n "$SEC_TRAV_STATUS_AFTER" ]; then
    fail "containment/traversal: a rejected run left working-tree residue ($SEC_TRAV_STATUS_AFTER)"
elif [ -e "$SEC_TRAV_TARGET/projects" ] || [ -n "$SEC_TRAV_LEFT" ]; then
    fail "containment/traversal: the rejected run still wrote outside \$HOME ($SEC_TRAV_LEFT)"
else
    pass "containment/traversal: refused with the outside repo byte-identical and clean"
fi

# The other direction (Pattern 4): `..` is not itself the offence. A path whose
# segments cancel back inside $HOME normalizes to a legitimate location, so a
# guard that rejects on the substring rather than on the resolved path fails here.
echo "[security] \`..\` segments that normalize back inside \$HOME are accepted"
SEC_TRAV_OK="$HOME/inside/../cont-traverse-ok-$$/.claude"
_sec_run --claude-dir "$SEC_TRAV_OK" --no-remote
if [ "$_SEC_RC" -eq 0 ] && [ -d "$HOME/cont-traverse-ok-$$/.claude/projects/.git" ]; then
    pass "containment/traversal-inside: resolved inside \$HOME and accepted"
else
    fail "containment/traversal-inside: a path resolving inside \$HOME was refused (rc=$_SEC_RC, output: $_SEC_OUT)"
fi

rm -rf "$(dirname "$TMPDIR_BASE")/cont-outside-$$" 2>/dev/null || true
rm -rf "$SEC_TRAV_ROOT" 2>/dev/null || true
