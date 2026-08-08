#!/usr/bin/env bash
# Tests: hooks/workflow-state/session-facts.js, hooks/lib/parse-closes-issues.js, bin/workflow/next-step, bin/workflow/lib/next-step/verdict.js, hooks/workflow-state/state-io/projection.js
# Tags: tl2, workflow, session-facts, closes-issues, caching, scope:issue-specific
#
# #1644 stage 4 — 型2: セッション内キャッシュの一度きり解決.
#
# session-facts.js wraps parseClosesIssues() with a write-once cache stored in
# the EXISTING `closes_issues` top-level state key: once state.closes_issues is
# non-empty, getClosesIssues() must return it as-is and never touch intent.md
# again. getSessionRepoContext() is a read-only synthesis over the existing
# `session_start_context` key -- it never writes.
# Written BEFORE the implementation: RED until hooks/workflow-state/session-facts.js lands.
#
# TL3 gap (what this test does NOT catch):
# - Whether workflow-init-driver (Path A/B/META) and skills/clarify-intent (Path
#   C's CI-4) actually call getClosesIssues at the call sites the plan names,
#   rather than continuing to call parseClosesIssues directly.
# - Whether the migrated consumers (session-title.js, render-final-report.js,
#   issue-close-write-outcome.js) were actually switched over.
# Closest-to-action mitigation: covered by the stage-4 implementation's own
# call-site tests, not this contract-level file.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"
SF_MODULE_N="$AGENTS_DIR_N/hooks/workflow-state/session-facts.js"
WFSTATE_MODULE_N="$AGENTS_DIR_N/hooks/workflow-state"
NEXT_STEP_N="$AGENTS_DIR_N/bin/workflow/next-step"
PARSE_CLI_N="$AGENTS_DIR_N/bin/parse-closes-issues"

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
# Pinned as a PAIR (#1799): a lone CLAUDE_WORKFLOW_DIR would still let
# supervisor-emit append to the developer's real ~/.workflow-plans.
export CLAUDE_WORKFLOW_DIR="$(nrm "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"
PLANS_DIR_N="$(nrm "$PLANS_DIR")"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

CONFIG_EMPTY="$TMPDIR_BASE/cfg-empty"; mkdir -p "$CONFIG_EMPTY"; : > "$CONFIG_EMPTY/.env"
export AGENTS_CONFIG_DIR="$(nrm "$CONFIG_EMPTY")"

FIXTURE_REPO="$TMPDIR_BASE/repo"; mkdir -p "$FIXTURE_REPO"
git init -q "$FIXTURE_REPO" >/dev/null 2>&1
git -C "$FIXTURE_REPO" config core.hooksPath /dev/null
export CLAUDE_PROJECT_DIR="$(nrm "$FIXTURE_REPO")"
cd "$FIXTURE_REPO" || exit 1

# --- fixture builders -------------------------------------------------------
STEPS_ALL="workflow_init clarify_intent research outline detail branching_complete write_tests review_tests run_tests review_security docs user_verification cleanup pre_final_report_gate final_report"

# fixture_state <sid> "<complete steps>" <cwd> <branch> [closes_issues-json]
# v1-shaped raw fixture (no "version"/"events") -- normalizeStateVersion
# migrates it to v2 on every read, always synthesizing session_start_context
# from cwd/git_branch. closes_issues is OMITTED entirely (not just []) unless
# the 5th arg is given, matching the "not yet recorded" precondition.
fixture_state() {
  local sid="$1" complete="$2" cwd="$3" branch="$4" issues="${5:-}"
  local json='{"steps":{' first=1 s st
  for s in $STEPS_ALL; do
    st="pending"; case " $complete " in *" $s "*) st="complete" ;; esac
    [ $first -eq 1 ] || json="$json,"; first=0
    json="$json\"$s\":{\"status\":\"$st\"}"
  done
  json="$json},\"cwd\":\"$cwd\",\"git_branch\":\"$branch\""
  if [ -n "$issues" ]; then json="$json,\"closes_issues\":$issues"; fi
  printf '%s' "$json}" > "$WORKFLOW_DIR/${sid}.json"
}

