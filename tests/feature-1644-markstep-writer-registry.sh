#!/usr/bin/env bash
# Tests: hooks/workflow-state/record-step-verdict.js, hooks/workflow-mark/mark-step-handler.js, hooks/workflow-mark/not-needed-handlers.js, bin/workflow/lib/next-step/state-ops.js, bin/workflow/lib/next-step/verdict.js
# Tags: tl1, static, workflow, markstep, class-completeness, scope:issue-specific
#
# #1644 — the markStep() writer registry.
#
# Why a registry at all: markStep has two kinds of caller, and folding them into
# one writer would break the second kind.
#   Class D (declared)  — the caller ASSERTS a step is settled. These must go
#                         through record-step-verdict.js so the manual-mark
#                         prohibitions, the approval invariant and the A-4
#                         co-write are stated exactly once.
#   Class O (observed)  — the process itself OBSERVED the fact (a RUN_CONTRACT
#                         line, a staged-tests token, an already-approved
#                         sentinel). Each owns its own evidence predicate and is
#                         deliberately NOT folded.
#
# The registry below is the SSOT for that partition. A new markStep call site
# fails this test until it is classified, which is the whole point.
# Written BEFORE the implementation: RED until the Class D sites delegate.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$AGENTS_DIR" || exit 1

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- expected [$2] got [$3]"; fi; }

# --- registry ---------------------------------------------------------------
# "<path> <expected direct markStep() call count AFTER the #1644 migration>"
CLASS_O_REGISTRY="
bin/workflow/reconcile-state 1
hooks/post-push-workflow-reset.js 1
hooks/workflow-mark.js 2
hooks/workflow-mark/branching-handler.js 1
hooks/workflow-mark/clarify-intent-complete-handler.js 1
hooks/workflow-mark/review-tests-handler.js 1
hooks/workflow-mark/user-verified-handler.js 1
hooks/workflow-run-tests.js 3
hooks/workflow-state/state-io/review-tests.js 2
"
# Class D sites must hold ZERO direct calls once they delegate. verdict.js keeps
# exactly one: persistResolutions is a Class O observation living in the same file.
CLASS_D_REGISTRY="
bin/workflow/lib/next-step/state-ops.js 0
bin/workflow/lib/next-step/verdict.js 1
hooks/workflow-mark/mark-step-handler.js 0
hooks/workflow-mark/not-needed-handlers.js 0
"
# The single declared-class writer, plus the module that defines markStep itself.
SINGLE_WRITER="hooks/workflow-state/record-step-verdict.js"
DEFINITION_SITE="hooks/workflow-state/state-io/core.js"

# Call sites the #1644 plan's inventory does not cover. Registered here only so
# R1a can distinguish "known but unclassified" from "brand new and unnoticed";
# R1c below fails until each one is moved into Class D or Class O for a stated
# reason. Do not leave entries here.
#
# bin/workflow/reconcile-state was parked here while its class was open. It is
# Class O: its markStep(sid, step, "complete") fires only after the script has
# itself observed hasCompletionEvidence plus the approval verdict, so the fact
# comes from evidence the process read, not from a caller asserting it —
# structurally the same shape as verdict.js persistResolutions.
NEEDS_CLASSIFICATION=""

# Count real call sites: comment lines (// ... or * ...) and the definition are
# not calls, and would otherwise make a doc mention look like a writer.
count_calls() {
  [ -f "$1" ] || { echo MISSING; return; }
  grep -n 'markStep(' "$1" \
    | grep -v ':[[:space:]]*//' \
    | grep -v ':[[:space:]]*\*' \
    | grep -v 'function markStep(' \
    | wc -l | tr -d ' '
}

