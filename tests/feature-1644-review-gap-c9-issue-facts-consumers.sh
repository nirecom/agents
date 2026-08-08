#!/usr/bin/env bash
# tests/feature-1644-review-gap-c9-issue-facts-consumers.sh
# Tests: hooks/workflow-state/session-facts.js, bin/parse-closes-issues, bin/render-final-report.js, bin/issue-close-write-outcome.js, hooks/lib/final-report-schema.js
# Tags: tl2, workflow, session-facts, closes-issues, cross-module, final-report, issue-close, scope:issue-specific, pwsh-not-required
#
# #1644 review gap C9 (HIGH) — cross-module consistency of the issue facts.
# Three consumers were migrated onto getClosesIssues() in stage 4:
#   bin/parse-closes-issues --session <sid> [--plans-dir <dir>]
#   bin/render-final-report.js <sid> <env-json> <outcome-json> <intent-md>
#   bin/issue-close-write-outcome.js --fallback <intent-md> <outcome-file>
# Driven against ONE seeded cache state, every consumer must report the same
# issue NUMBERS. This file exercises both shapes that can legitimately sit in
# state.closes_issues: the OBJECT shape written by parseClosesIssues today, and
# the LEGACY numeric-only shape ([1644, 1655]) that older state files carry.
#
# TL3 gap (what this test does NOT catch):
# - Whether /worktree-end and /issue-close-finalize actually invoke these CLIs
#   with the argv this test uses (arg drift in a SKILL.md is invisible here).
# - The real ~/.workflow-plans layout and a real merged PR's outcome JSON.
# Closest-to-action mitigation: the CLIs are spawned as real subprocesses with
# real files, so only the skill-side argv wiring is left to a TL3 run.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"
PARSE_CLI_N="$AGENTS_DIR_N/bin/parse-closes-issues"
RENDER_CLI_N="$AGENTS_DIR_N/bin/render-final-report.js"
OUTCOME_CLI_N="$AGENTS_DIR_N/bin/issue-close-write-outcome.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- expected [$2] got [$3]"; fi; }
check_contains() {
  if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"
  else fail "$1 -- expected [$2] in: $3"; fi
}
check_not_contains() {
  if printf '%s' "$3" | grep -qF -- "$2"; then fail "$1 -- did NOT expect [$2] in: $3"
  else pass "$1"; fi
}

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
  else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
WORKFLOW_DIR="$TMPDIR_BASE/wf"; PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"
# DUAL-PIN (#1799).
export CLAUDE_WORKFLOW_DIR="$(nrm "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"
PLANS_DIR_N="$(nrm "$PLANS_DIR")"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

# issue-close-write-outcome.js resolves session-facts.js under AGENTS_CONFIG_DIR,
# so it must point at the worktree under test (an isolated empty dir would make
# the require fail). The plans dir it would otherwise derive from config is
# pinned above, so no ambient config reaches the run.
export AGENTS_CONFIG_DIR="$AGENTS_DIR_N"

FIXTURE_REPO="$TMPDIR_BASE/repo"; mkdir -p "$FIXTURE_REPO"
git init -q "$FIXTURE_REPO" >/dev/null 2>&1
git -C "$FIXTURE_REPO" config core.hooksPath /dev/null
export CLAUDE_PROJECT_DIR="$(nrm "$FIXTURE_REPO")"
NEUTRAL_CWD="$TMPDIR_BASE/neutral"; mkdir -p "$NEUTRAL_CWD"
cd "$NEUTRAL_CWD" || exit 1

STEPS_ALL="workflow_init clarify_intent research outline detail branching_complete write_tests review_tests run_tests review_security docs user_verification cleanup pre_final_report_gate final_report"

# seed_state <sid> <closes_issues-json>
seed_state() {
  local sid="$1" issues="$2"
  local json='{"steps":{' first=1 s
  for s in $STEPS_ALL; do
    [ $first -eq 1 ] || json="$json,"; first=0
    json="$json\"$s\":{\"status\":\"pending\"}"
  done
  json="$json},\"cwd\":\"$FIXTURE_REPO\",\"git_branch\":\"feature/roundtrip-reduction\""
  json="$json,\"closes_issues\":$issues"
  printf '%s' "$json}" > "$WORKFLOW_DIR/${sid}.json"
}

