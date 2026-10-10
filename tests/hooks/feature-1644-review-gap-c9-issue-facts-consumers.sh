#!/usr/bin/env bash
# tests/hooks/feature-1644-review-gap-c9-issue-facts-consumers.sh
# Tests: hooks/workflow-state/session-facts.js, bin/parse-closes-issues, bin/render-final-report.js, bin/issue-close-write-outcome.js, hooks/lib/final-report-schema.js
# Tags: tl2, workflow, session-facts, closes-issues, cross-module, final-report, issue-close, scope:issue-specific, pwsh-not-required, feature-2434, control-dir
# #1644 C9: parse-closes-issues, render-final-report and issue-close-write-outcome
# must report the same issue numbers for one seeded cache (object + legacy shapes).
# #2434 C9-6: render-final-report derives its control files from --session under
# $WORKFLOW_STATE_DIR/<sid>.control/; legacy positionals only via the shim.
# TL3 gap: the real ~/.workflow-plans layout and a merged PR's outcome JSON.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
SCRIPT_CHECKOUT_ROOT_N="$(nrm "$SCRIPT_CHECKOUT_ROOT")"
PARSE_CLI_N="$SCRIPT_CHECKOUT_ROOT_N/bin/parse-closes-issues"
RENDER_CLI_N="$SCRIPT_CHECKOUT_ROOT_N/bin/render-final-report.js"
OUTCOME_CLI_N="$SCRIPT_CHECKOUT_ROOT_N/bin/issue-close-write-outcome.js"
SKILL_MD="$SCRIPT_CHECKOUT_ROOT/skills/session-close/SKILL.md"

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
export WORKFLOW_STATE_DIR="$(nrm "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"
PLANS_DIR_N="$(nrm "$PLANS_DIR")"
WORKFLOW_DIR_N="$(nrm "$WORKFLOW_DIR")"
unset CLAUDE_CODE_SESSION_ID
export HOME="$TMPDIR_BASE/home"; mkdir -p "$HOME" "$TMPDIR_BASE/tx"
export CLAUDE_TRANSCRIPT_BASE_DIR="$(nrm "$TMPDIR_BASE/tx")"

# issue-close-write-outcome.js resolves session-facts.js under AGENTS_MAIN_ROOT,
# so it must point at the worktree under test (an isolated empty dir would make
# the require fail). The plans dir it would otherwise derive from config is
# pinned above, so no ambient config reaches the run.

FIXTURE_REPO="$TMPDIR_BASE/repo"; mkdir -p "$FIXTURE_REPO"
git init -q "$FIXTURE_REPO" >/dev/null 2>&1
git -C "$FIXTURE_REPO" config core.hooksPath /dev/null
export CLAUDE_PROJECT_DIR="$(nrm "$FIXTURE_REPO")"
NEUTRAL_CWD="$TMPDIR_BASE/neutral"; mkdir -p "$NEUTRAL_CWD"
cd "$NEUTRAL_CWD" || exit 1

STEPS_ALL="workflow_init clarify_intent research outline detail branching_complete write_tests review_tests write_code run_tests review_security docs user_verification cleanup pre_final_report_gate final_report"

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

ENV_BODY='{"PR_NUMBER":"1900","BRANCH":"feature/roundtrip-reduction"}'

# ctl <sid> <name> -> the derived control path (#2434), Node-normalized.
ctl() { printf '%s' "$WORKFLOW_DIR_N/$1.control/$2"; }

# seed_control <sid> [env-json]: env + empty outcome at the derived control paths.
seed_control() {
  local sid="$1" body="${2:-$ENV_BODY}"
  mkdir -p "$WORKFLOW_DIR/$sid.control"
  printf '%s' "$body" > "$WORKFLOW_DIR/$sid.control/final-report-env.json"
  printf '%s' '{"issues":[]}' > "$WORKFLOW_DIR/$sid.control/issue-close-outcome.json"
}

# --- consumer drivers --------------------------------------------------------
consumer_parse() {  # <sid> -> JSON array as printed by the CLI
  run_with_timeout node "$PARSE_CLI_N" --session "$1" --plans-dir "$PLANS_DIR_N" 2>/dev/null
}

