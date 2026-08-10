#!/usr/bin/env bash
# Tests: hooks/workflow-state/plan-skip-allowance.js, hooks/gate-plan-skip-sentinel.js, bin/workflow/lib/next-step/advance.js, hooks/workflow-state/record-step-verdict.js
# Tags: tl1, tl2, static, workflow, advance, skip-allowance, ssot, scope:issue-specific
#
# #1644 — one skip-allowance policy, two callers.
#
# Why: after this change a plan step can be skipped through two doors — the
# sentinel the model echoes (gated by hooks/gate-plan-skip-sentinel.js) and the
# CLI's --advance --status skipped. If each door carried its own copy of "is
# this skip permitted", the two would drift and the stricter one would become
# advisory. Both must read the same module.
#
# The two paths deliberately differ in ONE respect: the sentinel path reads
# process.env (the hook runs inside the session's environment), while the CLI
# path must read the config FILE only — an inline `CONFIRM_TESTS=off <cmd>`
# prefix is model-issued text and must never be self-approval (#1644 A16).
# Written BEFORE the implementation: RED until plan-skip-allowance.js lands.
#
# TL3 gap (what this test does NOT catch):
# - Whether the real Claude Code PreToolUse registration actually routes the
#   sentinel command to gate-plan-skip-sentinel.js in a live session.
# Closest-to-action mitigation: surfaced at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"
MODULE="hooks/workflow-state/plan-skip-allowance.js"
MODULE_N="$AGENTS_DIR_N/$MODULE"
GATE_N="$AGENTS_DIR_N/hooks/gate-plan-skip-sentinel.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- expected [$2] got [$3]"; fi; }

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
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

# Empty config dir: no CONFIRM_* is inherited from the repo's own .env.
CONFIG_EMPTY="$TMPDIR_BASE/cfg-empty"; mkdir -p "$CONFIG_EMPTY"; : > "$CONFIG_EMPTY/.env"
CONFIG_TESTS_OFF="$TMPDIR_BASE/cfg-tests-off"; mkdir -p "$CONFIG_TESTS_OFF"
printf 'CONFIRM_TESTS=off\n' > "$CONFIG_TESTS_OFF/.env"
export AGENTS_CONFIG_DIR="$(nrm "$CONFIG_EMPTY")"

FIXTURE_REPO="$TMPDIR_BASE/repo"; mkdir -p "$FIXTURE_REPO"
git init -q "$FIXTURE_REPO" >/dev/null 2>&1
git -C "$FIXTURE_REPO" config core.hooksPath /dev/null
export CLAUDE_PROJECT_DIR="$(nrm "$FIXTURE_REPO")"
cd "$FIXTURE_REPO" || exit 1

STEPS_ALL="workflow_init clarify_intent research outline detail branching_complete write_tests review_tests write_code run_tests review_security docs user_verification cleanup pre_final_report_gate final_report"
make_state() {
  local sid="$1" complete="$2" json='{"steps":{' first=1 s st
  for s in $STEPS_ALL; do
    st="pending"; case " $complete " in *" $s "*) st="complete" ;; esac
    [ $first -eq 1 ] || json="$json,"; first=0
    json="$json\"$s\":{\"status\":\"$st\"}"
  done
  printf '%s' "$json},\"closes_issues\":[1644]}" > "$WORKFLOW_DIR/${sid}.json"
}

echo "=== P1: both doors require the same allowance module ==="
if [ -f "$AGENTS_DIR/$MODULE" ]; then pass "P1a: $MODULE exists"
else fail "P1a: $MODULE exists -- file not found"; fi

if grep -qF 'plan-skip-allowance' "$AGENTS_DIR/hooks/gate-plan-skip-sentinel.js"; then pass "P1b: the sentinel gate requires plan-skip-allowance"
else fail "P1b: the sentinel gate requires plan-skip-allowance -- no reference found"; fi

# The advance path's require may sit in advance.js or in record-step-verdict.js
# (the #1644 plan names both owners, at line 508 and line 45 respectively), so
# the assertion is on the path as a whole: at least one of the two must hold it,
# and no third copy of the policy may exist.
ADV_HOLDERS=0
for f in bin/workflow/lib/next-step/advance.js hooks/workflow-state/record-step-verdict.js; do
  if [ -f "$AGENTS_DIR/$f" ] && grep -qF 'plan-skip-allowance' "$AGENTS_DIR/$f"; then
    ADV_HOLDERS=$((ADV_HOLDERS + 1))
  fi
