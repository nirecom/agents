# Tests: install/linux/session-sync-init.sh
# Tags: bin, install, git, session-sync, security, installer, scope:issue-specific
# Part of tests/main-session-sync.sh; sourced after security.sh, whose _sec_run /
# _sec_old_root / _sec_temp_leftovers helpers it reuses.

echo ""
echo "=== session-sync-init.sh migration end state (#1773) ==="

# detail.md D: the transaction's terminal states are "everything moved under its
# bare final name in $PROJECTS_DIR" or "$CLAUDE_DIR exactly as it was". A `.bak`
# state exists at neither end — the pre-#1773 tests asserted one and were wrong.

SEC_MIG_ORIGIN="https://example.invalid/migration.git"

# --- Success path over a clean destination ---
echo "[security] migration moves the repo under bare final names"
SEC_MIG="$TMPDIR_BASE/mig-clean/.claude"
_sec_old_root "$SEC_MIG" "$SEC_MIG_ORIGIN"
SEC_MIG_HEAD="$_SEC_OLD_HEAD"
_sec_run --claude-dir "$SEC_MIG" --expected-origin "$SEC_MIG_ORIGIN" --no-remote
SEC_MIG_HEAD_AFTER=$(git -C "$SEC_MIG/projects" rev-parse --verify HEAD 2>/dev/null || echo "none")
if [ "$_SEC_RC" -ne 0 ]; then
    fail "migration/clean: installer failed (rc=$_SEC_RC, output: $_SEC_OUT)"
elif [ "$SEC_MIG_HEAD_AFTER" != "$SEC_MIG_HEAD" ]; then
    fail "migration/clean: destination repo is not the migrated one ($SEC_MIG_HEAD_AFTER)"
elif [ ! -f "$SEC_MIG/projects/.gitignore" ] || [ ! -f "$SEC_MIG/projects/.gitattributes" ]; then
    fail "migration/clean: seed files are missing their bare final names in \$PROJECTS_DIR"
else
    pass "migration/clean: repo and seed files landed under bare final names"
fi

# The three names must be gone from $CLAUDE_DIR — including any `.bak` form. The
# grep covers `.git`, `.gitignore`, `.gitattributes` and every suffixed variant,
# so a leftover under any staging or backup name fails here.
echo "[security] nothing git-shaped is left in \$CLAUDE_DIR"
SEC_MIG_RESIDUE=$(ls -A "$SEC_MIG" 2>/dev/null | grep -E '^\.git(ignore|attributes)?(\.|$)' | tr '\n' ' ' || true)
if [ -z "$SEC_MIG_RESIDUE" ]; then
    pass "migration/clean: \$CLAUDE_DIR holds no git metadata under any name"
else
    fail "migration/clean: \$CLAUDE_DIR still holds: $SEC_MIG_RESIDUE"
fi

# The installer normalizes the two seed files after migrating, so their content
# must be the canonical one — asserting the old content would contradict the
# post-migration normalization block the design leaves unchanged.
echo "[security] seed files carry their canonical post-install content"
if grep -q 'merge=union' "$SEC_MIG/projects/.gitattributes" 2>/dev/null; then
    pass "migration/clean: .gitattributes normalized after the move"
else
    fail "migration/clean: .gitattributes was not normalized after the move"
fi

# --- Only files under projects/ are restored to the new layout ---
# The legacy buggy installer's repo tracked projects/<enc>/*.jsonl plus a couple
# of root-level files. Migration moves only the three git names, so the session
# files stay at their true physical path and the restore has nothing to do; a
# restore run against $PROJECTS_DIR as the work-tree, or one without the
# `projects` pathspec, would instead deposit copies one level too deep.
echo "[security] the restore does not re-scatter the old root"
SEC_SCAT="$TMPDIR_BASE/mig-scatter/.claude"
mkdir -p "$SEC_SCAT/projects/enc-proj"
git init "$SEC_SCAT" >/dev/null 2>&1
_git_prepare_repo "$SEC_SCAT"
git -C "$SEC_SCAT" remote add origin "$SEC_MIG_ORIGIN" >/dev/null 2>&1
printf 'old-gitignore\n' > "$SEC_SCAT/.gitignore"
printf 'root-level\n' > "$SEC_SCAT/root-level.jsonl"
printf 'session-payload\n' > "$SEC_SCAT/projects/enc-proj/session.jsonl"
git -C "$SEC_SCAT" add -A >/dev/null 2>&1
git -C "$SEC_SCAT" commit -q -m "legacy layout" >/dev/null 2>&1

