#!/usr/bin/env bash
# tests/docs-2340-feat-update-docs-readme-md.sh
# Tests: bin/review-doc-size, bin/review-doc-heading-order, bin/review-doc-gates, hooks/lib/staged-doc-changes.js, hooks/workflow-gate/review-docs-checker.js, hooks/workflow-state/state-io/migrations/v3-to-v4.js
# Tags: TL2, docs, review-docs, staged, git, scope:issue-specific, pwsh-not-required
# #2340 — README conciseness + .md line limits enforced at the review_docs step.
# TDD: every source under test is NEW/MODIFIED and unbuilt; cases fail LOUD (RED), never skip.
# TL3 gap: no live claude -p hook dispatch; no Windows-native output parity.
# Mitigation: WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category hook-registration.

set -uo pipefail

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi
if ! command -v git >/dev/null 2>&1; then
  echo "SKIP: git not available"
  exit 77
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"
export AGENTS_DIR AGENTS_DIR_N

TMPDIR_BASE="$(mktemp -d 2>/dev/null || mktemp -d -t 'docs2340')"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# fixture isolation (rules/test/fixture-isolation.md)
WORKFLOW_DIR="$TMPDIR_BASE/wf"
PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"
export CLAUDE_WORKFLOW_DIR="$(nrm "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE

CONFIG_EMPTY="$TMPDIR_BASE/cfg-empty"
mkdir -p "$CONFIG_EMPTY"
: > "$CONFIG_EMPTY/.env"
export AGENTS_CONFIG_DIR="$(nrm "$CONFIG_EMPTY")"

# counters + assertions
PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$name"
  else fail "$name -- want=[$want] got=[$got]"; fi
}
assert_contains() {
  local name="$1" needle="$2" hay="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then pass "$name"
  else fail "$name -- expected [$needle] in: $hay"; fi
}
assert_not_contains() {
  local name="$1" needle="$2" hay="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then fail "$name -- did NOT expect [$needle] in: $hay"
  else pass "$name"; fi
}

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
  else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}
run_node() { run_with_timeout node "$@"; }

# RED gates: a source that does not exist yet fails loudly, never skips.
require_bin() {
  local name="$1" rel="$2"
  if [ -x "$AGENTS_DIR/$rel" ] || [ -f "$AGENTS_DIR/$rel" ]; then return 0; fi
  fail "$name: TOOL NOT FOUND: $rel — expected per #2340, not yet implemented (write_code has not run)"
  return 1
}
require_module() {
  local name="$1" rel="$2"
  if [ -f "$AGENTS_DIR/$rel" ]; then return 0; fi
  fail "$name: MODULE NOT FOUND: $rel — expected per #2340, not yet implemented (write_code has not run)"
  return 1
}

# git doc-repo fixture builders
# REPO_SEQ_FILE persists the counter across command-substitution subshells so
# each $(new_doc_repo) call gets a unique directory (not repo-1 every time).
REPO_SEQ=0
REPO_SEQ_FILE="$TMPDIR_BASE/.repo_seq"
printf '0' > "$REPO_SEQ_FILE"
new_doc_repo() {
  local seq
  seq=$(( $(cat "$REPO_SEQ_FILE") + 1 ))
  printf '%d' "$seq" > "$REPO_SEQ_FILE"
  REPO_SEQ=$seq
  local repo="$TMPDIR_BASE/repo-$seq"
  mkdir -p "$repo"
  git init -q "$repo" >/dev/null 2>&1
  git -C "$repo" config core.hooksPath /dev/null
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "test"
  printf 'baseline\n' > "$repo/.seed"
  git -C "$repo" add .seed >/dev/null 2>&1
  git -C "$repo" commit -q -m baseline >/dev/null 2>&1
  printf '%s' "$repo"
}

# gen_md <path> <n-lines> — an N-line markdown file (heading + filler lines).
gen_md() {
  local path="$1" n="$2" i
  mkdir -p "$(dirname "$path")"
  {
    echo "# Doc"
    for ((i = 2; i <= n; i++)); do echo "filler line $i"; done
  } > "$path"
}

# run_tool <repo> <tool-rel> [args...] — run a bin/ tool with CWD in the repo;
# sets TOOL_OUT and TOOL_RC.
run_tool() {
  local repo="$1" rel="$2"; shift 2
  TOOL_OUT="$(cd "$repo" && run_with_timeout "$AGENTS_DIR/$rel" "$@" 2>&1)"
  TOOL_RC=$?
}

# source each case group
. "$AGENTS_DIR/tests/docs-2340-feat-update-docs-readme-md/a-review-doc-size.sh"
. "$AGENTS_DIR/tests/docs-2340-feat-update-docs-readme-md/b-review-doc-heading-order.sh"
. "$AGENTS_DIR/tests/docs-2340-feat-update-docs-readme-md/c-review-doc-gates.sh"
. "$AGENTS_DIR/tests/docs-2340-feat-update-docs-readme-md/d-staged-doc-changes.sh"
. "$AGENTS_DIR/tests/docs-2340-feat-update-docs-readme-md/e-review-docs-checker.sh"
. "$AGENTS_DIR/tests/docs-2340-feat-update-docs-readme-md/f-v3-to-v4-migration.sh"

echo "=== GROUP A: bin/review-doc-size (staged/all, thresholds, exclusions) ==="
run_group_a
echo ""
echo "=== GROUP B: bin/review-doc-heading-order (SSOT, order, aliases) ==="
run_group_b
echo ""
echo "=== GROUP C: bin/review-doc-gates (aggregate exit code) ==="
run_group_c
echo ""
echo "=== GROUP D: hooks/lib/staged-doc-changes.js ==="
run_group_d
echo ""
echo "=== GROUP E: hooks/workflow-gate/review-docs-checker.js ==="
run_group_e
echo ""
echo "=== GROUP F: migrations/v3-to-v4.js ==="
run_group_f

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
