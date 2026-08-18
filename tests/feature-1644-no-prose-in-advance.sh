#!/usr/bin/env bash
# Tests: bin/workflow/lib/next-step/advance.js, bin/workflow/lib/next-step/advance-shared.js, hooks/workflow-state/record-step-verdict.js
# Tags: tl1, static, workflow, advance, no-prose, scope:issue-specific

# #1644 — the forward operation must decide from RECORDED FACTS only.
#
# Why: intent.md / outline.md are model-authored prose. If the advance path read
# them, a step could be settled because the plan text sounded convincing rather
# than because a condition was recorded — the same failure mode #1286 removed
# from the skip gate. State files and config files are the only admissible
# inputs here.
# Written BEFORE the implementation: RED until the three modules exist.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$AGENTS_DIR" || exit 1

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# advance-args.js joined the class in #1947: both next-step and set-workflow-type
# require it, so it inherits the same ban. It holds argv vocabulary only today —
# this pin forbids plan-reading logic from ever growing there.
TARGETS="
bin/workflow/lib/next-step/advance.js
bin/workflow/lib/next-step/advance-shared.js
bin/workflow/lib/next-step/advance-args.js
hooks/workflow-state/record-step-verdict.js
"

# Tokens that can only appear in code that reaches plan prose. `isTrivial` is the
# keyword-matching predicate over intent.md; the plans dir is where the artifacts
# live; the three artifact suffixes are the artifacts themselves.
FORBIDDEN_TOKENS="isTrivial -intent.md -outline.md -detail.md getWorkflowPlansDir WORKFLOW_PLANS_DIR"
# Modules whose entire purpose is parsing those artifacts.
FORBIDDEN_REQUIRES="session-title parse-closes-issues parse-worktrees workflow-plans-dir"

echo "=== N1: the advance-path modules exist ==="
for f in $TARGETS; do
  if [ -f "$f" ]; then pass "N1: $f exists"; else fail "N1: $f exists -- file not found"; fi
done

echo ""
echo "=== N2: no prose-reading API is referenced ==="
for f in $TARGETS; do
  [ -f "$f" ] || { fail "N2: $f is unreadable -- cannot prove it reads no prose"; continue; }
  for t in $FORBIDDEN_TOKENS; do
    if grep -qF -- "$t" "$f"; then
      fail "N2: $f must not reference $t -- found at $(grep -nF -- "$t" "$f" | head -1)"
    else
      pass "N2: $f does not reference $t"
    fi
  done
done

echo ""
echo "=== N3: no plan-artifact parser is required ==="
for f in $TARGETS; do
  [ -f "$f" ] || { fail "N3: $f is unreadable -- cannot prove its requires"; continue; }
  for m in $FORBIDDEN_REQUIRES; do
    if grep -n 'require(' "$f" | grep -qF -- "$m"; then
      fail "N3: $f must not require $m"
    else
      pass "N3: $f does not require $m"
    fi
  done
done

echo ""
echo "=== N4: the detector is not vacuous ==="
# A grep-based ban proves nothing unless the same grep flags a module that really
# does read prose. skip-signal-resolver.js is the reference positive.
CONTROL="hooks/workflow-state/skip-signal-resolver.js"
if grep -qF -- "isTrivial" "$CONTROL" && grep -qF -- "-intent.md" "$CONTROL"; then pass "N4: the token scan flags the known prose reader ($CONTROL)"
else fail "N4: the token scan flags the known prose reader ($CONTROL) -- detector is broken or the control moved"; fi

echo ""
echo "=== S1: Stage-5 SKILL.md call-site --next pinning (#1644 waste-type-5 regression guard) ==="
# Each declaring-gate call site migrated by Stage 5 either omits --next (its result
# is never consumed -- the skill proceeds to its own next documented step) or passes
# --next (its ACTION block IS consumed). A drive-by edit that adds/drops --next
# silently changes which contract applies -- pin both directions here.

NO_NEXT_FILES=(
  "skills/workflow-init/SKILL.md"
  "skills/workflow-init/SKILL.md"
  "skills/workflow-init/SKILL.md"
  "skills/workflow-init/SKILL.md"
  "skills/clarify-intent/SKILL.md"
  "skills/make-outline-plan/SKILL.md"
  "skills/make-outline-plan/SKILL.md"
)
NO_NEXT_TEXT=(
  'node "$AGENTS_CONFIG_DIR/bin/workflow/set-workflow-type" --session "$SESSION_ID" --type wf-meta --advance --step workflow_init --complete'
  'node "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --advance --step workflow_init --complete'
  '--target outline --advance --so-c1 <true|false> --so-c2 <true|false> | tail -1)`'
  'node "$AGENTS_CONFIG_DIR/bin/workflow/record-skip-judgment" --session "$SESSION_ID" --target outline --advance --c1 true --c2 true'
  '--target outline --advance --so-c1 <true|false> --so-c2 <true|false> | tail -1)`'
  'node "$AGENTS_CONFIG_DIR/bin/workflow/record-skip-judgment" --session "$SESSION_ID" --target outline --advance --c1 <true|false> --c2 <true|false>`'
  'node "$AGENTS_CONFIG_DIR/bin/workflow/record-skip-judgment" --session "$SESSION_ID" --target detail --advance --c1 <true|false> --c2 <true|false> --c3 <true|false>`'
)

for i in "${!NO_NEXT_FILES[@]}"; do
  f="${NO_NEXT_FILES[$i]}"
  t="${NO_NEXT_TEXT[$i]}"
  if [ ! -f "$f" ]; then fail "S1-no-next[$i]: $f exists -- file not found"; continue; fi
  if ! grep -qF -- "$t" "$f"; then
    fail "S1-no-next[$i]: $f does not contain expected call-site text: $t"
    continue
  fi
  pass "S1-no-next[$i]: $f contains the expected no-\`--next\` call site"
  # The captured span already runs to the command's natural terminator (closing
  # backtick / pipe) -- assert that span itself carries no --next flag.
  if printf '%s' "$t" | grep -qF -- '--next'; then
    fail "S1-no-next[$i]: $f call-site span itself contains --next -- fixture is wrong"
  else
    pass "S1-no-next[$i]: $f call-site span carries no --next flag"
  fi
done

WITH_NEXT_FILES=(
  "skills/make-outline-plan/SKILL.md"
  "skills/make-detail-plan/SKILL.md"
  "skills/run-tests/SKILL.md"
  "skills/run-tests/SKILL.md"
)
WITH_NEXT_TEXT=(
  'node "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --advance --step outline --complete --next'
  'node "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --advance --step detail --complete --next'
  'node "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --advance --step run_tests --complete --next'
  'node "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --advance --step run_tests --skipped --skip-reason "<reason>" --next'
)

for i in "${!WITH_NEXT_FILES[@]}"; do
  f="${WITH_NEXT_FILES[$i]}"
  t="${WITH_NEXT_TEXT[$i]}"
  if [ ! -f "$f" ]; then fail "S1-with-next[$i]: $f exists -- file not found"; continue; fi
  if grep -qF -- "$t" "$f"; then
    pass "S1-with-next[$i]: $f contains the expected --next-consuming call site"
  else
    fail "S1-with-next[$i]: $f does not contain expected call-site text: $t"
  fi
done

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
