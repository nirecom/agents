#!/usr/bin/env bash
# Tests: hooks/workflow-gate/staged-evidence.js, bin/workflow/lib/next-step/verdict.js, hooks/workflow-mark/mark-step-handler.js
# Tags: tl1, workflow, docs-only, ssot, run-tests, scope:issue-specific, pwsh-not-required
#
# #1644 stage 2 — CPR-SSOT for the docs-only predicate. Two consumers gain the
# check in this stage (verdict.js for the SKIP_HINT, mark-step-handler.js for the
# MARK_STEP guard); both must REFERENCE hooks/workflow-gate/staged-evidence.js,
# never restate the allowlist. A second copy of the regex is how the two doors
# start disagreeing about what "docs-only" means.
#
# TL3 gap (what this test does NOT catch):
# - Whether the two consumers agree at RUNTIME on a real staged set; that is
#   covered by the TL2 cases in feature-1644-run-tests-registration-sites.sh.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$AGENTS_DIR" || exit 1

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then pass "$desc"
  else fail "$desc -- expected [$expected] got [$actual]"; fi
}

OWNER="hooks/workflow-gate/staged-evidence.js"

# S1 — the allowlist regex has exactly one definition in the whole tree.
DEFS="$(grep -rln "DOCS_ONLY_ALLOWLIST *=" --include=*.js hooks bin 2>/dev/null | sort | tr '\n' ' ')"
check "S1 DOCS_ONLY_ALLOWLIST is defined only in the owner module" "$OWNER " "$DEFS"

# S2 — no re-implementation of the predicate under bin/workflow/. A copy of the
# allowlist shape (docs/*.md plus the four root files) is the duplication that
# S1 cannot see, because a copy need not reuse the constant's name.
COPIES="$(grep -rlE "CHANGELOG\|CONTRIBUTING|CONTRIBUTING\|LICENSE|docs\\\\/\.\+\\\\\.md" \
  --include=*.js bin/workflow 2>/dev/null | sort | tr '\n' ' ')"
check "S2 bin/workflow/ contains no copy of the docs-only allowlist shape" "" "$COPIES"

# S3 — no locally-defined docs-only predicate under bin/workflow/: consumers may
# call isDocsOnlyStaged, never declare one.
LOCALDEF="$(grep -rnE "function +isDocsOnly|isDocsOnly[A-Za-z]* *= *(function|\()" \
  --include=*.js bin/workflow 2>/dev/null | tr '\n' ' ')"
check "S3 bin/workflow/ defines no local docs-only predicate" "" "$LOCALDEF"

# S4 / S5 — the two stage-2 consumers require the owner module.
for consumer in bin/workflow/lib/next-step/verdict.js hooks/workflow-mark/mark-step-handler.js; do
  if grep -qE "require\(.*staged-evidence" "$consumer"; then
    pass "S4 $consumer requires the staged-evidence module"
  else
    fail "S4 $consumer does not require the staged-evidence module -- docs-only consumer missing its SSOT reference"
  fi
done

# S6 — and both actually call the shared predicate rather than importing it and
# hand-rolling a variant next to it.
for consumer in bin/workflow/lib/next-step/verdict.js hooks/workflow-mark/mark-step-handler.js; do
  if grep -q "isDocsOnlyStaged(" "$consumer"; then
    pass "S6 $consumer calls isDocsOnlyStaged()"
  else
    fail "S6 $consumer never calls isDocsOnlyStaged() -- docs-only branch is absent or re-implemented"
  fi
done

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