# write_intent <sid> <issue-token...> -- writes the "## Issues" SSOT section.
write_intent() {
  local sid="$1"; shift
  { echo "## Issues"; for tok in "$@"; do echo "- $tok"; done; } > "$PLANS_DIR/${sid}-intent.md"
}
rm_intent() { rm -f "$PLANS_DIR/${1}-intent.md"; }

# --- probes ------------------------------------------------------------------
GCI_PROBE="$TMPDIR_BASE/gci-probe.js"
cat > "$GCI_PROBE" <<'EOF'
const m = require(process.env.SF_MODULE);
const r = m.getClosesIssues(process.env.SF_SID, { plansDir: process.env.SF_PLANS_DIR });
process.stdout.write(JSON.stringify(r));
EOF

GRC_PROBE="$TMPDIR_BASE/grc-probe.js"
cat > "$GRC_PROBE" <<'EOF'
const m = require(process.env.SF_MODULE);
const r = m.getSessionRepoContext(process.env.SF_SID);
process.stdout.write(JSON.stringify(r));
EOF

RAWCLOSES_PROBE="$TMPDIR_BASE/rawcloses-probe.js"
cat > "$RAWCLOSES_PROBE" <<'EOF'
const wf = require(process.env.WFM);
const st = wf.readState(process.env.SF_SID);
const v = st && st.closes_issues !== undefined ? st.closes_issues : null;
process.stdout.write(JSON.stringify(v));
EOF

TOPKEYS_PROBE="$TMPDIR_BASE/topkeys-probe.js"
cat > "$TOPKEYS_PROBE" <<'EOF'
const wf = require(process.env.WFM);
process.stdout.write(JSON.stringify(wf.PERSISTED_TOP_LEVEL_KEYS.slice().sort()));
EOF

gci() { SF_MODULE="$SF_MODULE_N" SF_SID="$1" SF_PLANS_DIR="$PLANS_DIR_N" run_with_timeout node "$GCI_PROBE" 2>/dev/null || echo ""; }
grc() { SF_MODULE="$SF_MODULE_N" SF_SID="$1" run_with_timeout node "$GRC_PROBE" 2>/dev/null || echo ""; }
raw_closes() { WFM="$WFSTATE_MODULE_N" SF_SID="$1" run_with_timeout node "$RAWCLOSES_PROBE" 2>/dev/null || echo ""; }
parse_direct() { run_with_timeout node "$PARSE_CLI_N" "$PLANS_DIR/${1}-intent.md" 2>/dev/null || echo "[]"; }
raw_file_bytes() { cat "$WORKFLOW_DIR/${1}.json" 2>/dev/null || echo ""; }

# run_ns <args...> -- invoke bin/workflow/next-step, capturing stdout/stderr/rc.
NS_OUT=""
run_ns() {
  NS_OUT="$(run_with_timeout node "$NEXT_STEP_N" "$@" 2>/dev/null)" || true
}

echo "=== G1: module exists (sanity gate -- RED until session-facts.js lands) ==="
if [ -f "$AGENTS_DIR/hooks/workflow-state/session-facts.js" ]; then
  pass "G1: hooks/workflow-state/session-facts.js exists"
else
  fail "G1: hooks/workflow-state/session-facts.js exists -- file not found"
fi

echo ""
echo "=== G2: Path A/B/META -- once issues are finalized, closes_issues is recorded into state ==="
fixture_state g2 "workflow_init clarify_intent" "$FIXTURE_REPO" "feature/roundtrip-reduction"
write_intent g2 "#1644" "#1655"
OUT="$(gci g2)"
check "G2a: getClosesIssues returns the parsed issue set" \
  '[{"number":1644},{"number":1655}]' "$OUT"
check "G2b: the result is now recorded into state.closes_issues" \
  '[{"number":1644},{"number":1655}]' "$(raw_closes g2)"