echo "=== R1: every markStep() call site belongs to exactly one registry ==="
DISCOVERED="$(grep -rln 'markStep(' hooks bin 2>/dev/null | tr '\\' '/' | sort)"
REGISTERED="$(printf '%s\n%s\n%s\n%s\n%s\n' "$CLASS_O_REGISTRY" "$CLASS_D_REGISTRY" \
  "$SINGLE_WRITER" "$DEFINITION_SITE" "$NEEDS_CLASSIFICATION" | awk 'NF {print $1}' | sort -u)"

# Files that only MENTION markStep in prose are not call sites; drop them from
# the discovered set before comparing, using the same predicate as count_calls.
REAL=""
for f in $DISCOVERED; do
  n="$(count_calls "$f")"
  [ "$n" = "0" ] || REAL="$REAL$f
"
done
REAL="$(printf '%s' "$REAL" | sort -u)"

UNREGISTERED="$(comm -23 <(printf '%s\n' "$REAL") <(printf '%s\n' "$REGISTERED") | tr '\n' ' ')"
check "R1a: no unregistered markStep call site exists" "" "$(printf '%s' "$UNREGISTERED" | sed 's/ *$//')"

MISSING="$(comm -13 <(printf '%s\n' "$REAL") <(printf '%s\n' "$REGISTERED") | tr '\n' ' ')"
# A registered Class D file legitimately drops to zero calls after the migration,
# so only Class O / definition / single-writer entries must still be present.
# The definition site holds no CALL, and the single writer is covered by R4.
EXPECT_PRESENT="$(printf '%s\n' "$CLASS_O_REGISTRY" | awk 'NF {print $1}' | sort -u)"
STILL_MISSING=""
for f in $MISSING; do
  case "$(printf '%s\n' "$EXPECT_PRESENT" | grep -cxF "$f")" in
    0) ;;
    *) STILL_MISSING="$STILL_MISSING$f " ;;
  esac
done
check "R1b: every observed-class writer is still a real call site" "" \
  "$(printf '%s' "$STILL_MISSING" | sed 's/ *$//')"

# R1c: the partition must be total. An entry parked in NEEDS_CLASSIFICATION is a
# call site nobody has assigned a class to, so the registry is not yet a proof.
check "R1c: no markStep call site is left unclassified" "" \
  "$(printf '%s\n' "$NEEDS_CLASSIFICATION" | awk 'NF {print $1}' | tr '\n' ' ' | sed 's/ *$//')"

echo ""
echo "=== R2: Class O call counts are unchanged by the migration ==="
# Heredoc (not a pipeline) so the loop runs in THIS shell and the counters stick.
while read -r f n; do
  [ -n "$f" ] || continue
  check "R2: $f keeps $n direct markStep call(s)" "$n" "$(count_calls "$f")"
done <<EOF
$CLASS_O_REGISTRY
EOF

echo ""
echo "=== R3: Class D sites delegate to record-step-verdict.js ==="
while read -r f n; do
  [ -n "$f" ] || continue
  check "R3a: $f holds only $n direct markStep call(s)" "$n" "$(count_calls "$f")"
  if grep -qF 'record-step-verdict' "$f"; then
    pass "R3b: $f requires record-step-verdict"
  else
    fail "R3b: $f requires record-step-verdict -- no reference found"
  fi
done <<EOF
$CLASS_D_REGISTRY
EOF

echo ""
echo "=== R4: the single declared-class writer exists and owns the policy ==="
if [ -f "$SINGLE_WRITER" ]; then pass "R4a: $SINGLE_WRITER exists"
else fail "R4a: $SINGLE_WRITER exists -- file not found"; fi
check "R4b: the single writer calls markStep exactly once" "1" "$(count_calls "$SINGLE_WRITER")"
for sym in recordStepVerdict RECORDED_VERDICT_PREFIX ADVANCE_ORIGINS GATES; do
  if grep -qF "$sym" "$SINGLE_WRITER" 2>/dev/null; then
    pass "R4c: $SINGLE_WRITER exports/defines $sym"
  else
    fail "R4c: $SINGLE_WRITER exports/defines $sym -- symbol not found"
  fi
done

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
