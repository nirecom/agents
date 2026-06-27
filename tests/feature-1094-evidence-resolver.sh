#!/bin/bash
# Tests: hooks/lib/workflow-state/evidence-resolver.js
# Tags: L2, workflow, evidence, scope:issue-specific

# L3 gap (what this test does NOT catch):
# - real hook PreToolUse event in live claude session
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -euo pipefail

[ -f "hooks/lib/workflow-state/evidence-resolver.js" ] || { echo "SKIP: evidence-resolver.js not yet implemented"; exit 0; }

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="$AGENTS_DIR/hooks/lib/workflow-state/evidence-resolver.js"
# Node on Windows requires a native path (C:/...), not a POSIX/MSYS path (/c/...).
RESOLVER="$(cygpath -m "$RESOLVER" 2>/dev/null || echo "$RESOLVER")"

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
mkdir -p "$CLAUDE_WORKFLOW_DIR"

PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$PLANS_DIR"

PASS=0
FAIL=0

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    perl -e 'alarm 120; exec @ARGV' -- "$@"
  fi
}

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc -- expected [$expected] got [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

check_true() {
  local desc="$1" actual="$2"
  if [ "$actual" = "true" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc -- expected true, got [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

check_false() {
  local desc="$1" actual="$2"
  if [ "$actual" = "false" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc -- expected false, got [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

call_has_evidence() {
  local step="$1" sid="$2" opts="${3:-{}}"
  run_with_timeout node -e "
    const resolver = require('$RESOLVER');
    try {
      const result = resolver.hasCompletionEvidence('$step', '$sid', $opts);
      console.log(result ? 'true' : 'false');
    } catch (e) {
      console.log('ERROR: ' + e.message);
    }
  " 2>/dev/null
}

setup_repo() {
  local repo="$TMPDIR_BASE/repo-$RANDOM"
  mkdir -p "$repo"
  git -C "$repo" init -q
  # Disable inherited global core.hooksPath (points to agents/hooks pre-commit,
  # which blocks commits it cannot resolve to a linked worktree).
  git -C "$repo" config core.hooksPath /dev/null
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  echo "init" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q --no-verify -m "initial"
  echo "$repo"
}

to_node_path() {
  cygpath -m "$1" 2>/dev/null || echo "$1"
}

echo ""
echo "=== ER-1: clarify_intent + intent.md present → true ==="

SID="er1-$$"
touch "$PLANS_DIR/${SID}-intent.md"

OUT=$(WORKFLOW_PLANS_DIR="$PLANS_DIR" call_has_evidence "clarify_intent" "$SID")
check_true "ER-1. clarify_intent + intent.md present → true" "$OUT"

echo ""
echo "=== ER-2: clarify_intent + intent.md absent → false ==="

SID="er2-$$"
OUT=$(WORKFLOW_PLANS_DIR="$PLANS_DIR" call_has_evidence "clarify_intent" "$SID")
check_false "ER-2. clarify_intent + intent.md absent → false" "$OUT"

echo ""
echo "=== ER-3: docs + staged docs present → true ==="

REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
SID="er3-$$"
mkdir -p "$REPO/docs"
echo "doc content" > "$REPO/docs/guide.md"
git -C "$REPO" add docs/guide.md

OUT=$(run_with_timeout node -e "
  const resolver = require('$RESOLVER');
  try {
    const result = resolver.hasCompletionEvidence('docs', '$SID', { repoDir: '$REPO_N' });
    console.log(result ? 'true' : 'false');
  } catch (e) {
    console.log('ERROR: ' + e.message);
  }
" 2>/dev/null)
check_true "ER-3. docs + staged docs present → true" "$OUT"

echo ""
echo "=== ER-4: docs + no staged docs → false ==="

REPO=$(setup_repo)
REPO_N=$(to_node_path "$REPO")
SID="er4-$$"

OUT=$(run_with_timeout node -e "
  const resolver = require('$RESOLVER');
  try {
    const result = resolver.hasCompletionEvidence('docs', '$SID', { repoDir: '$REPO_N' });
    console.log(result ? 'true' : 'false');
  } catch (e) {
    console.log('ERROR: ' + e.message);
  }
" 2>/dev/null)
check_false "ER-4. docs + no staged docs → false" "$OUT"

echo ""
echo "=== ER-5: unknown_step → false (fail-open) ==="

SID="er5-$$"
OUT=$(call_has_evidence "unknown_step" "$SID")
check_false "ER-5. unknown_step → false (fail-open)" "$OUT"

echo ""
echo "=== ER-6: filesystem error → false (fail-open, no exception) ==="

SID="er6-$$"
OUT=$(WORKFLOW_PLANS_DIR="/nonexistent/path/$$" call_has_evidence "clarify_intent" "$SID")
check_false "ER-6. filesystem error → false (fail-open, no exception)" "$OUT"

echo ""
echo "=== ER-7: describeEvidence('clarify_intent') returns non-empty array ==="

OUT=$(run_with_timeout node -e "
  const resolver = require('$RESOLVER');
  try {
    const result = resolver.describeEvidence('clarify_intent');
    if (!Array.isArray(result)) { console.log('NOT_ARRAY'); process.exit(0); }
    if (result.length === 0) { console.log('EMPTY_ARRAY'); process.exit(0); }
    console.log('OK');
  } catch (e) {
    console.log('ERROR: ' + e.message);
  }
" 2>/dev/null)
check "ER-7. describeEvidence('clarify_intent') returns non-empty array" "OK" "$OUT"

echo ""
echo "=== ER-8: describeEvidence('docs') returns non-empty array ==="

OUT=$(run_with_timeout node -e "
  const resolver = require('$RESOLVER');
  try {
    const result = resolver.describeEvidence('docs');
    if (!Array.isArray(result)) { console.log('NOT_ARRAY'); process.exit(0); }
    if (result.length === 0) { console.log('EMPTY_ARRAY'); process.exit(0); }
    console.log('OK');
  } catch (e) {
    console.log('ERROR: ' + e.message);
  }
" 2>/dev/null)
check "ER-8. describeEvidence('docs') returns non-empty array" "OK" "$OUT"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
exit "$FAIL"