_sec_run --claude-dir "$SEC_SCAT" --expected-origin "$SEC_MIG_ORIGIN" --no-remote

if [ "$_SEC_RC" -ne 0 ]; then
    fail "migration/scatter: installer failed (rc=$_SEC_RC, output: $_SEC_OUT)"
elif [ "$(cat "$SEC_SCAT/projects/enc-proj/session.jsonl" 2>/dev/null)" != "session-payload" ]; then
    fail "migration/scatter: the session file under projects/ did not survive the move"
elif [ -e "$SEC_SCAT/projects/projects" ]; then
    fail "migration/scatter: the restore recreated projects/ one level too deep"
elif [ -e "$SEC_SCAT/projects/root-level.jsonl" ]; then
    fail "migration/scatter: a root-level tracked file was re-scattered into \$PROJECTS_DIR"
elif [ ! -f "$SEC_SCAT/root-level.jsonl" ]; then
    fail "migration/scatter: the root-level tracked file was destroyed"
else
    pass "migration/scatter: projects/ preserved in place, the old root not re-scattered"
fi

# --- Refusal over a destination repo that cannot identify itself ---
# The destination loses its own .git to this migration, so a matching origin is
# the only accepted proof. An origin-less repo is not "nothing contradicting us":
# it is the user's own unpublished work, and consuming it is the C2 defect.
echo "[security] migration onto an origin-less destination repo"
SEC_COL="$TMPDIR_BASE/mig-collide/.claude"
_sec_old_root "$SEC_COL" "$SEC_MIG_ORIGIN"
SEC_COL_HEAD="$_SEC_OLD_HEAD"
mkdir -p "$SEC_COL/projects"
git init "$SEC_COL/projects" >/dev/null 2>&1
_git_prepare_repo "$SEC_COL/projects"
printf 'incumbent\n' > "$SEC_COL/projects/incumbent.txt"
printf 'incumbent-ignore\n' > "$SEC_COL/projects/.gitignore"
printf 'incumbent-attrs\n' > "$SEC_COL/projects/.gitattributes"
git -C "$SEC_COL/projects" add -A >/dev/null 2>&1
git -C "$SEC_COL/projects" commit -q -m "incumbent repo" >/dev/null 2>&1
SEC_COL_INCUMBENT=$(git -C "$SEC_COL/projects" rev-parse --verify HEAD 2>/dev/null || echo "none")
SEC_COL_SNAP=$(_sec_tracked_snapshot "$SEC_COL/projects")

_sec_run --claude-dir "$SEC_COL" --expected-origin "$SEC_MIG_ORIGIN" --no-remote

SEC_COL_AFTER=$(git -C "$SEC_COL/projects" rev-parse --verify HEAD 2>/dev/null || echo "none")
SEC_COL_LEFT=$(_sec_temp_leftovers "$SEC_COL/projects")
SEC_COL_SRC_LEFT=$(_sec_temp_leftovers "$SEC_COL")
if [ "$_SEC_RC" -eq 0 ]; then
    fail "migration/collide: an origin-less destination repo was consumed (rc=0)"
elif [ "$SEC_COL_AFTER" != "$SEC_COL_INCUMBENT" ]; then
    fail "migration/collide: the incumbent repo was replaced by a refused run ($SEC_COL_AFTER)"
elif [ "$(_sec_tracked_snapshot "$SEC_COL/projects")" != "$SEC_COL_SNAP" ]; then
    fail "migration/collide: the incumbent working tree changed under a refused run"
elif [ ! -d "$SEC_COL/.git" ] || [ "$(git -C "$SEC_COL" rev-parse --verify HEAD 2>/dev/null)" != "$SEC_COL_HEAD" ]; then
    fail "migration/collide: the old repo was moved or damaged by a refused run"
elif [ -n "$SEC_COL_LEFT" ] || [ -n "$SEC_COL_SRC_LEFT" ]; then
    fail "migration/collide: staging artifact survived: $SEC_COL_LEFT$SEC_COL_SRC_LEFT"
else
    pass "migration/collide: origin-less destination refused with both repos intact"
fi