done
if [ "$ADV_HOLDERS" -ge 1 ]; then pass "P1c: the advance path requires plan-skip-allowance"
else fail "P1c: the advance path requires plan-skip-allowance -- neither advance.js nor record-step-verdict.js references it"; fi

echo ""
echo "=== P2: isSkipAllowedForCliPath never consults process.env ==="
if [ -f "$AGENTS_DIR/$MODULE" ]; then
  BODY="$(awk '/function isSkipAllowedForCliPath/,/^}/' "$AGENTS_DIR/$MODULE")"
  if [ -z "$BODY" ]; then
    fail "P2a: isSkipAllowedForCliPath is defined in $MODULE -- function not found"
  elif printf '%s' "$BODY" | grep -qF 'process.env'; then
    fail "P2a: isSkipAllowedForCliPath must not read process.env -- found a reference in its body"
  else
    pass "P2a: isSkipAllowedForCliPath does not read process.env"
  fi
  # Symmetric control: the sentinel-path function is SUPPOSED to read process.env.
  # Without this, P2a would also pass on a module where both functions vanished.
  SBODY="$(awk '/function isSkipAllowedForSentinelPath/,/^}/' "$AGENTS_DIR/$MODULE")"
  if printf '%s' "$SBODY" | grep -qF 'process.env'; then
    pass "P2b: isSkipAllowedForSentinelPath does read process.env (asymmetry is intended)"
  else
    fail "P2b: isSkipAllowedForSentinelPath does read process.env -- the two paths are no longer distinguishable"
  fi
else
  fail "P2a: isSkipAllowedForCliPath does not read process.env -- $MODULE not found"
  fail "P2b: isSkipAllowedForSentinelPath does read process.env -- $MODULE not found"
fi

echo ""
echo "=== P3: an inline env prefix cannot open the CLI door ==="
make_state p3 "workflow_init clarify_intent research"
CLI_PROBE="$TMPDIR_BASE/cli-probe.js"
cat > "$CLI_PROBE" <<'EOF'
const m = require(process.env.PSA_MODULE);
const r = m.isSkipAllowedForCliPath(process.env.PSA_SID, process.env.PSA_STEP);
process.stdout.write(String(r === true));
EOF
RC=0
OUT="$(PSA_MODULE="$MODULE_N" PSA_SID=p3 PSA_STEP=write_tests CONFIRM_TESTS=off \
  run_with_timeout node "$CLI_PROBE" 2>/dev/null)" || RC=$?
check "P3a: env-only CONFIRM_TESTS=off does NOT allow the CLI skip" "false" "$OUT"
RC=0
OUT="$(PSA_MODULE="$MODULE_N" PSA_SID=p3 PSA_STEP=write_tests \
  AGENTS_CONFIG_DIR="$(nrm "$CONFIG_TESTS_OFF")" run_with_timeout node "$CLI_PROBE" 2>/dev/null)" || RC=$?
check "P3b: config-file CONFIRM_TESTS=off DOES allow the CLI skip" "true" "$OUT"

echo ""
echo "=== P4: the hook's verdict and isSkipAllowedForSentinelPath agree ==="
SENT_PROBE="$TMPDIR_BASE/sent-probe.js"
cat > "$SENT_PROBE" <<'EOF'
const m = require(process.env.PSA_MODULE);
const r = m.isSkipAllowedForSentinelPath(process.env.PSA_SID, process.env.PSA_STEP);
process.stdout.write(r === true ? "allow" : "deny");
EOF

# hook_verdict <sid> <sentinel-command> [env assignments...]
hook_verdict() {
  local sid="$1" cmd="$2"; shift 2
  local payload out
  payload="$(printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$sid" "$cmd")"
  # Exports in a subshell, not `env`: run_with_timeout is a shell function and
  # `env` can only exec a real binary.
  out="$(printf '%s' "$payload" | (
    export WORKFLOW_SESSION_ID="$sid"
    for kv in "$@"; do export "${kv?}"; done
    run_with_timeout node "$GATE_N"
  ) 2>/dev/null)" || out=""
  case "$out" in
    *'"permissionDecision":"allow"'*) echo allow ;;
    *) echo deny ;;
  esac
}
module_verdict() {
  local sid="$1" step="$2"; shift 2
  (
    export PSA_MODULE="$MODULE_N" PSA_SID="$sid" PSA_STEP="$step"
    for kv in "$@"; do export "${kv?}"; done
    run_with_timeout node "$SENT_PROBE"
  ) 2>/dev/null || echo "PROBE_FAIL"
}

