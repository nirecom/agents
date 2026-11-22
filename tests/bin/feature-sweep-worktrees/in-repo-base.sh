#!/bin/bash
# Tests: bin/sweep-worktrees.sh
# Tags: feature-1610, feature-1849, sweep, worktree, in-repo-base, orphan-dir, repo-flag, unowned-leftover, config-dependent, scope:issue-specific, TL2, pwsh-not-required
# TL3 gap: a real sibling repo with live Windows file locks and a native EnterWorktree checkout is
# not reproduced; the fixtures are temp repos and hand-built leftovers.
#
# #1610: with WORKTREE_BASE_DIR unset the base is each repo's own <repo>/.claude/worktrees. The
# sweep scans the CWD repo plus every --repo <dir>; on an explicit shared base a leaf is assigned to
# at most one owner (gitlink reverse lookup, else notes `Main repo:` + basename), and a leaf with
# no proven owner is kept and reported on stderr as `unowned leftover:`. HOME, USERPROFILE and
# AGENTS_MAIN_ROOT are pinned to fixture dirs so the developer's real base is never scanned.

_IN_REPO_BASE_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# shellcheck source=./_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

. "$_IN_REPO_BASE_SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

# _lib.sh made TMPDIR_BASE before harness.sh pinned TMPDIR into the run root, and the command
# guard refuses git writes outside the run root; re-create it inside (the _lib trap removes it).
rmdir "$TMPDIR_BASE" 2>/dev/null
TMPDIR_BASE="$(make_tmp)"

harness_isolate "$TMPDIR_BASE/iso"
FX_HOME="$TMPDIR_BASE/home"
FX_CONF="$TMPDIR_BASE/conf"
mkdir -p "$FX_HOME" "$FX_CONF"

# fx_repo <dir> — a main-branch repo with hooks disabled.
fx_repo() {
    init_repo "$1"
    git -C "$1" config core.hooksPath /dev/null
}

fwd() { node -e "console.log(process.argv[1].replace(/\\\\/g,'/'))" -- "$(np "$1")" 2>/dev/null; }

# fx_orphan <dir> <main repo for notes|-> — a stale .git-less leftover, notes optional.
fx_orphan() {
    mkdir -p "$1"
    if [ "$2" != "-" ]; then printf '# Worktree Notes\nMain repo: %s\n' "$(fwd "$2")" > "$1/WORKTREE_NOTES.md"; fi
    printf 'x\n' > "$1/leftover.txt"
    make_stale "$1"
    make_stale "$(dirname "$1")"
}

# fx_gitlink_leftover <repo> <dir> <branch> — a WE-11 leftover whose admin dir was pruned.
fx_gitlink_leftover() {
    add_worktree "$1" "$2" "$3"
    mv "$2" "$2.hidden"
    git -C "$1" worktree prune
    mv "$2.hidden" "$2"
    make_stale "$2"
    make_stale "$(dirname "$2")"
}

# sweep_in <cwd> <base|-> <args...> — sets OUT (stdout), ERR (stderr), RC.
sweep_in() {
    local cwd="$1" base="$2"; shift 2
    local errf="$TMPDIR_BASE/sweep.err"
    local -a envs=(-u WORKTREE_BASE_DIR -u CLAUDE_CODE_SESSION_ID HOME="$FX_HOME" USERPROFILE="$(np "$FX_HOME")" AGENTS_MAIN_ROOT="$FX_CONF" SWEEP_SKIP_GH=1)
    [ "$base" != "-" ] && envs+=(WORKTREE_BASE_DIR="$base")
    OUT="$(cd "$cwd" && run_with_timeout 120 env "${envs[@]}" bash "$SWEEP" --apply --ci-mode --skip-gh-check "$@" 2>"$errf")"
    RC=$?
    ERR="$(cat "$errf" 2>/dev/null)"
}

R1="$TMPDIR_BASE/alpha"
R2="$TMPDIR_BASE/beta"
fx_repo "$R1"
fx_repo "$R2"

case_begin "default-base-is-in-repo" "bin/sweep-worktrees.sh"
orphan="$R1/.claude/worktrees/t-default/alpha"
fx_orphan "$orphan" "$R1"
sweep_in "$R1" -
if [ "$RC" -eq 0 ] && [ ! -d "$orphan" ] && [ "$(ci_field "$OUT" orphan_dirs_removed)" = "1" ]; then
    pass "S1 unset WORKTREE_BASE_DIR scans <repo>/.claude/worktrees and removes the owned orphan"
else
    fail "S1 default in-repo base" "rc=$RC exists=$([ -d "$orphan" ] && echo yes || echo no) out=$OUT err=$ERR"
fi
case_end

case_begin "repo-flag-scans-unregistered-sibling-repo" "bin/sweep-worktrees.sh"
sib="$R2/.claude/worktrees/t-sib/beta"
fx_orphan "$sib" "$R2"
sweep_in "$R1" -
if [ -d "$sib" ]; then
    pass "S2a without --repo the sibling repo's base is not scanned"