echo ""
echo "=== G3: after recording, deleting intent.md does not change the result (cache, not re-parse) ==="
rm_intent g2
OUT2="$(gci g2)"
check "G3: getClosesIssues after intent.md is removed still returns the recorded set" \
  '[{"number":1644},{"number":1655}]' "$OUT2"

echo ""
echo "=== G4: an unrecorded session parses intent.md exactly once ==="
fixture_state g4 "workflow_init clarify_intent" "$FIXTURE_REPO" "feature/roundtrip-reduction"
write_intent g4 "#1644"
FIRST="$(gci g4)"
check "G4a: first call records the issue parsed from intent.md" '[{"number":1644}]' "$FIRST"
BEFORE="$(raw_file_bytes g4)"
# Mutate intent.md to a DIFFERENT issue set. A caller that re-parses on every
# call would now return #9999; a caller honoring the write-once cache must
# keep returning the value it already recorded.
write_intent g4 "#9999"
SECOND="$(gci g4)"
check "G4b: a second call ignores the mutated intent.md and returns the cached set" \
  '[{"number":1644}]' "$SECOND"
AFTER="$(raw_file_bytes g4)"
check "G4c: the on-disk state file was not rewritten between the two calls" \
  "$BEFORE" "$AFTER"

echo ""
echo "=== G5: the recorded content matches parseClosesIssues() itself for the same intent.md ==="
fixture_state g5 "workflow_init clarify_intent" "$FIXTURE_REPO" "feature/roundtrip-reduction"
write_intent g5 "#1644" "repo#42"
DIRECT="$(parse_direct g5)"
VIA_FACTS="$(gci g5)"
check "G5: getClosesIssues agrees with parseClosesIssues on the same intent.md" "$DIRECT" "$VIA_FACTS"

echo ""
echo "=== G6: Path C regression -- the pre-existing closes_issues-empty gate is unchanged ==="
fixture_state g6 "workflow_init" "$FIXTURE_REPO" "feature/roundtrip-reduction"
run_ns --session g6
check_contains "G6a: before intent.md exists, next-step is blocked on closes_issues-empty (CURRENT behavior, unchanged by stage 4)" \
  "REASON='closes_issues-empty'" "$NS_OUT"
# CI-4-equivalent recording point: intent.md now exists, and clarify-intent
# would call getClosesIssues right after writing it.
write_intent g6 "#1644"
gci g6 >/dev/null
run_ns --session g6
check_not_contains "G6b: after the CI-4-equivalent recording point, the blocked state clears" \
  "REASON='closes_issues-empty'" "$NS_OUT"

echo ""
echo "=== G7: getSessionRepoContext is read-only over session_start_context ==="
fixture_state g7 "workflow_init clarify_intent" "$FIXTURE_REPO" "feature/roundtrip-reduction"
BEFORE="$(raw_file_bytes g7)"
CTX="$(grc g7)"
check "G7a: getSessionRepoContext synthesizes cwd/git_branch from session_start_context" \
  "$(printf '{"cwd":"%s","git_branch":"feature/roundtrip-reduction"}' "$FIXTURE_REPO")" "$CTX"
check "G7b: getSessionRepoContext performs no write" "$BEFORE" "$(raw_file_bytes g7)"

echo ""
echo "=== G8: stage 4 introduces no new persisted top-level state key ==="
# Baseline captured from hooks/workflow-state/state-io/projection.js
# PERSISTED_TOP_LEVEL_KEYS as of the start of stage 4 (#1644). The storage
# mapping decided for this stage reuses closes_issues / session_worktree /
# session_start_context -- none of which are new -- so this list must be
# byte-for-byte unchanged after the implementation lands.
BASELINE='["closes_issues","created_at","current","events","last_pushed_sha","merge_base_baseline","session_id","session_start_context","session_worktree","verbose_prompt","version","workflow_type"]'
ACTUAL="$(WFM="$WFSTATE_MODULE_N" run_with_timeout node "$TOPKEYS_PROBE" 2>/dev/null || echo "")"
check "G8: PERSISTED_TOP_LEVEL_KEYS is unchanged from the pre-stage-4 baseline" "$BASELINE" "$ACTUAL"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
