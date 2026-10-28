#!/usr/bin/env bash
# Tests: hooks/lib/precommit-tests-frontmatter.sh, bin/check-test-frontmatter.sh, bin/check-test-frontmatter/self-impl.sh, bin/check-self-impl.sh, bin/check-test-language-match.sh, bin/lib/test-language-match/case-addition.sh, bin/lib/test-language-match/multi-baseline.sh
# Tags: TL2, bin, hooks, pre-commit, merge, tests-gates, self-impl, case-markers, test-language-match, scope:issue-specific
# #2812: during a merge commit the tests/ gates judge each staged file against the parent(s) it came
# from (MERGE_HEAD included, 3-way when both parents differ), on real `git merge` fixture repos.
# This entrypoint: the self-impl and language-match rules, and the checker CLI arguments.
# Existence, merge shapes, fallbacks and the merge-parents.sh reader:
# tests/bin/feat-2812-tests-gates-merge-shapes.sh (split so the two run in parallel).
# Cases live in the sibling directory feat-2812-tests-gates-merge/.
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

case_begin "merge-fixture-leaves-merge-head" "hooks/lib/precommit-tests-frontmatter.sh"
raw fx-one '# one'
raw fx-two '# two'
mergefx "$TMPBASE/fx" "" "notes/n.txt=fx-one" "notes/n.txt=fx-two" "notes/n.txt=fx-one"
assert_eq "fixture: MERGE_HEAD=$(git -C "$TMPBASE/fx" rev-parse MERGE_HEAD 2>/dev/null)" \
  "fixture: MERGE_HEAD=$(git -C "$TMPBASE/fx" rev-parse up)"
case_end

# shellcheck source=feat-2812-tests-gates-merge/self-impl.sh
. "$CASE_DIR/self-impl.sh"
# shellcheck source=feat-2812-tests-gates-merge/language-match.sh
. "$CASE_DIR/language-match.sh"
# shellcheck source=feat-2812-tests-gates-merge/cli-args.sh
. "$CASE_DIR/cli-args.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
