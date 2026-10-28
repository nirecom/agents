#!/usr/bin/env bash
# Tests: hooks/lib/precommit-tests-frontmatter.sh, bin/lib/merge-parents.sh, bin/check-test-frontmatter.sh, bin/check-test-frontmatter/self-impl.sh
# Tags: TL2, bin, hooks, pre-commit, merge, merge-parents, tests-gates, worktree, scope:issue-specific
# #2812: merge shapes for the tests/ gates — MERGE_HEAD-only files (the #2748 reproduction), R1 on a
# shared path and R2 during a merge, a merge in a
# linked worktree, a temporary GIT_INDEX_FILE, the HEAD-only fallbacks with their note, and the
# bin/lib/merge-parents.sh reader on tab / newline paths. Split from
# tests/bin/feat-2812-tests-gates-merge.sh so the two run in parallel; both share its sibling directory.
# TL3 gap: a real merge `git commit` through the installed hooks/pre-commit binary (mitigation: the
# gate functions run here exactly as hooks/pre-commit sources them, with _cfg_dir at this checkout).
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPBASE/transcripts"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"
cd "$TMPBASE" || exit 1

CASE_DIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/feat-2812-tests-gates-merge"
# shellcheck source=feat-2812-tests-gates-merge/fixture.sh
. "$CASE_DIR/fixture.sh"
# shellcheck source=feat-2812-tests-gates-merge/bodies.sh
. "$CASE_DIR/bodies.sh"

case_begin "criss-cross-fixture-leaves-a-merge-with-two-bases" "hooks/lib/precommit-tests-frontmatter.sh"
raw cfx-one '# one'
crissfx "$TMPBASE/cfx" "" "notes/n.txt=cfx-one" "" ""
assert_eq "fixture: MERGE_HEAD=$(git -C "$TMPBASE/cfx" rev-parse MERGE_HEAD 2>/dev/null)" \
  "fixture: MERGE_HEAD=$(git -C "$TMPBASE/cfx" rev-parse y)"
case_end

# shellcheck source=feat-2812-tests-gates-merge/existence.sh
. "$CASE_DIR/existence.sh"
# shellcheck source=feat-2812-tests-gates-merge/shared-and-new.sh
. "$CASE_DIR/shared-and-new.sh"
# shellcheck source=feat-2812-tests-gates-merge/worktree.sh
. "$CASE_DIR/worktree.sh"
# shellcheck source=feat-2812-tests-gates-merge/fallback.sh
. "$CASE_DIR/fallback.sh"
# shellcheck source=feat-2812-tests-gates-merge/nul-paths.sh
. "$CASE_DIR/nul-paths.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