# Case 1 — outline, no recorded verdict and no CONFIRM_OUTLINE: both must refuse.
make_state p4a "workflow_init clarify_intent research"
H="$(hook_verdict p4a 'echo \"<<WORKFLOW_OUTLINE_NOT_NEEDED: single known file>>\"')"
M="$(module_verdict p4a outline)"
check "P4a: outline with no recorded verdict -- hook says deny" "deny" "$H"
check "P4a: outline with no recorded verdict -- module agrees with the hook" "$H" "$M"

# Case 2 — detail with a recorded orchestrator verdict: both must allow.
make_state p4b "workflow_init clarify_intent research outline"
# hasValidSkipJudgment requires the upstream artifact to exist and to be no newer
# than the recording (a stale verdict must not authorize a skip), so the artifact
# has to be in place BEFORE the judgment is written.
printf '# outline\n' > "$PLANS_DIR/p4b-outline.md"
run_with_timeout node "$AGENTS_DIR_N/bin/workflow/record-skip-judgment" \
  --session p4b --target detail --c1 true --c2 true --c3 true >/dev/null 2>&1
H="$(hook_verdict p4b 'echo \"<<WORKFLOW_DETAIL_NOT_NEEDED: recorded verdict satisfied>>\"')"
M="$(module_verdict p4b detail)"
check "P4b: detail with a recorded verdict -- hook says allow" "allow" "$H"
check "P4b: detail with a recorded verdict -- module agrees with the hook" "$H" "$M"

# Case 3 — write_tests with CONFIRM_TESTS=off in the environment: both must allow.
make_state p4c "workflow_init clarify_intent research outline detail branching_complete"
H="$(hook_verdict p4c 'echo \"<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: docs-only change>>\"' CONFIRM_TESTS=off)"
M="$(module_verdict p4c write_tests CONFIRM_TESTS=off)"
check "P4c: write_tests with CONFIRM_TESTS=off -- hook says allow" "allow" "$H"
check "P4c: write_tests with CONFIRM_TESTS=off -- module agrees with the hook" "$H" "$M"

echo ""
echo "=== P5: the CLI door reads the same recorded-judgment axis as the sentinel door ==="
# P3 exercised the ONE axis on which the two doors are supposed to differ (env vs
# config file). This case covers the other axis — a recorded orchestrator verdict —
# where they must NOT differ: the asymmetry is about how much the ENVIRONMENT is
# trusted, never about what counts as a permitted skip. Without this, "one policy,
# two callers" is only proven for the sentinel door (P4b).
cli_verdict() {
  local sid="$1" step="$2"; shift 2
  (
    export PSA_MODULE="$MODULE_N" PSA_SID="$sid" PSA_STEP="$step"
    for kv in "$@"; do export "${kv?}"; done
    run_with_timeout node "$CLI_PROBE"
  ) 2>/dev/null || echo "PROBE_FAIL"
}

# Case 1 — detail WITH a recorded orchestrator verdict.
make_state p5a "workflow_init clarify_intent research outline"
printf '# outline\n' > "$PLANS_DIR/p5a-outline.md"
run_with_timeout node "$AGENTS_DIR_N/bin/workflow/record-skip-judgment" \
  --session p5a --target detail --c1 true --c2 true --c3 true >/dev/null 2>&1
C="$(cli_verdict p5a detail)"
check "P5a: detail with a recorded verdict -- the CLI door allows the skip" "true" "$C"
# ...and the two doors reach the same answer from the same recorded fact.
M="$(module_verdict p5a detail)"
check "P5a: the CLI door and the sentinel door agree" \
  "$(if [ "$M" = "allow" ]; then echo true; else echo false; fi)" "$C"

# Case 2 — same step, NO recorded verdict. The plan leaves the unconditional-vs-
# judgment-gated question open for outline/detail on the CLI door (detail plan
# line 182 vs line 184), so this arm deliberately asserts only that the two doors
# stay in agreement rather than pinning a verdict the plan has not decided.
make_state p5b "workflow_init clarify_intent research outline"
C="$(cli_verdict p5b detail)"
M="$(module_verdict p5b detail)"
check "P5b: with no recorded verdict the two doors still agree" \
  "$(if [ "$M" = "allow" ]; then echo true; else echo false; fi)" "$C"
# Control: P5a would also pass on a module that returns true for everything, so
# pin a step the plan refuses unconditionally on the CLI door (detail plan line
# 185: clarify_intent has no CLI-side approval route at all).
C="$(cli_verdict p5a clarify_intent)"
check "P5c: the CLI door refuses clarify_intent even in a session with a recorded verdict" \
  "false" "$C"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