write_intent() {
  local sid="$1"; shift
  { echo "## Issues"; for tok in "$@"; do echo "- $tok"; done; } > "$PLANS_DIR/${sid}-intent.md"
}

ENV_JSON="$TMPDIR_BASE/env.json"
printf '%s' '{"PR_NUMBER":"1900","BRANCH":"feature/roundtrip-reduction"}' > "$ENV_JSON"
EMPTY_OUTCOME="$TMPDIR_BASE/empty-outcome.json"
printf '%s' '{"issues":[]}' > "$EMPTY_OUTCOME"

# --- consumer drivers --------------------------------------------------------
consumer_parse() {  # <sid> -> JSON array as printed by the CLI
  run_with_timeout node "$PARSE_CLI_N" --session "$1" --plans-dir "$PLANS_DIR_N" 2>/dev/null
}

# Numbers as rendered into the Final Report's <CLOSED_ISSUES_LIST> section.
consumer_render_numbers() {  # <sid>
  local sid="$1" out
  out="$(run_with_timeout node "$RENDER_CLI_N" "$sid" "$(nrm "$ENV_JSON")" \
    "$(nrm "$EMPTY_OUTCOME")" "$PLANS_DIR_N/${sid}-intent.md" 2>/dev/null)" || true
  printf '%s' "$out" | grep -oE '^- #[^ ]+$' | sed 's/^- #//' | tr '\n' ',' | sed 's/,$//'
}

# Numbers written into the outcome bag by --fallback.
consumer_outcome_numbers() {  # <sid>
  local sid="$1"
  local outfile="$TMPDIR_BASE/${sid}-issue-close-outcome.json"
  rm -f "$outfile"
  run_with_timeout node "$OUTCOME_CLI_N" --fallback "$PLANS_DIR_N/${sid}-intent.md" \
    "$(nrm "$outfile")" >/dev/null 2>&1 || true
  node -e '
    const fs=require("fs");
    let bag={issues:[]};
    try{bag=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));}catch(_){}
    process.stdout.write((bag.issues||[]).map(e=>String(e.issueNumber)).join(","));
  ' "$(nrm "$outfile")" 2>/dev/null
}

echo "=== C9-1: OBJECT-shaped cache — all three consumers agree ==="
SID_OBJ="c9obj"
seed_state "$SID_OBJ" '[{"number":1644},{"number":1655,"repo":"owner/repo"}]'
# intent.md deliberately names a DIFFERENT set: any consumer that bypassed the
# cache and re-parsed would show 9999 here.
write_intent "$SID_OBJ" "#9999"
P_OUT="$(consumer_parse "$SID_OBJ")"
R_OUT="$(consumer_render_numbers "$SID_OBJ")"
O_OUT="$(consumer_outcome_numbers "$SID_OBJ")"
check "C9-1a: parse-closes-issues --session returns the cached object entries" \
  '[{"number":1644},{"number":1655,"repo":"owner/repo"}]' "$P_OUT"
check "C9-1b: render-final-report lists the same numbers" "1644,1655" "$R_OUT"
check "C9-1c: issue-close-write-outcome --fallback records the same numbers" "1644,1655" "$O_OUT"
check_not_contains "C9-1d: no consumer leaked the contradicting intent.md issue (#9999)" \
  "9999" "$P_OUT$R_OUT$O_OUT"

echo ""
echo "=== C9-2: LEGACY numeric-only cache — consumer-by-consumer behavior ==="
# FINDING (pinned CURRENT behavior): state.closes_issues written by an older
# release is a bare number array. getClosesIssues() returns it VERBATIM (it only
# checks Array.isArray + length), so each consumer meets raw numbers:
#   - bin/parse-closes-issues   : passes them through unchanged (numbers out).
#   - issue-close-write-outcome : handles `typeof entry === "number"` explicitly
#                                 -> correct issue numbers.
#   - render-final-report.js    : does `.map((e) => e.number)` with NO numeric
#                                 branch -> undefined per entry, and the Final
#                                 Report renders "- #undefined".
# That asymmetry is the C9 finding: the numeric shape is handled in two of the
# three consumers. Asserted as-is (source untouched).
SID_LEG="c9leg"
seed_state "$SID_LEG" '[1644,1655]'
write_intent "$SID_LEG" "#9999"
P_OUT="$(consumer_parse "$SID_LEG")"
R_OUT="$(consumer_render_numbers "$SID_LEG")"
O_OUT="$(consumer_outcome_numbers "$SID_LEG")"
check "C9-2a: parse-closes-issues passes the legacy numeric entries through" \
  '[1644,1655]' "$P_OUT"