else
    fail "S2a without --repo the sibling repo's base is not scanned" "removed: $sib"
fi
sweep_in "$R1" - --repo "$(np "$R2")"
if [ "$RC" -eq 0 ] && [ ! -d "$sib" ]; then
    pass "S2b --repo <sibling> removes its owned orphan"
else
    fail "S2b --repo <sibling> removes its owned orphan" "rc=$RC out=$OUT err=$ERR"
fi
# The CLI got the owner via --repo: with the CWD repo's base it would refuse and count a failure.
if [ "$(ci_field "$OUT" orphan_dirs_skipped_failed)" = "0" ] && ! printf '%s' "$ERR" | grep -q 'cleanup-orphan-dir failed'; then
    pass "S2c cleanup-orphan-dir receives the sibling repo as --repo (no refusal)"
else
    fail "S2c cleanup-orphan-dir receives the sibling repo as --repo" "out=$OUT err=$ERR"
fi
case_end

case_begin "repo-flag-not-a-repo-warns-and-continues" "bin/sweep-worktrees.sh"
sweep_in "$R1" - --repo "$TMPDIR_BASE/not-a-repo"
if [ "$RC" -eq 0 ] && printf '%s' "$ERR" | grep -qi 'warn'; then
    pass "S3 --repo on a non-repo is skipped with a warning"
else
    fail "S3 --repo on a non-repo is skipped with a warning" "rc=$RC err=$ERR"
fi
case_end

SHARED="$TMPDIR_BASE/shared"
mkdir -p "$SHARED"

case_begin "shared-base-gitlink-reverse-lookup" "bin/sweep-worktrees.sh"
gl="$SHARED/t-gl/beta"
fx_gitlink_leftover "$R2" "$gl" feature/t-gl
sweep_in "$R1" "$(np "$SHARED")" --repo "$(np "$R2")"
if [ "$RC" -eq 0 ] && [ ! -d "$gl" ]; then
    pass "S4 shared base: a gitlink leftover is owned by its reverse-looked-up repo and removed"
else
    fail "S4 shared base gitlink reverse lookup" "rc=$RC out=$OUT err=$ERR"
fi
case_end

case_begin "shared-base-notes-owner-removed-once" "bin/sweep-worktrees.sh"
nl="$SHARED/t-notes/beta"
fx_orphan "$nl" "$R2"
sweep_in "$R2" "$(np "$SHARED")" --repo "$(np "$R2")" --repo "$(np "$R2")"
if [ "$RC" -eq 0 ] && [ ! -d "$nl" ] && [ "$(ci_field "$OUT" orphan_dirs_removed)" = "1" ] \
    && [ "$(ci_field "$OUT" orphan_dirs_skipped_failed)" = "0" ]; then
    pass "S5 shared base: a .git-less leftover whose notes name the owner is removed exactly once"
else
    fail "S5 shared base notes owner, processed once" "rc=$RC out=$OUT err=$ERR"
fi
case_end

case_begin "shared-base-unowned-leftover-kept-and-reported" "bin/sweep-worktrees.sh"
nonotes="$SHARED/t-nonotes/beta"
fx_orphan "$nonotes" -
mkdir -p "$TMPDIR_BASE/elsewhere/beta"
basename_only="$SHARED/t-basename/beta"
fx_orphan "$basename_only" "$TMPDIR_BASE/elsewhere/beta"
sweep_in "$R1" "$(np "$SHARED")" --repo "$(np "$R2")"
if [ -d "$nonotes" ] && [ -d "$basename_only" ]; then
    pass "S6a leftovers with no notes or a basename-only match are kept"
else
    fail "S6a unowned leftovers kept" "nonotes=$([ -d "$nonotes" ] && echo kept || echo gone) basename=$([ -d "$basename_only" ] && echo kept || echo gone)"
fi
if [ "$(printf '%s\n' "$ERR" | grep -c '^unowned leftover: ')" -ge 2 ]; then
    pass "S6b each unowned leftover is reported on stderr"
else
    fail "S6b each unowned leftover is reported on stderr" "err=$ERR"
fi
case_end

case_begin "native-claude-worktree-not-deleted" "bin/sweep-worktrees.sh"
native="$R1/.claude/worktrees/native-x"
add_worktree "$R1" "$native" feature/native-x
mkdir -p "$native/alpha"
printf 'x\n' > "$native/alpha/file.txt"
make_stale "$native/alpha"
sweep_in "$R1" -
if [ -d "$native/alpha" ] && [ -f "$native/.git" ]; then
    pass "S7 a native .claude/worktrees/<name> worktree and its repo-named child survive"
else
    fail "S7 native worktree survives" "rc=$RC out=$OUT err=$ERR"
fi
# Survival proves nothing unless the same run exited 0 and actually walked the native worktree.
scanned="$(ci_field "$OUT" scanned)"
if [ "$RC" -eq 0 ] && [[ "$scanned" =~ ^[0-9]+$ ]] && [ "$scanned" -ge 2 ]; then
    pass "S7b the sweep exited 0 and scanned the main plus the native worktree (scanned=$scanned)"
