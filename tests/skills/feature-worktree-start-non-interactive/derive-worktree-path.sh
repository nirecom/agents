#!/bin/bash
# tests/skills/feature-worktree-start-non-interactive/derive-worktree-path.sh
# Tests: skills/worktree-start/scripts/derive-worktree-name.sh
# Tags: worktree, start, derivation, worktree-base, TL2, scope:issue-specific
# #1610: WORKTREE_BASE= and WORKTREE_PATH=<base>/<TASK>/<REPO>; the default base is
# <repo>/.claude/worktrees, an explicit WORKTREE_BASE_DIR wins.
# Part of the feature-worktree-start-non-interactive suite — see the dispatcher.

_ISOLATION_TMP_ROOT="$(mktemp -d)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans" "$_ISOLATION_TMP_ROOT/home"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"
# A pinned HOME keeps a ~/git/worktrees fallback from matching the developer's tree.
export HOME="$_ISOLATION_TMP_ROOT/home"
unset WORKTREE_BASE_DIR

_DERIVE_WORKTREE_PATH_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$_DERIVE_WORKTREE_PATH_SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
setup_fixture
trap 'rm -rf "$_ISOLATION_TMP_ROOT" "$FIXTURE"' EXIT

PATH_REPO="$_ISOLATION_TMP_ROOT/path-repo"
mkdir -p "$PATH_REPO"
git -C "$PATH_REPO" init -q >/dev/null 2>&1
git -C "$PATH_REPO" config core.hooksPath /dev/null

# norm <path> — one spelling per path: mixed form, forward slashes, lowercase, no trailing /.
norm() {
    local p="$1"
    if command -v cygpath >/dev/null 2>&1 && [ -n "$p" ]; then p="$(cygpath -m "$p")"; fi
    p="${p//\\//}"; p="${p%/}"
    printf '%s' "$p" | tr '[:upper:]' '[:lower:]'
}
key() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }
key_count() { printf '%s\n' "$OUT" | grep -c "^$1=" || true; }

case_begin "default-base-is-in-repo" "skills/worktree-start/scripts/derive-worktree-name.sh"
run_derive P1 --intent "$INTENT_B1" --repo-dir "$PATH_REPO"
WANT_BASE="$(norm "$PATH_REPO/.claude/worktrees")"
GOT_BASE="$(norm "$(key WORKTREE_BASE)")"
if [ "$RC" -eq 0 ] && [ "$GOT_BASE" = "$WANT_BASE" ]; then
    pass "P1: WORKTREE_BASE defaults to <repo>/.claude/worktrees"
else
    fail "P1: want WORKTREE_BASE=$WANT_BASE (rc=$RC, out='$OUT', err='$ERR')"
fi
case "$GOT_BASE" in
    "$(norm "$HOME")"/*) fail "P1: default base is under HOME ($GOT_BASE)" ;;
    "") fail "P1: no WORKTREE_BASE emitted, so it cannot be checked against HOME" ;;
    *) pass "P1: the default base is not under HOME (~/git/worktrees is retired)" ;;
esac
case_end

case_begin "worktree-path-is-base-task-repo" "skills/worktree-start/scripts/derive-worktree-name.sh"
WANT_PATH="$GOT_BASE/$(norm "$(task_name)")/$(norm "$(repo_name)")"
GOT_PATH="$(norm "$(key WORKTREE_PATH)")"
if [ "$RC" -eq 0 ] && [ -n "$(task_name)" ] && [ -n "$GOT_BASE" ] && [ "$GOT_PATH" = "$WANT_PATH" ]; then
    pass "P2: WORKTREE_PATH is <base>/<TASK_NAME>/<REPO_NAME>"
else
    fail "P2: want WORKTREE_PATH=$WANT_PATH got '$GOT_PATH' (out='$OUT')"
fi
if [ "$(key_count WORKTREE_BASE)" = "1" ] && [ "$(key_count WORKTREE_PATH)" = "1" ]; then
    pass "P2: WORKTREE_BASE= and WORKTREE_PATH= each appear exactly once"
else
    fail "P2: key counts base=$(key_count WORKTREE_BASE) path=$(key_count WORKTREE_PATH) (out='$OUT')"
fi
case_end

case_begin "explicit-base-dir-wins" "skills/worktree-start/scripts/derive-worktree-name.sh"
CUSTOM_BASE="$_ISOLATION_TMP_ROOT/custom-base"
mkdir -p "$CUSTOM_BASE"
export WORKTREE_BASE_DIR="$CUSTOM_BASE"
run_derive P3 --intent "$INTENT_B1" --repo-dir "$PATH_REPO"
unset WORKTREE_BASE_DIR
GOT_BASE="$(norm "$(key WORKTREE_BASE)")"
GOT_PATH="$(norm "$(key WORKTREE_PATH)")"
if [ "$RC" -eq 0 ] && [ "$GOT_BASE" = "$(norm "$CUSTOM_BASE")" ] \
    && [ "$GOT_PATH" = "$GOT_BASE/$(norm "$(task_name)")/$(norm "$(repo_name)")" ]; then
    pass "P3: an explicit WORKTREE_BASE_DIR is the base and prefixes WORKTREE_PATH"
else
    fail "P3: want base=$(norm "$CUSTOM_BASE") (rc=$RC, out='$OUT', err='$ERR')"
fi
case_end

case_begin "path-is-idempotent" "skills/worktree-start/scripts/derive-worktree-name.sh"
run_derive P4a --intent "$INTENT_B1" --repo-dir "$PATH_REPO"
FIRST="$(key WORKTREE_PATH)"
run_derive P4b --intent "$INTENT_B1" --repo-dir "$PATH_REPO"
if [ -n "$FIRST" ] && [ "$FIRST" = "$(key WORKTREE_PATH)" ]; then
    pass "P4: two runs emit the same WORKTREE_PATH"
else
    fail "P4: WORKTREE_PATH differs or is missing ('$FIRST' vs '$(key WORKTREE_PATH)')"
fi
case_end

case_begin "output-shape" "skills/worktree-start/scripts/derive-worktree-name.sh"
report_shape derive-worktree-path
case_end

finish