# --- Success path over a destination that identifies itself and collides ---
# The other direction (Pattern 4): once the destination proves it is the same
# session-sync repo, Phase 1a stages the incumbents aside, Phase 2 promotes the
# incoming copies onto the bare names, and Phase 3 removes the staged incumbents.
echo "[security] migration over a colliding destination that matches origin"
SEC_COL2="$TMPDIR_BASE/mig-collide-ok/.claude"
_sec_old_root "$SEC_COL2" "$SEC_MIG_ORIGIN"
SEC_COL2_HEAD="$_SEC_OLD_HEAD"
mkdir -p "$SEC_COL2/projects"
git init "$SEC_COL2/projects" >/dev/null 2>&1
_git_prepare_repo "$SEC_COL2/projects"
git -C "$SEC_COL2/projects" remote add origin "$SEC_MIG_ORIGIN" >/dev/null 2>&1
printf 'incumbent\n' > "$SEC_COL2/projects/incumbent.txt"
printf 'incumbent-ignore\n' > "$SEC_COL2/projects/.gitignore"
printf 'incumbent-attrs\n' > "$SEC_COL2/projects/.gitattributes"
git -C "$SEC_COL2/projects" add -A >/dev/null 2>&1
git -C "$SEC_COL2/projects" commit -q -m "incumbent repo" >/dev/null 2>&1
SEC_COL2_INCUMBENT=$(git -C "$SEC_COL2/projects" rev-parse --verify HEAD 2>/dev/null || echo "none")

_sec_run --claude-dir "$SEC_COL2" --expected-origin "$SEC_MIG_ORIGIN" --no-remote

SEC_COL2_AFTER=$(git -C "$SEC_COL2/projects" rev-parse --verify HEAD 2>/dev/null || echo "none")
SEC_COL2_LEFT=$(_sec_temp_leftovers "$SEC_COL2/projects")
SEC_COL2_SRC_LEFT=$(_sec_temp_leftovers "$SEC_COL2")
if [ "$_SEC_RC" -ne 0 ]; then
    fail "migration/collide-ok: installer failed (rc=$_SEC_RC, output: $_SEC_OUT)"
elif [ "$SEC_COL2_AFTER" = "$SEC_COL2_INCUMBENT" ]; then
    fail "migration/collide-ok: the incumbent repo survived — the migration was skipped"
elif [ "$SEC_COL2_AFTER" != "$SEC_COL2_HEAD" ]; then
    fail "migration/collide-ok: destination repo is neither the incumbent nor the migrated one ($SEC_COL2_AFTER)"
elif [ -n "$SEC_COL2_LEFT" ] || [ -n "$SEC_COL2_SRC_LEFT" ]; then
    fail "migration/collide-ok: staging artifact survived: $SEC_COL2_LEFT$SEC_COL2_SRC_LEFT"
else
    pass "migration/collide-ok: incoming repo promoted, staged incumbents cleaned up"
fi

# Phase 3 removes the staged incumbents rather than renaming them to a `.bak`
# name the user would have to clean up by hand.
echo "[security] no backup-suffixed residue in \$PROJECTS_DIR"
SEC_COL2_BAK=$(ls -A "$SEC_COL2/projects" 2>/dev/null | grep -E '\.(bak|old|migrate-tmp)' | tr '\n' ' ' || true)
if [ -z "$SEC_COL2_BAK" ]; then
    pass "migration/collide-ok: \$PROJECTS_DIR carries no backup-suffixed residue"
else
    fail "migration/collide-ok: \$PROJECTS_DIR carries residue: $SEC_COL2_BAK"
fi

# --- Idempotence: a second run has nothing left to migrate ---
# rules/test/installer.md — re-running must not fail nor resurrect the old layout.
echo "[security] re-running after a successful migration is a no-op"
_sec_run --claude-dir "$SEC_MIG" --expected-origin "$SEC_MIG_ORIGIN" --no-remote
SEC_MIG_HEAD_2=$(git -C "$SEC_MIG/projects" rev-parse --verify HEAD 2>/dev/null || echo "none")
if [ "$_SEC_RC" -eq 0 ] && [ "$SEC_MIG_HEAD_2" = "$SEC_MIG_HEAD" ] && [ ! -e "$SEC_MIG/.git" ]; then
    pass "migration is idempotent on a second run"
else
    fail "second run disturbed the migrated layout (rc=$_SEC_RC head=$SEC_MIG_HEAD_2)"
fi