else
    fail "S7b the sweep exited 0 and scanned the native worktree" "rc=$RC scanned=$scanned out=$OUT err=$ERR"
fi
case_end

# Two scanned repos share the basename `proj` on one explicit base. The CWD is a third repo so the
# registry pass (CWD repo only) never touches the leaves: only the orphan pass and its gates judge them.
PA="$TMPDIR_BASE/a/proj"
PB="$TMPDIR_BASE/b/proj"
PC="$TMPDIR_BASE/gamma"
fx_repo "$PA"
fx_repo "$PB"
fx_repo "$PC"
DUP="$TMPDIR_BASE/dup-shared"
mkdir -p "$DUP"

case_begin "same-basename-registered-leftover-kept" "bin/sweep-worktrees.sh"
reg="$DUP/t-reg/proj"
add_worktree "$PA" "$reg" feature/t-reg
rm -f "$reg/.git"
printf '# Worktree Notes\nMain repo: %s\n' "$(fwd "$PA")" > "$reg/WORKTREE_NOTES.md"
make_stale "$reg"
make_stale "$(dirname "$reg")"
sweep_in "$PC" "$(np "$DUP")" --repo "$(np "$PA")" --repo "$(np "$PB")"
if [ "$RC" -eq 0 ] && [ -d "$reg" ] && [ -f "$reg/WORKTREE_NOTES.md" ]; then
    pass "S8a a .git-less leaf still registered in its notes owner a/proj survives the sweep"
else
    fail "S8a registered same-basename leaf survives" "rc=$RC exists=$([ -d "$reg" ] && echo yes || echo no) out=$OUT err=$ERR"
fi
if [ "$(ci_field "$OUT" orphan_dirs_skipped_registered)" -ge 1 ] 2>/dev/null \
    && [ "$(ci_field "$OUT" orphan_dirs_removed)" = "0" ] && [ "$(ci_field "$OUT" orphan_dirs_skipped_failed)" = "0" ] \
    && ! printf '%s\n' "$ERR" | grep -qF "$reg"; then
    pass "S8b the leaf is kept by the registry gate, not by a failed removal or an unowned report"
else
    fail "S8b registry gate keeps the same-basename leaf" "out=$OUT err=$ERR"
fi
case_end

case_begin "same-basename-unregistered-leftover-follows-notes-owner" "bin/sweep-worktrees.sh"
unreg="$DUP/t-unreg/proj"
fx_orphan "$unreg" "$PB"
sweep_in "$PC" "$(np "$DUP")" --repo "$(np "$PA")" --repo "$(np "$PB")"
if [ "$RC" -eq 0 ] && [ ! -d "$unreg" ] && [ "$(ci_field "$OUT" orphan_dirs_removed)" = "1" ] \
    && [ "$(ci_field "$OUT" orphan_dirs_skipped_failed)" = "0" ] && ! printf '%s\n' "$ERR" | grep -q 'unowned leftover: '; then
    pass "S9 control: an unregistered stale leaf whose notes name b/proj is removed once through its notes owner"
else
    fail "S9 control: unregistered same-basename leaf follows the notes owner" "rc=$RC exists=$([ -d "$unreg" ] && echo yes || echo no) out=$OUT err=$ERR"
fi
if [ -d "$reg" ]; then
    pass "S9b the registered a/proj leaf from S8 is still kept on the second sweep"
else
    fail "S9b the registered a/proj leaf was removed by the second sweep" "out=$OUT err=$ERR"
fi
case_end

# sweep_in passes --apply first; a later --dry-run wins (last write-mode flag sets the mode).
case_begin "in-repo-base-dry-run-reports-and-keeps" "bin/sweep-worktrees.sh"
dry="$R1/.claude/worktrees/t-dry/alpha"
fx_orphan "$dry" "$R1"
sweep_in "$R1" - --dry-run
if [ "$RC" -eq 0 ] && [ -d "$dry" ] && printf '%s\n' "$ERR" | grep 'would remove orphan dir: ' | grep -q 't-dry/alpha'; then
    pass "S10 dry-run prints 'would remove orphan dir' for the in-repo orphan and keeps it"
else
    fail "S10 dry-run reports and keeps the in-repo orphan" "rc=$RC exists=$([ -d "$dry" ] && echo yes || echo no) out=$OUT err=$ERR"
fi
case_end

case_begin "non-repo-cwd-without-repo-flag-errors" "bin/sweep-worktrees.sh"
nr_cwd="$TMPDIR_BASE/not-a-repo-cwd"
mkdir -p "$nr_cwd"
sweep_in "$nr_cwd" -
if [ "$RC" -ne 0 ] && printf '%s\n' "$ERR" | grep -q '^ERROR: ' && [ -d "$dry" ]; then
    pass "S11 a non-repo CWD without --repo exits non-zero with an ERROR line and removes nothing"
else
    fail "S11 non-repo CWD without --repo errors" "rc=$RC exists=$([ -d "$dry" ] && echo yes || echo no) out=$OUT err=$ERR"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