# Numbers as rendered into the Final Report's <CLOSED_ISSUES_LIST> section.
consumer_render_numbers() {  # <sid>
  local sid="$1" out
  seed_control "$sid"
  out="$(run_with_timeout node "$RENDER_CLI_N" "$sid" "$(ctl "$sid" final-report-env.json)" \
    "$(ctl "$sid" issue-close-outcome.json)" "$PLANS_DIR_N/${sid}-intent.md" 2>/dev/null)" || true
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
# FINDING (pinned CURRENT behavior): getClosesIssues() returns a legacy bare
# number array verbatim. parse-closes-issues passes numbers through and
# issue-close-write-outcome handles `typeof entry === "number"`, but
# render-final-report maps `e.number` with no numeric branch and renders
# "- #undefined" -- the C9 asymmetry, asserted as-is (source untouched).
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
seed_control "$SID_E"
RENDER_FULL="$(run_with_timeout node "$RENDER_CLI_N" "$SID_E" "$(ctl "$SID_E" final-report-env.json)" \
  "$(ctl "$SID_E" issue-close-outcome.json)" "$PLANS_DIR_N/${SID_E}-intent.md" 2>&1)" || true
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
echo "=== C9-6: #2434 render-final-report derives control files from --session ==="
R6_ENV='{"PR_NUMBER":"2434","PR_TITLE":"Derived title","BRANCH":"feature/x"}'
R6_RC=0; R6_OUT=""
render6() {  # argv... -> sets R6_RC / R6_OUT
  R6_RC=0
  R6_OUT="$(run_with_timeout node "$RENDER_CLI_N" "$@" 2>/dev/null)" || R6_RC=$?
}

# --session reads env/outcome from <sid>.control and intent from PLANS.
S6A="c96sess"; seed_control "$S6A" "$R6_ENV"; write_intent "$S6A" "#1644"
render6 --session "$S6A"
check "C9-6a: --session exits 0" "0" "$R6_RC"
check_contains "C9-6a: --session renders the derived env PR line" "- PR #2434: Derived title" "$R6_OUT"
check_contains "C9-6a: --session renders the PLANS intent issue" "- #1644" "$R6_OUT"

# Only the legacy <plans>/<sid>-final-report-env.json exists: migrated, then read.
S6B="c96mig"; write_intent "$S6B" "#1655"
printf '%s' "$R6_ENV" > "$PLANS_DIR/${S6B}-final-report-env.json"
render6 --session "$S6B"
check "C9-6b: --session with a legacy PLANS env exits 0" "0" "$R6_RC"
check_contains "C9-6b: legacy PLANS env content is rendered" "- PR #2434: Derived title" "$R6_OUT"
if [ -f "$WORKFLOW_DIR/$S6B.control/final-report-env.json" ]; then
  pass "C9-6b: legacy PLANS env migrated to the derived control path"
else
  fail "C9-6b: legacy PLANS env migrated to the derived control path -- derived file absent"
fi

# --session with no env anywhere fails (no silent empty report).
S6C="c96noenv"; write_intent "$S6C" "#1644"
render6 --session "$S6C"
if [ "$R6_RC" -ne 0 ]; then pass "C9-6c: --session with a missing env exits non-zero"
else fail "C9-6c: --session with a missing env exits non-zero -- got 0"; fi

# Legacy positional equal to the derived path: accepted (shim).
S6D="c96legd"; seed_control "$S6D" "$R6_ENV"; write_intent "$S6D" "#1644"
render6 "$S6D" "$(ctl "$S6D" final-report-env.json)" "$(ctl "$S6D" issue-close-outcome.json)" \
  "$PLANS_DIR_N/${S6D}-intent.md"
check "C9-6d: legacy derived positional exits 0" "0" "$R6_RC"
check_contains "C9-6d: legacy derived positional renders the env" "- PR #2434: Derived title" "$R6_OUT"

# Legacy positional with the <sid>-final-report-env.json basename: accepted, read via derived.
S6E="c96legb"; write_intent "$S6E" "#1644"
printf '%s' "$R6_ENV" > "$PLANS_DIR/${S6E}-final-report-env.json"
render6 "$S6E" "$PLANS_DIR_N/${S6E}-final-report-env.json"
check "C9-6e: legacy PLANS-basename positional exits 0" "0" "$R6_RC"
check_contains "C9-6e: legacy PLANS-basename positional renders the env" "- PR #2434" "$R6_OUT"
if [ -f "$WORKFLOW_DIR/$S6E.control/final-report-env.json" ]; then
  pass "C9-6e: legacy PLANS-basename positional lands at the derived control path"
else
  fail "C9-6e: legacy PLANS-basename positional lands at the derived control path -- derived file absent"
fi

# Legacy positionals that match neither rule: rejected, nothing rendered.
S6F="c96rej"; S6O="c96other"; write_intent "$S6F" "#1644"
seed_control "$S6O" "$R6_ENV"
printf '%s' "$R6_ENV" > "$TMPDIR_BASE/env.json"
printf '%s' "$R6_ENV" > "$PLANS_DIR/${S6O}-final-report-env.json"
while IFS='|' read -r label envarg; do
  [ -n "$label" ] || continue
  render6 "$S6F" "$envarg"
  if [ "$R6_RC" -ne 0 ]; then pass "C9-6f: rejected legacy env ($label)"
  else fail "C9-6f: rejected legacy env ($label) -- accepted with exit 0"; fi
  check_not_contains "C9-6f: nothing rendered for $label" "- PR #2434" "$R6_OUT"
done <<EOF
other-sid-control|$(ctl "$S6O" final-report-env.json)
other-sid-plans|$PLANS_DIR_N/${S6O}-final-report-env.json
arbitrary-path|$(nrm "$TMPDIR_BASE/env.json")
EOF

# Invalid or missing sid is rejected on the --session form.
while IFS='|' read -r label sid; do
  [ -n "$label" ] || continue
  if [ "$sid" = "@MISSING@" ]; then render6 --session; else render6 --session "$sid"; fi
  if [ "$R6_RC" -ne 0 ]; then pass "C9-6g: invalid sid rejected ($label)"
  else fail "C9-6g: invalid sid rejected ($label) -- exit 0"; fi
  check "C9-6g: invalid sid renders nothing ($label)" "" "$R6_OUT"
done <<'EOF'
traversal|../c96sess
space|a b
empty|
missing|@MISSING@
EOF

# SKILL.md wiring: the render call passes --session and no control paths.
R6_LINE="$(grep -F 'render-final-report.js' "$SKILL_MD" | head -1)"
check_contains "C9-6h: SKILL render-final-report call passes --session" "--session" "$R6_LINE"
check_not_contains "C9-6h: SKILL render-final-report call passes no control path" "<CONTROL_DIR>/" "$R6_LINE"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
