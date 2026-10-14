#!/usr/bin/env bash
# tests/hooks/fix-2654-closes-issues-intent-source.sh
# Tests: bin/workflow/lib/next-step/list.js, bin/workflow/lib/next-step/verdict.js, hooks/workflow-state/session-facts.js
# Tags: tl2, workflow, closes-issues, next-step, regression-2654, scope:issue-specific, pwsh-not-required
# #2654: the clarify_intent gate (verdict.js), the --list [!] overlay (list.js) and
# getClosesIssues() all read <plans>/<sid>-intent.md `## Issues`, never a stale
# state.closes_issues. Every fixture seeds a contradicting state value on purpose.
# TL3 gap: a real /clarify-intent rewrite of intent.md inside a live session.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category: skill-orchestration.
set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

readonly TMP_ROOT="$(make_tmp)"
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT"
export WORKFLOW_STATE_DIR="$(np "$WORKFLOW_STATE_DIR")"
export WORKFLOW_PLANS_DIR="$(np "$WORKFLOW_PLANS_DIR")"
STATE_DIR_SH="$TMP_ROOT/workflow-state"
PLANS_DIR_SH="$TMP_ROOT/plans"

FIXTURE_REPO="$TMP_ROOT/repo"; mkdir -p "$FIXTURE_REPO"
harness_git_init "$FIXTURE_REPO"
export CLAUDE_PROJECT_DIR="$(np "$FIXTURE_REPO")"
NEUTRAL_CWD="$TMP_ROOT/neutral"; mkdir -p "$NEUTRAL_CWD"
cd "$NEUTRAL_CWD" || exit 1

ROOT_N="$(np "$SCRIPT_CHECKOUT_ROOT")"
NEXT_STEP_N="$ROOT_N/bin/workflow/next-step"
SF_MODULE_N="$ROOT_N/hooks/workflow-state/session-facts.js"

check_eq() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi; }
check_contains() {
  if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1" "expected [$2] in: $3"; fi
}
check_not_contains() {
  if printf '%s' "$3" | grep -qF -- "$2"; then fail "$1" "did NOT expect [$2] in: $3"; else pass "$1"; fi
}

STEPS_ALL="workflow_init clarify_intent research outline detail branching_complete write_tests review_tests write_code run_tests review_security docs user_verification cleanup pre_final_report_gate final_report"

# seed_state <sid> [closes_issues-json] -- v1 raw fixture, workflow_init complete, so the
# current step is clarify_intent. cwd is the Node-form repo path next-step resolves itself.
seed_state() {
  local sid="$1" issues="${2:-}" json='{"steps":{' first=1 s st
  for s in $STEPS_ALL; do
    st="pending"; [ "$s" = "workflow_init" ] && st="complete"
    [ $first -eq 1 ] || json="$json,"; first=0
    json="$json\"$s\":{\"status\":\"$st\"}"
  done
  json="$json},\"cwd\":\"$CLAUDE_PROJECT_DIR\",\"git_branch\":\"fix/2654\""
  [ -n "$issues" ] && json="$json,\"closes_issues\":$issues"
  printf '%s' "$json}" > "$STATE_DIR_SH/${sid}.json"
}

# write_intent <sid> <ref>... -- `## Issues` with one bullet per ref (zero refs = empty section).
write_intent() {
  local sid="$1" t; shift
  { echo "# intent"; echo; echo "## Issues"; for t in "$@"; do echo "- $t"; done; } > "$PLANS_DIR_SH/${sid}-intent.md"
}

NS_OUT=""; NS_RC=0
run_ns() { NS_RC=0; NS_OUT="$(run_with_timeout 60 node "$NEXT_STEP_N" "$@" 2>/dev/null)" || NS_RC=$?; }
clarify_row() { run_ns --list --session "$1"; printf '%s\n' "$NS_OUT" | grep -E 'clarify_intent' | head -n1; }

GCI_PROBE="$TMP_ROOT/gci-probe.js"
cat > "$GCI_PROBE" <<'EOF'
const m = require(process.env.SF_MODULE);
process.stdout.write(JSON.stringify(m.getClosesIssues(process.env.SF_SID, { plansDir: process.env.SF_PLANS_DIR })));
EOF
gci() { SF_MODULE="$SF_MODULE_N" SF_SID="$1" SF_PLANS_DIR="$WORKFLOW_PLANS_DIR" run_with_timeout 60 node "$GCI_PROBE" 2>/dev/null; }

echo "=== G9: intent.md with an EMPTY ## Issues blocks, whatever state.closes_issues says ==="
seed_state g9 '[{"number":1644}]'
write_intent g9