check "C9-2b: issue-close-write-outcome --fallback resolves legacy numbers correctly" \
  "1644,1655" "$O_OUT"
check "C9-2c: render-final-report drops the numbers on the legacy shape (BUG, pinned)" \
  "undefined,undefined" "$R_OUT"
# No consumer crashes and none silently drops an ENTRY (count is preserved even
# where the number itself is lost).
check "C9-2d: render still emits one line per issue (arity preserved)" \
  "2" "$(printf '%s' "$R_OUT" | awk -F, '{print NF}')"

echo ""
echo "=== C9-3: NO cache — all three fall back to intent.md and still agree ==="
SID_NC="c9nocache"
rm -f "$WORKFLOW_DIR/${SID_NC}.json"
write_intent "$SID_NC" "#1644" "owner/repo#1655"
P_OUT="$(consumer_parse "$SID_NC")"
R_OUT="$(consumer_render_numbers "$SID_NC")"
O_OUT="$(consumer_outcome_numbers "$SID_NC")"
check "C9-3a: parse-closes-issues parses intent.md when no state exists" \
  '[{"number":1644},{"number":1655,"repo":"owner/repo"}]' "$P_OUT"
check "C9-3b: render-final-report reports the same numbers" "1644,1655" "$R_OUT"
check "C9-3c: outcome writer reports the same numbers" "1644,1655" "$O_OUT"
if [ -e "$WORKFLOW_DIR/${SID_NC}.json" ]; then
  fail "C9-3d: a read-mostly consumer fabricated a workflow state file"
else
  pass "C9-3d: no consumer fabricated a workflow state file"
fi

echo ""
echo "=== C9-4: EMPTY issue set — consistent '(none)' handling, no crash ==="
SID_E="c9empty"
seed_state "$SID_E" '[]'
write_intent "$SID_E"     # heading present, zero entries
check "C9-4a: parse-closes-issues returns []" '[]' "$(consumer_parse "$SID_E")"
check "C9-4b: outcome writer records no entries" "" "$(consumer_outcome_numbers "$SID_E")"
RENDER_FULL="$(run_with_timeout node "$RENDER_CLI_N" "$SID_E" "$(nrm "$ENV_JSON")" \
  "$(nrm "$EMPTY_OUTCOME")" "$PLANS_DIR_N/${SID_E}-intent.md" 2>&1)" || true
check_contains "C9-4c: render-final-report renders the (none) placeholder" \
  "- (none)" "$RENDER_FULL"
check_not_contains "C9-4d: render-final-report does not emit '#undefined' on an empty set" \
  "#undefined" "$RENDER_FULL"

echo ""
echo "=== C9-5: cross-shape agreement matrix on the SAME numbers ==="
# Same two issue numbers expressed in each shape: every consumer that resolves
# numbers at all must report the identical number list across both shapes.
seed_state c9m_obj '[{"number":1644},{"number":1655}]'
seed_state c9m_num '[1644,1655]'
write_intent c9m_obj "#9999"
write_intent c9m_num "#9999"
check "C9-5a: outcome writer agrees across object and numeric shapes" \
  "$(consumer_outcome_numbers c9m_obj)" "$(consumer_outcome_numbers c9m_num)"
# Documented DISAGREEMENT (the C9-2c bug, restated as a matrix cell):
OBJ_R="$(consumer_render_numbers c9m_obj)"
NUM_R="$(consumer_render_numbers c9m_num)"
if [ "$OBJ_R" = "$NUM_R" ]; then
  fail "C9-5b: render agreed across shapes -- source may have been fixed; update this test's finding"
else
  pass "C9-5b: render DISAGREES across shapes (obj=[$OBJ_R] num=[$NUM_R]) -- the pinned C9 bug"
fi

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