case_begin "g9-gate-blocks-on-empty-intent-issues" "bin/workflow/lib/next-step/verdict.js"
run_ns --session g9
check_not_contains "G9-pre: the run reaches the closes_issues gate (no repo-dir-mismatch)" "repo-dir-mismatch" "$NS_OUT"
check_contains "G9a: ACTION=blocked" "ACTION=blocked" "$NS_OUT"
check_contains "G9b: REASON=closes_issues-empty despite a non-empty state value" "closes_issues-empty" "$NS_OUT"
case_end

case_begin "g9-list-flags-empty-intent-issues" "bin/workflow/lib/next-step/list.js"
check_contains "G9c: --list clarify_intent row shows [!]" "[!]" "$(clarify_row g9)"
case_end

echo ""
echo "=== G9m: a MISSING intent.md blocks, whatever state.closes_issues says ==="
seed_state g9m '[{"number":1644},{"number":1655}]'

case_begin "g9m-gate-blocks-on-missing-intent" "bin/workflow/lib/next-step/verdict.js"
run_ns --session g9m
check_contains "G9m-a: REASON=closes_issues-empty with no intent.md" "closes_issues-empty" "$NS_OUT"
case_end

case_begin "g9m-reader-returns-empty-on-missing-intent" "hooks/workflow-state/session-facts.js"
check_eq "G9m-b: getClosesIssues returns [] with no intent.md" "[]" "$(gci g9m)"
case_end

echo ""
echo "=== G10: no state.closes_issues, intent.md names 2 issues -> not blocked ==="
seed_state g10
write_intent g10 "#2654" "#2655"

case_begin "g10-gate-passes-on-intent-issues" "bin/workflow/lib/next-step/verdict.js"
run_ns --session g10
check_not_contains "G10-pre: no repo-dir-mismatch" "repo-dir-mismatch" "$NS_OUT"
check_eq "G10-rc: next-step exits 0" "0" "$NS_RC"
check_contains "G10-act: ACTION=invoke" "ACTION=invoke" "$NS_OUT"
check_not_contains "G10a: not blocked on closes_issues-empty" "closes_issues-empty" "$NS_OUT"
check_contains "G10b: routes to clarify-intent" "NEXT_SKILL=clarify-intent" "$NS_OUT"
case_end

case_begin "g10-list-marks-current-not-blocked" "bin/workflow/lib/next-step/list.js"
G10_ROW="$(clarify_row g10)"
check_contains "G10c: --list clarify_intent row shows [*]" "[*]" "$G10_ROW"
check_not_contains "G10d: --list clarify_intent row has no [!]" "[!]" "$G10_ROW"
case_end

echo ""
echo "=== G11: intent.md narrowed from 4 issues to 2 (the #2654 report) ==="
seed_state g11 '[{"number":1644},{"number":1655},{"number":1700},{"number":1701}]'
write_intent g11 "#1644" "#1655" "#1700" "#1701"

case_begin "g11-reader-follows-narrowed-intent" "hooks/workflow-state/session-facts.js"
check_eq "G11a: before narrowing, 4 issues" \
  '[{"number":1644},{"number":1655},{"number":1700},{"number":1701}]' "$(gci g11)"
write_intent g11 "#1644" "#1655"
check_eq "G11b: after narrowing, exactly the 2 remaining issues" \
  '[{"number":1644},{"number":1655}]' "$(gci g11)"
case_end

case_begin "g11-list-after-narrowing" "bin/workflow/lib/next-step/list.js"
check_contains "G11c: --list clarify_intent row shows [*]" "[*]" "$(clarify_row g11)"
case_end

case_begin "g11-gate-after-narrowing" "bin/workflow/lib/next-step/verdict.js"
run_ns --session g11
check_eq "G11d-rc: next-step exits 0 (no crash behind an empty output)" "0" "$NS_RC"
check_contains "G11d-act: narrowed intent.md routes ACTION=invoke" "ACTION=invoke" "$NS_OUT"
check_contains "G11d-skill: narrowed intent.md routes to clarify-intent" "NEXT_SKILL=clarify-intent" "$NS_OUT"
check_not_contains "G11d: narrowed intent.md still clears the gate" "closes_issues-empty" "$NS_OUT"
# Narrowed further to zero: the stale 4-issue state value must not keep the gate open.
write_intent g11
run_ns --session g11
check_contains "G11e: narrowed to zero issues, the gate blocks" "closes_issues-empty" "$NS_OUT"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
